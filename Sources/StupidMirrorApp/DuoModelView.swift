import AppKit
@preconcurrency import AVFoundation
import Metal
import SceneKit
import SwiftUI

@MainActor
final class DuoModelPresentation: ObservableObject {
    var screenPoint: ((CGPoint, CGSize, Bool) -> CGPoint?)?
}

/// The native mirror uses the same immutable rig as the web preview. Updating
/// a posture only changes the spring target; it never replaces this view.
struct DuoModelView: NSViewRepresentable {
    let pose: DuoModelPose
    let mirrorSession: MirrorCaptureSession
    let presentation: DuoModelPresentation
    var previewImage: NSImage?
    var reducesMotion = false

    @MainActor
    final class Coordinator: NSObject {
        let model: DuoModelRenderer
        let session: MirrorCaptureSession
        let root = SCNNode()
        let camera = SCNNode()
        var bones: [SCNNode] = []
        var materials: [SCNMaterial] = []
        weak var view: DuoSceneView?
        var target: DuoModelPose?
        var hinge = DuoPoseSpring(value: 180)
        var orientation = DuoPoseSpring(value: 0)
        var orientationTarget = 0.0
        var reduceMotion = false
        var moving = false
        var matchingFrame = false
        var opacity = 0.0
        var lastTick = 0.0
        var displayLink: CADisplayLink?
        var videoConsumer: UUID?
        var textureCache: CVMetalTextureCache?
        var pendingFrame: (CMSampleBuffer, CVMetalTexture, DuoModelPose)?
        var pendingPreview: (NSImage, DuoModelPose)?
        var lastPreviewImage: NSImage?
        // SceneKit keeps a few frames in flight. Retain their backing buffers
        // as well as the CV wrappers until the renderer advances past them.
        var videoTextures: [(CMSampleBuffer, CVMetalTexture)] = []
        var hitMesh: (DuoModelPose, CGSize, MirrorScreenMesh)?
        lazy var relay = LatestMainQueueRelay<CMSampleBuffer> { [weak self] frame in self?.receive(frame) }

        init(model: DuoModelRenderer, session: MirrorCaptureSession) {
            self.model = model
            self.session = session
        }

        func makeScene() -> SCNScene {
            let asset = model.asset
            func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, components: Int, float: Bool = true) -> SCNGeometrySource {
                SCNGeometrySource(data: data, semantic: semantic, vectorCount: asset.vertexCount, usesFloatComponents: float,
                                  componentsPerVector: components, bytesPerComponent: float ? 4 : 2,
                                  dataOffset: 0, dataStride: components * (float ? 4 : 2))
            }
            let elements = asset.parts.map { part in
                SCNGeometryElement(data: asset.indices.subdata(in: (part.offset * 4)..<((part.offset + part.count) * 4)),
                                   primitiveType: .triangles, primitiveCount: part.count / 3, bytesPerIndex: 4)
            }
            let geometry = SCNGeometry(sources: [source(asset.positions, .vertex, components: 3),
                                                source(asset.texcoords, .texcoord, components: 2)], elements: elements)
            materials = asset.parts.map { part in
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = NSColor(calibratedRed: CGFloat(part.color[0]), green: CGFloat(part.color[1]),
                                                    blue: CGFloat(part.color[2]), alpha: 1)
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                return material
            }
            geometry.materials = materials
            bones = (0..<asset.jointCount).map { _ in SCNNode() }
            for bone in bones { root.addChildNode(bone) }
            let body = SCNNode(geometry: geometry)
            body.skinner = SCNSkinner(baseGeometry: geometry, bones: bones,
                                     boneInverseBindTransforms: bones.map { _ in NSValue(scnMatrix4: SCNMatrix4Identity) },
                                     boneWeights: source(asset.weights, .boneWeights, components: 8),
                                     boneIndices: source(asset.joints, .boneIndices, components: 8, float: false))
            root.addChildNode(body)
            let scene = SCNScene()
            scene.rootNode.addChildNode(root)
            camera.camera = SCNCamera()
            camera.position = SCNVector3(0, 60, 0)
            camera.look(at: .init(0, 0, 0), up: .init(0, 0, -1), localFront: .init(0, 0, -1))
            scene.rootNode.addChildNode(camera)
            return scene
        }

