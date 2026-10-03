import SwiftUI

/// The one guide for iPhones. It checks the phone's real state over the
/// device tunnel sidecar (USB, Developer Mode, installed agent, Wi-Fi
/// connections) and runs the single USB preparation that enables both wired
/// control and wireless mirroring.
struct IPhoneSetupGuideView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @Environment(\.dismiss) private var dismiss

    private var usbSession: DeviceSession? { store.iphoneSetupUSBSession }
    private var readiness: IOSDeviceReadiness? { store.iphoneSetupReadiness }
    private var phase: IPhoneSetupPhase { store.iphoneSetupPhase }

    private var hasSigningTeam: Bool {
        !store.controlXcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    private var isInspecting: Bool { phase == .inspecting }

    private var agentPrepared: Bool {
        if case .ready = phase { return true }
        return readiness?.runnerInstalled == true && readiness?.wifiConnections == true
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
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    usbStep
                    developerModeStep
                    accountStep
                    agentStep

                    Text(store.t("iphone.setup.note"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minHeight: 520)
        .task {
            await store.refreshIPhoneSetupReadiness()
        }
        .onChange(of: usbSession?.id) { _, _ in
            Task { await store.refreshIPhoneSetupReadiness() }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.t("iphone.setup.title"))
                    .font(.title2.weight(.semibold))
                Text(store.t("iphone.setup.subtitle"))
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
            .help(store.t("common.close"))
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button(store.t("status.controlOpenDiagnostics")) {
                store.presentDiagnostics()
            }
            .disabled(isPreparing)
            Button(store.t("iphone.setup.recheck")) {
                Task { await store.refreshIPhoneSetupReadiness() }
            }
            .disabled(isPreparing || isInspecting || usbSession == nil)
            Spacer()
            if isPreparing {
                Button(store.t("iphone.setup.stop"), role: .cancel) {
                    store.cancelIPhoneSetupPreparation()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button(store.t("common.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            if agentPrepared {
                Button(store.t("iphone.setup.reprepare")) {
                    store.prepareIPhoneAgent(force: true)
                }
                .disabled(isPreparing || usbSession == nil || !hasSigningTeam)
                Button(store.t("iphone.setup.finish")) {
                    store.finishIPhoneSetupAndDiscover()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparing)
            } else {
                Button(store.t("iphone.setup.prepare")) {
                    store.prepareIPhoneAgent()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparing || isInspecting || usbSession == nil || !hasSigningTeam || readiness?.developerMode == false)
            }
        }
        .padding(20)
    }

    // MARK: Steps

    private var usbStep: some View {
        setupStep(
            number: 1,
            title: store.t("iphone.setup.step.usb.title"),
            body: store.t("iphone.setup.step.usb.body"),
            status: usbSession.map {
                String(format: store.t("iphone.setup.usb.connected"), $0.device.name)
            } ?? store.t("iphone.setup.usb.waiting"),
            icon: usbSession == nil ? "iphone.slash" : "checkmark.circle.fill",
            color: usbSession == nil ? Theme.Palette.pending : Theme.Palette.live
        )
    }

    private var developerModeStep: some View {
        let (status, icon, color): (String, String, Color) = {
            guard usbSession != nil else {
                return (store.t("iphone.setup.developerMode.unknown"), "questionmark.circle", .secondary)
            }
            switch readiness?.developerMode {
            case .some(true):
                return (store.t("iphone.setup.developerMode.on"), "checkmark.circle.fill", Theme.Palette.live)
            case .some(false):
                return (store.t("iphone.setup.developerMode.off"), "exclamationmark.triangle.fill", Theme.Palette.danger)
            case .none:
                return (
                    store.t(isInspecting ? "iphone.setup.inspecting" : "iphone.setup.developerMode.unknown"),
                    isInspecting ? "hourglass" : "questionmark.circle",
                    .secondary
                )
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            setupStep(
                number: 2,
                title: store.t("iphone.setup.step.developerMode.title"),
                body: store.t("iphone.setup.step.developerMode.body"),
                status: status,
                icon: icon,
                color: color
            )
            if usbSession != nil, readiness?.developerMode == false {
                Text(store.t("iphone.setup.developerMode.howTo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            setupStep(
                number: 3,
                title: store.t("iphone.setup.step.account.title"),
                body: store.t("iphone.setup.step.account.body"),
                status: nil,
                icon: nil,
                color: .secondary
            )

            HStack(spacing: 10) {
                signingStatus
                Spacer()
                Button {
                    Task { await store.detectSigningTeams() }
                } label: {
                    if store.isDetectingSigningTeams {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(store.t("control.setup.detectAccount"))
                    } else {
                        Text(store.t("control.setup.detectAccount"))
                    }
                }
                .disabled(store.isDetectingSigningTeams)
            }
            .padding(.leading, 40)

            if store.detectedSigningTeams.count > 1 {
                Picker(store.t("control.setup.chooseAccount"), selection: selectedTeamBinding) {
                    Text(store.t("control.setup.chooseAccountPlaceholder")).tag("")
                    ForEach(store.detectedSigningTeams) { team in
                        Text("\(team.name) · \(team.id)").tag(team.id)
                    }
                }
                .padding(.leading, 40)
            }

            DisclosureGroup(store.t("control.setup.manualEntry")) {
                TextField(store.t("settings.xcodeTeam"), text: $store.controlXcodeOrgID)
                    .textFieldStyle(.roundedBorder)
                Text(store.t("control.setup.manualEntryHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 40)
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            setupStep(
                number: 4,
                title: store.t("iphone.setup.step.agent.title"),
                body: store.t("iphone.setup.step.agent.body"),
                status: agentStatus.text,
                icon: agentStatus.icon,
                color: agentStatus.color
            )
            if !isPreparing, usbSession != nil, let readiness {
                VStack(alignment: .leading, spacing: 4) {
                    checkRow(
                        readiness.runnerInstalled == true
                            ? String(format: store.t("iphone.setup.agent.installed"), readiness.productVersion)
                            : store.t("iphone.setup.agent.notInstalled"),
                        ok: readiness.runnerInstalled == true
                    )
                    checkRow(
                        store.t(readiness.wifiConnections == true ? "iphone.setup.wifi.on" : "iphone.setup.wifi.off"),
                        ok: readiness.wifiConnections == true
                    )
                    if readiness.isOnNetwork {
                        checkRow(store.t("iphone.setup.network.visible"), ok: true)
                    }
                    if readiness.developerImageMounted == false {
                        checkRow(store.t("iphone.setup.developerImage.missing"), ok: false)
                    }
                    if readiness.passwordProtected == true {
                        Label(store.t("iphone.setup.passcode.on"), systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 40)
            }
        }
    }

    private var agentStatus: (text: String, icon: String, color: Color) {
        switch phase {
        case let .preparing(step):
            let text = store.t(Self.stepKey(step))
            // The guide may now be looking at another phone than the one
            // being prepared; say which one is busy.
            if let preparing = store.iphoneSetupPreparingSession, preparing.id != usbSession?.id {
                return (String(format: store.t("iphone.setup.preparingOther"), preparing.device.name) + " " + text,
                        "hourglass", Theme.Palette.pending)
            }
            return (text, "hourglass", Theme.Palette.pending)
        case let .ready(reachableOverWiFi):
            return (
                store.t(reachableOverWiFi ? "iphone.setup.ready.wifi" : "iphone.setup.ready.usbOnly"),
                "checkmark.circle.fill",
                Theme.Palette.live
            )
        case let .failed(message):
            return (message, "exclamationmark.triangle.fill", Theme.Palette.danger)
        case .inspecting:
            return (store.t("iphone.setup.inspecting"), "hourglass", .secondary)
        case .idle:
            if readiness?.runnerInstalled == true, readiness?.wifiConnections == true {
                return (store.t("iphone.setup.prepared"), "checkmark.circle.fill", Theme.Palette.live)
            }
            return (store.t("iphone.setup.notPrepared"), "circle.dashed", .secondary)
        }
    }

    private static func stepKey(_ step: IOSAgentSetupStep) -> String {
        switch step {
        case .inspecting: "iphone.setup.step.inspecting"
        case .building: "iphone.setup.step.building"
        case .installing: "iphone.setup.step.installing"
        case .launching: "iphone.setup.step.launching"
        case .waitingForDevice: "iphone.setup.step.waitingForDevice"
        case .enablingWiFi: "iphone.setup.step.enablingWiFi"
        case .verifyingNetwork: "iphone.setup.step.verifyingNetwork"
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var signingStatus: some View {
        if let selectedTeam {
            Label(store.t("control.setup.accountReady"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.live)
                .help("\(selectedTeam.name) · \(selectedTeam.id)")
        } else if hasSigningTeam {
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

    private func checkRow(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle" : "circle")
            .font(.caption)
            .foregroundStyle(ok ? Theme.Palette.live : .secondary)
    }

    private func setupStep(
        number: Int,
        title: String,
        body: String,
        status: String?,
        icon: String?,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.Palette.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status, let icon {
                    Label(status, systemImage: icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
