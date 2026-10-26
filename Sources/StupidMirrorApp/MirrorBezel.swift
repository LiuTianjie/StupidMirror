import AppKit
import SwiftUI

/// Geometry and artwork shared by the native windows and the Codex panel.
/// The screen is placed inside DeviceKit's chassis, using its framebuffer mask.
struct MirrorBezel {
    let id: String
    let size: CGSize
    let screenRect: CGRect
    let artwork: NSImage
    let screenMask: NSImage?
    var mesh: MirrorScreenMesh?
    var duo: DuoModelPose?

    var displaySize: CGSize { size }
    var aspectRatio: Double { displaySize.width / max(displaySize.height, 1) }

    func screenPoint(_ point: CGPoint, clamped: Bool) -> CGPoint? {
        if let mesh { return mesh.screenPoint(point, clamped: clamped) }
        let result = CGPoint(x: (point.x * size.width - screenRect.minX) / screenRect.width,
                             y: (point.y * size.height - screenRect.minY) / screenRect.height)
        guard clamped || (result.x >= 0 && result.x <= 1 && result.y >= 0 && result.y <= 1) else { return nil }
        return CGPoint(x: min(max(result.x, 0), 1), y: min(max(result.y, 0), 1))
    }

    @MainActor
    func preview(includeImages: Bool, includeModel: Bool = false, postureIconLandscape: Bool? = nil) -> CodexPreviewShell {
        CodexPreviewShell(
            id: id, width: size.width, height: size.height,
            screenX: screenRect.minX, screenY: screenRect.minY,
            screenWidth: screenRect.width, screenHeight: screenRect.height,
            artwork: includeImages && duo == nil ? Self.png(artwork) : nil,
            mask: includeImages ? screenMask.flatMap(Self.png) : nil,
            mesh: includeImages ? mesh : nil,
            duo: duo,
            model: includeModel && duo != nil ? DuoModelRenderer.shared?.asset : nil,
            postureIcons: includeImages ? DeviceKitResources.previewIcons(landscape: postureIconLandscape ?? (size.width > size.height)) : nil
        )
    }

    @MainActor
    private static func png(_ image: NSImage) -> String? {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }
}

@MainActor
enum MirrorBezelCatalog {
    private struct Profile {
        let name: String
        let models: [String]
        let chrome: String
        let mask: String?
    }

    private struct Insets: Decodable {
        var top: CGFloat = 0
        var left: CGFloat = 0
        var bottom: CGFloat = 0
        var right: CGFloat = 0
    }

    private struct Chrome: Decodable {
        struct Images: Decodable {
            struct Sizing: Decodable {
                let leftWidth: CGFloat
                let rightWidth: CGFloat
                let topHeight: CGFloat
                let bottomHeight: CGFloat
            }
            let composite: String
            let topLeft: String
            let topRight: String
            let bottomLeft: String
            let bottomRight: String
            let sizing: Sizing
            let devicePadding: Insets?
        }
        struct Input: Decodable {
            struct Offsets: Decodable {
                struct Position: Decodable { let x: CGFloat; let y: CGFloat }
                let normal: Position
            }
            let image: String?
            let anchor: String?
            let align: String?
            let onTop: Bool?
            let offsets: Offsets?
        }
        let images: Images
        let inputs: [Input]?
    }

