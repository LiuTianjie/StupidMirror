import AppKit
import SceneKit
import simd

/// Device Hub's V68 mesh and original articulated book_close clip. Both
/// renderers keep the entire chassis on the GPU across all three postures.
struct DuoModelAsset: Codable, Sendable {
    struct Part: Codable, Sendable {
        let offset: Int
        let count: Int
        let color: [Float]
        /// 0 = chassis, 1 = inner display, 2 = cover display.
        let screen: Int
    }
    let id: String
    let vertexCount: Int
    let jointCount: Int
    let sampleCount: Int
    let positions: Data
    let texcoords: Data
    let joints: Data
    let weights: Data
    let indices: Data
    let poses: Data
    let bounds: Data
    let parts: [Part]
    enum CodingKeys: String, CodingKey {
        case id, positions, texcoords, joints, weights, indices, poses, bounds, parts
        case vertexCount = "vertex_count", jointCount = "joint_count", sampleCount = "sample_count"
    }
}

struct DuoModelPose: Codable, Equatable, Sendable {
    let modelID: String
    let angle: Double
    /// Physical clockwise rotation, shared by the inner and cover panels.
    let orientation: Double
    let screen: Int
    let frameAspectRatio: Double
    let screenReady: Bool
    enum CodingKeys: String, CodingKey {
        case angle, orientation, screen
        case modelID = "model_id", frameAspectRatio = "frame_aspect_ratio", screenReady = "screen_ready"
    }
}

/// Critically damped motion keeps its velocity when the target changes.
/// It advances at display refresh, independently of video and WDA polling.
struct DuoPoseSpring {
    var value: Double
    var velocity = 0.0
    mutating func advance(to target: Double, elapsed: Double) -> Bool {
        let dt = min(max(elapsed, 0), 0.05), omega = 16.0
        let offset = value - target, carry = velocity + omega * offset, decay = exp(-omega * dt)
        value = target + (offset + carry * dt) * decay
        velocity = (velocity - omega * carry * dt) * decay
        if abs(value - target) < 0.015 && abs(velocity) < 0.15 {
            value = target; velocity = 0
            return false
        }
        return true
    }
}

@MainActor
final class DuoModelRenderer {
    static let shared = DuoModelRenderer()
    let asset: DuoModelAsset
    private let positions: [SIMD3<Float>]
    private let texcoords: [SIMD2<Float>]
    private let weights: [SIMD8<Float>]
    private let joints: [SIMD8<UInt16>]
    private let indices: [UInt32]
    private let poses: [simd_float4x4]
    private let bounds: [SIMD4<Float>]
    private var cachedBezel: (DuoModelPose, MirrorBezel)?

