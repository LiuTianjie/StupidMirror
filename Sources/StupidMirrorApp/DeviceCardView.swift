import SwiftUI

// Sidebar row: status dot, device name, one-line status. Native list feel.
struct DeviceRowView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: AppiumControlSession
    @State private var confirmsRemoval = false

    let session: DeviceSession

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    private var isConnected: Bool { session.device.connectionState == .connected }
    private var isLive: Bool { mirrorSession.state == .running && isConnected }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 16))
                .foregroundStyle(isConnected ? .primary : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.device.name)
                    .font(.body)
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 3)
        .opacity(isConnected ? 1 : 0.6)
        .contextMenu {
            Button(store.t("card.openMirror")) { store.start(session) }
                .disabled(!isConnected)
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
    }

    private var statusLabel: String {
        let state = isConnected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
        let transport = session.transport == .wireless
            ? store.t("transport.wireless")
            : store.t("transport.usb")
        return "\(state) · \(transport)"
    }

    private var statusColor: Color {
        switch mirrorSession.state {
        case .running: isConnected ? Theme.Palette.live : Theme.Palette.pending
        case .starting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .stopped: isConnected ? Color.secondary.opacity(0.5) : Theme.Palette.pending
        }
    }
}

// Detail pane: large preview, device meta, native action buttons.
struct DeviceDetailView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: AppiumControlSession

    let session: DeviceSession

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    private var isConnected: Bool { session.device.connectionState == .connected }
    private var isLive: Bool { mirrorSession.state == .running && isConnected }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Theme.Spacing.xl)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(Theme.Palette.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.device.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            StatusPill(
                title: session.transport == .wireless
                    ? store.t("transport.wireless")
                    : store.t("transport.usb"),
                color: session.transport == .wireless ? Theme.Palette.control : .secondary
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 56)
        .background(.bar)
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { proxy in
            let aspect = store.displayAspectRatio(for: session)
            let size = fittedSize(in: proxy.size, aspect: aspect)
            let radius = min(size.width, size.height) * 0.12

            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

                Group {
                    if session.transport == .wireless,
                       let wirelessFrame = mirrorSession.latestWirelessFrame {
                        Image(nsImage: wirelessFrame)
                            .resizable()
                            .scaledToFill()
                    } else if let thumbnail = store.thumbnails[session.id] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(controlGestureLayer(aspectRatio: aspect))
                .overlay {
                    AutomationActionOverlayView(actions: mirrorSession.automationActions)
                }

                if controlSession.isConnecting {
                    Color.black.opacity(0.42)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .allowsHitTesting(false)

                    ControlConnectionLoadingView(controlSession: controlSession) {
                        store.stopControl(for: session)
                    }
                    .padding(Theme.Spacing.md)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeOut(duration: 0.18), value: controlSession.isConnecting)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 8) {
                if case let .failed(message) = mirrorSession.state {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                } else if mirrorSession.state == .starting {
                    ProgressView().controlSize(.small)
                    if session.transport == .wireless {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 4) {
                                Text(mirrorSession.wirelessStartupDetail
                                    ?? store.t("detail.wirelessStarting"))
                                Text(String(
                                    format: store.t("wireless.start.elapsed"),
                                    wirelessStartupElapsed(at: context.date)
                                ))
                                .foregroundStyle(.tertiary)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 220)
                        }
                        Button(store.t("wireless.start.cancel")) {
                            store.stop(session)
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                } else if session.transport == .wireless && mirrorSession.state == .stopped {
                    Image(systemName: "play.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(store.t("detail.wirelessStopped"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if store.thumbnailErrors[session.id] != nil {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                } else if isConnected {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func wirelessStartupElapsed(at date: Date) -> Int {
        guard let beganAt = mirrorSession.wirelessStartupBeganAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(beganAt)))
    }

    private func fittedSize(in container: CGSize, aspect: Double) -> CGSize {
        let ratio = CGFloat(max(aspect, 0.1))
        let w = container.width
        let h = container.height
        if w / h > ratio {
            return CGSize(width: h * ratio, height: h)
        }
        return CGSize(width: w, height: w / ratio)
    }

    private func controlGestureLayer(aspectRatio: Double) -> some View {
        ControlGestureOverlay(
            isEnabled: store.canUseControl && controlSession.isReady,
            aspectRatio: aspectRatio,
            onTap: { point in
                store.tapControl(for: session, normalizedX: point.x, normalizedY: point.y)
            },
            onSwipe: { start, end, durationMS in
                store.swipeControl(for: session, from: start, to: end, durationMS: durationMS)
            },
            onFlick: { direction in
                store.flickControl(for: session, direction: direction)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ControlConnectionLoadingView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var controlSession: AppiumControlSession
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = elapsedSeconds(at: timeline.date)

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Theme.Palette.accent)

                VStack(spacing: 4) {
                    Text(store.t("control.loading.title"))
                        .font(.headline)
                        .foregroundStyle(Theme.Overlay.primaryText)
                    Text(store.t(phaseTitleKey))
                        .font(.callout)
                        .foregroundStyle(Theme.Overlay.secondaryText)
                        .multilineTextAlignment(.center)
                }

                Text(store.t(expectationKey))
                    .font(.caption)
                    .foregroundStyle(Theme.Overlay.secondaryText)
                    .multilineTextAlignment(.center)

                Text(String(
                    format: store.t("control.loading.elapsed"),
                    elapsed / 60,
                    elapsed % 60
                ))
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.Palette.pending)

                Text(store.t("control.loading.keepAwake"))
                    .font(.caption2)
                    .foregroundStyle(Theme.Overlay.tertiaryText)
                    .multilineTextAlignment(.center)

                Button(store.t("common.cancel"), action: cancel)
                    .controlSize(.small)
                    .tint(Theme.Overlay.primaryText)
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(Theme.Overlay.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.Overlay.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
    }

    private var phaseTitleKey: String {
        switch controlSession.connectionPhase ?? .startingService {
        case .startingService: "control.loading.startingService"
        case .reusingAgent: "control.loading.reusingAgent"
        case .installingAgent: "control.loading.installingAgent"
        case .finishing: "control.loading.finishing"
        }
    }

    private var expectationKey: String {
        switch controlSession.connectionPhase ?? .startingService {
        case .startingService: "control.loading.expectation.short"
        case .reusingAgent: "control.loading.expectation.reuse"
        case .installingAgent: "control.loading.expectation.install"
        case .finishing: "control.loading.expectation.finishing"
        }
    }

    private func elapsedSeconds(at date: Date) -> Int {
        guard let startedAt = controlSession.connectionStartedAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(startedAt)))
    }
}

