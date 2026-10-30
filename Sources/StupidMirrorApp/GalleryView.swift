import AppKit
import Combine
import SwiftUI

// The dashboard: a top strip on the window ground carrying the app's global
// controls, the device list and the selected device as two dark panels, and
// one status line at the foot.
struct GalleryView: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(spacing: 0) {
            DashboardTopBar()
                .frame(height: DashboardWindowLayout.topBarHeight)

            HStack(alignment: .top, spacing: DashboardWindowLayout.gutter) {
                DeviceSidebar()
                    .frame(width: DashboardWindowLayout.sidebarWidth)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, DashboardWindowLayout.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusFooter
                .frame(height: DashboardWindowLayout.bottomBarHeight)
        }
        // The title bar is transparent; let the top strip share its row with
        // the traffic lights instead of sitting under an empty band.
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.Surface.ground)
        .foregroundStyle(Theme.Ink.primary)
        #if DEBUG
        .overlay {
            if ProcessInfo.processInfo.environment["STUPIDMIRROR_CONTROL_LOADING_PREVIEW"] == "1" {
                ControlConnectionLoadingDebugPreview()
            }
        }
        #endif
        .sheet(item: activeSheetBinding) { sheet in
            Group {
                switch sheet {
                case .diagnostics:
                    DiagnosticsView()
                        .environmentObject(store)
                        .frame(width: 580, height: 540)
                case .settings:
                    SettingsView(initialTab: store.settingsTab)
                        .environmentObject(store)
                        .frame(width: 800, height: 600)
                case .activation:
                    SettingsView(initialTab: .license)
                        .environmentObject(store)
                        .frame(width: 800, height: 600)
                case .iphoneSetup:
                    IPhoneSetupGuideView()
                        .environmentObject(store)
                        .frame(width: 640)
                }
            }
            .foregroundStyle(Theme.Ink.primary)
            .presentationBackground(Theme.Surface.panel)
        }
    }

    // MARK: Status footer

    private var statusFooter: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: Theme.Spacing.sm) {
                Circle()
                    .fill(store.connectedSessions.isEmpty ? Theme.Ink.tertiary : Theme.Palette.live)
                    .frame(width: 6, height: 6)
                Text(store.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if store.shouldOfferControlDiagnostics {
                    Button(store.t("status.controlOpenDiagnostics")) {
                        store.presentDiagnostics()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DashboardWindowLayout.gutter + 8)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if store.cameraPermissionPresentation == .fullPage {
            PermissionView()
        } else {
            VStack(spacing: DashboardWindowLayout.gutter) {
                if store.cameraPermissionPresentation == .banner {
                    CameraPermissionBanner()
                }

                if store.microphonePermissionStatus != .authorized
                    && store.audioPlaybackEnabled
                    && store.hasConnectedIOSDevice {
                    MicrophonePermissionBanner()
                }

                authorizedDetail
            }
        }
    }

    @ViewBuilder
    private var authorizedDetail: some View {
        if let session = selectedSession {
            DeviceDetailView(session: session)
                .id(session.id)
        } else if store.sessions.isEmpty {
            EmptyDevicesView(refresh: store.refresh)
        } else {
            ContentUnavailablePlaceholder(
                icon: "iphone.gen3",
                title: store.t("detail.selectTitle"),
                message: store.t("detail.selectBody")
            )
        }
    }

    private var selectedSession: DeviceSession? {
        guard let id = store.selectedSessionID else { return nil }
        return store.sessions.first { $0.id == id }
    }

    private var activeSheetBinding: Binding<DashboardSheet?> {
        Binding(
            get: { store.activeSheet },
            set: { store.setActiveSheet($0) }
        )
    }
}

// MARK: - Top bar

/// The strip beside the traffic lights: the product name, then the global
/// actions that used to live in the toolbar. The strip itself drags the
/// window.
private struct DashboardTopBar: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    BrandMark(size: 15)
                    Text("StupidMirror")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Ink.primary)
                }
                .allowsHitTesting(false)

                Spacer(minLength: 12)

                if store.licenseManager.showsDashboardActivationEntry {
                    Button {
                        store.presentActivation()
                    } label: {
                        Label(store.t("license.badge.unactivated"), systemImage: licenseBadgeIcon)
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                    .help(store.t("license.badge.help"))
                }

                MCPStatusButton(manager: store.mcpServer)

                Rectangle()
                    .fill(Theme.Surface.hairline)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 6)

                Button {
                    store.discoverWirelessDevices()
                } label: {
                    Label(store.t("toolbar.discoverWireless"), systemImage: "wifi")
                }
                .buttonStyle(IconButtonStyle(isOn: store.wirelessMirroringEnabled))
                .help(store.t("toolbar.discoverWirelessHelp"))

                Button {
                    store.refresh()
                } label: {
                    Label(store.t("toolbar.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut("r", modifiers: [.command])
                .help(store.t("toolbar.refresh"))
                .padding(.trailing, 6)

                Button {
                    store.toggleDiagnostics()
                } label: {
                    Label(store.t("toolbar.diagnostics"), systemImage: "stethoscope")
                }
                .buttonStyle(IconButtonStyle())
                .help(store.t("toolbar.diagnostics"))

                Button {
                    store.toggleSettings()
                } label: {
                    Label(store.t("toolbar.settings"), systemImage: "gearshape")
                }
                .buttonStyle(IconButtonStyle())
                .help(store.t("toolbar.settings"))
            }
            // Clear the traffic lights on the leading edge.
            .padding(.leading, 84)
            .padding(.trailing, DashboardWindowLayout.gutter + 4)
        }
    }

    private var licenseBadgeIcon: String {
        switch store.licenseManager.state {
        case .unavailable:
            "lock"
        case .unlicensed, .checking, .licensed:
            "key"
        }
    }
}