        func update(_ pose: DuoModelPose, previewImage: NSImage?, reduceMotion: Bool) {
            self.reduceMotion = reduceMotion
            let changed = target.map { abs($0.angle - pose.angle) > 0.001 || $0.orientation != pose.orientation || $0.screen != pose.screen } ?? true
            if target == nil {
                hinge.value = pose.angle
                orientation.value = pose.orientation
            }
            if changed {
                // Half-open and open share the same display. Keep its last
                // frame on the folding screen instead of flashing black.
                if target?.screen != pose.screen || target?.orientation != pose.orientation {
                    matchingFrame = false
                    opacity = 0
                    pendingFrame = nil
                    pendingPreview = nil
                    lastPreviewImage = nil
                }
                hitMesh = nil
                var delta = (pose.orientation - orientation.value).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                orientationTarget = orientation.value + delta
            }
            target = pose
            if session.state != .running, !session.isChangingPosture,
               let previewImage, lastPreviewImage !== previewImage {
                let aspect = previewImage.size.width / max(previewImage.size.height, 1)
                if abs(aspect / pose.frameAspectRatio - 1) < 0.02 {
                    pendingPreview = (previewImage, pose)
                    lastPreviewImage = previewImage
                }
            }
            if reduceMotion {
                hinge = DuoPoseSpring(value: pose.angle)
                orientation = DuoPoseSpring(value: orientationTarget)
            }
            moving = abs(hinge.value - pose.angle) > 0.015 || abs(orientation.value - orientationTarget) > 0.015
            render()
            wake()
        }

        func wake() {
            guard let view else { return }
            if displayLink == nil {
                let link = view.displayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            if displayLink?.isPaused == true || lastTick == 0 { lastTick = CACurrentMediaTime() }
            displayLink?.isPaused = false
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let target, let view, view.window != nil else { link.isPaused = true; return }
            let now = CACurrentMediaTime(), elapsed = max(0, now - lastTick)
            lastTick = now
            let hingeMoving = hinge.advance(to: target.angle, elapsed: elapsed)
            let rotating = orientation.advance(to: orientationTarget, elapsed: elapsed)
            moving = hingeMoving || rotating
            render(elapsed: elapsed)
            if !moving && (!matchingFrame || opacity >= 1) { link.isPaused = true }
        }

        func render(elapsed: Double = 0) {
            guard let target, let view else { return }
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            // Commit the video texture and the rig together. A separate
            // transaction per video frame competes with SceneKit's renderer.
            if let (image, pose) = pendingPreview {
                pendingPreview = nil
                if pose.screen == target.screen, pose.orientation == target.orientation {
                    setScreenContents(image, pose: pose)
                    matchingFrame = true
                }
            }
            if let (frame, cachedTexture, pose) = pendingFrame {
                pendingFrame = nil
                if pose.screen == target.screen, pose.orientation == target.orientation,
                   let texture = CVMetalTextureGetTexture(cachedTexture) {
                    videoTextures.append((frame, cachedTexture))
                    if videoTextures.count > 4 { videoTextures.removeFirst(videoTextures.count - 4) }
                    setScreenContents(texture, pose: pose)
                    matchingFrame = true
                }
            }
            opacity = matchingFrame ? min(1, opacity + elapsed / 0.06) : 0
            for (bone, matrix) in zip(bones, model.matrices(angle: hinge.value)) { bone.simdTransform = matrix }
            root.simdTransform = DuoModelRenderer.modelTransform(angle: hinge.value, orientation: orientation.value)
            camera.camera?.projectionTransform = SCNMatrix4(model.projection(angle: hinge.value, orientation: orientation.value,
                                                                             viewport: view.bounds.size))
            camera.camera?.motionBlurIntensity = reduceMotion ? 0 : 0.16 * min(abs(hinge.velocity) / 600, 1)
            for (index, part) in model.asset.parts.enumerated() where part.screen > 0 {
                materials[index].diffuse.intensity = part.screen == target.screen ? opacity : 0
            }
            SCNTransaction.commit()
            view.needsDisplay = true
        }

        private func setScreenContents(_ contents: Any, pose: DuoModelPose) {
            let a = DuoModelRenderer.rotatedUV(SIMD2(0, 0), orientation: pose.orientation)
            let b = DuoModelRenderer.rotatedUV(SIMD2(1, 0), orientation: pose.orientation)
            let c = DuoModelRenderer.rotatedUV(SIMD2(0, 1), orientation: pose.orientation)
            let transform = simd_float4x4(SIMD4(b.x - a.x, b.y - a.y, 0, 0),
                                         SIMD4(c.x - a.x, c.y - a.y, 0, 0),
                                         SIMD4(0, 0, 1, 0), SIMD4(a.x, a.y, 0, 1))
            for (index, part) in model.asset.parts.enumerated() where part.screen == pose.screen {
                materials[index].diffuse.contents = contents
                materials[index].diffuse.contentsTransform = SCNMatrix4(transform)
            }
        }

        private func receive(_ frame: CMSampleBuffer) {
            // Accept the first matching display frame during the fold; its
            // arrival is independent of the spring settling or HID reply.
            guard let target, let textureCache,
                  let pixels = CMSampleBufferGetImageBuffer(frame) else { return }
            let aspect = Double(CVPixelBufferGetWidth(pixels)) / Double(max(CVPixelBufferGetHeight(pixels), 1))
            guard abs(aspect / target.frameAspectRatio - 1) < 0.02 else { return }
            var cachedTexture: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixels, nil,
                                                            .bgra8Unorm_srgb, CVPixelBufferGetWidth(pixels),
                                                            CVPixelBufferGetHeight(pixels), 0, &cachedTexture) == kCVReturnSuccess,
                  let cachedTexture else { return }
            pendingFrame = (frame, cachedTexture, target)
            wake()
        }