    private init?() {
        guard let url = DeviceKitResources.duoBundle?.url(forResource: "V68", withExtension: "usdz"),
              let scene = try? SCNScene(url: url, options: nil),
              let built = Self.load(scene) else { return nil }
        positions = built.positions; texcoords = built.texcoords
        weights = built.weights; joints = built.joints; indices = built.indices
        poses = built.poses; bounds = built.bounds
        // This revision describes our binary layout. The installed Xcode
        // supplies the asset; no Apple model is bundled with the plugin.
        asset = DuoModelAsset(
            id: "devicehub-v68-rig-1", vertexCount: positions.count,
            jointCount: built.jointCount, sampleCount: bounds.count,
            positions: Self.data(positions.flatMap { [$0.x, $0.y, $0.z] }),
            texcoords: Self.data(texcoords.flatMap { [$0.x, $0.y] }),
            joints: Self.data(joints.flatMap { value in (0..<8).map { value[$0] } }),
            weights: Self.data(weights.flatMap { value in (0..<8).map { value[$0] } }),
            indices: Self.data(indices),
            poses: Self.data(poses.flatMap { m in (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } } }),
            bounds: Self.data(bounds.flatMap { [$0.x, $0.y, $0.z, $0.w] }), parts: built.parts
        )
    }

    func bezel(display: SimulatorDisplayState?, aspectRatio: Double = 1398.0 / 2034,
               requestedPosture: DevicePosture? = nil,
               changingPosture: Bool = false, isRunning: Bool = true) -> MirrorBezel {
        // Discovery and thumbnails precede the runner's display metadata.
        // Use the real chassis immediately; this visual estimate never becomes
        // a confirmed simulator posture or a control coordinate source.
        let confirmedDisplay = display != nil
        let display = display ?? Self.previewDisplay(aspectRatio: aspectRatio)
        let angle = min(max(requestedPosture?.hingeAngle ?? display.hingeAngle ?? 180, 0), 180)
        let screen = requestedPosture.map { $0 == .closed ? 2 : 1 } ?? (display.activeScreen == "outer" ? 2 : 1)
        let raw: Double
        switch display.orientation {
        case "rot90": raw = 90
        case "rot180": raw = 180
        case "rot270": raw = 270
        default: raw = 0
        }
        let orientation = (raw + (display.activeScreen == "inner" ? 270 : 0)).truncatingRemainder(dividingBy: 360)
        let frameOrientation = (orientation + (screen == 1 ? 90 : 0)).truncatingRemainder(dividingBy: 360)
        let portraitAspect = screen == 1 ? 2007.0 / 2853 : 1398.0 / 2034
        let aspect = frameOrientation == 90 || frameOrientation == 270 ? 1 / portraitAspect : portraitAspect
        let pose = DuoModelPose(modelID: asset.id, angle: angle, orientation: orientation, screen: screen,
                                frameAspectRatio: aspect, screenReady: confirmedDisplay && isRunning && !changingPosture)
        if let cachedBezel, cachedBezel.0 == pose { return cachedBezel.1 }
        let rect = framing(angle: angle, orientation: orientation)
        let size = CGSize(width: rect.width * 100, height: rect.height * 100)
        let mesh = screenMesh(pose: pose, viewport: size)
        let xs = mesh.vertices.map { $0[0] }, ys = mesh.vertices.map { $0[1] }
        let screenRect = CGRect(x: (xs.min() ?? 0) * size.width, y: (ys.min() ?? 0) * size.height,
                                width: ((xs.max() ?? 1) - (xs.min() ?? 0)) * size.width,
                                height: ((ys.max() ?? 1) - (ys.min() ?? 0)) * size.height)
        let bezel = MirrorBezel(id: "\(asset.id)|\(angle)|\(orientation)|\(screen)", size: size,
                                screenRect: screenRect, artwork: NSImage(size: size), screenMask: nil,
                                mesh: mesh, duo: pose)
        cachedBezel = (pose, bezel)
        return bezel
    }

    private static func previewDisplay(aspectRatio: Double) -> SimulatorDisplayState {
        let aspect = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1398.0 / 2034
        let portraitAspect = min(aspect, 1 / aspect)
        let inner = abs(portraitAspect - 2007.0 / 2853) < abs(portraitAspect - 1398.0 / 2034)
        return SimulatorDisplayState(
            displayID: inner ? 3 : 1,
            nativeWidth: inner ? 2007 : 1398, nativeHeight: inner ? 2853 : 2034,
            pointScale: 3, orientation: aspect > 1 ? "rot90" : "rot0",
            foldable: true, hingeAngle: inner ? 180 : 0, posture: inner ? .open : .closed
        )
    }

    func matrices(angle: Double) -> [simd_float4x4] {
        let step = min(max(angle, 0), 180) / 180 * Double(asset.sampleCount - 1)
        let lower = Int(step), upper = min(lower + 1, asset.sampleCount - 1), t = Float(step - Double(lower))
        return (0..<asset.jointCount).map { index in
            let a = poses[lower * asset.jointCount + index], b = poses[upper * asset.jointCount + index]
            return simd_float4x4(a.columns.0 + (b.columns.0 - a.columns.0) * t,
                                a.columns.1 + (b.columns.1 - a.columns.1) * t,
                                a.columns.2 + (b.columns.2 - a.columns.2) * t,
                                a.columns.3 + (b.columns.3 - a.columns.3) * t)
        }
    }

    static func modelTransform(angle: Double, orientation: Double) -> simd_float4x4 {
        // Follow the cover at the closed end; by the half-open preset we face
        // the articulated inner screen, matching Device Hub's preset views.
        let t = Float(min(max(angle / 130, 0), 1))
        let cover = -Float.pi / 2 * (1 - t * t * (3 - 2 * t))
        return simd_float4x4(simd_quatf(angle: Float(-orientation * .pi / 180), axis: SIMD3(0, 1, 0))
                            * simd_quatf(angle: cover, axis: SIMD3(0, 0, 1)))
    }

    func framing(angle: Double, orientation: Double) -> CGRect {
        let step = min(max(angle, 0), 180) / 180 * Double(bounds.count - 1)
        let lower = Int(step), upper = min(lower + 1, bounds.count - 1)
        let b = bounds[lower] + (bounds[upper] - bounds[lower]) * Float(step - Double(lower))
        let radians = orientation * .pi / 180, c = cos(radians), s = sin(radians)
        let corners = [(b.x, b.y), (b.z, b.y), (b.x, b.w), (b.z, b.w)].map {
            CGPoint(x: Double($0.0) * c - Double($0.1) * s, y: Double($0.0) * s + Double($0.1) * c)
        }
        let x = corners.map(\.x), y = corners.map(\.y)
        return CGRect(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
    }

    func projection(angle: Double, orientation: Double, viewport: CGSize) -> simd_float4x4 {
        let rect = framing(angle: angle, orientation: orientation)
        let aspect = max(viewport.width, 1) / max(viewport.height, 1)
        let hh = Float(max(rect.height, rect.width / aspect) / 2 / 0.975), hw = hh * Float(aspect)
        let near: Float = 0.1, far: Float = 100
        return simd_float4x4(
            SIMD4(60 / hw, 0, 0, 0), SIMD4(0, 60 / hh, 0, 0),
            SIMD4(Float(rect.midX) / hw, -Float(rect.midY) / hh, -(far + near) / (far - near), -1),
            SIMD4(0, 0, -2 * far * near / (far - near), 0)
        )
    }

    func screenMesh(pose: DuoModelPose, viewport: CGSize) -> MirrorScreenMesh {
        let matrices = matrices(angle: pose.angle), model = Self.modelTransform(angle: pose.angle, orientation: pose.orientation)
        let projection = projection(angle: pose.angle, orientation: pose.orientation, viewport: viewport)
        var vertices: [[Double]] = [], triangles: [Int] = [], mapped: [UInt32: Int] = [:]
        for part in asset.parts where part.screen == pose.screen {
            for index in indices[part.offset..<(part.offset + part.count)] {
                if let existing = mapped[index] { triangles.append(existing); continue }
                let i = Int(index)
                let world = model * Self.skin(positions[i], weights: weights[i], joints: joints[i], matrices: matrices)
                let clip = projection * SIMD4(world.x, -world.z, world.y - 60, 1)
                let uv = Self.rotatedUV(texcoords[i], orientation: pose.orientation)
                mapped[index] = vertices.count; triangles.append(vertices.count)
                vertices.append([Double(clip.x / clip.w + 1) / 2, Double(1 - clip.y / clip.w) / 2, Double(uv.x), Double(uv.y)])
            }
        }
        return MirrorScreenMesh(vertices: vertices, triangles: triangles, frameAspectRatio: pose.frameAspectRatio)
    }

    static func rotatedUV(_ uv: SIMD2<Float>, orientation: Double) -> SIMD2<Float> {
        switch Int(orientation.rounded()) % 360 {
        case 90: SIMD2(1 - uv.y, uv.x)
        case 180: SIMD2(1 - uv.x, 1 - uv.y)
        case 270: SIMD2(uv.y, 1 - uv.x)
        default: uv
        }
    }

    private struct Built {
        var positions: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var weights: [SIMD8<Float>] = []
        var joints: [SIMD8<UInt16>] = []
        var indices: [UInt32] = []
        var poses: [simd_float4x4] = []
        var bounds: [SIMD4<Float>] = []
        var parts: [DuoModelAsset.Part] = []
        var jointCount = 0
    }

    private static func load(_ scene: SCNScene) -> Built? {
        var bones: [String: SCNNode] = [:], animations: [CAKeyframeAnimation] = [], nodes: [SCNNode] = []
        func collect(_ animation: CAAnimation) {
            if let k = animation as? CAKeyframeAnimation { animations.append(k) }
            for child in (animation as? CAAnimationGroup)?.animations ?? [] { collect(child) }
        }
        scene.rootNode.enumerateChildNodes { node, _ in
            nodes.append(node)
            for bone in node.skinner?.bones ?? [] { if let name = bone.name { bones[name] = bone } }
            for key in node.animationKeys {
                if let animation = node.animationPlayer(forKey: key)?.animation { collect(CAAnimation(scnAnimation: animation)) }
            }
            node.removeAllAnimations()
        }
        let tracks = animations.compactMap { a -> (SCNNode, CAKeyframeAnimation)? in
            guard let name = a.keyPath?.split(separator: ".").first?.split(separator: "/").last, let bone = bones[String(name)] else { return nil }
            return (bone, a)
        }
        guard !tracks.isEmpty else { return nil }
        var built = Built(), palette: [(SCNNode, simd_float4x4)] = []
        func paletteIndex(_ bone: SCNNode, bind: simd_float4x4) -> UInt16 {
            if let i = palette.firstIndex(where: { $0.0 === bone && $0.1 == bind }) { return UInt16(i) }
            palette.append((bone, bind)); return UInt16(palette.count - 1)
        }
        for node in nodes {
            guard let geometry = node.geometry, let ps = geometry.sources(for: .vertex).first, !geometry.materials.isEmpty else { continue }
            let uvs = geometry.sources(for: .texcoord).first, channels = geometry.geometrySourceChannels?.map(\.intValue)
            let pc = channels?[geometry.sources.firstIndex(of: ps)!] ?? 0
            let uc = uvs.flatMap { geometry.sources.firstIndex(of: $0) }.map { channels?[$0] ?? 0 } ?? 0
            let boneMap: [UInt16]
            if let skin = node.skinner, let inverse = skin.boneInverseBindTransforms {
                boneMap = zip(skin.bones, inverse).map { paletteIndex($0, bind: simd_float4x4($1.scnMatrix4Value) * simd_float4x4(skin.baseGeometryBindTransform)) }
            } else { boneMap = [paletteIndex(node, bind: matrix_identity_float4x4)] }
            guard !boneMap.isEmpty else { return nil }
            var vertexMap: [UInt64: UInt32] = [:]
            for (elementIndex, element) in geometry.elements.enumerated() {
                guard let faces = corners(element) else { return nil }
                let material = geometry.materials[elementIndex % geometry.materials.count]
                let screen = material.name == "CvyXbAGXoolRUYl" ? 1 : material.name == "YqugYDOqMSOpqyA" ? 2 : 0
                let level: Float
                if screen > 0 { level = 0 }
                else if let rgb = (material.diffuse.contents as? NSColor)?.usingColorSpace(.deviceRGB) {
                    level = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) > 0.1 ? 0.4 : 0.015
                } else { level = 0.12 }
                let start = built.indices.count
                for face in faces {
                    var faceIndices: [UInt32] = []
                    for corner in face {
                        guard corner.indices.contains(pc), corner.indices.contains(uc) else { return nil }
                        let pi = corner[pc], ui = corner[uc], key = UInt64(pi) << 32 | UInt64(ui)
                        if let index = vertexMap[key] { faceIndices.append(index); continue }
                        let p = components(ps, pi), uv = uvs.map { components($0, ui) } ?? [0, 0]
                        guard p.count >= 3, uv.count >= 2 else { return nil }
                        var influence = SIMD8<Float>(1, 0, 0, 0, 0, 0, 0, 0), joint = SIMD8<UInt16>(repeating: boneMap[0])
                        if let skin = node.skinner, skin.boneWeights.componentsPerVector > 0 {
                            let w = components(skin.boneWeights, pi), j = components(skin.boneIndices, pi)
                            guard w.count <= 8, w.count == j.count else { return nil }
                            influence = .zero
                            for slot in w.indices {
                                guard boneMap.indices.contains(Int(j[slot])) else { return nil }
                                influence[slot] = w[slot]; joint[slot] = boneMap[Int(j[slot])]
                            }
                        }
                        let index = UInt32(built.positions.count)
                        vertexMap[key] = index; faceIndices.append(index)
                        built.positions.append(SIMD3(p[0], p[1], p[2])); built.texcoords.append(SIMD2(uv[0], uv[1]))
                        built.weights.append(influence); built.joints.append(joint)
                    }
                    for i in 1..<(faceIndices.count - 1) { built.indices.append(contentsOf: [faceIndices[0], faceIndices[i], faceIndices[i + 1]]) }
                }
                built.parts.append(.init(offset: start, count: built.indices.count - start, color: [level, level, level], screen: screen))
            }
        }
        guard !built.positions.isEmpty, palette.count < 256,
              built.parts.contains(where: { $0.screen == 1 }), built.parts.contains(where: { $0.screen == 2 }) else { return nil }
        built.jointCount = palette.count
        // SceneKit represents rigid one-bone parts with implicit weight 1.
        // Their bind-space boxes give a conservative framing envelope without
        // skinning tens of thousands of camera/button vertices at startup.
        var rigidBounds: [UInt16: (SIMD3<Float>, SIMD3<Float>)] = [:]
        var flexible: [Int] = []
        for i in built.positions.indices {
            if built.weights[i][0] == 1 {
                let joint = built.joints[i][0], point = built.positions[i]
                let old = rigidBounds[joint] ?? (point, point)
                rigidBounds[joint] = (simd_min(old.0, point), simd_max(old.1, point))
            } else { flexible.append(i) }
        }
        // Original clip frames 260...380 at 24 fps, with GPU interpolation
        // between samples. No snapshots or file IO occurs during transitions.
        for frame in 0...120 {
            let angle = Double(frame) * 1.5
            pose(tracks, at: (380 - Double(frame)) / 24)
            let matrices = palette.map { $0.0.simdWorldTransform * $0.1 }
            built.poses.append(contentsOf: matrices)
            let model = modelTransform(angle: angle, orientation: 0)
            var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
            func include(_ world: SIMD4<Float>) {
                let p = model * world
                let point = SIMD2(p.x, p.z) * (60 / (60 - p.y))
                low = simd_min(low, point); high = simd_max(high, point)
            }
            for (joint, box) in rigidBounds {
                for x in [box.0.x, box.1.x] {
                    for y in [box.0.y, box.1.y] {
                        for z in [box.0.z, box.1.z] { include(matrices[Int(joint)] * SIMD4(x, y, z, 1)) }
                    }
                }
            }
            for i in flexible {
                include(skin(built.positions[i], weights: built.weights[i], joints: built.joints[i], matrices: matrices))
            }
            built.bounds.append(SIMD4(low.x, low.y, high.x, high.y))
        }
        return built
    }

    private static func skin(_ position: SIMD3<Float>, weights: SIMD8<Float>, joints: SIMD8<UInt16>, matrices: [simd_float4x4]) -> SIMD4<Float> {
        let p = SIMD4(position, 1)
        var result = SIMD4<Float>.zero
        for i in 0..<8 where weights[i] > 0 { result += (matrices[Int(joints[i])] * p) * weights[i] }
        return result
    }

    private static func corners(_ e: SCNGeometryElement) -> [[[Int]]]? {
        guard e.primitiveType == .triangles || e.primitiveType == .polygon, [1, 2, 4].contains(e.bytesPerIndex),
              e.data.count % e.bytesPerIndex == 0 else { return nil }
        let indices: [Int] = e.data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: e.bytesPerIndex).map { offset in
                switch e.bytesPerIndex {
                case 1: Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                case 2: Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                default: Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                }
            }
        }
        let header = e.primitiveType == .polygon ? e.primitiveCount : 0
        guard indices.count >= header else { return nil }
        let counts = header > 0 ? Array(indices.prefix(header)) : Array(repeating: 3, count: e.primitiveCount), total = counts.reduce(0, +)
        guard counts.allSatisfy({ $0 >= 3 }), header + total * e.indicesChannelCount <= indices.count else { return nil }
        var cursor = 0
        return counts.map { count in
            defer { cursor += count }
            return (0..<count).map { corner in
                (0..<e.indicesChannelCount).map { channel in
                    indices[header + (e.hasInterleavedIndicesChannels ? (cursor + corner) * e.indicesChannelCount + channel : channel * total + cursor + corner)]
                }
            }
        }
    }

    private static func pose(_ tracks: [(SCNNode, CAKeyframeAnimation)], at time: Double) {
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        for (bone, track) in tracks {
            guard let values = track.values as? [NSValue], !values.isEmpty else { continue }
            let times = track.keyTimes?.map { $0.doubleValue * track.duration } ?? [0]
            let upper = times.firstIndex(where: { $0 >= time }) ?? (values.count - 1), lower = max(0, upper - 1)
            let span = times[upper] - times[lower], t = Float(span > 0 ? min(max((time - times[lower]) / span, 0), 1) : 0)
            switch track.keyPath?.split(separator: ".").last {
            case "position", "scale":
                let a = values[lower].scnVector3Value, b = values[upper].scnVector3Value
                let value = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)) * (1 - t) + SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)) * t
                if track.keyPath?.hasSuffix("position") == true { bone.simdPosition = value } else { bone.simdScale = value }
            case "orientation":
                let a = values[lower].scnVector4Value, b = values[upper].scnVector4Value
                bone.simdOrientation = simd_slerp(simd_quatf(vector: SIMD4(Float(a.x), Float(a.y), Float(a.z), Float(a.w))),
                                                 simd_quatf(vector: SIMD4(Float(b.x), Float(b.y), Float(b.z), Float(b.w))), t)
            default: break
            }
        }
        SCNTransaction.commit()
    }

    private static func components(_ source: SCNGeometrySource, _ index: Int) -> [Float] {
        source.data.withUnsafeBytes { bytes in
            (0..<source.componentsPerVector).map { component in
                let offset = source.dataOffset + index * source.dataStride + component * source.bytesPerComponent
                if source.usesFloatComponents {
                    return source.bytesPerComponent == 8 ? Float(bytes.loadUnaligned(fromByteOffset: offset, as: Double.self))
                        : bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                }
                switch source.bytesPerComponent {
                case 1: return Float(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                case 2: return Float(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                default: return Float(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                }
            }
        }
    }

    private static func data<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }
}