/// "MCP :8765" with a state dot; opens the MCP settings.
private struct MCPStatusButton: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var manager: MCPServerManager

    var body: some View {
        Button {
            store.presentMCPSettings()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text("MCP")
                    .font(.system(size: 12, weight: .medium))
                if manager.status.isRunning {
                    Text(":\(String(manager.port))")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
        .help(store.t("toolbar.mcp"))
    }

    private var dotColor: Color {
        switch manager.status {
        case .running: Theme.Palette.live
        case .starting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .stopped: Theme.Ink.tertiary
        }
    }
}

// MARK: - Sidebar

private struct DeviceSidebar: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.t("menu.devices"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
                Spacer(minLength: 8)
                if !store.connectedSessions.isEmpty {
                    Text(String(store.connectedSessions.count))
                        .font(Theme.mono(11, weight: .medium))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .help(String(format: store.t("dashboard.sidebar.connected"), store.connectedSessions.count))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.sessions.isEmpty {
                        Text(store.t("menu.noDevices"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Ink.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .strokeBorder(
                                        Theme.Surface.controlStroke,
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                    )
                            }
                    } else {
                        ForEach(store.sessions) { session in
                            DeviceRowView(
                                session: session,
                                isSelected: store.selectedSessionID == session.id
                            ) {
                                store.select(session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Surface.sidebarDivider)
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                SidebarSwitchRow(
                    title: store.t("toolbar.autoStart"),
                    systemImage: store.autoStartMirrors ? "bolt.fill" : "bolt",
                    isOn: $store.autoStartMirrors
                )
                .help(store.t("settings.autoOpen"))

                SidebarSwitchRow(
                    title: store.t("toolbar.audioPlayback"),
                    systemImage: store.audioPlaybackEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    isOn: store.audioPlaybackToggle
                )
                .disabled((store.isRequestingMicrophonePermission || store.isRequestingCameraPermission) || !store.canPlayDeviceAudioOnMac)
                .help(store.t("settings.audioPlaybackHelp"))

                if hasActiveWork {
                    Button {
                        store.stopAll()
                    } label: {
                        Label(store.t("menu.stopAll"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .help(store.t("menu.stopAll"))
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 8)
            .animation(.easeOut(duration: 0.15), value: hasActiveWork)
        }
        // The sidebar is part of the window, not a card on it: only the
        // device panel is raised, so the selection reads as feeding it.
        .frame(maxHeight: .infinity, alignment: .top)
        .onReceive(activityChanges) { _ in updateActiveWork() }
        .onAppear(perform: updateActiveWork)
    }

    /// "Stop all" only means something while a mirror or control session is
    /// up; the same command stays in the app menu as ⌘. at all times.
    @State private var hasActiveWork = false

    private var activityChanges: AnyPublisher<Void, Never> {
        let mirrors = store.sessions.map { $0.mirrorSession.$state.map { _ in () }.eraseToAnyPublisher() }
        let controls = store.sessions.map { $0.controlSession.$state.map { _ in () }.eraseToAnyPublisher() }
        return Publishers.MergeMany(mirrors + controls + [store.$sessions.map { _ in () }.eraseToAnyPublisher()])
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    private func updateActiveWork() {
        hasActiveWork = store.sessions.contains { session in
            session.mirrorSession.state != .stopped || session.controlSession.state != .unavailable
        }
    }
}

private struct SidebarSwitchRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Theme.Ink.primary : Theme.Ink.tertiary)
                .frame(width: 24, height: 24)
                .background(
                    Theme.Surface.sidebarTile,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
                )
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.15), value: isOn)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? Theme.Ink.primary : Theme.Ink.secondary)
            Spacer(minLength: 8)
            SettingSwitch(isOn: $isOn, label: title)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

// MARK: - Shared states

/// A whole-panel message: a neutral disc, a title and one sentence.
struct ContentUnavailablePlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            IconDisc(systemName: icon, size: 52)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelSurface()
    }
}

struct PermissionView: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: "video",
                title: store.t("permission.title"),
                subtitle: store.t("permission.usbBanner.title")
            )
            .padding(16)

            VStack(spacing: 14) {
                Spacer(minLength: 0)
                StatusGlyph(kind: store.permissionStatus == .notDetermined ? .idle : .warning, size: 44)
                Text(permissionBody)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        store.discoverWirelessDevices()
                    } label: {
                        Label(store.t("toolbar.discoverWireless"), systemImage: "wifi")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))

                    Button {
                        store.recheckCameraPermission()
                    } label: {
                        Label(store.t("permission.recheck"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))

                    Button {
                        if store.permissionStatus == .notDetermined {
                            Task {
                                await store.requestCameraPermission()
                            }
                        } else {
                            store.openCameraPrivacySettings()
                        }
                    } label: {
                        if store.isRequestingCameraPermission {
                            Label(store.t("permission.requesting"), systemImage: "hourglass")
                        } else {
                            Label(primaryActionTitle, systemImage: primaryActionIcon)
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(store.isRequestingCameraPermission)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .wellSurface()
            .padding([.horizontal, .bottom], 12)
        }
        .panelSurface()
    }

    private var permissionBody: String {
        switch store.permissionStatus {
        case .notDetermined:
            store.t("permission.body.notDetermined")
        case .denied, .restricted:
            store.t("permission.body.denied")
        default:
            store.t("permission.body")
        }
    }

    private var primaryActionTitle: String {
        store.permissionStatus == .notDetermined
            ? store.t("permission.requestAccess")
            : store.t("permission.openSettings")
    }

    private var primaryActionIcon: String {
        store.permissionStatus == .notDetermined ? "video.badge.checkmark" : "gearshape"
    }
}

/// A notice that sits above the device panel: an amber mark, one title,
/// one sentence, and the action that clears it.
private struct NoticeCard<Actions: View>: View {
    let glyph: StatusGlyph.Kind
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusGlyph(kind: glyph, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                actions()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .panelSurface(radius: Theme.Radius.card)
    }
}

