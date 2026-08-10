import AppKit
import SwiftUI

struct GalleryView: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
            } detail: {
                detail
            }
            // Reserve the footer inside the actual content bounds. The footer
            // overlay cannot be pushed below the window even when split-view
            // children report a larger intrinsic minimum height.
            .padding(.bottom, DashboardWindowLayout.bottomBarHeight + 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            VStack(spacing: 0) {
                Divider()
                bottomBar
            }
                .frame(height: DashboardWindowLayout.bottomBarHeight + 1)
                .frame(maxWidth: .infinity)
                .zIndex(1)
        }
        .toolbar { toolbarContent }
        .sheet(item: activeSheetBinding) { sheet in
            switch sheet {
            case .diagnostics:
                DiagnosticsView()
                    .environmentObject(store)
                    .frame(width: 560, height: 520)
            case .settings:
                SettingsView(initialTab: store.settingsTab)
                    .environmentObject(store)
                    .frame(width: 720, height: 650)
            case .activation:
                LicenseActivationView(licenseManager: store.licenseManager)
                    .environmentObject(store)
                    .frame(width: 540)
            case .controlSetup:
                ControlSetupGuideView()
                    .environmentObject(store)
                    .frame(width: 560)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $store.selectedSessionID) {
            Section {
                if store.sessions.isEmpty {
                    Label(store.t("menu.noDevices"), systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.sessions) { session in
                        DeviceRowView(session: session)
                            .tag(session.id)
                    }
                }
            } header: {
                Text("\(store.t("menu.devices")) (\(store.sessions.count))")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Bottom bar (spans full window width — no split-column seam)

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Circle()
                .fill(store.connectedSessions.isEmpty ? Color.secondary : Theme.Palette.live)
                .frame(width: 7, height: 7)
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if store.shouldOfferControlDiagnostics {
                Button {
                    store.presentDiagnostics()
                } label: {
                    Label(store.t("status.controlOpenDiagnostics"), systemImage: "wrench.and.screwdriver")
                }
                .controlSize(.small)
            }

            Spacer(minLength: Theme.Spacing.md)

            if let session = selectedSession {
                DeviceActionBar(session: session)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: DashboardWindowLayout.bottomBarHeight)
        .background(.bar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if store.permissionStatus != .authorized {
            PermissionView()
        } else {
            VStack(spacing: 0) {
                if store.microphonePermissionStatus != .authorized {
                    MicrophonePermissionBanner()
                    Divider()
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

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $store.autoStartMirrors) {
                Label(store.t("toolbar.autoStart"), systemImage: "bolt.badge.a")
            }
            .toggleStyle(.button)
            .help(store.t("settings.autoOpen"))
        }
        ToolbarItemGroup(placement: .automatic) {
            Button {
                store.stopAll()
            } label: {
                Label(store.t("toolbar.stop"), systemImage: "stop.fill")
            }
            .help(store.t("menu.stopAll"))

            if store.licenseManager.state.showsDashboardActivationEntry {
                Button {
                    store.presentActivation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: licenseBadgeIcon)
                        Text(store.t("license.badge.unactivated"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(licenseBadgeColor)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(licenseBadgeColor.opacity(0.14))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(licenseBadgeColor.opacity(0.28), lineWidth: 1)
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(store.t("license.badge.help"))
            }

            Button {
                store.toggleSettings()
            } label: {
                Label(store.t("toolbar.settings"), systemImage: "gearshape")
            }
            .help(store.t("toolbar.settings"))

            Button {
                store.presentMCPSettings()
            } label: {
                MCPToolbarLabel(manager: store.mcpServer)
            }
            .help(store.t("toolbar.mcp"))

            Button {
                store.toggleDiagnostics()
            } label: {
                Label(store.t("toolbar.diagnostics"), systemImage: "stethoscope")
            }
            .help(store.t("toolbar.diagnostics"))

            Button {
                store.refresh()
            } label: {
                Label(store.t("toolbar.refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .help(store.t("toolbar.refresh"))
        }
    }

    private var licenseBadgeColor: Color {
        switch store.licenseManager.state {
        case .expired, .unavailable:
            Theme.Palette.danger
        case .trialNotStarted, .trial:
            Theme.Palette.pending
        case .checking, .licensed:
            .secondary
        }
    }

    private var licenseBadgeIcon: String {
        switch store.licenseManager.state {
        case .expired, .unavailable:
            "lock.fill"
        case .trialNotStarted, .trial, .checking, .licensed:
            "key.fill"
        }
    }
}

struct ContentUnavailablePlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PermissionView: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "video.badge.exclamationmark")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(store.t("permission.title"))
                .font(.title3.weight(.semibold))
            Text(permissionBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: Theme.Spacing.sm) {
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
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(store.t("permission.requesting"))
                        }
                    } else {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .disabled(store.isRequestingCameraPermission)

                Button {
                    store.recheckCameraPermission()
                } label: {
                    Label(store.t("permission.recheck"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct MicrophonePermissionBanner: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: "speaker.wave.2")
                .font(.title2)
                .foregroundStyle(Theme.Palette.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.t("permission.microphone.title"))
                    .font(.headline)
                Text(bodyCopy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.md)

            if store.microphonePermissionStatus == .notDetermined {
                Button {
                    Task {
                        await store.requestMicrophonePermission()
                    }
                } label: {
                    if store.isRequestingMicrophonePermission {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(store.t("permission.requesting"))
                        }
                    } else {
                        Label(store.t("permission.microphone.requestAccess"), systemImage: "mic.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .disabled(store.isRequestingMicrophonePermission)
            } else {
                Button {
                    store.openMicrophonePrivacySettings()
                } label: {
                    Label(store.t("permission.microphone.openSettings"), systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)

                Button {
                    store.recheckMicrophonePermission()
                } label: {
                    Label(store.t("permission.recheck"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Palette.accent.opacity(0.08))
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

struct EmptyDevicesView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(store.t("empty.title"))
                .font(.title3.weight(.semibold))
            Text(store.t("empty.body"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                refresh()
            } label: {
                Label(store.t("toolbar.refresh"), systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.t("toolbar.diagnostics"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label(store.t("common.close"), systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(store.t("common.close"))
                Button {
                    store.refresh()
                } label: {
                    Label(store.t("toolbar.refresh"), systemImage: "arrow.clockwise")
                }
            }
            .padding(18)

            Divider()

            List {
                Section(store.t("diagnostics.runtime")) {
                    ForEach(store.diagnostics) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(item.value)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section(store.t("diagnostics.devices")) {
                    if store.sessions.isEmpty {
                        Text(store.t("diagnostics.noDevices"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.device.name)
                                    .font(.headline)
                                Text(session.device.udid ?? store.t("common.noUDID"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("\(store.t("diagnostic.mirror")): \(store.mirrorStateLabel(session.mirrorSession.state)) / \(store.t("diagnostic.control")): \(store.controlStateLabel(session.controlSession.state))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(store.t("diagnostics.controlPrereq")) {
                    Text(store.t("diagnostics.controlHelp"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ControlSetupGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceGalleryStore

    private var selectedSession: DeviceSession? {
        guard let id = store.selectedSessionID else { return nil }
        return store.sessions.first { $0.id == id }
    }

    private var selectedTeamBinding: Binding<String> {
        Binding(
            get: { store.controlXcodeOrgID },
            set: { store.selectSigningTeam($0) }
        )
    }

    private var selectedTeam: XcodeSigningTeam? {
        store.detectedSigningTeams.first { $0.id == store.controlXcodeOrgID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2)
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.t("control.setup.title"))
                        .font(.title2.weight(.semibold))
                    Text(store.t("control.setup.subtitle"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label(store.t("common.close"), systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                setupStep(number: 1, titleKey: "control.setup.step1.title", bodyKey: "control.setup.step1.body")
                setupStep(number: 2, titleKey: "control.setup.step2.title", bodyKey: "control.setup.step2.body")

                VStack(alignment: .leading, spacing: 10) {
                    setupStep(number: 3, titleKey: "control.setup.step3.title", bodyKey: "control.setup.step3.body")

                    HStack(spacing: 10) {
                        signingStatus
                        Spacer()
                        Button {
                            Task { await store.detectSigningTeams() }
                        } label: {
                            if store.isDetectingSigningTeams {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(store.t("control.setup.detectAccount"))
                            }
                        }
                        .disabled(store.isDetectingSigningTeams)
                    }
                    .padding(.leading, 42)

                    if store.detectedSigningTeams.count > 1 {
                        Picker(store.t("control.setup.chooseAccount"), selection: selectedTeamBinding) {
                            Text(store.t("control.setup.chooseAccountPlaceholder")).tag("")
                            ForEach(store.detectedSigningTeams) { team in
                                Text("\(team.name) · \(team.id)").tag(team.id)
                            }
                        }
                        .padding(.leading, 42)
                    }

                    DisclosureGroup(store.t("control.setup.manualEntry")) {
                        TextField(store.t("settings.xcodeTeam"), text: $store.controlXcodeOrgID)
                            .textFieldStyle(.roundedBorder)
                        Text(store.t("control.setup.manualEntryHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 42)
                }

                Text(store.t("control.setup.mirrorNote"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(20)

            Divider()

            HStack {
                Button(store.t("status.controlOpenDiagnostics")) {
                    store.presentDiagnostics()
                }
                Spacer()
                Button(store.t("common.cancel")) {
                    dismiss()
                }
                Button(store.t("control.setup.retry")) {
                    guard let session = selectedSession else { return }
                    Task {
                        await store.detectSigningTeams()
                        store.setActiveSheet(nil)
                        store.connectControl(for: session)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .disabled(store.isDetectingSigningTeams || selectedSession == nil)
            }
            .padding(20)
        }
        .task {
            await store.detectSigningTeams()
        }
    }

    @ViewBuilder
    private var signingStatus: some View {
        if let selectedTeam {
            Label(store.t("control.setup.accountReady"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.live)
                .help("\(selectedTeam.name) · \(selectedTeam.id)")
        } else if !store.controlXcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(store.t("control.setup.accountConfigured"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.live)
        } else if store.detectedSigningTeams.count > 1 {
            Label(store.t("control.setup.chooseAccount"), systemImage: "person.2")
                .foregroundStyle(Theme.Palette.pending)
        } else {
            Label(store.t("control.setup.accountMissing"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.pending)
        }
    }

    private func setupStep(number: Int, titleKey: String, bodyKey: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.Palette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(store.t(titleKey))
                    .font(.headline)
                Text(store.t(bodyKey))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MCPToolbarLabel: View {
    @ObservedObject var manager: MCPServerManager

    var body: some View {
        Label("MCP", systemImage: manager.status.isRunning ? "terminal.fill" : "terminal")
            .foregroundStyle(manager.status.isRunning ? Theme.Palette.live : .secondary)
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
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.t("toolbar.settings"))
                        .font(.title2.weight(.semibold))
                    Text(store.t("settings.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label(store.t("common.close"), systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(store.t("common.close"))
            }
            .padding(20)

            Divider()

            TabView(selection: $selectedTab) {
                Form {
                    LicenseSettingsSection(licenseManager: store.licenseManager)

                    Section(store.t("settings.language")) {
                        Picker(store.t("settings.language"), selection: $store.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section(store.t("settings.mirroring")) {
                        Toggle(store.t("settings.autoOpen"), isOn: $store.autoStartMirrors)
                    }

                    Section(store.t("settings.control")) {
                        HStack {
                            StatusPill(
                                title: store.appiumServiceStateLabel(store.appiumService.state),
                                color: appiumServiceColor
                            )
                            Text(store.appiumService.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        HStack {
                            Button {
                                store.appiumService.check(serverURL: store.appiumServerURL)
                            } label: {
                                Label(store.t("settings.check"), systemImage: "waveform.path.ecg")
                            }

                            Button {
                                store.appiumService.start(serverURL: store.appiumServerURL)
                            } label: {
                                Label(store.t("settings.startAppium"), systemImage: "play.fill")
                            }

                            Button {
                                store.appiumService.stop()
                            } label: {
                                Label(store.t("settings.stop"), systemImage: "stop.fill")
                            }
                        }

                        Text(store.t("settings.appiumHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        DisclosureGroup(store.t("settings.controlAdvanced")) {
                            TextField(store.t("settings.appiumURL"), text: $store.appiumServerURL)
                            TextField(store.t("settings.bundleID"), text: $store.controlBundleID)
                            TextField(store.t("settings.xcodeTeam"), text: $store.controlXcodeOrgID)
                            TextField(store.t("settings.xcodeSigningID"), text: $store.controlXcodeSigningID)
                            TextField(store.t("settings.wdaBundleID"), text: $store.controlWDABundleID)
                            Toggle(store.t("settings.usePrebuiltWDA"), isOn: $store.controlUsePrebuiltWDA)
                        }
                    }
                }
                .formStyle(.grouped)
                .tabItem { Label(store.t("settings.general"), systemImage: "gearshape") }
                .tag(DashboardSettingsTab.general)

                MCPAutomationSettingsView(manager: store.mcpServer)
                    .environmentObject(store)
                    .tabItem { Label(store.t("mcp.title"), systemImage: "terminal") }
                    .tag(DashboardSettingsTab.mcp)
            }
            .padding(12)
        }
    }

    private var appiumServiceColor: Color {
        switch store.appiumService.state {
        case .running:
            .green
        case .checking, .starting:
            .orange
        case .missing, .failed:
            .red
        case .unknown, .stopped:
            .secondary
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
    @State private var portDraft = ""
    @State private var tutorialClient: MCPTutorialClient = .codex
    @State private var showToken = false
    @State private var confirmRotation = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox(store.t("mcp.server")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            store.t("mcp.enabled"),
                            isOn: Binding(
                                get: { manager.enabled },
                                set: { value in Task { await manager.setEnabled(value) } }
                            )
                        )
                        HStack {
                            StatusPill(title: statusTitle, color: statusColor)
                            Text(manager.endpoint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text(String(format: store.t("mcp.clients"), manager.connectedClientCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if case let .failed(message) = manager.status {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        HStack {
                            TextField(store.t("mcp.port"), text: $portDraft)
                                .frame(width: 110)
                            Button(store.t("mcp.applyPort")) {
                                applyPort()
                            }
                            Text(store.t("mcp.localOnly"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox(store.t("mcp.token")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(showToken ? manager.bearerToken : String(repeating: "•", count: 32))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                            Button(showToken ? store.t("mcp.hide") : store.t("mcp.show")) {
                                showToken.toggle()
                            }
                            Button(store.t("mcp.copyToken")) { copy(manager.bearerToken) }
                            Button(store.t("mcp.rotateToken"), role: .destructive) {
                                confirmRotation = true
                            }
                        }
                        Text(store.t("mcp.tokenHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox(store.t("mcp.connect")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("", selection: $tutorialClient) {
                            Text("Codex").tag(MCPTutorialClient.codex)
                            Text("Claude Code").tag(MCPTutorialClient.claude)
                        }
                        .pickerStyle(.segmented)

                        Text(tutorialClient == .codex ? store.t("mcp.codexSteps") : store.t("mcp.claudeSteps"))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .top) {
                            ScrollView(.horizontal) {
                                Text(connectionText)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            Button(store.t("mcp.copyConfig")) { copy(connectionText) }
                        }

                        Text(store.t("mcp.verify"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("“\(store.t("mcp.testPrompt"))”")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                }

                GroupBox(store.t("mcp.logs")) {
                    if manager.callLog.isEmpty {
                        Text(store.t("mcp.noLogs"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(manager.callLog.prefix(20)) { entry in
                                HStack {
                                    Circle()
                                        .fill(entry.succeeded ? Color.green : Color.red)
                                        .frame(width: 7, height: 7)
                                    Text(entry.tool).font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text("\(entry.durationMilliseconds) ms")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .padding(8)
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

    private var connectionText: String {
        tutorialClient == .codex ? manager.codexConfiguration : manager.claudeCommand
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
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
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
