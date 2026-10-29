import SwiftUI

// Sidebar row: platform icon, name, state and transport, a state dot.
struct DeviceRowView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: DeviceControlSession
    @State private var confirmsRemoval = false
    @State private var isHovered = false

    let session: DeviceSession
    let isSelected: Bool
    let select: () -> Void

    init(session: DeviceSession, isSelected: Bool, select: @escaping () -> Void) {
        self.session = session
        self.isSelected = isSelected
        self.select = select
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    private var isConnected: Bool { session.device.connectionState == .connected }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: session.platform.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.tertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.device.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
                        .lineLimit(1)
                    Text(statusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if controlSession.isReady {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.control)
                        .help(store.controlStateLabel(controlSession.state))
                }

                if let statusColor {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.Surface.sidebarSelection : (isHovered ? Theme.Surface.sidebarHover : .clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isConnected ? 1 : 0.6)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(store.t("card.openMirror")) { store.start(session) }
                .disabled(!store.canAttemptConnection(session))
            Button(store.t("card.stopMirror")) { store.stop(session) }
            Divider()
            Button(store.t("card.refreshThumbnail")) { store.refreshThumbnail(for: session) }
                .disabled(!isConnected)
            Divider()
            Button(store.t("device.remove"), role: .destructive) {
                confirmsRemoval = true
            }
        }
        .confirmationDialog(
            store.t("device.remove.title"),
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button(store.t("device.remove"), role: .destructive) {
                store.removeDevice(session)
            }
            Button(store.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: store.t("device.remove.message"), session.device.name))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusLabel: String {
        let state = isConnected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
        return "\(state) · \(session.transportLabel(store))"
    }

    /// Only states worth a glance get a dot; a stopped, connected device
    /// is the resting case and the label already says so.
    private var statusColor: Color? {
        switch mirrorSession.state {
        case .running: isConnected ? Theme.Palette.live : Theme.Palette.pending
        case .starting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .stopped: isConnected ? nil : Theme.Palette.pending
        }
    }
}

extension DeviceSession {
    @MainActor
    func transportLabel(_ store: DeviceGalleryStore) -> String {
        if transport == .simulator { return store.t("transport.simulator") }
        if platform == .android { return store.t("transport.adb") }
        return transport == .wireless ? store.t("transport.wireless") : store.t("transport.usb")
    }
}