#if DEBUG
struct ControlConnectionLoadingDebugPreview: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @StateObject private var controlSession: AppiumControlSession

    init() {
        _controlSession = StateObject(wrappedValue: AppiumControlSession(device: DeviceIdentity(
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
            controlSession.showConnectionPreview(phase: .installingAgent, elapsedSeconds: 73)
        }
    }
}
#endif

// Lives in the full-width bottom bar. Status pills + actions for the
// currently selected device.
struct DeviceActionBar: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: AppiumControlSession
    @State private var confirmsRemoval = false

    let session: DeviceSession

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    private var isConnected: Bool { session.device.connectionState == .connected }
    private var isLive: Bool { mirrorSession.state == .running && isConnected }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatusPill(title: mirrorStatusLabel, color: mirrorStatusColor)
            StatusPill(title: controlStatusLabel, color: controlColor)

            Button {
                store.refreshThumbnail(for: session)
            } label: {
                Label(store.t("card.refreshThumbnail"), systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!isConnected)
            .help(store.t("card.refreshThumbnail"))

            Button {
                if controlSession.isReady || controlSession.isConnecting {
                    store.stopControl(for: session)
                } else {
                    store.connectControl(for: session)
                }
            } label: {
                Label(
                    controlButtonTitle,
                    systemImage: controlButtonIcon
                )
            }
            .controlSize(.small)
            .disabled(!isConnected || (store.canUseControl && session.device.udid == nil))
            .help(store.t(store.canUseControl ? "detail.controlHelp" : "detail.controlActivationHelp"))

            Button {
                store.pressBack(for: session)
            } label: {
                Label(store.t("mirror.back"), systemImage: "chevron.backward")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!store.canUseControl || !controlSession.isReady)
            .help(store.t("mirror.back"))

            Button {
                store.pressHome(for: session)
            } label: {
                Label(store.t("mirror.home"), systemImage: "house")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!store.canUseControl || !controlSession.isReady)
            .help(store.t("mirror.home"))

            Button {
                store.openAppSwitcher(for: session)
            } label: {
                Label(store.t("mirror.appSwitcher"), systemImage: "rectangle.grid.2x2")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!store.canUseControl || !controlSession.isReady)
            .help(store.t("mirror.appSwitcher"))

            Button {
                isLive ? store.stop(session) : store.start(session)
            } label: {
                Label(
                    isLive ? store.t("detail.closeMirror") : store.t("detail.openMirror"),
                    systemImage: isLive ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(isLive ? Theme.Palette.danger : Theme.Palette.accent)
            .disabled(!isConnected)

            Menu {
                Button(store.t("device.remove"), role: .destructive) {
                    confirmsRemoval = true
                }
            } label: {
                Label(store.t("device.actions"), systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .help(store.t("device.actions"))
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

    private var mirrorStatusLabel: String {
        isConnected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
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
            "square.and.arrow.down"
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
        default:
            return store.controlStateLabel(controlSession.state)
        }
    }

    private func localizedControlFailure(_ message: String) -> String {
        if message.hasPrefix("control.error.") {
            return store.t(message)
        }
        return message.isEmpty ? store.t("control.state.failed") : message
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

    private var mirrorStatusColor: Color {
        switch mirrorSession.state {
        case .running: isConnected ? Theme.Palette.live : Theme.Palette.pending
        case .starting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .stopped: isConnected ? Color.secondary : Theme.Palette.pending
        }
    }

    private var controlColor: Color {
        if !store.canUseControl { return Theme.Palette.pending }
        switch controlSession.state {
        case .ready: return Theme.Palette.control
        case .connecting: return Theme.Palette.pending
        case .failed: return Theme.Palette.danger
        case .unavailable: return .secondary
        }
    }
}
