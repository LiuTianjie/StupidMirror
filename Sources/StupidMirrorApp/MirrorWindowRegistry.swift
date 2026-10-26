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

    /// Opens a mirror after `DeviceGalleryStore` has applied the simultaneous
    /// device policy. Callers must never use this as an alternative start path.
    func openAuthorized(session: DeviceSession, store: DeviceGalleryStore) {
        DockPresence.windowWillShow()
        if let window = windows[session.id] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            startCapture(session: session, store: store)
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
        let window = MirrorWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.borderless, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.device.name
        window.identifier = DockPresence.mirrorIdentifier
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isMovable = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: MirrorWindowChrome.minimumWidth, height: 200 + MirrorWindowChrome.height)
        window.contentView = makeMirrorContentView(rootView: rootView)
        configureContextMenu(for: window, session: session, store: store)
        var frame = window.frame
        frame.size = defaultSize
        window.setFrame(frame, display: false)
        window.center()

        installDelegate(for: window, session: session, aspectRatio: aspectRatio)
        windows[session.id] = window

        if store.floatingMirrorIDs.contains(session.id) {
            window.level = .floating
        }

        startCapture(session: session, store: store)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startCapture(session: DeviceSession, store: DeviceGalleryStore) {
        session.mirrorSession.start()
    }

    func hasWindow(for sessionID: String) -> Bool {
        windows[sessionID] != nil
    }

    func close(session: DeviceSession) {
        session.mirrorSession.stop()
        if let window = windows[session.id] {
            windows[session.id] = nil
            delegates[session.id] = nil
            window.close()
        }
    }

    func rekey(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        if let window = windows.removeValue(forKey: oldID) {
            windows[newID] = window
        }
        if let delegate = delegates.removeValue(forKey: oldID) {
            delegate.sessionID = newID
            delegates[newID] = delegate
        }
    }

    func refreshContent(session: DeviceSession, store: DeviceGalleryStore) {
        guard let window = windows[session.id] else { return }
        update(window: window, session: session, store: store)
    }

    func closeAll(sessions: [DeviceSession]) {
        for session in sessions {
            close(session: session)
        }
    }

    func updateAspectRatio(for session: DeviceSession, aspectRatio: Double) {
        guard aspectRatio > 0 else { return }
        delegates[session.id]?.aspectRatio = MirrorBezelCatalog.bezel(for: session, aspectRatio: aspectRatio).aspectRatio
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
        let ratio = MirrorBezelCatalog.bezel(for: session, aspectRatio: aspectRatio).aspectRatio
        let target = windowSize(forLongEdge: longEdge, aspectRatio: ratio, in: visible)

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
        let aspectRatio = MirrorBezelCatalog.bezel(for: session, aspectRatio: aspectRatio).aspectRatio
        let delegate = delegates[session.id]
        delegate?.aspectRatio = aspectRatio
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let longEdge = max(window.frame.width, window.frame.height - MirrorWindowChrome.height)
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
        var width = max(aspectRatio >= 1 ? longEdge : longEdge * aspectRatio,
                        MirrorWindowChrome.minimumWidth, 200 * aspectRatio)
        var height = width / aspectRatio
        let maxWidth = visible.width * 0.92
        if width > maxWidth {
            width = maxWidth
            height = width / aspectRatio
        }
        let maxHeight = visible.height * 0.92 - MirrorWindowChrome.height
        if height > maxHeight {
            height = maxHeight
            width = height * aspectRatio
        }
        return CGSize(width: width, height: height + MirrorWindowChrome.height)
    }

    private func update(window: NSWindow, session: DeviceSession, store: DeviceGalleryStore) {
        let rootView = StandaloneMirrorWindowView(session: session)
            .environmentObject(store)
        let aspectRatio = resolvedAspectRatio(for: session, fallback: store.displayAspectRatio(for: session))
        window.title = session.device.name
        // Discovery refreshes update the existing SwiftUI graph. Replacing the
        // host destroys open menus, hover state, and the keyboard responder.
        if let host = window.contentView?.subviews.first as? TransparentHostingView<AnyView> {
            host.rootView = AnyView(rootView)
        }
        delegates[session.id]?.aspectRatio = aspectRatio
        configureContextMenu(for: window, session: session, store: store)
    }

    private func configureContextMenu(for window: NSWindow, session: DeviceSession, store: DeviceGalleryStore) {
        (window as? MirrorWindow)?.makeContextMenu = { [weak store] in
            guard let store else { return MirrorNativeMenu.make() }
            let menu = MirrorNativeMenu.make()
            let ready = store.canUseControl && session.controlSession.isReady
            MirrorNativeMenu.add(store.t(session.mirrorSession.state == .running ? "mirror.pause" : "mirror.start"),
                                 to: menu, enabled: store.canAttemptConnection(session)) {
                session.mirrorSession.state == .running ? store.stop(session) : store.start(session)
            }
            menu.addItem(.separator())
            MirrorNativeMenu.add(store.t(session.controlSession.isReady ? "mirror.disconnectControl" : "card.installControlAgent"),
                                 to: menu, enabled: store.canAttemptConnection(session)
                                    && !(store.canUseControl && session.device.udid == nil)) {
                session.controlSession.isReady ? store.stopControl(for: session) : store.connectControl(for: session)
            }
            MirrorNativeMenu.add(store.t("mirror.home"), to: menu, enabled: ready) { store.pressHome(for: session) }
            MirrorNativeMenu.add(store.t("mirror.appSwitcher"), to: menu, enabled: ready) { store.openAppSwitcher(for: session) }
            MirrorNativeMenu.add(store.t("mirror.pasteClipboard"), to: menu, enabled: ready) {
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
                store.typeControlText(text, for: session)
            }
            menu.addItem(.separator())
            MirrorNativeMenu.addSubmenu(store.t("mirror.size"), to: menu) { sizes in
                for preset in MirrorSizePreset.allCases {
                    MirrorNativeMenu.add(store.t(preset.labelKey), to: sizes) {
                        MirrorWindowRegistry.shared.setSizePreset(preset, for: session,
                                                                 aspectRatio: store.displayAspectRatio(for: session))
                    }
                }
            }
            MirrorNativeMenu.add(store.t("mirror.floatOnTop"), to: menu, checked: store.isFloating(session)) {
                store.toggleFloating(for: session)
            }
            menu.addItem(.separator())
            MirrorNativeMenu.add(store.t("mirror.close"), to: menu) { store.stop(session) }
            return menu
        }
    }

    private func resolvedAspectRatio(for session: DeviceSession, fallback: Double) -> Double {
        let screenRatio = session.mirrorSession.frameAspectRatio ?? fallback
        return MirrorBezelCatalog.bezel(for: session, aspectRatio: screenRatio).aspectRatio
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
        let delegate = MirrorWindowDelegate(sessionID: session.id) { [weak self, weak mirrorSession = session.mirrorSession] sessionID in
            mirrorSession?.stop()
            self?.windows[sessionID] = nil
            self?.delegates[sessionID] = nil
        }
        delegate.aspectRatio = aspectRatio
        window.delegate = delegate
        delegates[session.id] = delegate
    }

    private func makeMirrorContentView(rootView: some View) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        let host = TransparentHostingView(rootView: AnyView(rootView))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        return container
    }

    private func defaultMirrorSize(for session: DeviceSession, aspectRatio: Double) -> CGSize {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return windowSize(forLongEdge: min(visible.height * 0.88, 980), aspectRatio: aspectRatio, in: visible)
    }

}