// Keep identity and connection state compact so the live screen gets the space.
struct DeviceDetailView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: DeviceControlSession

    let session: DeviceSession

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    private var isConnected: Bool { session.device.connectionState == .connected }

    /// The well's corner follows the panel's: panel radius minus this inset.
    private static let wellInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactHeader

            preview
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .wellSurface(radius: Theme.Radius.panel - Self.wellInset, outlined: false)
                .padding(.horizontal, Self.wellInset)

            DeviceActionDock(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .panelSurface()
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.device.name)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    Text(session.transportLabel(store))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize()
                }
                .help(headerSubtitle)
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        StateDot(kind: mirrorGlyph)
                        Text("\(store.t("diagnostic.mirror")) \(mirrorStatusLabel)")
                    }
                    .help([mirrorStatusLabel, mirrorDetail].compactMap { $0 }.joined(separator: " · "))
                    HStack(spacing: 6) {
                        StateDot(kind: controlGlyph)
                        Text("\(store.t("diagnostic.control")) \(controlStatusLabel)")
                        if isConnected && store.canUseControl && controlSession.supportsContinuousTouch {
                            Text("HID")
                                .font(Theme.mono(9, weight: .semibold))
                                .foregroundStyle(Theme.Palette.control)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.tint(Theme.Palette.control), in: Capsule())
                                .fixedSize()
                                .help(store.t("dashboard.control.hidHelp"))
                                .accessibilityLabel(store.t("dashboard.control.hidHelp"))
                        }
                    }
                    .help([controlStatusLabel, controlDetail].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.isIOSSimulator && session.device.formFactor == .foldable {
                ViewThatFits(in: .horizontal) {
                    DevicePosturePicker(session: session).fixedSize()
                    DevicePosturePicker(session: session, showsLabels: false).fixedSize()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// "iPhone18,4 · iOS 27.0 · 00008150", one separator throughout.
    private var headerSubtitle: String {
        let device = session.device
        var parts = [device.productType]
        if let version = device.osVersion, !version.isEmpty {
            let platform = session.platform == .android ? "Android" : "iOS"
            parts.append(version.hasPrefix(platform) ? version : "\(platform) \(version)")
        }
        if let udid = device.udid, !udid.isEmpty {
            parts.append(String(udid.prefix(8)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Status lines

    private var mirrorGlyph: StatusGlyph.Kind {
        guard isConnected else { return .working }
        switch mirrorSession.state {
        case .running: return .done
        case .starting: return .working
        case .failed: return .failed
        case .stopped: return .idle
        }
    }

    /// The state alone: the line already starts with "Mirror", so the
    /// sidebar's "镜像中" would read "镜像 镜像中" here.
    private var mirrorStatusLabel: String {
        guard isConnected else { return store.connectionStateLabel(session.device.connectionState) }
        return switch mirrorSession.state {
        case .running: store.t("dashboard.mirror.running")
        case .starting: store.t("mirror.state.starting")
        case .stopped: store.t("mirror.state.stopped")
        case .failed: store.t("mirror.state.failed")
        }
    }

    private var mirrorDetail: String? {
        guard isConnected else { return store.t("mirror.reconnectingBody") }
        switch mirrorSession.state {
        case .running:
            if let ratio = mirrorSession.frameAspectRatio {
                return session.transportLabel(store) + " · " + aspectLabel(ratio)
            }
            return session.transportLabel(store)
        case .starting:
            return mirrorSession.wirelessStartupDetail
        case let .failed(message):
            return message
        case .stopped:
            return nil
        }
    }

    private var controlGlyph: StatusGlyph.Kind {
        if !store.canUseControl { return .warning }
        switch controlSession.state {
        case .ready: return .control
        case .connecting: return .working
        case .failed: return .failed
        case .unavailable: return .idle
        }
    }

    private var controlStatusLabel: String {
        if !store.canUseControl {
            return store.t("control.state.activationRequired")
        }
        switch controlSession.state {
        case .connecting:
            return compactControlStatus(controlSession.statusMessage)
        case let .failed(message):
            return localizedControlFailure(message)
        case .unavailable:
            return store.t("dashboard.control.notConnected")
        case .ready:
            return store.t("dashboard.control.ready")
        }
    }

    private var controlDetail: String? {
        if !store.canUseControl { return nil }
        switch controlSession.state {
        case .ready: return store.t("dashboard.control.readyDetail")
        case .unavailable: return store.t("dashboard.control.optional")
        default: return nil
        }
    }

    private func aspectLabel(_ ratio: Double) -> String {
        ratio < 1 ? store.t("dashboard.orientation.portrait") : store.t("dashboard.orientation.landscape")
    }

    private func localizedControlFailure(_ message: String) -> String {
        if message.hasPrefix("control.error.") {
            return store.t(message)
        }
        return message.isEmpty ? store.t("mirror.state.failed") : message
    }

    private func compactControlStatus(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Appium") {
            return store.t("control.phase.appium")
        }
        if message.localizedCaseInsensitiveContains("WebDriverAgent")
            || message.localizedCaseInsensitiveContains("WDA") {
            return store.t("control.phase.wda")
        }
        if message.localizedCaseInsensitiveContains("screen size") {
            return store.t("control.phase.screen")
        }
        return store.t("control.state.connecting")
    }

    // MARK: Preview

    private var preview: some View {
        let aspect = store.displayAspectRatio(for: session)
        let bezel = MirrorBezelCatalog.bezel(for: session, aspectRatio: aspect)
        let hasLivePreview = !session.needsCameraPermission && mirrorSession.state == .running
        return DeviceBezelView(bezel: bezel, gestureHandlers: hasLivePreview && isConnected
                              && store.canUseControl && controlSession.isReady
                              && !mirrorSession.isChangingPosture ? store.gestureHandlers(for: session) : nil,
                              screenImage: mirrorSession.latestWirelessFrame ?? store.thumbnails[session.id],
                              mirrorSession: mirrorSession) {
            ZStack {
                Color.black
                Group {
                    if hasLivePreview {
                        MirrorPreviewView(mirrorSession: mirrorSession, forwardsAudio: false)
                    } else if !session.needsCameraPermission, let frame = mirrorSession.latestWirelessFrame {
                        Image(nsImage: frame).resizable().scaledToFit()
                    } else if let thumbnail = store.thumbnails[session.id] {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        placeholder
                    }
                }
                .overlay { AutomationActionOverlayView(actions: mirrorSession.automationActions) }
                if controlSession.isConnecting {
                    Color.black.opacity(0.5).allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if controlSession.isConnecting {
                ControlConnectionLoadingView(controlSession: controlSession) {
                    store.stopControl(for: session)
                }
                .padding(Theme.Spacing.md)
            }
        }
    }

    /// An unlit phone screen: always dark, whatever the window appearance,
    /// so the bezel reads as a device rather than a grey card.
    private var placeholder: some View {
        ZStack {
            Color(white: 0.07)
            VStack(spacing: 12) {
                if case let .failed(message) = mirrorSession.state {
                    StatusGlyph(kind: .failed, size: 30)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                } else if mirrorSession.state == .starting {
                    StatusGlyph(kind: .working, size: 30)
                    if session.showsMirrorStartupProgress {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 4) {
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
                            .frame(maxWidth: 220)
                        }
                        Button(store.t("agent.start.cancel")) {
                            store.stop(session)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                } else if session.usesIOSAgentVideo && mirrorSession.state == .stopped {
                    Button {
                        store.start(session)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.14), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canAttemptConnection(session))
                    .accessibilityLabel(store.t("detail.openMirror"))
                    Text(store.t("detail.wirelessStopped"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                } else if store.thumbnailErrors[session.id] != nil {
                    StatusGlyph(kind: .warning, size: 30)
                } else if isConnected {
                    StatusGlyph(kind: .working, size: 30)
                } else {
                    StatusGlyph(kind: .working, size: 30)
                    Text(store.t("mirror.reconnectingBody"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func wirelessStartupElapsed(at date: Date) -> Int {
        guard let beganAt = mirrorSession.wirelessStartupBeganAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(beganAt)))
    }
}

struct ControlConnectionLoadingView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var controlSession: DeviceControlSession
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = elapsedSeconds(at: timeline.date)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusGlyph(kind: .working, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.t(titleKey))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.Overlay.primaryText)
                        Text(store.t(phaseTitleKey))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Overlay.secondaryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(store.t(expectationKey))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Overlay.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(store.t(keepAwakeKey))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Overlay.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(String(format: store.t("control.loading.elapsed"), elapsed / 60, elapsed % 60))
                        .font(Theme.mono(12, weight: .medium))
                        .foregroundStyle(Theme.Palette.pending)
                    Spacer(minLength: 8)
                    Button(store.t("common.cancel"), action: cancel)
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        .fixedSize()
                }
            }
            .padding(16)
            .frame(maxWidth: 330)
            .background(Theme.Overlay.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Overlay.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
    }

    private var phaseTitleKey: String {
        let phase = controlSession.connectionPhase ?? .startingAgent
        if controlSession.platform == .android {
            return switch phase {
            case .startingService: "control.loading.android.startingService"
            case .startingAgent, .connectingAgent: "control.loading.android.connectingAgent"
            case .finishing: "control.loading.android.finishing"
            }
        }
        return switch phase {
        case .startingService, .startingAgent: "control.loading.startingAgent"
        case .connectingAgent: "control.loading.connectingAgent"
        case .finishing: "control.loading.finishing"
        }
    }

    private var expectationKey: String {
        let phase = controlSession.connectionPhase ?? .startingAgent
        if controlSession.platform == .android {
            return switch phase {
            case .startingService: "control.loading.expectation.short"
            case .startingAgent, .connectingAgent: "control.loading.android.expectation.agent"
            case .finishing: "control.loading.expectation.finishing"
            }
        }
        return switch phase {
        case .startingService, .startingAgent: "control.loading.expectation.agent"
        case .connectingAgent: "control.loading.expectation.short"
        case .finishing: "control.loading.expectation.finishing"
        }
    }

    private var titleKey: String {
        controlSession.platform == .android
            ? "control.loading.android.title"
            : "control.loading.title"
    }

    private var keepAwakeKey: String {
        controlSession.platform == .android
            ? "control.loading.android.keepAwake"
            : "control.loading.keepAwake"
    }

    private func elapsedSeconds(at date: Date) -> Int {
        guard let startedAt = controlSession.connectionStartedAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(startedAt)))
    }
}

#if DEBUG
struct ControlConnectionLoadingDebugPreview: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @StateObject private var controlSession: DeviceControlSession

    init() {
        _controlSession = StateObject(wrappedValue: DeviceControlSession(device: DeviceIdentity(
            id: "loading-preview",
            udid: "00000000-0000000000000000",
            name: "Preview iPhone",
            productType: "iPhone",
            osVersion: nil,
            connectionState: .connected,
            trustState: .trusted
        )))
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Color.white
                Color(red: 0.75, green: 0.18, blue: 0.22)
                Color(red: 0.08, green: 0.36, blue: 0.72)
            }
            Color.black.opacity(0.42)
                .ignoresSafeArea()
            ControlConnectionLoadingView(controlSession: controlSession) {}
                .environmentObject(store)
                .padding(24)
        }
        .onAppear {
            controlSession.showConnectionPreview(phase: .startingAgent, elapsedSeconds: 73)
        }
    }
}
#endif

// The row under the screen: phone navigation on the left, then refresh,
// more, control and the mirror window. Opening the mirror is the one white
// pill on the panel.
struct DeviceActionDock: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: DeviceControlSession
    @State private var confirmsRemoval = false

    let session: DeviceSession

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    private var isConnected: Bool { session.device.connectionState == .connected }
    private var isLive: Bool { mirrorSession.state == .running && isConnected }
    private var navigationDisabled: Bool { !store.canUseControl || !controlSession.isReady }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    store.pressBack(for: session)
                } label: {
                    Label(store.t("mirror.back"), systemImage: "chevron.backward")
                }
                .help(store.t("mirror.back"))

                Button {
                    store.pressHome(for: session)
                } label: {
                    Label(store.t("mirror.home"), systemImage: "house")
                }
                .help(store.t("mirror.home"))

                Button {
                    store.openAppSwitcher(for: session)
                } label: {
                    Label(store.t("mirror.appSwitcher"), systemImage: "rectangle.grid.2x2")
                }
                .help(store.t("mirror.appSwitcher"))
            }
            .buttonStyle(IconButtonStyle())
            .disabled(navigationDisabled)
            .padding(3)
            .outlinedCapsule(fill: Theme.Surface.well, stroke: Theme.Surface.hairline)

            Spacer(minLength: 8)

            Menu {
                Button(store.t("card.refreshThumbnail")) {
                    store.refreshThumbnail(for: session)
                }
                .disabled(!isConnected)
                Divider()
                Button(store.t("device.remove"), role: .destructive) {
                    confirmsRemoval = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Ink.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(store.t("device.actions"))
            .accessibilityLabel(store.t("device.actions"))

            Button {
                if controlSession.isReady || controlSession.isConnecting {
                    store.stopControl(for: session)
                } else {
                    store.connectControl(for: session)
                }
            } label: {
                Label(controlButtonTitle, systemImage: controlButtonIcon)
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .disabled(!store.canAttemptConnection(session) || (store.canUseControl && session.device.udid == nil))
            .help(store.t(store.canUseControl ? "detail.controlHelp" : "detail.controlActivationHelp"))

            Button {
                isLive ? store.stop(session) : store.start(session)
            } label: {
                Label(
                    isLive ? store.t("detail.closeMirror") : store.t("detail.openMirror"),
                    systemImage: isLive ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(PillButtonStyle(kind: isLive ? .secondary : .primary))
            .disabled(!store.canAttemptConnection(session))
        }
        .confirmationDialog(
            store.t("device.remove.title"),
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button(store.t("device.remove"), role: .destructive) {
                store.removeDevice(session)
            }
            Button(store.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: store.t("device.remove.message"), session.device.name))
        }
    }

    private var controlButtonTitle: String {
        if controlSession.isReady {
            return store.t("detail.disconnectControl")
        } else if controlSession.isConnecting {
            return store.t("common.cancel")
        } else {
            return store.t("detail.installControlAgent")
        }
    }

    private var controlButtonIcon: String {
        if controlSession.isReady || controlSession.isConnecting {
            "bolt.slash"
        } else {
            "hand.tap"
        }
    }
}
