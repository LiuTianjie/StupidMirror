import AppKit
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
                        .frame(width: 720, height: 660)
                case .activation:
                    LicenseActivationView(licenseManager: store.licenseManager)
                        .environmentObject(store)
                        .frame(width: 540)
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
                Text("StupidMirror")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Ink.secondary)
                    .allowsHitTesting(false)

                Spacer(minLength: 12)

                if store.licenseManager.showsDashboardActivationEntry {
                    Button {
                        store.presentActivation()
                    } label: {
                        Label(store.t("license.badge.unactivated"), systemImage: licenseBadgeIcon)
                    }
                    .buttonStyle(TintedPillStyle(color: licenseBadgeColor))
                    .help(store.t("license.badge.help"))
                }

                MCPStatusButton(manager: store.mcpServer)

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

    private var licenseBadgeColor: Color {
        switch store.licenseManager.state {
        case .unavailable:
            Theme.Palette.danger
        case .unlicensed:
            Theme.Palette.pending
        case .checking, .licensed:
            Theme.Ink.secondary
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
                    .foregroundStyle(Theme.Ink.primary)
                if manager.status.isRunning {
                    Text(":\(String(manager.port))")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
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

/// A compact pill in a state's hue on its own dark tint.
struct TintedPillStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .labelStyle(TintedPillLabelStyle())
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                Capsule()
                    .fill(color.opacity(configuration.isPressed ? 0.26 : 0.16))
            )
            .contentShape(Capsule())
    }
}

private struct TintedPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

// MARK: - Sidebar

