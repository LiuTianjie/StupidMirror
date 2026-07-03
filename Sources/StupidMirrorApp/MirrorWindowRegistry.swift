import AppKit
import SwiftUI

enum MirrorSizePreset: CaseIterable {
    case small, medium, large

    var heightFraction: CGFloat {
        switch self {
        case .small: 0.5
        case .medium: 0.7
        case .large: 0.9
        }
    }

    var maxLongEdge: CGFloat {
        switch self {
        case .small: 520
        case .medium: 720
        case .large: 980
        }
    }

    var labelKey: String {
        switch self {
        case .small: "mirror.size.small"
        case .medium: "mirror.size.medium"
        case .large: "mirror.size.large"
        }
    }
}

@MainActor
final class MirrorWindowRegistry {
    static let shared = MirrorWindowRegistry()

    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: MirrorWindowDelegate] = [:]

    private init() {}

    func open(session: DeviceSession, store: DeviceGalleryStore) {
        if let window = windows[session.id] {
            session.mirrorSession.start()
            update(window: window, session: session, store: store)
            resize(window: window, session: session, aspectRatio: resolvedAspectRatio(for: session, fallback: store.displayAspectRatio(for: session)), centerIfNeeded: false)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = StandaloneMirrorWindowView(session: session)
            .environmentObject(store)
        let aspectRatio = resolvedAspectRatio(for: session, fallback: store.displayAspectRatio(for: session))
        let defaultSize = defaultMirrorSize(for: session, aspectRatio: aspectRatio)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.device.name
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 200, height: 200 + MirrorWindowChrome.height)
        window.contentView = makeMirrorContentView(rootView: rootView)
        var frame = window.frame
        frame.size = defaultSize
        window.setFrame(frame, display: false)
        window.center()

        installDelegate(for: window, session: session, aspectRatio: aspectRatio)
        windows[session.id] = window

        if store.floatingMirrorIDs.contains(session.id) {
            window.level = .floating
        }

        session.mirrorSession.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(session: DeviceSession) {
        session.mirrorSession.stop()
        if let window = windows[session.id] {
            windows[session.id] = nil
            delegates[session.id] = nil
            window.close()
        }
    }

    func closeAll(sessions: [DeviceSession]) {
        for session in sessions {
            close(session: session)
        }
    }

    func updateAspectRatio(for session: DeviceSession, aspectRatio: Double) {
        guard aspectRatio > 0 else { return }
        delegates[session.id]?.aspectRatio = aspectRatio
    }

    func setFloating(_ floating: Bool, for session: DeviceSession) {
        guard let window = windows[session.id] else { return }
        window.level = floating ? .floating : .normal
    }

    // Snap the window to a preset fraction of the screen's long edge, so the
    // user doesn't have to drag-resize. Keeps the window centered in place.
    func setSizePreset(_ preset: MirrorSizePreset, for session: DeviceSession, aspectRatio: Double) {
        guard aspectRatio > 0, let window = windows[session.id] else { return }
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let longEdge = min(visible.height * preset.heightFraction, preset.maxLongEdge)
        let target = windowSize(forLongEdge: longEdge, aspectRatio: aspectRatio, in: visible)

        var frame = window.frame
        let centerX = frame.midX
        let centerY = frame.midY
        frame.size = target
        frame.origin.x = centerX - target.width / 2
        frame.origin.y = centerY - target.height / 2
        window.setFrame(frame, display: true, animate: true)
    }

    // Called when the live frame ratio changes (device rotation): relock the
    // aspect and resize to fit, keeping the window centered in place.
    func applyLiveAspectRatio(_ aspectRatio: Double, for session: DeviceSession) {
        guard aspectRatio > 0, let window = windows[session.id] else { return }
        let delegate = delegates[session.id]
        delegate?.aspectRatio = aspectRatio
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let longEdge = min(visible.height * 0.85, 900)
        let targetContentSize = windowSize(forLongEdge: longEdge, aspectRatio: aspectRatio, in: visible)
        let target = targetContentSize
        guard abs(window.frame.width - target.width) > 2 || abs(window.frame.height - target.height) > 2 else { return }

        var frame = window.frame
        let centerX = frame.midX
        let centerY = frame.midY
        frame.size = target
        frame.origin.x = centerX - target.width / 2
        frame.origin.y = centerY - target.height / 2
        window.setFrame(frame, display: true, animate: true)
    }

    private func windowSize(forLongEdge longEdge: CGFloat, aspectRatio: Double, in visible: CGRect) -> CGSize {
        var width = aspectRatio >= 1 ? longEdge : longEdge * aspectRatio
        var height = width / aspectRatio
        let maxWidth = visible.width * 0.92
        if width > maxWidth {
            width = maxWidth
            height = width / aspectRatio
        }
        return CGSize(width: width, height: height + MirrorWindowChrome.height)
    }

    private func update(window: NSWindow, session: DeviceSession, store: DeviceGalleryStore) {
        let rootView = StandaloneMirrorWindowView(session: session)
            .environmentObject(store)
        let aspectRatio = resolvedAspectRatio(for: session, fallback: store.displayAspectRatio(for: session))
        window.title = session.device.name
        window.contentView = makeMirrorContentView(rootView: rootView)
        installDelegate(for: window, session: session, aspectRatio: aspectRatio)
    }

    private func resolvedAspectRatio(for session: DeviceSession, fallback: Double) -> Double {
        if let liveRatio = session.mirrorSession.frameAspectRatio, liveRatio > 0 {
            return liveRatio
        }
        return fallback
    }

    private func resize(window: NSWindow, session: DeviceSession, aspectRatio: Double, centerIfNeeded: Bool) {
        let targetContentSize = defaultMirrorSize(for: session, aspectRatio: aspectRatio)
        let targetSize = targetContentSize
        guard abs(window.frame.width - targetSize.width) > 2 || abs(window.frame.height - targetSize.height) > 2 else { return }

        var frame = window.frame
        frame.origin.x += (frame.width - targetSize.width) / 2
        frame.origin.y += frame.height - targetSize.height
        frame.size = targetSize
        window.setFrame(frame, display: true, animate: false)
        if centerIfNeeded {
            window.center()
        }
    }

    private func installDelegate(for window: NSWindow, session: DeviceSession, aspectRatio: Double) {
        delegates[session.id]?.detach()
        let delegate = MirrorWindowDelegate { [weak self, weak mirrorSession = session.mirrorSession] in
            mirrorSession?.stop()
            self?.windows[session.id] = nil
            self?.delegates[session.id] = nil
        }
        delegate.aspectRatio = aspectRatio
        window.delegate = delegate
        delegates[session.id] = delegate
    }

    // The SwiftUI chrome + phone content fill the borderless window, clipped
    // to the window's rounded corners.
    private func makeMirrorContentView(rootView: some View) -> NSView {
        // Rounded clip so the square window corners never reveal the black
        // video backing as wedges outside the phone's larger corner radius.
        let container = RoundedContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))

        let host = TransparentHostingView(rootView: rootView)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        return container
    }

    private func defaultMirrorSize(for session: DeviceSession, aspectRatio: Double) -> CGSize {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxPhoneHeight = min(visibleHeight * 0.92 - MirrorWindowChrome.height, 980)

        if session.mirrorSession.frameAspectRatio == nil,
           let profile = DeviceDisplayProfile.profile(for: session.device.productType, name: session.device.name) {
            let height = min(profile.logicalSize.height, maxPhoneHeight)
            return CGSize(width: height * CGFloat(profile.aspectRatio), height: height + MirrorWindowChrome.height)
        }

        let height = defaultMirrorHeight()
        return CGSize(width: max(280, height * aspectRatio), height: height + MirrorWindowChrome.height)
    }

    private func defaultMirrorHeight() -> CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(max(visibleHeight * 0.9 - MirrorWindowChrome.height, 700), 1080)
    }
}

@MainActor
private final class MirrorWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    var aspectRatio: Double = 0

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func detach() {
        // Kept so delegate replacement and close can use the same cleanup path.
    }

    // Lock the proportions during a live resize. Unlike contentAspectRatio,
    // this is fed the user's proposed size every frame and returns the
    // adjusted one, so the dragged edge/corner stays glued to the cursor.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard aspectRatio > 0 else { return frameSize }
        return NSSize(width: frameSize.width, height: frameSize.width / aspectRatio + MirrorWindowChrome.height)
    }

    func windowWillClose(_ notification: Notification) {
        detach()
        onClose()
    }
}

// Clips its content to a rounded rect matching the phone's corner radius,
// so the square window corners never expose the black video backing as
// wedges outside the phone's larger radius.
private final class RoundedContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(max(min(bounds.width, bounds.height) * 0.14, 44), 96)
    }
}

// NSHostingView paints an opaque backing by default, so a borderless
// window shows a square white wedge outside the SwiftUI corner radius.
// Forcing a clear layer lets the rounded phone frame sit on transparency.
private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = .clear
    }
}
