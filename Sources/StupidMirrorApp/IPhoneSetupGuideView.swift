import SwiftUI

/// The one guide for iPhones. It checks the phone's real state over the
/// device tunnel sidecar (USB, Developer Mode, installed agent, Wi-Fi
/// connections) and runs the single USB preparation that enables both wired
/// control and wireless mirroring.
struct IPhoneSetupGuideView: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @State private var showManualEntry = false
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
            SheetHeader(
                icon: "iphone.gen3.radiowaves.left.and.right",
                title: store.t("iphone.setup.title"),
                subtitle: store.t("iphone.setup.subtitle"),
                closeHelp: store.t("common.close")
            ) {
                dismiss()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupLabel(
                        title: usbSession?.device.name ?? store.t("iphone.setup.usb.waiting"),
                        trailing: String(format: store.t("iphone.setup.progress"), readySteps)
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        usbStep
                        RowDivider()
                        developerModeStep
                        RowDivider()
                        accountStep
                        RowDivider()
                        agentStep
                    }
                    .wellSurface()

                    Text(store.t("iphone.setup.note"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            footer
        }
        .frame(minHeight: 560)
        .task {
            await store.refreshIPhoneSetupReadiness()
        }
        .onChange(of: usbSession?.id) { _, _ in
            Task { await store.refreshIPhoneSetupReadiness() }
        }
    }

    /// Steps that are already satisfied, at their true count.
    private var readySteps: Int {
        var count = 0
        if usbSession != nil { count += 1 }
        if readiness?.developerMode == true { count += 1 }
        if hasSigningTeam { count += 1 }
        if agentPrepared { count += 1 }
        return count
    }

    // MARK: Footer

    private var footer: some View {
        SheetFooter {
            Button(store.t("status.controlOpenDiagnostics")) {
                store.presentDiagnostics()
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .disabled(isPreparing)
            Button {
                Task { await store.refreshIPhoneSetupReadiness() }
            } label: {
                Label(store.t("iphone.setup.recheck"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .disabled(isPreparing || isInspecting || usbSession == nil)
            Spacer()
            if isPreparing {
                Button(store.t("iphone.setup.stop"), role: .cancel) {
                    store.cancelIPhoneSetupPreparation()
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            } else {
                Button(store.t("common.cancel")) {
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            }
            if agentPrepared {
                Button(store.t("iphone.setup.reprepare")) {
                    store.prepareIPhoneAgent(force: true)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(isPreparing || usbSession == nil || !hasSigningTeam)
                Button(store.t("iphone.setup.finish")) {
                    store.finishIPhoneSetupAndDiscover()
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparing)
            } else {
                Button(store.t("iphone.setup.prepare")) {
                    store.prepareIPhoneAgent()
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isPreparing || isInspecting || usbSession == nil || !hasSigningTeam || readiness?.developerMode == false)
            }
        }
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
            glyph: usbSession == nil ? .idle : .done
        )
    }

    private var developerModeStep: some View {
        let (status, glyph): (String, StatusGlyph.Kind) = {
            guard usbSession != nil else {
                return (store.t("iphone.setup.developerMode.unknown"), .idle)
            }
            switch readiness?.developerMode {
            case .some(true):
                return (store.t("iphone.setup.developerMode.on"), .done)
            case .some(false):
                return (store.t("iphone.setup.developerMode.off"), .failed)
            case .none:
                return (
                    store.t(isInspecting ? "iphone.setup.inspecting" : "iphone.setup.developerMode.unknown"),
                    isInspecting ? .working : .idle
                )
            }
        }()
        return VStack(alignment: .leading, spacing: 0) {
            setupStep(
                number: 2,
                title: store.t("iphone.setup.step.developerMode.title"),
                body: store.t("iphone.setup.step.developerMode.body"),
                status: status,
                glyph: glyph
            )
            if usbSession != nil, readiness?.developerMode == false {
                Text(store.t("iphone.setup.developerMode.howTo"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.stepIndent)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
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
                glyph: hasSigningTeam ? .done : .idle
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
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .disabled(store.isDetectingSigningTeams)
            }
            .padding(.leading, Self.stepIndent)
            .padding(.trailing, 14)

            if store.detectedSigningTeams.count > 1 {
                Picker(store.t("control.setup.chooseAccount"), selection: selectedTeamBinding) {
                    Text(store.t("control.setup.chooseAccountPlaceholder")).tag("")
                    ForEach(store.detectedSigningTeams) { team in
                        Text("\(team.name) · \(team.id)").tag(team.id)
                    }
                }
                .padding(.leading, Self.stepIndent)
                .padding(.trailing, 14)
            }

            DisclosureHeader(
                isExpanded: $showManualEntry,
                insets: EdgeInsets(top: 8, leading: Self.stepIndent, bottom: 8, trailing: 14),
                accessibilityTitle: store.t("control.setup.manualEntry")
            ) {
                Text(store.t("control.setup.manualEntry"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.secondary)
            }
            if showManualEntry {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(store.t("settings.xcodeTeam"), text: $store.controlXcodeOrgID)
                        .fieldSurface(monospaced: true)
                    Text(store.t("control.setup.manualEntryHelp"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                .padding(.leading, Self.stepIndent)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupStep(
                number: 4,
                title: store.t("iphone.setup.step.agent.title"),
                body: store.t("iphone.setup.step.agent.body"),
                status: agentStatus.text,
                glyph: agentStatus.glyph
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
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                }
                .padding(.leading, Self.stepIndent)
                .padding(.bottom, 12)
            }
        }
    }

    private var agentStatus: (text: String, glyph: StatusGlyph.Kind) {
        switch phase {
        case let .preparing(step):
            let text = store.t(Self.stepKey(step))
            // The guide may now be looking at another phone than the one
            // being prepared; say which one is busy.
            if let preparing = store.iphoneSetupPreparingSession, preparing.id != usbSession?.id {
                return (String(format: store.t("iphone.setup.preparingOther"), preparing.device.name) + " " + text, .working)
            }
            return (text, .working)
        case let .ready(reachableOverWiFi):
            return (store.t(reachableOverWiFi ? "iphone.setup.ready.wifi" : "iphone.setup.ready.usbOnly"), .done)
        case let .failed(message):
            return (message, .failed)
        case .inspecting:
            return (store.t("iphone.setup.inspecting"), .working)
        case .idle:
            if readiness?.runnerInstalled == true, readiness?.wifiConnections == true {
                return (store.t("iphone.setup.prepared"), .done)
            }
            return (store.t("iphone.setup.notPrepared"), .idle)
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

    /// Left edge of a step's text, past the number disc.
    private static let stepIndent: CGFloat = 52

    @ViewBuilder
    private var signingStatus: some View {
        if let selectedTeam {
            pieceLabel(store.t("control.setup.accountReady"), glyph: .done)
                .help("\(selectedTeam.name) · \(selectedTeam.id)")
        } else if hasSigningTeam {
            pieceLabel(store.t("control.setup.accountConfigured"), glyph: .done)
        } else if store.detectedSigningTeams.count > 1 {
            pieceLabel(store.t("control.setup.chooseAccount"), glyph: .warning)
        } else {
            pieceLabel(store.t("control.setup.accountMissing"), glyph: .warning)
        }
    }

    private func pieceLabel(_ text: String, glyph: StatusGlyph.Kind) -> some View {
        HStack(spacing: 8) {
            StatusGlyph(kind: glyph, size: 18)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.primary)
        }
    }

    private func checkRow(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            StatusGlyph(kind: ok ? .done : .idle, size: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(ok ? Theme.Ink.primary : Theme.Ink.secondary)
        }
    }

    private func setupStep(
        number: Int,
        title: String,
        body: String,
        status: String?,
        glyph: StatusGlyph.Kind
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(Theme.mono(12, weight: .medium))
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: 24, height: 24)
                .background(Theme.Surface.raised, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Ink.primary)
                Text(body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    HStack(spacing: 8) {
                        StatusGlyph(kind: glyph, size: 18)
                        Text(status)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(statusInk(glyph))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private func statusInk(_ glyph: StatusGlyph.Kind) -> Color {
        switch glyph {
        case .done: Theme.Palette.live
        case .failed: Theme.Palette.danger
        case .warning, .working: Theme.Palette.pending
        case .control: Theme.Palette.control
        case .idle: Theme.Ink.secondary
        }
    }
}