private struct DeviceSidebar: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: "iphone.gen3.radiowaves.left.and.right",
                title: store.t("menu.devices"),
                subtitle: String(format: store.t("dashboard.sidebar.connected"), store.connectedSessions.count)
            ) {
                QuietChip(title: "\(store.sessions.count)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.sessions.isEmpty {
                        Text(store.t("menu.noDevices"))
                            .font(.system(size: 12.5))
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
                    .fill(Theme.Surface.hairline)
                    .frame(height: 1)

                SidebarSwitchRow(
                    title: store.t("toolbar.autoStart"),
                    systemImage: "bolt",
                    isOn: $store.autoStartMirrors
                )
                .help(store.t("settings.autoOpen"))

                SidebarSwitchRow(
                    title: store.t("toolbar.audioPlayback"),
                    systemImage: store.audioPlaybackEnabled ? "speaker.wave.2" : "speaker.slash",
                    isOn: store.audioPlaybackToggle
                )
                .disabled((store.isRequestingMicrophonePermission || store.isRequestingCameraPermission) || !store.canPlayDeviceAudioOnMac)
                .help(store.t("settings.audioPlaybackHelp"))

                Button {
                    store.stopAll()
                } label: {
                    Label(store.t("menu.stopAll"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .help(store.t("menu.stopAll"))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panelSurface()
    }
}

private struct SidebarSwitchRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Ink.tertiary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.secondary)
            Spacer(minLength: 8)
            SettingSwitch(isOn: $isOn, label: title)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
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
                VStack(alignment: .leading, spacing: 18) {
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
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
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
            .padding(.horizontal, 20)
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupLabel(title: title, trailing: trailing)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wellSurface()
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceGalleryStore
    @State private var selectedTab: DashboardSettingsTab

    init(initialTab: DashboardSettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: "gearshape",
                title: store.t("toolbar.settings"),
                subtitle: store.t("settings.subtitle"),
                closeHelp: store.t("common.close")
            ) {
                dismiss()
            }

            SegmentedPills(
                selection: $selectedTab,
                items: [
                    .init(value: .general, title: store.t("settings.general")),
                    .init(value: .mcp, title: store.t("mcp.title")),
                ]
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            switch selectedTab {
            case .general:
                generalTab
            case .mcp:
                MCPAutomationSettingsView(manager: store.mcpServer)
                    .environmentObject(store)
            }
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LicenseSettingsSection(licenseManager: store.licenseManager)

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

                SettingsGroup(title: store.t("settings.control")) {
                    HStack(spacing: 10) {
                        StatusPill(
                            title: store.appiumServiceStateLabel(store.appiumService.state),
                            color: appiumServiceColor
                        )
                        Text(store.appiumService.message)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button {
                            store.appiumService.check(serverURL: store.appiumServerURL)
                        } label: {
                            Label(store.t("settings.check"), systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                        Button {
                            store.appiumService.stop()
                        } label: {
                            Label(store.t("settings.stop"), systemImage: "stop.fill")
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        Button {
                            store.appiumService.start(serverURL: store.appiumServerURL)
                        } label: {
                            Label(store.t("settings.startAppium"), systemImage: "play.fill")
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    Text(store.t("settings.appiumHelp"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 11)

                    RowDivider()

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledField(store.t("settings.appiumURL"), text: $store.appiumServerURL)
                            LabeledField(store.t("settings.bundleID"), text: $store.controlBundleID)
                            LabeledField(store.t("settings.xcodeTeam"), text: $store.controlXcodeOrgID)
                            LabeledField(store.t("settings.xcodeSigningID"), text: $store.controlXcodeSigningID)
                            LabeledField(store.t("settings.wdaBundleID"), text: $store.controlWDABundleID)
                        }
                        .padding(.top, 10)
                    } label: {
                        Text(store.t("settings.controlAdvanced"))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Ink.primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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

private enum MCPTutorialClient: String, CaseIterable, Identifiable {
    case codex
    case claude
    var id: String { rawValue }
}

struct MCPAutomationSettingsView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject var manager: MCPServerManager
    @StateObject private var codexInstaller = CodexPluginInstaller()
    @State private var portDraft = ""
    @State private var tutorialClient: MCPTutorialClient = .codex
    @State private var showToken = false
    @State private var confirmRotation = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                codexSetup

                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(title: store.t("mcp.advanced"))
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 18) {
                            serverGroup
                            tokenGroup
                            connectGroup
                        }
                        .padding(.top, 12)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                            Text("\(store.t("mcp.server")) · \(statusTitle)")
                                .font(.system(size: 13))
                            Text(manager.endpoint)
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.Ink.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(14)
                    .wellSurface()
                }

                logsGroup
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .onAppear { portDraft = String(manager.port) }
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

    private var codexSetup: some View {
        SettingsGroup(title: store.t("mcp.codex.title")) {
            VStack(alignment: .leading, spacing: 0) {
                Text(store.t("mcp.codex.intro"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)

                RowDivider()

                codexStep(
                    glyph: store.sessions.isEmpty ? .idle : .done,
                    title: store.t("mcp.codex.step1"),
                    detail: store.sessions.isEmpty
                        ? store.t("mcp.codex.noDevice")
                        : String(format: store.t("mcp.codex.devices"), store.sessions.count)
                ) {
                    Button(store.t("mcp.codex.phoneSetup")) { store.presentIPhoneSetup() }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }

                RowDivider()

                codexStep(
                    glyph: codexInstallGlyph,
                    title: store.t("mcp.codex.step2"),
                    detail: codexInstallDetail
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
                }
                if let error = codexInstaller.error {
                    Text(error)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.Ink.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 48)
                        .padding(.trailing, 14)
                        .padding(.bottom, 11)
                }

                RowDivider()

                codexStep(
                    glyph: manager.connectedClientCount > 0 ? .done : .idle,
                    title: store.t("mcp.codex.step3"),
                    detail: store.t("mcp.codex.newChat")
                ) {
                    HStack(spacing: 6) {
                        Button(store.t("mcp.codex.copyPrompt")) { copy(store.t("mcp.codex.prompt")) }
                            .buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                        Button(store.t("mcp.codex.open")) { codexInstaller.openCodex() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(store.t("mcp.codex.prompt"))”")
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                    Text(store.t("mcp.codex.screen"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 48)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }
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
                ? store.t("mcp.codex.installed") + " · " + store.t("mcp.codex.connected")
                : store.t("mcp.codex.installed")
        }
        return manager.connectedClientCount > 0 ? store.t("mcp.codex.connected") : store.t("mcp.codex.intro.short")
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
        NSPasteboard.general.setString(value, forType: .string)
    }
}
