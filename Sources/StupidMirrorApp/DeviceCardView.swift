import SwiftUI

// Sidebar row: status dot, device name, one-line status. Native list feel.
struct DeviceRowView: View {
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
        }
    }

    private var statusLabel: String {
        isConnected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
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
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.Spacing.xl)
            .navigationTitle(session.device.name)
            .navigationSubtitle(session.device.subtitle)
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
                    if let thumbnail = store.thumbnails[session.id] {
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
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 8) {
                if store.thumbnailErrors[session.id] != nil {
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
            isEnabled: controlSession.isReady,
            aspectRatio: aspectRatio,
            onTap: { point in
                store.tapControl(for: session, normalizedX: point.x, normalizedY: point.y)
            },
            onSwipe: { start, end in
                store.swipeControl(for: session, from: start, to: end)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Lives in the full-width bottom bar. Status pills + actions for the
// currently selected device.
struct DeviceActionBar: View {
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
            .disabled(session.device.udid == nil || !isConnected)

            Button {
                store.pressBack(for: session)
            } label: {
                Label(store.t("mirror.back"), systemImage: "chevron.backward")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!controlSession.isReady)
            .help(store.t("mirror.back"))

            Button {
                store.pressHome(for: session)
            } label: {
                Label(store.t("mirror.home"), systemImage: "house")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!controlSession.isReady)
            .help(store.t("mirror.home"))

            Button {
                store.openAppSwitcher(for: session)
            } label: {
                Label(store.t("mirror.appSwitcher"), systemImage: "rectangle.grid.2x2")
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .disabled(!controlSession.isReady)
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
        }
    }

    private var mirrorStatusLabel: String {
        isConnected
            ? store.mirrorStateLabel(mirrorSession.state)
            : store.connectionStateLabel(session.device.connectionState)
    }

    private var controlButtonTitle: String {
        if controlSession.isReady {
            store.t("detail.disconnectControl")
        } else if controlSession.isConnecting {
            store.t("common.cancel")
        } else {
            store.t("detail.installControlAgent")
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
        switch controlSession.state {
        case .connecting:
            compactControlStatus(controlSession.statusMessage)
        case let .failed(message):
            localizedControlFailure(message)
        default:
            store.controlStateLabel(controlSession.state)
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
        switch controlSession.state {
        case .ready: Theme.Palette.control
        case .connecting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .unavailable: .secondary
        }
    }
}