// The title bar owns window dragging. Phone touches always follow the normal
// responder chain, and explicit control bounds take priority over resizing.
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    let toolbarControls = NSHashTable<WindowControlAreaView>.weakObjects()
    var makeContextMenu: (() -> NSMenu)?
    let resizeAreas = NSHashTable<ResizeHandleView>.weakObjects()
    private weak var activeResize: ResizeHandleView?

    func isToolbarControl(at point: NSPoint) -> Bool {
        toolbarControls.allObjects.contains { $0.window === self && $0.containsWindowPoint(point) }
    }

    override func sendEvent(_ event: NSEvent) {
        if let activeResize {
            if event.type == .leftMouseDragged { activeResize.mouseDragged(with: event); return }
            if event.type == .leftMouseUp {
                activeResize.mouseUp(with: event)
                self.activeResize = nil
                return
            }
        }
        if event.type == .leftMouseDown {
            if isToolbarControl(at: event.locationInWindow) {
                super.sendEvent(event)
                return
            }
            if let resize = resizeAreas.allObjects.first(where: { $0.containsWindowPoint(event.locationInWindow) }) {
                activeResize = resize
                resize.mouseDown(with: event)
                return
            }
        }
        // The native toolbar input view receives the normal AppKit mouse
        // sequence. Do not swallow mouseDown before AppKit establishes its
        // drag target; resize edges are the only manually routed exception.
        super.sendEvent(event)
    }
}

@MainActor
private final class MirrorWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (String) -> Void
    var sessionID: String

    var aspectRatio: Double = 0

    init(sessionID: String, onClose: @escaping (String) -> Void) {
        self.sessionID = sessionID
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
        onClose(sessionID)
    }
}

// The chassis artwork defines the window silhouette. Keep the hosting layer
// clear so it cannot paint square white corners outside that artwork.
private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
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

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = (window as? MirrorWindow)?.makeContextMenu?() else {
            super.rightMouseDown(with: event)
            return
        }
        // Build once per opening. Video refreshes cannot replace a submenu
        // while the pointer is moving into it.
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
