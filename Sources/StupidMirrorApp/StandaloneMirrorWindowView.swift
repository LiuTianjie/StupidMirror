import AppKit
import SwiftUI

struct StandaloneMirrorWindowView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: DeviceControlSession

    let session: DeviceSession
    @State private var chromeVisible = false
    @State private var chromeHideWorkItem: DispatchWorkItem?
    @State private var menuTrackingDepth = 0
    @State private var chromePointer = WindowChromePointer()

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                MirrorWindowChromeBar(
                    session: session,
                    isVisible: chromeVisible,
                    pointer: chromePointer,
                    showChrome: showChrome,
                    scheduleHideChrome: scheduleHideChrome
                )
                .frame(height: MirrorWindowChrome.height)
                phoneFrame
            }

            resizeHandles
        }
        .background(Color.clear)
        .frame(minWidth: MirrorWindowChrome.minimumWidth, minHeight: 180)
        .animation(.easeInOut(duration: 0.16), value: statusTitle)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: statusTitle)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTrackingDepth += 1
            chromeHideWorkItem?.cancel()
            chromeHideWorkItem = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTrackingDepth = max(0, menuTrackingDepth - 1)
            if menuTrackingDepth == 0 { scheduleHideChrome() }
        }
        .onDisappear {
            chromeHideWorkItem?.cancel()
        }
        .onChange(of: mirrorSession.simulatorDisplay) { _, _ in
            MirrorWindowRegistry.shared.applyLiveAspectRatio(store.displayAspectRatio(for: session), for: session)
        }
        .onChange(of: mirrorSession.frameAspectRatio) { _, newRatio in
            guard let newRatio else { return }
            MirrorWindowRegistry.shared.applyLiveAspectRatio(newRatio, for: session)
            // The phone rotated: control coordinates follow the new screen size
            // now instead of at the next keep-alive.
            session.controlSession.refreshScreenSize()
        }
    }

    private var bezel: MirrorBezel {
        MirrorBezelCatalog.bezel(for: session, aspectRatio: store.displayAspectRatio(for: session))
    }

    private var resizeHandles: some View {
        let aspectRatio = bezel.aspectRatio

        return ZStack {
            VStack(spacing: 0) {
                WindowResizeHandle(region: .top, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                    .frame(maxWidth: .infinity)
                    .frame(height: MirrorWindowChrome.resizeEdgeHitThickness)
                Spacer()
                WindowResizeHandle(region: .bottom, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                    .frame(maxWidth: .infinity)
                    .frame(height: MirrorWindowChrome.resizeEdgeHitThickness)
            }

            HStack(spacing: 0) {
                WindowResizeHandle(region: .left, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                    .frame(maxHeight: .infinity)
                    .frame(width: MirrorWindowChrome.resizeEdgeHitThickness)
                Spacer()
                WindowResizeHandle(region: .right, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                    .frame(maxHeight: .infinity)
                    .frame(width: MirrorWindowChrome.resizeEdgeHitThickness)
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    WindowResizeHandle(region: .topLeft, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                        .frame(width: MirrorWindowChrome.cornerHitSize, height: MirrorWindowChrome.cornerHitSize)
                    Spacer()
                    WindowResizeHandle(region: .topRight, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                        .frame(width: MirrorWindowChrome.cornerHitSize, height: MirrorWindowChrome.cornerHitSize)
                }
                Spacer()
                HStack(spacing: 0) {
                    WindowResizeHandle(region: .bottomLeft, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                        .frame(width: MirrorWindowChrome.cornerHitSize, height: MirrorWindowChrome.cornerHitSize)
                    Spacer()
                    WindowResizeHandle(region: .bottomRight, aspectRatio: aspectRatio, onHover: showChrome, onExit: scheduleHideChrome)
                        .frame(width: MirrorWindowChrome.cornerHitSize, height: MirrorWindowChrome.cornerHitSize)
                }
            }
        }
        // NSWindow routes the narrow native resize regions directly. The
        // full-size SwiftUI overlay must not intercept the toolbar below it.
        .allowsHitTesting(false)
    }

    private var phoneFrame: some View {
        DeviceBezelView(bezel: bezel,
                        gestureHandlers: store.canUseControl && controlSession.isReady
                        && !mirrorSession.isChangingPosture ? store.gestureHandlers(for: session) : nil,
                        screenImage: mirrorSession.latestWirelessFrame, mirrorSession: mirrorSession) {
            ZStack {
                Color.black
                Group {
                    if bezel.mesh != nil, let frame = mirrorSession.latestWirelessFrame {
                        // Both panels share one decoded frame. A second video
                        // consumer would disconnect the first panel's stream.
                        Image(nsImage: frame).resizable().scaledToFit()
                    } else {
                        MirrorPreviewView(mirrorSession: mirrorSession, cornerRadius: 0)
                    }
                }
                    .overlay {
                        AutomationActionOverlayView(actions: mirrorSession.automationActions)
                    }
                if mirrorSession.state != .running || session.device.connectionState != .connected {
                    statusOverlay
                }
                if controlSession.isConnecting {
                    Color.black.opacity(0.42).allowsHitTesting(false)
                }
            }
        }
        .overlay(keyboardForwardingLayer)
        .overlay {
            if controlSession.isConnecting {
                ControlConnectionLoadingView(controlSession: controlSession) {
                    store.stopControl(for: session)
                }
                .padding(12)
            }
        }
    }

    private var statusOverlay: some View {
        VStack(spacing: 12) {
            if session.device.connectionState != .connected {
                StatusGlyph(kind: .working, size: 34)
            } else {
                ProgressOrIcon(state: mirrorSession.state)
            }
            Text(statusTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Ink.primary)
            if mirrorSession.state == .starting && session.showsMirrorStartupProgress {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 5) {
                        Text(mirrorSession.wirelessStartupDetail
                            ?? store.t("detail.wirelessStarting"))
                            .foregroundStyle(Theme.Ink.secondary)
                        Text(String(
                            format: store.t("agent.start.elapsed"),
                            wirelessStartupElapsed(at: context.date)
                        ))
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.Palette.pending)
                    }
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
                Button(store.t("agent.start.cancel")) {
                    store.stop(session)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
            if session.device.connectionState != .connected {
                Text(store.t("mirror.reconnectingBody"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if case let .failed(message) = mirrorSession.state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if session.showsMirrorStartupProgress
                    && store.canAttemptConnection(session) {
                    Button(store.t("agent.start.retry")) {
                        store.start(session)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.well)
    }

    private var statusTitle: String {
        session.device.connectionState == .connected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
    }

    private func wirelessStartupElapsed(at date: Date) -> Int {
        guard let beganAt = mirrorSession.wirelessStartupBeganAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(beganAt)))
    }

    private var keyboardForwardingLayer: some View {
        KeyboardForwardingView(
            isEnabled: store.canUseControl
                && controlSession.isReady
                && session.device.connectionState == .connected
        ) { text in
            store.typeControlText(text, for: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showChrome() {
        chromeHideWorkItem?.cancel()
        chromeHideWorkItem = nil
        withAnimation(.easeOut(duration: 0.14)) {
            chromeVisible = true
        }
    }

    private func scheduleHideChrome() {
        chromeHideWorkItem?.cancel()
        guard menuTrackingDepth == 0, !chromePointer.containsMouse else { return }
        let workItem = DispatchWorkItem {
            // Recheck actual pointer geometry: menu tracking and resize-edge
            // exits do not necessarily produce matching toolbar hover events.
            guard menuTrackingDepth == 0, !chromePointer.containsMouse else { return }
            withAnimation(.easeIn(duration: 0.12)) {
                chromeVisible = false
            }
        }
        chromeHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }
}

private struct MirrorWindowChromeBar: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    let session: DeviceSession
    let isVisible: Bool
    let pointer: WindowChromePointer
    let showChrome: () -> Void
    let scheduleHideChrome: () -> Void
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @State private var screenshotCopied = false
    @State private var screenshotFeedbackTask: Task<Void, Never>?

    init(
        session: DeviceSession,
        isVisible: Bool,
        pointer: WindowChromePointer,
        showChrome: @escaping () -> Void,
        scheduleHideChrome: @escaping () -> Void
    ) {
        self.session = session
        self.isVisible = isVisible
        self.pointer = pointer
        self.showChrome = showChrome
        self.scheduleHideChrome = scheduleHideChrome
        self.mirrorSession = session.mirrorSession
    }

    @ViewBuilder
    private var screenSwitcher: some View {
        if session.isIOSSimulator && session.device.formFactor == .foldable {
            DevicePosturePicker(session: session, showsLabels: false)
                .background(WindowControlArea(isEnabled: isVisible))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let showsPosture = session.isIOSSimulator && session.device.formFactor == .foldable
            let compact = geometry.size.width < (showsPosture ? 456 : 304)
            HStack(spacing: 8) {
                windowDots
                    .background(WindowControlArea(isEnabled: isVisible))
                Spacer(minLength: 16)
                if compact {
                    ChromeIconButton(systemName: "house", help: store.t("mirror.home")) {
                        store.pressHome(for: session)
                    }
                    .disabled(!store.canUseControl || !session.controlSession.isReady)
                    .background(WindowControlArea(isEnabled: isVisible))
                    overflowMenu
                        .background(WindowControlArea(isEnabled: isVisible))
                } else {
                    fullControls.fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: MirrorWindowChrome.height - 6)
            .background { Capsule().fill(.regularMaterial).allowsHitTesting(false) }
            .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false) }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
        }
        .contentShape(Rectangle())
        .overlay(WindowChromeInteractionArea(pointer: pointer, onEnter: showChrome, onExit: scheduleHideChrome))
        .onDisappear {
            screenshotFeedbackTask?.cancel()
        }
    }

    private var windowDots: some View {
        HStack(spacing: 11) {
            WindowDot(color: .systemRed) { _ in store.stop(session) }
            WindowDot(color: .systemYellow) { $0?.miniaturize(nil) }
            WindowDot(color: .systemGray) { $0?.zoom(nil) }
        }
    }

    private var fullControls: some View {
        HStack(spacing: 8) {
                    ChromeIconButton(
                        systemName: screenshotCopied ? "checkmark" : "camera",
                        help: store.t(screenshotCopied ? "mirror.screenshotCopied" : "mirror.copyScreenshot")
                    ) {
                        copyScreenshotToClipboard()
                    }
                    .disabled(session.mirrorSession.state != .running)
                    .background(WindowControlArea(isEnabled: isVisible))

                    ChromeIconButton(
                        systemName: store.audioPlaybackEnabled && session.canPlayAudioOnMac ? "speaker.wave.2.fill" : "speaker.slash",
                        help: store.t(session.canPlayAudioOnMac ? "settings.audioPlaybackHelp" :
                            (session.isIOSSimulator ? "settings.audioSimulatorHelp" : "settings.audioPhoneOnlyHelp"))
                    ) {
                        store.audioPlaybackToggle.wrappedValue.toggle()
                    }
                    .disabled((store.isRequestingMicrophonePermission || store.isRequestingCameraPermission) || !session.canPlayAudioOnMac)
                    .background(WindowControlArea(isEnabled: isVisible))

                    ChromeIconButton(systemName: "chevron.backward", help: store.t("mirror.back")) {
                        store.pressBack(for: session)
                    }
                    .disabled(!store.canUseControl || !session.controlSession.isReady)
                    .background(WindowControlArea(isEnabled: isVisible))

                    ChromeIconButton(systemName: "house", help: store.t("mirror.home")) {
                        store.pressHome(for: session)
                    }
                    .disabled(!store.canUseControl || !session.controlSession.isReady)
                    .background(WindowControlArea(isEnabled: isVisible))

                    ChromeIconButton(systemName: "rectangle.grid.2x2", help: store.t("mirror.appSwitcher")) {
                        store.openAppSwitcher(for: session)
                    }
                    .disabled(!store.canUseControl || !session.controlSession.isReady)
                    .background(WindowControlArea(isEnabled: isVisible))

                    screenSwitcher
        }
    }

    private var overflowMenu: some View {
        MirrorNativeMenuButton(help: store.t("mirror.moreControls"), onOpen: showChrome, onClose: scheduleHideChrome) {
            let menu = MirrorNativeMenu.make()
            let ready = store.canUseControl && session.controlSession.isReady
            MirrorNativeMenu.add(store.t("mirror.copyScreenshot"), to: menu, symbol: "camera",
                                 enabled: mirrorSession.state == .running, action: copyScreenshotToClipboard)
            MirrorNativeMenu.add(store.t("settings.audioPlayback"), to: menu,
                                 enabled: !store.isRequestingMicrophonePermission && !store.isRequestingCameraPermission && session.canPlayAudioOnMac,
                                 checked: store.audioPlaybackEnabled && session.canPlayAudioOnMac) {
                store.audioPlaybackToggle.wrappedValue.toggle()
            }
            MirrorNativeMenu.add(store.t("mirror.back"), to: menu, symbol: "chevron.backward", enabled: ready) { store.pressBack(for: session) }
            MirrorNativeMenu.add(store.t("mirror.appSwitcher"), to: menu, symbol: "rectangle.grid.2x2", enabled: ready) { store.openAppSwitcher(for: session) }
            if session.isIOSSimulator && session.device.formFactor == .foldable {
                let canChange = !mirrorSession.isChangingPosture && session.device.connectionState == .connected
                menu.addItem(.separator())
                MirrorNativeMenu.add(store.t("mirror.rotateDevice"), to: menu, symbol: "rotate.right", enabled: canChange) {
                    store.rotateSimulator(session)
                }
                for posture in DevicePosture.allCases {
                    MirrorNativeMenu.add(store.t(posture.labelKey), to: menu, symbol: posture.systemImage,
                                         enabled: canChange, checked: mirrorSession.simulatorDisplay?.posture == posture) {
                        store.changePosture(posture, for: session)
                    }
                }
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
            return menu
        }
        .frame(width: 28, height: 24)
    }

    private func copyScreenshotToClipboard() {
        guard let snapshot = session.mirrorSession.latestFrameStore.pngSnapshot(),
              let pngData = snapshot.pngData else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(pngData, forType: .png) else {
            NSSound.beep()
            return
        }

        if let image = NSImage(data: pngData),
           let tiffData = image.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }

        screenshotFeedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            screenshotCopied = true
        }
        screenshotFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.12)) {
                screenshotCopied = false
            }
        }
    }
}

private struct ChromeIconButton: View {
    let systemName: String
    let help: String
    var emphasized: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(emphasized ? Theme.Ink.primary : Theme.Ink.secondary)
        .background(.black.opacity(0.001))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct WindowDot: View {
    let color: NSColor
    let action: (NSWindow?) -> Void

    var body: some View {
        WindowDotView(color: color, action: action)
            .frame(width: 13, height: 13)
    }
}

private struct WindowDotView: NSViewRepresentable {
    let color: NSColor
    let action: (NSWindow?) -> Void

    func makeNSView(context: Context) -> DotControlView {
        DotControlView(color: color, action: action)
    }

    func updateNSView(_ nsView: DotControlView, context: Context) {
        nsView.color = color
        nsView.action = action
    }
}

private final class DotControlView: NSView {
    var color: NSColor {
        didSet {
            layer?.backgroundColor = color.cgColor
        }
    }
    var action: (NSWindow?) -> Void

    init(color: NSColor, action: @escaping (NSWindow?) -> Void) {
        self.color = color
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.75
        layer?.cornerRadius = 6.5
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func mouseDown(with event: NSEvent) {
        action(window)
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView {
        DragAreaView()
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {}
}

/// Keep the interaction region alive when the toolbar's artwork fades out.
@MainActor
private final class WindowChromePointer {
    weak var view: WindowChromeInteractionView?

    var containsMouse: Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        if view.isDragging { return true }
        return view.bounds.intersection(view.visibleRect).contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

private struct WindowChromeInteractionArea: NSViewRepresentable {
    let pointer: WindowChromePointer
    let onEnter: () -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> WindowChromeInteractionView {
        let view = WindowChromeInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WindowChromeInteractionView, context: Context) {
        pointer.view = view
        view.onEnter = onEnter
        view.onExit = onExit
    }
}

private final class WindowChromeInteractionView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    private var hoverArea: NSTrackingArea?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    var isDragging: Bool { dragStart != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A completely transparent borderless-window pixel can be skipped by
        // WindowServer before NSWindow.sendEvent or NSView.hitTest is called.
        // Paint this toolbar-only input plane even while its artwork is hidden.
        // Keep alpha above 1/255 so it survives an 8-bit backing-store resolve.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local) else { return nil }
        // Only controls pass through this overlay. All toolbar whitespace is
        // an actual native mouse target, including the gaps around the capsule.
        if let window = window as? MirrorWindow,
           window.isToolbarControl(at: convert(local, to: nil)) { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        onEnter()
        dragStart = (mouse: NSEvent.mouseLocation, origin: window.frame.origin)
        window.makeKeyAndOrderFront(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = (window as? MirrorWindow)?.makeContextMenu?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        moveWindowWithPointer()
    }

    override func mouseUp(with event: NSEvent) {
        moveWindowWithPointer()
        dragStart = nil
        onExit()
    }

    private func moveWindowWithPointer() {
        guard let window, let dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                                      y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // SwiftUI's non-clipping hosts can expose a visibleRect larger than
        // this view. Track only the toolbar's own 44-point bounds.
        let area = NSTrackingArea(rect: bounds.intersection(visibleRect), options: [.activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}

final class DragAreaView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Geometry only: this view never handles input or covers a SwiftUI button.
private struct WindowControlArea: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> WindowControlAreaView {
        let view = WindowControlAreaView()
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: WindowControlAreaView, context: Context) {
        view.isEnabled = isEnabled
    }
}

final class WindowControlAreaView: NSView {
    var isEnabled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? MirrorWindow)?.toolbarControls.add(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func containsWindowPoint(_ point: CGPoint) -> Bool {
        guard isEnabled, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        // visibleRect is the ancestor clipping region, not the button bounds.
        // Under SwiftUI it can cover the entire window when clipsToBounds is
        // false; using it alone incorrectly excludes every point from dragging.
        return bounds.intersection(visibleRect).contains(convert(point, from: nil))
    }
}

enum WindowResizeCorner {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isTop: Bool {
        switch self {
        case .topLeft, .top, .topRight: true
        default: false
        }
    }

    var isBottom: Bool {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: true
        default: false
        }
    }

    var isLeft: Bool {
        switch self {
        case .topLeft, .left, .bottomLeft: true
        default: false
        }
    }

    var isRight: Bool {
        switch self {
        case .topRight, .right, .bottomRight: true
        default: false
        }
    }

    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight:
            NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .topRight, .bottomLeft:
            NSCursor.frameResize(position: .topRight, directions: .all)
        case .left, .right:
            NSCursor.resizeLeftRight
        case .top, .bottom:
            NSCursor.resizeUpDown
        }
    }

    func resizeVector(aspectRatio: Double) -> CGVector {
        let verticalPerWidth = 1 / CGFloat(aspectRatio)
        return switch self {
        case .topLeft:
            CGVector(dx: -1, dy: verticalPerWidth)
        case .topRight:
            CGVector(dx: 1, dy: verticalPerWidth)
        case .bottomLeft:
            CGVector(dx: -1, dy: -verticalPerWidth)
        case .bottomRight:
            CGVector(dx: 1, dy: -verticalPerWidth)
        case .left:
            CGVector(dx: -1, dy: 0)
        case .right:
            CGVector(dx: 1, dy: 0)
        case .top:
            CGVector(dx: 0, dy: verticalPerWidth)
        case .bottom:
            CGVector(dx: 0, dy: -verticalPerWidth)
        }
    }

    func containsResizePoint(_ point: CGPoint, in bounds: CGRect) -> Bool {
        guard bounds.contains(point) else { return false }
        return activeRects(in: bounds).contains { $0.contains(point) }
    }

    func activeRects(in bounds: CGRect) -> [CGRect] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let thickness = min(MirrorWindowChrome.resizeEdgeHitThickness, bounds.width, bounds.height)
        let minX = bounds.minX
        let maxX = bounds.maxX
        let minY = bounds.minY
        let maxY = bounds.maxY

        let horizontalRect: CGRect?
        let verticalRect: CGRect?

        switch self {
        case .topLeft:
            horizontalRect = CGRect(x: minX, y: maxY - thickness, width: bounds.width, height: thickness)
            verticalRect = CGRect(x: minX, y: minY, width: thickness, height: bounds.height)
        case .top:
            horizontalRect = CGRect(x: minX, y: maxY - thickness, width: bounds.width, height: thickness)
            verticalRect = nil
        case .topRight:
            horizontalRect = CGRect(x: minX, y: maxY - thickness, width: bounds.width, height: thickness)
            verticalRect = CGRect(x: maxX - thickness, y: minY, width: thickness, height: bounds.height)
        case .right:
            horizontalRect = nil
            verticalRect = CGRect(x: maxX - thickness, y: minY, width: thickness, height: bounds.height)
        case .bottomLeft:
            horizontalRect = CGRect(x: minX, y: minY, width: bounds.width, height: thickness)
            verticalRect = CGRect(x: minX, y: minY, width: thickness, height: bounds.height)
        case .bottom:
            horizontalRect = CGRect(x: minX, y: minY, width: bounds.width, height: thickness)
            verticalRect = nil
        case .bottomRight:
            horizontalRect = CGRect(x: minX, y: minY, width: bounds.width, height: thickness)
            verticalRect = CGRect(x: maxX - thickness, y: minY, width: thickness, height: bounds.height)
        case .left:
            horizontalRect = nil
            verticalRect = CGRect(x: minX, y: minY, width: thickness, height: bounds.height)
        }

        return [horizontalRect, verticalRect].compactMap { $0 }
    }
}

private extension CGVector {
    func projectedDistance(along vector: CGVector) -> CGFloat {
        let denominator = vector.dx * vector.dx + vector.dy * vector.dy
        guard denominator > 0 else { return 0 }
        return (dx * vector.dx + dy * vector.dy) / denominator
    }
}

private struct WindowResizeHandle: NSViewRepresentable {
    let region: WindowResizeCorner
    let aspectRatio: Double
    let onHover: () -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> ResizeHandleView {
        ResizeHandleView(region: region, aspectRatio: aspectRatio, onHover: onHover, onExit: onExit)
    }

    func updateNSView(_ nsView: ResizeHandleView, context: Context) {
        nsView.region = region
        nsView.aspectRatio = aspectRatio
        nsView.onHover = onHover
        nsView.onExit = onExit
    }
}

final class ResizeHandleView: NSView {
    var region: WindowResizeCorner
    var aspectRatio: Double
    var onHover: () -> Void
    var onExit: () -> Void
    private var startFrame: NSRect?
    private var startMouseLocation: NSPoint?
    private var didPushCursor = false
    private var resizeTrackingAreas: [NSTrackingArea] = []

    init(region: WindowResizeCorner, aspectRatio: Double, onHover: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.region = region
        self.aspectRatio = aspectRatio
        self.onHover = onHover
        self.onExit = onExit
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard region.containsResizePoint(convert(point, from: superview), in: bounds) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? MirrorWindow)?.resizeAreas.add(self)
    }

    func containsWindowPoint(_ point: CGPoint) -> Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && region.containsResizePoint(convert(point, from: nil), in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in resizeTrackingAreas {
            removeTrackingArea(area)
        }
        resizeTrackingAreas = region.activeRects(in: bounds).map { rect in
            NSTrackingArea(
                rect: rect,
                options: [.activeAlways, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
        }
        for area in resizeTrackingAreas {
            addTrackingArea(area)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in region.activeRects(in: bounds) {
            addCursorRect(rect, cursor: region.cursor)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover()
        pushCursor()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onExit()
        if startFrame == nil {
            popCursor()
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onHover()
        pushCursor()
        startFrame = window?.frame
        startMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startFrame,
              let startMouseLocation,
              aspectRatio > 0 else {
            return
        }

        let minPhoneHeight = max((window.contentMinSize.height - MirrorWindowChrome.height), 180)
        let resizeVector = region.resizeVector(aspectRatio: aspectRatio)
        let mouseDelta = CGVector(
            dx: NSEvent.mouseLocation.x - startMouseLocation.x,
            dy: NSEvent.mouseLocation.y - startMouseLocation.y
        )
        let projectedDelta = mouseDelta.projectedDistance(along: resizeVector)
        let proposedWidth: CGFloat
        switch region {
        case .top, .bottom:
            let startPhoneHeight = startFrame.height - MirrorWindowChrome.height
            proposedWidth = (startPhoneHeight + projectedDelta) * CGFloat(aspectRatio)
        default:
            proposedWidth = startFrame.width + projectedDelta
        }
        var width = proposedWidth
        width = max(width, max(window.contentMinSize.width, minPhoneHeight * aspectRatio))
        let phoneHeight = width / CGFloat(aspectRatio)
        let height = phoneHeight + MirrorWindowChrome.height

        var frame = startFrame
        switch region {
        case .topLeft:
            frame.origin.x = startFrame.maxX - width
            frame.origin.y = startFrame.minY
        case .top:
            frame.origin.x = startFrame.midX - width / 2
            frame.origin.y = startFrame.minY
        case .topRight:
            frame.origin.x = startFrame.minX
            frame.origin.y = startFrame.minY
        case .right:
            frame.origin.x = startFrame.minX
            frame.origin.y = startFrame.midY - height / 2
        case .bottomRight:
            frame.origin.x = startFrame.minX
            frame.origin.y = startFrame.maxY - height
        case .bottom:
            frame.origin.x = startFrame.midX - width / 2
            frame.origin.y = startFrame.maxY - height
        case .bottomLeft:
            frame.origin.x = startFrame.maxX - width
            frame.origin.y = startFrame.maxY - height
        case .left:
            frame.origin.x = startFrame.maxX - width
            frame.origin.y = startFrame.midY - height / 2
        }
        frame.size = CGSize(width: width, height: height)
        window.setFrame(frame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        startFrame = nil
        startMouseLocation = nil
        popCursor()
        onExit()
    }

    private func pushCursor() {
        guard !didPushCursor else { return }
        region.cursor.push()
        didPushCursor = true
    }

    private func popCursor() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }
}