    private static var cache: [String: MirrorBezel] = [:]
    private static let profiles: [Profile] = {
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes", isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return directories.sorted { $0.path < $1.path }.compactMap { directory in
            guard directory.pathExtension == "simdevicetype",
                  let data = try? Data(contentsOf: directory.appendingPathComponent("Contents/Resources/profile.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let chrome = plist["chromeIdentifier"] as? String else { return nil }
            var models = plist["representedModelIdentifiers"] as? [String] ?? []
            if let model = plist["modelIdentifier"] as? String { models.append(model) }
            return Profile(
                name: directory.deletingPathExtension().lastPathComponent,
                models: models, chrome: chrome, mask: plist["framebufferMask"] as? String
            )
        }
    }()

    static func bezel(for session: DeviceSession, aspectRatio: Double) -> MirrorBezel {
        if session.platform == .iOS, session.device.formFactor == .foldable,
           let model = DuoModelRenderer.shared {
            return model.bezel(display: session.mirrorSession.simulatorDisplay, aspectRatio: aspectRatio,
                               requestedPosture: session.mirrorSession.requestedSimulatorPosture,
                               changingPosture: session.mirrorSession.isChangingPosture,
                               isRunning: session.mirrorSession.state == .running)
        }
        return bezel(
            productType: session.device.productType, name: session.device.name,
            platform: session.platform, formFactor: session.device.formFactor,
            display: session.mirrorSession.simulatorDisplay, aspectRatio: aspectRatio
        )
    }

    static func bezel(
        productType: String, name: String, platform: DevicePlatform,
        formFactor: DeviceFormFactor, display: SimulatorDisplayState?, aspectRatio: Double
    ) -> MirrorBezel {
        let aspect = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 9.0 / 19.5
        if platform == .iOS, formFactor == .foldable, let model = DuoModelRenderer.shared {
            return model.bezel(display: display, aspectRatio: aspect, isRunning: display != nil)
        }
        let landscape = aspect > 1
        let orientation: Int
        switch display?.orientation {
        case "rot90" where landscape: orientation = 90
        case "rot270" where landscape: orientation = 270
        case "rot180" where !landscape: orientation = 180
        default: orientation = landscape ? 90 : 0
        }
        let profile = profiles.first { $0.models.contains(productType) || $0.name.caseInsensitiveCompare(productType) == .orderedSame }
            ?? profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        // Duo's inner panel has its own chassis and mask. The outer profile
        // alone cannot describe it, even though both belong to one device.
        let isInner = formFactor == .foldable && display?.activeScreen == "inner"
        let chromeID = isInner ? "com.apple.dt.devicekit.chrome.phone14" : profile?.chrome
        let maskID = isInner ? "BF0DC480-5EE2-4EC1-B02B-C75E94759832" : profile?.mask
        let displaySize = display.map { "\($0.nativeWidth)x\($0.nativeHeight)@\($0.pointScale)" } ?? "profile"
        let key = "\(productType)|\(chromeID ?? "plain")|\(maskID ?? "none")|\(displaySize)|\(orientation)|\(Int((landscape ? 1 / aspect : aspect) * 1000))"
        if let cached = cache[key] { return cached }

        let bezel: MirrorBezel
        if platform == .iOS, let chromeID,
           let result = makeDeviceKitBezel(
               id: key, chromeID: chromeID, maskID: maskID,
               name: profile?.name ?? productType, display: display,
               orientation: orientation, aspect: aspect
           ) {
            bezel = result
        } else {
            // No matching installed device artwork: keep all screen pixels.
            // Never guess a phone radius and cut corners out of an unknown UI.
            bezel = plainBezel(id: key, aspect: aspect)
        }
        cache[key] = bezel
        return bezel
    }

    private static func makeDeviceKitBezel(
        id: String, chromeID: String, maskID: String?, name: String,
        display: SimulatorDisplayState?, orientation: Int, aspect: Double
    ) -> MirrorBezel? {
        guard let chromeName = chromeID.split(separator: ".").last else { return nil }
        let resources = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome/\(chromeName).devicechrome/Contents/Resources", isDirectory: true)
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("chrome.json")),
              let chrome = try? JSONDecoder().decode(Chrome.self, from: data),
              let composite = loadPDF(chrome.images.composite, in: resources) else { return nil }
        let sizing = chrome.images.sizing
        let padding = chrome.images.devicePadding ?? Insets()
        let maskURL = maskID.map { URL(fileURLWithPath: "/Library/Developer/DeviceKit/FramebufferMasks/\($0).pdf") }
        let mask = maskURL.flatMap { NSImage(contentsOf: $0) }
        let maskSize = mask?.size
        let baseScreen = CGSize(
            width: composite.size.width - sizing.leftWidth - sizing.rightWidth,
            height: composite.size.height - sizing.topHeight - sizing.bottomHeight
        )
        var screenSize = baseScreen
        if let display, display.nativeWidth > 0, display.nativeHeight > 0, display.pointScale > 0 {
            // A mask PDF's canvas is not necessarily points or native pixels.
            // Duo's inner mask, for example, uses a separate design resolution.
            screenSize = CGSize(width: display.nativeWidth / display.pointScale,
                                height: display.nativeHeight / display.pointScale)
        } else if let maskSize, maskSize.width > 0, maskSize.height > 0 {
            let scale: CGFloat
            if maskSize.height < 1100 && maskSize.width < 700 {
                scale = 1
            } else if name.hasPrefix("iPad") || name.contains("SE") || name == "iPhone XR" || name == "iPhone 11"
                || (["iPhone 6", "iPhone 6s", "iPhone 7", "iPhone 8"].contains(name)) {
                scale = 2
            } else {
                scale = max(1, (maskSize.width / max(baseScreen.width, 1)).rounded())
            }
            screenSize = CGSize(width: maskSize.width / scale, height: maskSize.height / scale)
        }
        // Native screenshot dimensions can differ by one pixel from a profile.
        // Fit the full live frame; do not use aspect-fill to hide that mismatch.
        let portraitAspect = orientation == 90 || orientation == 270 ? 1 / aspect : aspect
        screenSize.height = screenSize.width / portraitAspect
        let bodySize = CGSize(width: screenSize.width + sizing.leftWidth + sizing.rightWidth,
                              height: screenSize.height + sizing.topHeight + sizing.bottomHeight)
        let total = CGSize(width: bodySize.width + padding.left + padding.right,
                           height: bodySize.height + padding.top + padding.bottom)
        let bodyRect = CGRect(x: padding.left, y: padding.top, width: bodySize.width, height: bodySize.height)
        let screenRect = CGRect(x: padding.left + sizing.leftWidth, y: padding.top + sizing.topHeight,
                                width: screenSize.width, height: screenSize.height)
        let topLeft = loadPDF(chrome.images.topLeft, in: resources)?.size ?? .zero
        let topRight = loadPDF(chrome.images.topRight, in: resources)?.size ?? .zero
        let bottomLeft = loadPDF(chrome.images.bottomLeft, in: resources)?.size ?? .zero
        let bottomRight = loadPDF(chrome.images.bottomRight, in: resources)?.size ?? .zero
        composite.capInsets = NSEdgeInsets(
            top: max(topLeft.height, topRight.height), left: max(topLeft.width, bottomLeft.width),
            bottom: max(bottomLeft.height, bottomRight.height), right: max(topRight.width, bottomRight.width)
        )
        composite.resizingMode = .stretch
        let transform = rotation(orientation, size: total)
        let orientedSize = orientation == 90 || orientation == 270 ? CGSize(width: total.height, height: total.width) : total
        guard let artwork = raster(size: orientedSize, draw: { context in
            context.concatenate(transform)
            @MainActor func drawButtons(onTop: Bool) {
                for input in chrome.inputs ?? [] where (input.onTop ?? false) == onTop {
                    guard let imageName = input.image, let image = loadPDF(imageName, in: resources),
                          let offsets = input.offsets?.normal else { continue }
                    var x = bodyRect.minX + offsets.x
                    var y = bodyRect.minY + offsets.y
                    switch input.anchor {
                    case "left": x -= image.size.width
                    case "right": x += bodySize.width
                    case "top": y -= image.size.height
                    case "bottom": y += bodySize.height
                    default: continue
                    }
                    if input.align == "trailing" {
                        if input.anchor == "left" || input.anchor == "right" { y += bodySize.height }
                        else { x += bodySize.width }
                    }
                    image.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: image.size),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            drawButtons(onTop: false)
            composite.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawButtons(onTop: true)
        }) else { return nil }
        let orientedScreen = screenRect.applying(transform)
        let orientedMask = mask.flatMap { mask in
            raster(size: orientedScreen.size) { context in
                context.concatenate(rotation(orientation, size: screenSize))
                mask.draw(in: CGRect(origin: .zero, size: screenSize), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        return MirrorBezel(id: id, size: orientedSize, screenRect: orientedScreen, artwork: artwork, screenMask: orientedMask)
    }

    private static func plainBezel(id: String, aspect: Double) -> MirrorBezel {
        let screen = CGSize(width: aspect > 1 ? 700 : 360, height: aspect > 1 ? 700 / aspect : 360 / aspect)
        let size = CGSize(width: screen.width + 12, height: screen.height + 12)
        let artwork = raster(size: size) { _ in
            NSColor(white: 0.06, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
        } ?? NSImage(size: size)
        return MirrorBezel(id: id, size: size, screenRect: CGRect(x: 6, y: 6, width: screen.width, height: screen.height),
                           artwork: artwork, screenMask: nil)
    }

    private static func loadPDF(_ name: String, in root: URL) -> NSImage? {
        NSImage(contentsOf: root.appendingPathComponent(name).appendingPathExtension("pdf"))
    }

    private static func rotation(_ degrees: Int, size: CGSize) -> CGAffineTransform {
        switch degrees {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        default: .identity
        }
    }

    private static func raster(size: CGSize, draw: (CGContext) -> Void) -> NSImage? {
        let scale: CGFloat = 2
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}

/// Only the video viewport is interactive. The chassis is separate artwork,
/// so its padding never shifts normalized touch coordinates.
struct DeviceBezelView<Screen: View>: View {
    let bezel: MirrorBezel
    var gestureHandlers: ControlGestureHandlers?
    var screenImage: NSImage?
    var mirrorSession: MirrorCaptureSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var duoPresentation = DuoModelPresentation()
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        GeometryReader { geometry in
            if let pose = bezel.duo, let mirrorSession {
                ZStack {
                    DuoModelView(pose: pose, mirrorSession: mirrorSession, presentation: duoPresentation,
                                 previewImage: screenImage, reducesMotion: reduceMotion)
                        .allowsHitTesting(false)
                    if let gestureHandlers {
                        ControlGestureOverlay(isEnabled: true, aspectRatio: pose.frameAspectRatio,
                                              handlers: gestureHandlers, coordinateMapper: { point, bounds, clamped in
                            duoPresentation.screenPoint?(CGPoint(x: point.x / max(bounds.width, 1),
                                                                 y: 1 - point.y / max(bounds.height, 1)), bounds, clamped)
                        })
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
            let scale = min(geometry.size.width / bezel.displaySize.width, geometry.size.height / bezel.displaySize.height)
            let size = CGSize(width: bezel.displaySize.width * scale, height: bezel.displaySize.height * scale)
            ZStack(alignment: .topLeading) {
                flatBody(scale: scale)
                if let gestureHandlers {
                    ControlGestureOverlay(isEnabled: true, aspectRatio: bezel.aspectRatio,
                                          handlers: gestureHandlers, coordinateMapper: { point, bounds, clamped in
                        bezel.screenPoint(CGPoint(x: point.x / max(bounds.width, 1),
                                                  y: 1 - point.y / max(bounds.height, 1)), clamped: clamped)
                    })
                    .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: bezel.id)
            }
        }
    }

    private func flatBody(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: bezel.artwork)
                .resizable()
                .frame(width: bezel.size.width * scale, height: bezel.size.height * scale)
                .allowsHitTesting(false)
            screen()
                .frame(width: bezel.screenRect.width * scale, height: bezel.screenRect.height * scale)
                .mask {
                    if let mask = bezel.screenMask { Image(nsImage: mask).resizable() }
                    else { Rectangle() }
                }
                .offset(x: bezel.screenRect.minX * scale, y: bezel.screenRect.minY * scale)
        }
        .frame(width: bezel.size.width * scale, height: bezel.size.height * scale, alignment: .topLeading)
    }
}
