import AppKit
import SwiftUI

struct StandaloneMirrorWindowView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: AppiumControlSession

    let session: DeviceSession
    @State private var chromeVisible = false
    @State private var chromeHideWorkItem: DispatchWorkItem?

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
                    showChrome: showChrome,
                    scheduleHideChrome: scheduleHideChrome
                )
                .frame(height: MirrorWindowChrome.height)
                phoneFrame
            }

            resizeHandles
        }
        .background(windowShellColor.opacity(chromeVisible ? 1 : 0))
        .frame(minWidth: 180, minHeight: 180)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.16), value: statusTitle)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: statusTitle)
        .contextMenu {
            Button(mirrorSession.state == .running ? store.t("mirror.pause") : store.t("mirror.start")) {
                mirrorSession.state == .running ? store.stop(session) : store.start(session)
            }
            .disabled(session.device.connectionState != .connected)

            Divider()

            Button(controlSession.isReady ? store.t("mirror.disconnectControl") : store.t("card.installControlAgent")) {
                controlSession.isReady ? store.stopControl(for: session) : store.connectControl(for: session)
            }
            .disabled(session.device.udid == nil || session.device.connectionState != .connected)

            Button(store.t("mirror.home")) {
                store.pressHome(for: session)
            }
            .disabled(!controlSession.isReady)

            Button(store.t("mirror.appSwitcher")) {
                store.openAppSwitcher(for: session)
            }
            .disabled(!controlSession.isReady)

            Button(store.t("mirror.pasteClipboard")) {
                pasteClipboardText()
            }
            .disabled(!controlSession.isReady)

            Divider()

            Menu(store.t("mirror.size")) {
                ForEach(MirrorSizePreset.allCases, id: \.self) { preset in
                    Button(store.t(preset.labelKey)) {
                        MirrorWindowRegistry.shared.setSizePreset(
                            preset,
                            for: session,
                            aspectRatio: store.displayAspectRatio(for: session)
                        )
                    }
                }
            }

            Toggle(store.t("mirror.floatOnTop"), isOn: Binding(
                get: { store.isFloating(session) },
                set: { _ in store.toggleFloating(for: session) }
            ))

            Divider()

            Button(store.t("mirror.close")) {
                store.stop(session)
            }
        }
        .onAppear {
            if mirrorSession.state == .stopped {
                mirrorSession.start()
            }
        }
        .onChange(of: mirrorSession.frameAspectRatio) { _, newRatio in
            guard let newRatio else { return }
            MirrorWindowRegistry.shared.applyLiveAspectRatio(newRatio, for: session)
        }
    }

    private var windowShellColor: Color {
        Color(red: 0.83, green: 0.93, blue: 0.91)
    }

    private var resizeHandles: some View {
        let aspectRatio = mirrorSession.frameAspectRatio ?? store.displayAspectRatio(for: session)

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
        .allowsHitTesting(true)
    }

    private var phoneFrame: some View {
        GeometryReader { proxy in
            let cornerRadius = phoneCornerRadius(for: proxy.size)
            let phoneShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            ZStack {
                MirrorPreviewView(mirrorSession: mirrorSession, cornerRadius: cornerRadius)
                    .overlay(controlGestureLayer)
                    .overlay(keyboardForwardingLayer)

                if mirrorSession.state != .running || session.device.connectionState != .connected {
                    statusOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .clipShape(phoneShape)
            .overlay(
                phoneShape
                    .strokeBorder(.white.opacity(0.42), lineWidth: 0.7)
            )
            .overlay(
                phoneShape
                    .strokeBorder(.black.opacity(0.055), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.11), radius: 20, y: 10)
            .contentShape(phoneShape)
        }
        .background(Color.clear)
    }

    private var statusOverlay: some View {
        VStack(spacing: 12) {
            ProgressOrIcon(state: mirrorSession.state)
                .font(.system(size: 24, weight: .semibold))
            Text(statusTitle)
                .font(.headline)
            if session.device.connectionState != .connected {
                Text(store.t("mirror.reconnectingBody"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if case let .failed(message) = mirrorSession.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var statusTitle: String {
        session.device.connectionState == .connected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
    }

    private func phoneCornerRadius(for size: CGSize) -> CGFloat {
        // Real iPhone screen corners are ~14% of the short edge.
        min(max(min(size.width, size.height) * 0.14, 44), 96)
    }

    private var controlGestureLayer: some View {
        ControlGestureOverlay(
            isEnabled: controlSession.isReady,
            aspectRatio: store.displayAspectRatio(for: session),
            onTap: { point in
                store.tapControl(for: session, normalizedX: point.x, normalizedY: point.y)
            },
            onSwipe: { start, end, durationMS in
                store.swipeControl(for: session, from: start, to: end, durationMS: durationMS)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyboardForwardingLayer: some View {
        KeyboardForwardingView(
            isEnabled: controlSession.isReady && session.device.connectionState == .connected
        ) { text in
            store.typeControlText(text, for: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pasteClipboardText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        store.typeControlText(text, for: session)
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
        let workItem = DispatchWorkItem {
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
    let showChrome: () -> Void
    let scheduleHideChrome: () -> Void

    var body: some View {
        ZStack {
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .center) {
                HStack(spacing: 11) {
                    WindowDot(color: .systemRed) { _ in
                        store.stop(session)
                    }
                    WindowDot(color: .systemYellow) {
                        $0?.miniaturize(nil)
                    }
                    WindowDot(color: .systemGray) {
                        $0?.zoom(nil)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    ChromeIconButton(systemName: "chevron.backward", help: store.t("mirror.back")) {
                        store.pressBack(for: session)
                    }
                    .disabled(!session.controlSession.isReady)

                    ChromeIconButton(systemName: "house", help: store.t("mirror.home")) {
                        store.pressHome(for: session)
                    }
                    .disabled(!session.controlSession.isReady)

                    ChromeIconButton(systemName: "rectangle.grid.2x2", help: store.t("mirror.appSwitcher")) {
                        store.openAppSwitcher(for: session)
                    }
                    .disabled(!session.controlSession.isReady)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            inside ? showChrome() : scheduleHideChrome()
        }
    }
}

private struct ChromeIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.72))
        .background(.black.opacity(0.001))
        .help(help)
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

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView {
        DragAreaView()
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {}
}

private final class DragAreaView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
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

private final class ResizeHandleView: NSView {
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
        guard region.containsResizePoint(point, in: bounds) else { return nil }
        return super.hitTest(point)
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