        func screenPoint(_ point: CGPoint, size: CGSize, clamped: Bool) -> CGPoint? {
            guard let target, !moving, matchingFrame, target.screenReady, opacity > 0.99 else { return nil }
            if hitMesh?.0 != target || hitMesh?.1 != size {
                hitMesh = (target, size, model.screenMesh(pose: target, viewport: size))
            }
            return hitMesh?.2.screenPoint(point, clamped: clamped)
        }

        func dispose() {
            displayLink?.invalidate()
            displayLink = nil
            relay.invalidate()
            if let videoConsumer { session.removeVideoSampleBufferConsumer(videoConsumer) }
            for material in materials { material.diffuse.contents = nil }
            pendingFrame = nil
            pendingPreview = nil
            lastPreviewImage = nil
            videoTextures.removeAll()
            if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
            textureCache = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: DuoModelRenderer.shared!, session: mirrorSession)
    }

    func makeNSView(context: Context) -> DuoSceneView {
        let view = DuoSceneView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.usesReverseZ = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.scene = context.coordinator.makeScene()
        view.pointOfView = context.coordinator.camera
        context.coordinator.view = view
        if let device = view.device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &context.coordinator.textureCache)
        }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.render() }
        presentation.screenPoint = { [weak coordinator = context.coordinator] point, size, clamped in
            coordinator?.screenPoint(point, size: size, clamped: clamped)
        }
        let relay = context.coordinator.relay
        context.coordinator.videoConsumer = mirrorSession.addVideoSampleBufferConsumer { [weak relay] in relay?.submit($0) }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DuoSceneView, context: Context) {
        context.coordinator.update(pose, previewImage: previewImage, reduceMotion: reducesMotion)
    }

    static func dismantleNSView(_ view: DuoSceneView, coordinator: Coordinator) {
        coordinator.dispose()
        view.onLayout = nil
        view.scene = nil
    }
}

final class DuoSceneView: SCNView {
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { false }
    override func layout() { super.layout(); onLayout?() }
}