struct MicrophonePermissionBanner: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        NoticeCard(
            glyph: .warning,
            title: store.t("permission.microphone.title"),
            message: bodyCopy
        ) {
            if store.microphonePermissionStatus == .notDetermined {
                Button {
                    Task { await store.enableAudioPlayback() }
                } label: {
                    if store.isRequestingMicrophonePermission || store.isRequestingCameraPermission {
                        Text(store.t("permission.requesting"))
                    } else {
                        Text(store.t("permission.microphone.requestAccess"))
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(store.isRequestingMicrophonePermission || store.isRequestingCameraPermission)
            } else {
                Button {
                    store.recheckMicrophonePermission()
                } label: {
                    Label(store.t("permission.recheck"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(store.t("permission.recheck"))

                Button(store.t("permission.microphone.openSettings")) {
                    store.openMicrophonePrivacySettings()
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            }
        }
    }

    private var bodyCopy: String {
        switch store.microphonePermissionStatus {
        case .notDetermined:
            store.t("permission.microphone.body.notDetermined")
        case .denied, .restricted:
            store.t("permission.microphone.body.denied")
        case .authorized:
            store.t("permission.microphone.body.authorized")
        @unknown default:
            store.t("permission.microphone.body.denied")
        }
    }
}

struct CameraPermissionBanner: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        NoticeCard(
            glyph: .warning,
            title: store.t("permission.usbBanner.title"),
            message: store.t("permission.usbBanner.body")
        ) {
            Button {
                store.recheckCameraPermission()
            } label: {
                Label(store.t("permission.recheck"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help(store.t("permission.recheck"))

            Button {
                if store.permissionStatus == .notDetermined {
                    Task {
                        await store.requestCameraPermission()
                    }
                } else {
                    store.openCameraPrivacySettings()
                }
            } label: {
                if store.isRequestingCameraPermission {
                    Text(store.t("permission.requesting"))
                } else {
                    Text(
                        store.permissionStatus == .notDetermined
                            ? store.t("permission.requestAccess")
                            : store.t("permission.openSettings")
                    )
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(store.isRequestingCameraPermission)
        }
    }
}

/// First run: the frame and title stay, the well shows a drawn phone on a
/// cable, and the first action sits where devices will appear.
struct EmptyDevicesView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: "tray",
                title: store.t("empty.title"),
                subtitle: store.t("dashboard.empty.subtitle")
            ) {
                QuietChip(title: "USB · Wi-Fi · ADB")
            }
            .padding(16)

            ConnectPhoneIllustration()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .wellSurface()
                .padding(.horizontal, 12)

            VStack(spacing: 6) {
                Text(store.t("dashboard.empty.headline"))
                    .font(.system(size: 14, weight: .semibold))
                Text(store.t("empty.body"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)

            HStack(spacing: 8) {
                Button {
                    store.presentIPhoneSetup()
                } label: {
                    Label(store.t("iphone.setup.open"), systemImage: "iphone.gen3")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))

                Button {
                    store.discoverWirelessDevices()
                } label: {
                    Label(store.t("toolbar.discoverWireless"), systemImage: "wifi")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))

                Button {
                    refresh()
                } label: {
                    Label(store.t("toolbar.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .panelSurface()
    }
}

/// A phone drawn in hairlines with its screen lit in the live green, a
/// cable dropping to a Mac port: the one picture the empty state needs.
struct ConnectPhoneIllustration: View {
    var body: some View {
        Canvas { context, size in
            let phoneHeight = min(size.height * 0.62, 230)
            let phoneWidth = phoneHeight * 0.49
            let origin = CGPoint(
                x: size.width / 2 - phoneWidth / 2,
                y: size.height / 2 - phoneHeight / 2 - phoneHeight * 0.08
            )
            let phone = CGRect(origin: origin, size: CGSize(width: phoneWidth, height: phoneHeight))
            let line = Theme.Illustration.line
            let faint = Theme.Illustration.faint

            // Offset shadow plate, like an isometric drop.
            let plate = phone.offsetBy(dx: -10, dy: 10)
            context.stroke(
                Path(roundedRect: plate, cornerRadius: phoneWidth * 0.2, style: .continuous),
                with: .color(faint),
                lineWidth: 1
            )

            context.fill(
                Path(roundedRect: phone, cornerRadius: phoneWidth * 0.2, style: .continuous),
                with: .color(Theme.Surface.well)
            )
            context.stroke(
                Path(roundedRect: phone, cornerRadius: phoneWidth * 0.2, style: .continuous),
                with: .color(line),
                lineWidth: 1.2
            )

            let screen = phone.insetBy(dx: phoneWidth * 0.07, dy: phoneWidth * 0.07)
            context.stroke(
                Path(roundedRect: screen, cornerRadius: phoneWidth * 0.15, style: .continuous),
                with: .color(faint),
                lineWidth: 1
            )

            // The lit band: the one thing in colour.
            let band = CGRect(
                x: screen.minX + screen.width * 0.12,
                y: screen.minY + screen.height * 0.2,
                width: screen.width * 0.76,
                height: screen.height * 0.16
            )
            context.fill(
                Path(roundedRect: band, cornerRadius: 6, style: .continuous),
                with: .color(Theme.Palette.live.opacity(0.85))
            )
            for index in 0..<3 {
                let y = band.minY + band.height * (0.3 + Double(index) * 0.2)
                var stripe = Path()
                stripe.move(to: CGPoint(x: band.minX + 10, y: y))
                stripe.addLine(to: CGPoint(x: band.maxX - (index == 2 ? 34 : 14), y: y))
                context.stroke(stripe, with: .color(Theme.Surface.well.opacity(0.55)), lineWidth: 1.4)
            }

            // Text lines on the screen.
            for index in 0..<6 {
                let y = band.maxY + 18 + Double(index) * 13
                guard y < screen.maxY - 22 else { break }
                var row = Path()
                row.move(to: CGPoint(x: screen.minX + screen.width * 0.12, y: y))
                row.addLine(to: CGPoint(
                    x: screen.maxX - screen.width * (index.isMultiple(of: 3) ? 0.36 : 0.12),
                    y: y
                ))
                context.stroke(row, with: .color(Theme.Illustration.text), lineWidth: 1.2)
            }

            // Cable: dotted drop from the port to a plug.
            let port = CGPoint(x: phone.midX, y: phone.maxY)
            let plug = CGRect(x: port.x - 7, y: port.y + 26, width: 14, height: 22)
            var cable = Path()
            cable.move(to: port)
            cable.addLine(to: CGPoint(x: port.x, y: plug.minY))
            context.stroke(cable, with: .color(line), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.stroke(
                Path(roundedRect: plug, cornerRadius: 3, style: .continuous),
                with: .color(line),
                lineWidth: 1.2
            )
            var lead = Path()
            lead.move(to: CGPoint(x: plug.midX, y: plug.maxY))
            lead.addCurve(
                to: CGPoint(x: plug.midX + phoneWidth * 1.3, y: plug.maxY + 26),
                control1: CGPoint(x: plug.midX, y: plug.maxY + 26),
                control2: CGPoint(x: plug.midX + phoneWidth * 0.6, y: plug.maxY + 8)
            )
            context.stroke(lead, with: .color(line), lineWidth: 1.2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "stethoscope",
                title: store.t("toolbar.diagnostics"),
                subtitle: String(format: store.t("dashboard.sidebar.connected"), store.connectedSessions.count),
                closeHelp: store.t("common.close")
            ) {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupLabel(title: store.t("diagnostics.runtime"))
                        VStack(spacing: 0) {
                            ForEach(Array(store.diagnostics.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { RowDivider() }
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(item.name)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.Ink.secondary)
                                    Spacer(minLength: 12)
                                    Text(item.value)
                                        .font(Theme.mono(12))
                                        .foregroundStyle(Theme.Ink.primary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                            }
                        }
                        .wellSurface()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        GroupLabel(title: store.t("diagnostics.devices"), trailing: "\(store.sessions.count)")
                        VStack(spacing: 0) {
                            if store.sessions.isEmpty {
                                Text(store.t("diagnostics.noDevices"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.Ink.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            } else {
                                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                                    if index > 0 { RowDivider() }
                                    DiagnosticsDeviceRow(session: session)
                                }
                            }
                        }
                        .wellSurface()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        GroupLabel(title: store.t("diagnostics.controlPrereq"))
                        Text(store.t("diagnostics.controlHelp"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .wellSurface()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            SheetFooter {
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Label(store.t("toolbar.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }
}

private struct DiagnosticsDeviceRow: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var mirrorSession: MirrorCaptureSession
    @ObservedObject private var controlSession: DeviceControlSession
    let session: DeviceSession

    init(session: DeviceSession) {
        self.session = session
        self.mirrorSession = session.mirrorSession
        self.controlSession = session.controlSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.device.name)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(store.t("diagnostic.mirror")) \(store.mirrorStateLabel(mirrorSession.state)) · \(store.t("diagnostic.control")) \(store.controlStateLabel(controlSession.state))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
            }
            HStack(spacing: 10) {
                Text(session.device.udid ?? store.t("common.noUDID"))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let latency = controlSession.gestureLatencySummary {
                    Text(String(
                        format: store.t("diagnostics.gestureLatency"),
                        latency.medianMS,
                        latency.slowestMS,
                        latency.count
                    ))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .help(store.t("diagnostics.gestureLatencyHelp"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The action row at the foot of a sheet, on a hairline.
struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Surface.hairline)
                .frame(height: 1)
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Settings

/// Open at login (off until turned on) and Sparkle updates.
struct StartupAndUpdatesSection: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        SettingsGroup(title: store.t("settings.startupUpdates")) {
            SettingRow(store.t("settings.launchAtLogin"), help: store.t(launchAtLoginHelpKey)) {
                SettingSwitch(
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ),
                    label: store.t("settings.launchAtLogin")
                )
                .disabled(launchAtLogin.state == .unavailable)
            }
            if launchAtLogin.state == .requiresApproval {
                RowDivider()
                SettingRow(store.t("settings.launchAtLoginApproval")) {
                    Button(store.t("settings.openLoginItems")) {
                        launchAtLogin.openLoginItemsSettings()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
            }
            if let error = launchAtLogin.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.danger)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            RowDivider()

            if updater.isConfigured {
                SettingRow(store.t("settings.autoCheckUpdates")) {
                    SettingSwitch(
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticallyChecksForUpdates($0) }
                        ),
                        label: store.t("settings.autoCheckUpdates")
                    )
                }
                RowDivider()
                SettingRow(store.t("settings.checkForUpdates"), help: updateStatus) {
                    Button(store.t("settings.checkForUpdates")) {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .disabled(!updater.canCheckForUpdates)
                }
            } else {
                SettingRow(
                    String(format: store.t("settings.currentVersion"), updater.currentVersion),
                    help: store.t("settings.updatesUnavailable")
                ) {
                    EmptyView()
                }
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var launchAtLoginHelpKey: String {
        switch launchAtLogin.state {
        case .requiresApproval: "settings.launchAtLoginApproval"
        case .unavailable: "settings.launchAtLoginUnavailable"
        case .enabled, .disabled: "settings.launchAtLoginHelp"
        }
    }

    private var updateStatus: String {
        var parts = [String(format: store.t("settings.currentVersion"), updater.currentVersion)]
        if let available = updater.availableVersion {
            parts.append(String(format: store.t("settings.updateAvailable"), available))
        } else if let date = updater.lastCheckDate {
            parts.append(String(
                format: store.t("settings.lastUpdateCheck"),
                date.formatted(date: .abbreviated, time: .shortened)
            ))
        }
        return parts.joined(separator: " · ")
    }
}

/// A labelled well holding settings rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    var trailing: String?
    /// A sentence under the group, outside the well, for context that
    /// would otherwise crowd a row.
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                GroupLabel(title: title, trailing: trailing)
                    .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wellSurface(radius: Theme.Radius.panel - DashboardWindowLayout.gutter, outlined: false)
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceGalleryStore
    @State private var selectedTab: DashboardSettingsTab
    @State private var showControlAdvanced = false
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @ObservedObject private var updater = AppUpdater.shared
    /// Bumped when Appium's state changes, which the store does not republish.
    @State private var appiumRevision = 0

    init(initialTab: DashboardSettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DashboardWindowLayout.gutter) {
            SettingsSidebar(mcp: store.mcpServer, license: store.licenseManager, selection: $selectedTab)
                .frame(width: 224)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelSurface()
        }
        .padding(.horizontal, DashboardWindowLayout.gutter)
        .padding(.vertical, DashboardWindowLayout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.ground)
        .onReceive(store.appiumService.objectWillChange) { _ in
            DispatchQueue.main.async { appiumRevision &+= 1 }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .general:
            SettingsPage(
                title: store.t("settings.tab.general"),
                statuses: generalStatuses
            ) {
                generalContent
            }
        case .mirroring:
            SettingsPage(title: store.t("settings.tab.mirroring"), statuses: mirroringStatuses) {
                mirroringContent
            }
        case .mcp:
            MCPAutomationSettingsView(manager: store.mcpServer)
                .environmentObject(store)
        case .license:
            SettingsPage(title: store.t("settings.tab.license"), statuses: licenseStatuses) {
                LicenseActivationView(licenseManager: store.licenseManager)
            }
        }
    }

    private var generalStatuses: [SettingsPageStatus] {
        let launch = launchAtLogin.isEnabled
        var items = [SettingsPageStatus(
            color: launch ? Theme.Palette.live : nil,
            text: "\(store.t("settings.status.launch")) \(store.t(launch ? "common.on" : "common.off"))"
        )]
        if updater.isConfigured {
            let auto = updater.automaticallyChecksForUpdates
            items.append(SettingsPageStatus(
                color: auto ? Theme.Palette.live : nil,
                text: "\(store.t("settings.status.updates")) \(store.t(auto ? "common.on" : "common.off"))"
            ))
        }
        return items
    }

    private var mirroringStatuses: [SettingsPageStatus] {
        _ = appiumRevision
        return [
            SettingsPageStatus(
                color: store.wirelessMirroringEnabled ? Theme.Palette.live : nil,
                text: "\(store.t("transport.wireless")) \(store.t(store.wirelessMirroringEnabled ? "common.on" : "common.off"))"
            ),
            SettingsPageStatus(
                color: store.appiumService.state == .unknown ? nil : appiumServiceColor,
                text: "Appium \(store.appiumServiceStateLabel(store.appiumService.state))"
            ),
        ]
    }

    private var licenseStatuses: [SettingsPageStatus] {
        let state = store.licenseManager.state
        return [SettingsPageStatus(color: LicenseState.dotColor(state), text: store.licenseStatusLabel(state))]
    }

    @ViewBuilder
    private var generalContent: some View {
        SettingsGroup(title: store.t("settings.interface")) {
            SettingRow(store.t("settings.appearance")) {
                SegmentedPills(
                    selection: $store.appearance,
                    items: AppAppearance.allCases.map { .init(value: $0, title: store.t($0.titleKey)) }
                )
            }
            RowDivider()
            SettingRow(store.t("settings.language")) {
                SegmentedPills(
                    selection: $store.language,
                    items: AppLanguage.allCases.map { .init(value: $0, title: $0.displayName) }
                )
            }
        }

        StartupAndUpdatesSection()
    }

    @ViewBuilder
    private var mirroringContent: some View {
        SettingsGroup(title: store.t("settings.mirroring")) {
            SettingRow(store.t("settings.autoOpen")) {
                SettingSwitch(isOn: $store.autoStartMirrors, label: store.t("settings.autoOpen"))
            }
            RowDivider()
            SettingRow(store.t("settings.wirelessMirroring"), help: store.t("settings.wirelessMirroringHelp")) {
                SettingSwitch(isOn: $store.wirelessMirroringEnabled, label: store.t("settings.wirelessMirroring"))
            }
            RowDivider()
            SettingRow(store.t("iphone.setup.title"), help: store.t("iphone.setup.subtitle")) {
                Button(store.t("iphone.setup.open")) {
                    store.presentIPhoneSetup()
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
            RowDivider()
            SettingRow(store.t("settings.audioPlayback"), help: store.t("settings.audioPlaybackHelp")) {
                SettingSwitch(isOn: store.audioPlaybackToggle, label: store.t("settings.audioPlayback"))
                    .disabled((store.isRequestingMicrophonePermission || store.isRequestingCameraPermission) || !store.canPlayDeviceAudioOnMac)
            }
        }

            SettingsGroup(title: store.t("settings.control"), footer: store.t("settings.appiumHelp")) {
                SettingRow(
                    "Appium",
                    help: store.appiumService.state == .unknown ? store.t("settings.appiumIdle") : store.appiumService.message
                ) {
                    HStack(spacing: 8) {
                        StatusPill(
                            title: store.appiumServiceStateLabel(store.appiumService.state),
                            color: appiumServiceColor
                        )
                        Button {
                            store.appiumService.check(serverURL: store.appiumServerURL)
                        } label: {
                            Label(store.t("settings.check"), systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                        if store.appiumService.state == .running {
                            Button {
                                store.appiumService.stop()
                            } label: {
                                Label(store.t("settings.stop"), systemImage: "stop.fill")
                            }
                            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        } else {
                            Button {
                                store.appiumService.start(serverURL: store.appiumServerURL)
                            } label: {
                                Label(store.t("settings.startAppium"), systemImage: "play.fill")
                            }
                            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        }
                    }
                    .fixedSize()
                }

                RowDivider()

                DisclosureHeader(
                    isExpanded: $showControlAdvanced,
                    accessibilityTitle: store.t("settings.controlAdvanced")
                ) {
                    Text(store.t("settings.controlAdvanced"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Ink.primary)
                }
                if showControlAdvanced {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledField(store.t("settings.appiumURL"), text: $store.appiumServerURL)
                        LabeledField(store.t("settings.bundleID"), text: $store.controlBundleID)
                        LabeledField(store.t("settings.xcodeTeam"), text: $store.controlXcodeOrgID)
                        LabeledField(store.t("settings.xcodeSigningID"), text: $store.controlXcodeSigningID)
                        LabeledField(store.t("settings.wdaBundleID"), text: $store.controlWDABundleID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                }
            }
    }

    private var appiumServiceColor: Color {
        switch store.appiumService.state {
        case .running:
            Theme.Palette.live
        case .checking, .starting:
            Theme.Palette.pending
        case .missing, .failed:
            Theme.Palette.danger
        case .unknown, .stopped:
            Theme.Ink.secondary
        }
    }
}

/// The settings sheet's navigation, drawn like the dashboard's device list:
/// a small label, one two-line row per page with its live state, and the
/// product and version at the foot.
private struct SettingsSidebar: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject var mcp: MCPServerManager
    @ObservedObject var license: LicenseManager
    @Binding var selection: DashboardSettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.t("toolbar.settings"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Ink.tertiary)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(DashboardSettingsTab.allCases, id: \.self) { tab in
                    SettingsSidebarRow(
                        title: store.t(tab.titleKey),
                        detail: detail(for: tab),
                        dot: dot(for: tab),
                        systemImage: tab.systemImage,
                        isSelected: selection == tab
                    ) {
                        selection = tab
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            Rectangle()
                .fill(Theme.Surface.sidebarDivider)
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            HStack(spacing: 10) {
                BrandMark(size: 13)
                    .frame(width: 24, height: 24)
                    .background(
                        Theme.Surface.sidebarTile,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 1, style: .continuous)
                    )
                Text("StupidMirror")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Ink.secondary)
                Spacer(minLength: 8)
                Text(updater.currentVersion)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func detail(for tab: DashboardSettingsTab) -> String {
        switch tab {
        case .general:
            return "\(store.t(store.appearance.titleKey)) · \(store.language.displayName)"
        case .mirroring:
            return store.wirelessMirroringEnabled
                ? "USB · \(store.t("transport.wireless"))"
                : store.t("settings.sidebar.usbOnly")
        case .mcp:
            return mcp.status.isRunning
                ? "MCP · :\(String(mcp.port))"
                : "MCP \(store.mcpStatusLabel(mcp.status))"
        case .license:
            return store.licenseStatusLabel(license.state)
        }
    }

    private func dot(for tab: DashboardSettingsTab) -> Color? {
        switch tab {
        case .general, .mirroring:
            return nil
        case .mcp:
            return mcp.status.isRunning ? Theme.Palette.live : MCPServerStatus.color(mcp.status)
        case .license:
            return LicenseState.dotColor(license.state)
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let detail: String
    let dot: Color?
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.tertiary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
                        .fixedSize()
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.Surface.sidebarSelection : (isHovered ? Theme.Surface.sidebarHover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension DeviceGalleryStore {
    func mcpStatusLabel(_ status: MCPServerStatus) -> String {
        switch status {
        case .stopped: t("mcp.status.stopped")
        case .starting: t("mcp.status.starting")
        case .running: t("mcp.status.running")
        case .failed: t("mcp.status.failed")
        }
    }

    func licenseStatusLabel(_ state: LicenseState) -> String {
        switch state {
        case .checking: t("license.status.checking")
        case .unlicensed: t("license.status.unlicensed")
        case .licensed: t("license.status.licensed")
        case .unavailable: t("license.status.unavailable")
        }
    }
}

extension MCPServerStatus {
    static func color(_ status: MCPServerStatus) -> Color? {
        switch status {
        case .running: Theme.Palette.live
        case .starting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .stopped: nil
        }
    }
}

extension LicenseState {
    static func dotColor(_ state: LicenseState) -> Color? {
        switch state {
        case .licensed: Theme.Palette.live
        case .checking: nil
        case .unlicensed: Theme.Palette.pending
        case .unavailable: Theme.Palette.danger
        }
    }
}

extension DashboardSettingsTab {
    var titleKey: String {
        switch self {
        case .general: "settings.tab.general"
        case .mirroring: "settings.tab.mirroring"
        case .mcp: "settings.tab.mcp"
        case .license: "settings.tab.license"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .mirroring: "iphone"
        case .mcp: "sparkles"
        case .license: "key"
        }
    }
}

/// One state on a settings page's header line: an optional dot and a label.
struct SettingsPageStatus: Hashable {
    let color: Color?
    let text: String
}

/// One settings page, headed like the dashboard's device panel: the page
/// name with a small tag, a line of state dots, and the close button; then
/// its groups, each set in a grey well.
struct SettingsPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceGalleryStore
    let title: String
    var tag: String?
    var statuses: [SettingsPageStatus] = []
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.Ink.primary)
                            .fixedSize()
                        if let tag, !tag.isEmpty {
                            Text(tag)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Ink.tertiary)
                                .fixedSize()
                        }
                    }
                    if !statuses.isEmpty {
                        HStack(spacing: 14) {
                            ForEach(statuses, id: \.self) { status in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(status.color ?? Theme.Surface.controlStroke)
                                        .frame(width: 6, height: 6)
                                    Text(status.text)
                                        .fixedSize()
                                }
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help(store.t("common.close"))
                .accessibilityLabel(store.t("common.close"))
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                    }
                    content()
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A grey label over a dark field.
struct LabeledField: View {
    let title: String
    @Binding var text: String
    var monospaced = true

    init(_ title: String, text: Binding<String>, monospaced: Bool = true) {
        self.title = title
        self._text = text
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.secondary)
            TextField(title, text: $text)
                .fieldSurface(monospaced: monospaced)
        }
    }
}

/// The client's own app icon when it is installed, otherwise a symbol tile.
private struct ClientAppIcon: View {
    let symbol: String
    let bundleIDs: [String]

    var body: some View {
        Group {
            if let image = Self.appIcon(for: bundleIDs) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Ink.primary)
                    .frame(width: 38, height: 38)
                    .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }

    private static func appIcon(for bundleIDs: [String]) -> NSImage? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

/// One AI client's connection: who it is, where it stands, one primary
/// action, and a starter prompt to paste into a new chat.
private struct EqualWidthColumns: Layout {
    var spacing: CGFloat

    private func columnWidth(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
        let total = proposal.width ?? 640
        return max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = columnWidth(proposal, count: subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: proposal.width ?? width * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = columnWidth(ProposedViewSize(width: bounds.width, height: nil), count: subviews.count)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (width + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

private struct ClientCard<Actions: View>: View {
    let icon: String
    var appBundleIDs: [String] = []
    let name: String
    let tagline: String
    let glyph: StatusGlyph.Kind
    let detail: String
    let failure: String?
    let prompt: String
    let copyPromptTitle: String
    @ViewBuilder var actions: () -> Actions
    let onCopyPrompt: () -> Void
    @State private var isPromptHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ClientAppIcon(symbol: icon, bundleIDs: appBundleIDs)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Ink.primary)
                        if glyph != .idle {
                            StateDot(kind: glyph)
                        }
                    }
                    Text(tagline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Palette.danger)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 14)

            Button(action: onCopyPrompt) {
                HStack(alignment: .top, spacing: 10) {
                    Text("“\(prompt)”")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isPromptHovered ? "doc.on.doc.fill" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isPromptHovered ? Theme.Ink.primary : Theme.Ink.tertiary)
                        .padding(.top, 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    isPromptHovered ? Theme.Surface.selected : Theme.Surface.raised,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isPromptHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isPromptHovered)
            .padding(.top, 14)
            .help(copyPromptTitle)
            .accessibilityLabel("\(copyPromptTitle): \(prompt)")

            Spacer(minLength: 16)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8, content: actions)
                VStack(alignment: .leading, spacing: 6, content: actions)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .wellSurface(radius: Theme.Radius.panel - DashboardWindowLayout.gutter, outlined: false)
    }
}

private enum MCPTutorialClient: String, CaseIterable, Identifiable {
    case codex
    case claude
    var id: String { rawValue }
}

struct MCPAutomationSettingsView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var manager: MCPServerManager
    @StateObject private var codexInstaller = CodexPluginInstaller()
    @StateObject private var claudeConnector = ClaudeCodeConnector()
    @State private var portDraft = ""
    @State private var tutorialClient: MCPTutorialClient = .codex
    @State private var showToken = false
    @State private var showAdvanced = false
    @State private var confirmRotation = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage(
            title: store.t("settings.tab.mcp"),
            statuses: [
                SettingsPageStatus(
                    color: MCPServerStatus.color(manager.status),
                    text: manager.status.isRunning
                        ? "MCP :\(String(manager.port))"
                        : "MCP \(statusTitle)"
                ),
                SettingsPageStatus(
                    color: manager.connectedClientCount > 0 ? Theme.Palette.control : nil,
                    text: String(format: store.t("mcp.clients"), manager.connectedClientCount)
                ),
            ],
            note: store.t("mcp.clients.intro")
        ) {

                clientSetup

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: store.t("mcp.advanced"))
                        .padding(.horizontal, 6)
                    VStack(alignment: .leading, spacing: 0) {
                        DisclosureHeader(
                            isExpanded: $showAdvanced,
                            insets: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16),
                            accessibilityTitle: store.t("mcp.advanced")
                        ) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 6, height: 6)
                                Text("\(store.t("mcp.server")) · \(statusTitle)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.Ink.primary)
                                    .fixedSize()
                                Text(manager.endpoint)
                                    .font(Theme.mono(12))
                                    .foregroundStyle(Theme.Ink.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        if showAdvanced {
                            VStack(alignment: .leading, spacing: 18) {
                                serverGroup
                                tokenGroup
                                connectGroup
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                            .transition(.opacity)
                        }
                    }
                    .wellSurface(radius: Theme.Radius.panel - DashboardWindowLayout.gutter, outlined: false)
                }

                logsGroup
        }
        .onAppear {
            portDraft = String(manager.port)
            claudeConnector.refresh(endpoint: manager.endpoint)
        }
        .confirmationDialog(store.t("mcp.rotateConfirm"), isPresented: $confirmRotation) {
            Button(store.t("mcp.rotateToken"), role: .destructive) {
                do { try manager.rotateToken() } catch { errorMessage = error.localizedDescription }
            }
            Button(store.t("common.cancel"), role: .cancel) {}
        }
        .alert(store.t("mcp.error"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var serverGroup: some View {
        SettingsGroup(title: store.t("mcp.server")) {
            SettingRow(store.t("mcp.enabled")) {
                SettingSwitch(
                    isOn: Binding(
                        get: { manager.enabled },
                        set: { value in Task { await manager.setEnabled(value) } }
                    ),
                    label: store.t("mcp.enabled")
                )
            }
            RowDivider()
            HStack(spacing: 10) {
                StatusPill(title: statusTitle, color: statusColor)
                Text(manager.endpoint)
                    .font(Theme.mono(12))
                    .textSelection(.enabled)
                Spacer()
                Text(String(format: store.t("mcp.clients"), manager.connectedClientCount))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if case let .failed(message) = manager.status {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.danger)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
            }
            RowDivider()
            SettingRow(store.t("mcp.port"), help: store.t("mcp.localOnly")) {
                HStack(spacing: 6) {
                    TextField(store.t("mcp.port"), text: $portDraft)
                        .fieldSurface(monospaced: true)
                        .frame(width: 96)
                    Button(store.t("mcp.applyPort")) {
                        applyPort()
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
    }

    private var tokenGroup: some View {
        SettingsGroup(title: store.t("mcp.token")) {
            HStack(spacing: 6) {
                Text(showToken ? manager.bearerToken : String(repeating: "•", count: 32))
                    .font(Theme.mono(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(showToken ? store.t("mcp.hide") : store.t("mcp.show")) {
                    showToken.toggle()
                }
                .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                Button(store.t("mcp.copyToken")) { copy(manager.bearerToken) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                Button(store.t("mcp.rotateToken"), role: .destructive) {
                    confirmRotation = true
                }
                .buttonStyle(PillButtonStyle(kind: .destructive, compact: true))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Text(store.t("mcp.tokenHelp"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
        }
    }

    private var connectGroup: some View {
        SettingsGroup(title: store.t("mcp.connect")) {
            VStack(alignment: .leading, spacing: 12) {
                SegmentedPills(
                    selection: $tutorialClient,
                    items: [
                        .init(value: .codex, title: "Codex"),
                        .init(value: .claude, title: "Claude Code"),
                    ]
                )

                Text(tutorialClient == .codex ? store.t("mcp.codexSteps") : store.t("mcp.claudeSteps"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    ScrollView(.horizontal) {
                        Text(connectionText)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.Ink.primary)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Theme.Surface.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.Surface.hairline, lineWidth: 1)
                    }
                    Button(store.t("mcp.copyConfig")) { copy(connectionText) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }

                Text(store.t("mcp.verify"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
                Text("“\(store.t("mcp.testPrompt"))”")
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
            }
            .padding(14)
        }
    }

    private var logsGroup: some View {
        SettingsGroup(
            title: store.t("mcp.logs"),
            trailing: manager.callLog.isEmpty ? nil : "\(min(manager.callLog.count, 20))"
        ) {
            if manager.callLog.isEmpty {
                Text(store.t("mcp.noLogs"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .padding(14)
            } else {
                ForEach(Array(manager.callLog.prefix(20).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { RowDivider() }
                    HStack(spacing: 10) {
                        StatusGlyph(kind: entry.succeeded ? .done : .failed, size: 16)
                        Text(entry.tool)
                            .font(Theme.mono(12))
                        if let deviceID = entry.deviceID {
                            Text(deviceID.prefix(8))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.Ink.tertiary)
                        }
                        if let errorCode = entry.errorCode {
                            Text(errorCode)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.Palette.danger)
                        }
                        Spacer()
                        Text("\(entry.durationMilliseconds) ms")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                }
            }
        }
    }

    private var connectionText: String {
        tutorialClient == .codex ? manager.codexConfiguration : manager.claudeCommand
    }

    private var clientSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: store.t("mcp.codex.step1")) {
                codexStep(
                    glyph: store.sessions.isEmpty ? .idle : .done,
                    title: store.sessions.isEmpty
                        ? store.t("mcp.devices.none")
                        : String(format: store.t("mcp.devices.ready"), store.sessions.count),
                    detail: store.sessions.isEmpty
                        ? store.t("mcp.codex.noDevice")
                        : store.t("mcp.devices.firstTime")
                ) {
                    Button(store.t("mcp.codex.phoneSetup")) { store.presentIPhoneSetup() }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                GroupLabel(title: store.t("mcp.clients.step2"))
                    .padding(.horizontal, 6)
                EqualWidthColumns(spacing: 12) {
                    ClientCard(
                        icon: "chevron.left.forwardslash.chevron.right",
                        appBundleIDs: ["com.openai.codex", "com.openai.chat"],
                        name: "Codex",
                        tagline: store.t("mcp.codex.tagline"),
                        glyph: codexInstallGlyph,
                        detail: codexInstallDetail,
                        failure: codexInstaller.error,
                        prompt: store.t("mcp.codex.prompt"),
                        copyPromptTitle: store.t("mcp.clients.copyPrompt")
                    ) {
                        Button {
                            Task {
                                await manager.setEnabled(true)
                                await codexInstaller.install()
                            }
                        } label: {
                            Label(
                                store.t(codexInstaller.installedThisSession ? "mcp.codex.reinstall" : "mcp.codex.install"),
                                systemImage: "puzzlepiece.extension"
                            )
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        .disabled(codexInstaller.isInstalling)
                        Button(store.t("mcp.codex.open")) { codexInstaller.openCodex() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                            .help("Codex")
                    } onCopyPrompt: {
                        copy(store.t("mcp.codex.prompt"))
                    }

                    ClientCard(
                        icon: "asterisk",
                        appBundleIDs: ["com.anthropic.claudefordesktop"],
                        name: "Claude Code",
                        tagline: store.t("mcp.claude.tagline"),
                        glyph: claudeGlyph,
                        detail: claudeDetail,
                        failure: claudeConnector.failure.map(claudeFailureText),
                        prompt: store.t("mcp.claude.prompt"),
                        copyPromptTitle: store.t("mcp.clients.copyPrompt")
                    ) {
                        Button {
                            Task {
                                await manager.setEnabled(true)
                                await claudeConnector.connect(endpoint: manager.endpoint)
                            }
                        } label: {
                            Label(
                                store.t(claudeConnector.isConnected ? "mcp.claude.reconnect" : "mcp.claude.connect"),
                                systemImage: "puzzlepiece.extension"
                            )
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        .disabled(claudeConnector.isConnecting)
                        Button(store.t("mcp.claude.open")) { claudeConnector.openClaude() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                            .help("Claude")
                    } onCopyPrompt: {
                        copy(store.t("mcp.claude.prompt"))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var claudeGlyph: StatusGlyph.Kind {
        if claudeConnector.isConnecting { return .working }
        if claudeConnector.failure != nil { return .failed }
        return claudeConnector.isConnected ? .done : .idle
    }

    private var claudeDetail: String {
        if claudeConnector.isConnecting { return store.t("mcp.claude.connecting") }
        if claudeConnector.failure != nil { return store.t("mcp.codex.failed") }
        guard claudeConnector.isConnected else { return store.t("mcp.claude.intro") }
        return claudeConnector.keptExistingServer
            ? store.t("mcp.claude.connected") + " " + store.t("mcp.claude.keptServer")
            : store.t("mcp.claude.connected")
    }

    private func claudeFailureText(_ failure: ClaudeCodeConnector.Failure) -> String {
        switch failure {
        case .cliMissing: store.t("mcp.claude.cliMissing")
        case .helperMissing: store.t("mcp.claude.helperMissing")
        case .pluginMissing: store.t("mcp.claude.pluginMissing")
        case let .commandFailed(output): output
        }
    }

    private func codexStep<Action: View>(
        glyph: StatusGlyph.Kind,
        title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            StatusGlyph(kind: glyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var codexInstallGlyph: StatusGlyph.Kind {
        if codexInstaller.isInstalling { return .working }
        if codexInstaller.error != nil { return .failed }
        if codexInstaller.installedThisSession { return .done }
        return .idle
    }

    private var codexInstallDetail: String {
        if codexInstaller.isInstalling { return store.t("mcp.codex.installing") }
        if codexInstaller.error != nil { return store.t("mcp.codex.failed") }
        if codexInstaller.installedThisSession {
            return manager.connectedClientCount > 0
                ? store.t("mcp.codex.installed") + " " + store.t("mcp.codex.connected")
                : store.t("mcp.codex.installed")
        }
        return store.t("mcp.codex.cardIntro")
    }

    private var statusTitle: String {
        switch manager.status {
        case .stopped: store.t("mcp.status.stopped")
        case .starting: store.t("mcp.status.starting")
        case .running: store.t("mcp.status.running")
        case .failed: store.t("mcp.status.failed")
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .running: Theme.Palette.live
        case .starting: Theme.Palette.pending
        case .failed: Theme.Palette.danger
        case .stopped: Theme.Ink.tertiary
        }
    }

    private func applyPort() {
        guard let port = Int(portDraft) else {
            errorMessage = store.t("mcp.invalidPort")
            return
        }
        Task {
            do { try await manager.setPort(port) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppCopy.plain(value), forType: .string)
    }
}
