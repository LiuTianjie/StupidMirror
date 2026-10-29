@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

enum DashboardSheet: String, Identifiable, Equatable, Sendable {
    case diagnostics
    case settings
    case activation
    case iphoneSetup

    var id: String { rawValue }

    static func toggling(_ target: DashboardSheet, from current: DashboardSheet?) -> DashboardSheet? {
        current == target ? nil : target
    }
}

/// Where the iPhone setup guide is.
enum IPhoneSetupPhase: Equatable, Sendable {
    case idle
    case inspecting
    case preparing(IOSAgentSetupStep)
    case ready(reachableOverWiFi: Bool)
    case failed(String)
}

enum CameraPermissionPresentation: Equatable {
    case hidden
    case fullPage
    case banner
}

enum DashboardSettingsTab: Hashable, Sendable, CaseIterable {
    case general
    case mirroring
    case mcp
    case license
}

@MainActor
final class DeviceGalleryStore: ObservableObject {
    let licenseManager: LicenseManager
    lazy var automationService = DeviceAutomationService(store: self)
    lazy var mcpServer = MCPServerManager(automation: automationService)

    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var permissionStatus: AVAuthorizationStatus = AVFoundationMirrorBackend.videoAuthorizationStatus()
    @Published private(set) var microphonePermissionStatus: AVAuthorizationStatus = AVFoundationMirrorBackend.audioAuthorizationStatus()
    @Published private(set) var isRequestingCameraPermission = false
    @Published private(set) var isRequestingMicrophonePermission = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var statusMessage: String = AppCopy.text("status.ready", language: DeviceGalleryStore.initialLanguage)
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var thumbnailAspectRatios: [String: Double] = [:]
    @Published private(set) var thumbnailErrors: [String: String] = [:]
    @Published var appiumService = AppiumServiceManager()
    @Published var autoStartMirrors = UserDefaults.standard.bool(forKey: DeviceGalleryStore.autoStartMirrorsDefaultsKey) {
        didSet { UserDefaults.standard.set(autoStartMirrors, forKey: Self.autoStartMirrorsDefaultsKey) }
    }
    @Published var wirelessMirroringEnabled = DeviceGalleryStore.boolDefault(
        DeviceGalleryStore.wirelessMirroringEnabledDefaultsKey,
        env: "STUPIDMIRROR_WIRELESS_MIRRORING"
    ) {
        didSet {
            UserDefaults.standard.set(wirelessMirroringEnabled, forKey: Self.wirelessMirroringEnabledDefaultsKey)
            refresh()
        }
    }
    @Published var audioPlaybackEnabled = UserDefaults.standard.bool(forKey: DeviceGalleryStore.audioPlaybackEnabledDefaultsKey) {
        didSet {
            UserDefaults.standard.set(audioPlaybackEnabled, forKey: Self.audioPlaybackEnabledDefaultsKey)
            applyAudioPlaybackPreference()
        }
    }
    @Published var floatingMirrorIDs = Set<String>()
    @Published var appiumServerURL = DeviceGalleryStore.stringDefault(
        DeviceGalleryStore.appiumServerURLDefaultsKey,
        env: "STUPIDMIRROR_APPIUM_SERVER_URL",
        info: "StupidMirrorDefaultAppiumServerURL",
        fallback: "http://127.0.0.1:4723"
    ) {
        didSet { UserDefaults.standard.set(appiumServerURL, forKey: Self.appiumServerURLDefaultsKey) }
    }
    @Published var controlBundleID = DeviceGalleryStore.stringDefault(
        DeviceGalleryStore.controlBundleIDDefaultsKey,
        env: "STUPIDMIRROR_CONTROL_BUNDLE_ID",
        info: "StupidMirrorDefaultControlBundleID",
        fallback: ""
    ) {
        didSet { UserDefaults.standard.set(controlBundleID, forKey: Self.controlBundleIDDefaultsKey) }
    }
    @Published var controlXcodeOrgID = DeviceGalleryStore.stringDefault(
        DeviceGalleryStore.controlXcodeOrgIDDefaultsKey,
        env: "STUPIDMIRROR_XCODE_ORG_ID",
        info: "StupidMirrorDefaultXcodeOrgID",
        fallback: ""
    ) {
        didSet { UserDefaults.standard.set(controlXcodeOrgID, forKey: Self.controlXcodeOrgIDDefaultsKey) }
    }
    @Published var controlXcodeSigningID = DeviceGalleryStore.stringDefault(
        DeviceGalleryStore.controlXcodeSigningIDDefaultsKey,
        env: "STUPIDMIRROR_XCODE_SIGNING_ID",
        info: "StupidMirrorDefaultXcodeSigningID",
        fallback: "Apple Development"
    ) {
        didSet { UserDefaults.standard.set(controlXcodeSigningID, forKey: Self.controlXcodeSigningIDDefaultsKey) }
    }
    @Published var controlWDABundleID = DeviceGalleryStore.stringDefault(
        DeviceGalleryStore.controlWDABundleIDDefaultsKey,
        env: "STUPIDMIRROR_WDA_BUNDLE_ID",
        info: "StupidMirrorDefaultWDABundleID",
        fallback: ""
    ) {
        didSet { UserDefaults.standard.set(controlWDABundleID, forKey: Self.controlWDABundleIDDefaultsKey) }
    }
    @Published private(set) var detectedSigningTeams: [XcodeSigningTeam] = []
    @Published private(set) var isDetectingSigningTeams = false
    @Published private(set) var iphoneSetupPhase: IPhoneSetupPhase = .idle
    @Published private(set) var iphoneSetupReadiness: IOSDeviceReadiness?
    /// Which phone `iphoneSetupReadiness` describes.
    private var iphoneSetupReadinessUDID: String?
    @Published private(set) var iphoneSetupPreparingUDID: String?
    private var iphoneSetupTask: Task<Void, Never>?
    private var iphoneSetupInspection: Task<Void, Never>?
    @Published private(set) var activeSheet: DashboardSheet?
    @Published private(set) var settingsTab: DashboardSettingsTab = .general
    @Published var selectedSessionID: String?
    @Published var appearance: AppAppearance = .stored {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppAppearance.defaultsKey)
            appearance.apply()
        }
    }
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey)
            statusMessage = localizedStatusMessage
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var shutdownTask: Task<Void, Never>?
    private var signingTeamDetectionTask: Task<[XcodeSigningTeam], Never>?
    private var refreshRequestedWhileRunning = false
    private var thumbnailCaptures: [String: ThumbnailCapture] = [:]
    private var wirelessThumbnailTasks: [String: Task<Void, Never>] = [:]
    /// Keyed by the mirror the work serves; see `session(owning:)`.
    private var wirelessTransportTasks: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]
    private var discoveryRetryTask: Task<Void, Never>?
    private var removedDeviceIDs = Set<String>()
    private var desiredMirrorIDs = Set<String>()
    private var desiredControlIDs = Set<String>() {
        didSet { reconcileUSBCaptureHolds() }
    }
    private var pendingActivationMirrorIDs = Set<String>()
    private var disconnectedSince: [String: Date] = [:]
    private var lastConnectedCount = 0
    private var lastReconnectingCount = 0
    private var isShuttingDown = false

    private static let periodicRefreshInterval: TimeInterval = 10
    private static let reconnectRetentionInterval: TimeInterval = 30
    private static let maxRetainedDisconnectedSessions = 4
    private static let discoveryRetryDelays: [Duration] = [.milliseconds(500), .seconds(1.5), .seconds(3)]

    private static let languageDefaultsKey = "StupidMirror.language"
    private static let autoStartMirrorsDefaultsKey = "StupidMirror.autoStartMirrors"
    private var embeddedPreviewIDs = Set<String>()
    private var shouldAutoStartMirrors: Bool {
        autoStartMirrors && !CommandLine.arguments.contains("--mcp-background")
    }
    private static let wirelessMirroringEnabledDefaultsKey = "StupidMirror.wirelessMirroringEnabled"
    private static let wirelessSetupGuideSeenDefaultsKey = "StupidMirror.wirelessSetupGuideSeen"
    private static let audioPlaybackEnabledDefaultsKey = "StupidMirror.audioPlaybackEnabled"
    private static let appiumServerURLDefaultsKey = "StupidMirror.appiumServerURL"
    private static let controlBundleIDDefaultsKey = "StupidMirror.controlBundleID"
    private static let controlXcodeOrgIDDefaultsKey = "StupidMirror.controlXcodeOrgID"
    private static let controlXcodeSigningIDDefaultsKey = "StupidMirror.controlXcodeSigningID"
    private static let controlWDABundleIDDefaultsKey = "StupidMirror.controlWDABundleID"

    private static func stringDefault(_ key: String, env: String, info: String, fallback: String) -> String {
        if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
            return value
        }
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: info) as? String, !value.isEmpty {
            return value
        }
        return fallback
    }

    private static func boolDefault(_ key: String, env: String) -> Bool {
        if let value = ProcessInfo.processInfo.environment[env]?.lowercased() {
            return ["1", "true", "yes", "on"].contains(value)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    nonisolated static func latestValueByID<Value>(_ values: [Value], id: (Value) -> String) -> [String: Value] {
        var lookup: [String: Value] = [:]
        for value in values {
            lookup[id(value)] = value
        }
        return lookup
    }

    private static var initialLanguage: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: languageDefaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }

    var diagnostics: [DiagnosticItem] {
        let androidRuntime = AndroidRuntime.status
        return [
            DiagnosticItem(name: t("diagnostic.camera"), value: authorizationLabel(permissionStatus)),
            DiagnosticItem(name: t("diagnostic.microphone"), value: authorizationLabel(microphonePermissionStatus)),
            DiagnosticItem(
                name: t("diagnostic.backend"),
                value: "iPhone: WDA H.264 over SRT (USB / Wi-Fi); Mac audio: USB"
            ),
            DiagnosticItem(
                name: t("settings.wirelessMirroring"),
                value: wirelessMirroringEnabled ? t("common.on") : t("common.off")
            ),
            DiagnosticItem(name: t("diagnostic.detected"), value: "\(connectedSessions.count)"),
            DiagnosticItem(name: t("diagnostic.reconnecting"), value: "\(reconnectingSessions.count)"),
            DiagnosticItem(name: t("diagnostic.autoStart"), value: autoStartMirrors ? t("common.on") : t("common.off")),
            DiagnosticItem(name: t("diagnostic.appiumServer"), value: appiumServerURL),
            DiagnosticItem(name: t("diagnostic.appiumService"), value: appiumServiceStateLabel(appiumService.state)),
            DiagnosticItem(name: t("diagnostic.appiumDetail"), value: appiumService.message),
            DiagnosticItem(name: t("diagnostic.deviceControlState"), value: deviceControlDiagnosticLabel),
            DiagnosticItem(name: t("diagnostic.controlBundle"), value: controlBundleID.isEmpty ? t("common.notSet") : controlBundleID),
            DiagnosticItem(name: t("diagnostic.xcodeTeam"), value: controlXcodeOrgID.isEmpty ? t("common.notSet") : controlXcodeOrgID),
            DiagnosticItem(name: t("diagnostic.wdaBundle"), value: effectiveControlWDABundleID.isEmpty ? t("common.default") : effectiveControlWDABundleID),
            DiagnosticItem(name: t("diagnostic.libimobiledevice"), value: DeviceMetadataService.isAvailable ? t("connection.connected") : t("appium.state.missing")),
            DiagnosticItem(
                name: t("diagnostic.androidADB"),
                value: androidRuntime.adbPath ?? t("appium.state.missing")
            ),
            DiagnosticItem(
                name: t("diagnostic.androidMirror"),
                value: androidRuntime.mirroringAvailable
                    ? "scrcpy server \(androidRuntime.scrcpyServerVersion ?? "")"
                    : t("appium.state.missing")
            )
        ]
    }

    var shouldOfferControlDiagnostics: Bool {
        statusMessage == t("status.controlAppiumUnavailable")
    }

    var connectedSessions: [DeviceSession] {
        sessions.filter { $0.device.connectionState == .connected }
    }

    /// Wireless iPhones are `.connected` while usbmuxd lists them on the
    /// network, so every transport uses the same rule.
    func canAttemptConnection(_ session: DeviceSession) -> Bool {
        session.device.connectionState == .connected
    }

    var reconnectingSessions: [DeviceSession] {
        sessions.filter { $0.device.connectionState == .disconnected }
    }

    var canUseControl: Bool {
        licenseManager.state.capabilities.controlEnabled
    }

    /// An iPhone whose audio the Mac could play. Simulators play through the
    /// Mac already.
    var hasConnectedIOSDevice: Bool {
        connectedSessions.contains { $0.platform == .iOS && $0.transport == .usb }
    }

    var canPlayDeviceAudioOnMac: Bool {
        connectedSessions.contains { $0.canPlayAudioOnMac }
    }

    var cameraPermissionPresentation: CameraPermissionPresentation {
        guard connectedSessions.contains(where: { $0.needsCameraPermission }) else { return .hidden }
        return Self.cameraPermissionPresentation(
            authorizationStatus: permissionStatus,
            hasCameraIndependentConnectedDevice: connectedSessions.contains {
                !$0.needsCameraPermission
            }
        )
    }

    nonisolated static func cameraPermissionPresentation(
        authorizationStatus: AVAuthorizationStatus,
        hasCameraIndependentConnectedDevice: Bool
    ) -> CameraPermissionPresentation {
        guard authorizationStatus != .authorized else { return .hidden }
        return hasCameraIndependentConnectedDevice ? .banner : .fullPage
    }

    var needsIOSAudioPermission: Bool {
        hasConnectedIOSDevice && microphonePermissionStatus != .authorized
    }

    private var deviceControlDiagnosticLabel: String {
        if sessions.contains(where: { $0.controlSession.isReady }) {
            return t("control.state.ready")
        }
        if sessions.contains(where: { $0.controlSession.isConnecting }) {
            return t("control.state.connectingWDA")
        }
        if sessions.contains(where: {
            if case .failed = $0.controlSession.state { return true }
            return false
        }) {
            return t("control.state.failed")
        }
        return t("control.state.unavailable")
    }

    init(licenseManager: LicenseManager? = nil) {
        self.licenseManager = licenseManager ?? LicenseManager.live()
        language = Self.initialLanguage
        let status = AVFoundationMirrorBackend.allowScreenCaptureDevices()
        statusMessage = "CoreMediaIO screen capture devices enabled: \(status)"
        self.licenseManager.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self else { return }
                self.enforceSimultaneousDeviceLimit(state.capabilities)
                self.enforceSimultaneousControlLimit(state.capabilities)
                self.refresh()
            }
            .store(in: &cancellables)
        installDeviceObservers()
        startPeriodicRefresh()
        refreshIfCameraAuthorized()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.licenseManager.bootstrap()
            self.refresh()
            await self.mcpServer.startIfEnabled()
        }
    }

    func refreshIfCameraAuthorized() {
        permissionStatus = AVFoundationMirrorBackend.videoAuthorizationStatus()
        microphonePermissionStatus = AVFoundationMirrorBackend.audioAuthorizationStatus()
        refresh()
    }

    func discoverWirelessDevices() {
        wirelessMirroringEnabled = true
        guard UserDefaults.standard.bool(forKey: Self.wirelessSetupGuideSeenDefaultsKey) else {
            presentIPhoneSetup(for: iphoneSetupUSBSession)
            return
        }
        continueWirelessDiscovery()
    }

    private func continueWirelessDiscovery() {
        statusMessage = t("status.discoveringWireless")
        if wirelessMirroringEnabled {
            refresh()
        } else {
            wirelessMirroringEnabled = true
        }
    }

    /// Opens the iPhone setup guide and starts checking the phone's state.
    func presentIPhoneSetup(for session: DeviceSession? = nil) {
        if let session, session.platform == .iOS {
            select(session)
        } else if let usb = iphoneSetupUSBSession {
            select(usb)
        }
        // Reopening the guide while a preparation runs keeps showing it.
        if case .preparing = iphoneSetupPhase {
            setActiveSheet(.iphoneSetup)
            return
        }
        iphoneSetupPhase = .idle
        iphoneSetupReadiness = nil
        iphoneSetupReadinessUDID = nil
        setActiveSheet(.iphoneSetup)
    }

    var isPreparingIPhone: Bool {
        if case .preparing = iphoneSetupPhase { return true }
        return false
    }

    /// Re-reads the selected USB iPhone's state for the setup guide.
    /// Concurrent calls share one inspection.
    func refreshIPhoneSetupReadiness() async {
        if let inFlight = iphoneSetupInspection {
            await inFlight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inspectIPhoneForSetup()
        }
        iphoneSetupInspection = task
        await task.value
        iphoneSetupInspection = nil
    }

    private func inspectIPhoneForSetup() async {
        guard !isPreparingIPhone else { return }
        guard let session = iphoneSetupUSBSession, let udid = session.device.udid, !udid.isEmpty else {
            // The phone went away: nothing shown may describe it any longer.
            iphoneSetupReadiness = nil
            iphoneSetupReadinessUDID = nil
            iphoneSetupPhase = .idle
            return
        }
        if iphoneSetupReadinessUDID != udid {
            iphoneSetupReadiness = nil
            if case .ready = iphoneSetupPhase { iphoneSetupPhase = .idle }
            if case .failed = iphoneSetupPhase { iphoneSetupPhase = .idle }
        }
        iphoneSetupPhase = .inspecting
        if detectedSigningTeams.isEmpty {
            await detectSigningTeams()
        }
        let configuration = iosControlConfiguration()
        do {
            let readiness = try await IOSAgentService.inspect(udid: udid, configuration: configuration)
            guard iphoneSetupUSBSession?.device.udid == udid, !isPreparingIPhone else { return }
            iphoneSetupReadiness = readiness
            iphoneSetupReadinessUDID = udid
            iphoneSetupPhase = .idle
        } catch {
            guard iphoneSetupUSBSession?.device.udid == udid, !isPreparingIPhone else { return }
            iphoneSetupReadiness = nil
            iphoneSetupReadinessUDID = nil
            iphoneSetupPhase = .failed(agentErrorMessage(error))
        }
    }

    /// Starts the one-time USB preparation: build and install the agent,
    /// test-launch it, and switch on Wi-Fi connections. Runs until it ends or
    /// `cancelIPhoneSetupPreparation()`, even when the guide is closed.
    func prepareIPhoneAgent(force: Bool = false) {
        guard !isPreparingIPhone else { return }
        guard let session = iphoneSetupUSBSession,
              let udid = session.device.udid, !udid.isEmpty else {
            iphoneSetupPhase = .failed(t("iphone.setup.error.connectUSB"))
            return
        }
        guard !controlXcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            iphoneSetupPhase = .failed(t(IOSAgentError.missingSigningTeam.copyKey))
            return
        }
        thumbnailCaptures[session.id]?.cancel()
        thumbnailCaptures[session.id] = nil
        iphoneSetupPhase = .preparing(.inspecting)
        iphoneSetupPreparingUDID = udid
        statusMessage = t("iphone.setup.preparing")
        let configuration = iosControlConfiguration()
        iphoneSetupTask = Task { @MainActor [weak self] in
            do {
                let result = try await IOSAgentService.prepare(
                    udid: udid,
                    configuration: configuration,
                    force: force
                ) { [weak self] step in
                    await MainActor.run {
                        guard let self, self.isPreparingIPhone, !Task.isCancelled else { return }
                        self.iphoneSetupPhase = .preparing(step)
                    }
                }
                try Task.checkCancellation()
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: Self.wirelessSetupGuideSeenDefaultsKey)
                self.iphoneSetupPhase = .ready(reachableOverWiFi: result.reachableOverWiFi)
                self.statusMessage = self.t("iphone.setup.ready")
                self.iphoneSetupReadiness = try? await IOSAgentService.inspect(udid: udid, configuration: configuration)
                self.iphoneSetupReadinessUDID = udid
            } catch {
                guard let self else { return }
                if error is CancellationError || Task.isCancelled {
                    self.iphoneSetupPhase = .idle
                    self.statusMessage = self.t("iphone.setup.cancelled")
                } else {
                    let message = self.agentErrorMessage(error)
                    self.iphoneSetupPhase = .failed(message)
                    self.statusMessage = message
                }
            }
            self?.iphoneSetupTask = nil
            self?.iphoneSetupPreparingUDID = nil
        }
    }

    func cancelIPhoneSetupPreparation() {
        iphoneSetupTask?.cancel()
    }

    /// The phone the running preparation targets, for the guide to name.
    var iphoneSetupPreparingSession: DeviceSession? {
        guard let udid = iphoneSetupPreparingUDID else { return nil }
        return sessions.first { $0.platform == .iOS && $0.device.udid == udid }
    }

    func finishIPhoneSetupAndDiscover() {
        UserDefaults.standard.set(true, forKey: Self.wirelessSetupGuideSeenDefaultsKey)
        setActiveSheet(nil)
        continueWirelessDiscovery()
    }

    var iphoneSetupUSBSession: DeviceSession? {
        if let selectedSessionID,
           let selected = sessions.first(where: { $0.id == selectedSessionID }),
           selected.platform == .iOS,
           selected.transport == .usb,
           selected.device.connectionState == .connected,
           selected.device.udid?.isEmpty == false {
            return selected
        }
        return sessions.first {
            $0.platform == .iOS
                && $0.transport == .usb
                && $0.device.connectionState == .connected
                && $0.device.udid?.isEmpty == false
        }
    }

    func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestCameraPermission() async {
        guard !isRequestingCameraPermission else { return }
        isRequestingCameraPermission = true
        defer { isRequestingCameraPermission = false }
        let granted = await AVFoundationMirrorBackend.requestVideoAccess()
        updateCameraPermissionStatus(AVFoundationMirrorBackend.videoAuthorizationStatus())
        if granted {
            refresh()
        } else {
            statusMessage = t("status.permissionRequired")
        }
    }

    func recheckCameraPermission() {
        updateCameraPermissionStatus(AVFoundationMirrorBackend.videoAuthorizationStatus())
        if permissionStatus == .authorized {
            refresh()
        } else {
            statusMessage = t("status.permissionRequired")
        }
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestMicrophonePermission() async {
        guard !isRequestingMicrophonePermission else { return }
        isRequestingMicrophonePermission = true
        defer { isRequestingMicrophonePermission = false }
        let granted = await AVFoundationMirrorBackend.requestAudioAccess()
        updateMicrophonePermissionStatus(AVFoundationMirrorBackend.audioAuthorizationStatus())
        if granted {
            audioPlaybackEnabled = true
        }
    }

    func recheckMicrophonePermission() {
        updateMicrophonePermissionStatus(AVFoundationMirrorBackend.audioAuthorizationStatus())
    }

    private func updateCameraPermissionStatus(_ status: AVAuthorizationStatus) {
        guard permissionStatus != status else { return }
        permissionStatus = status
        // Physical iPhone video does not depend on Camera permission. Only
        // the optional USB audio input must be released after revocation.
        applyAudioPlaybackPreference()
        refresh()
    }

    private func updateMicrophonePermissionStatus(_ status: AVAuthorizationStatus) {
        guard microphonePermissionStatus != status else { return }
        microphonePermissionStatus = status
        applyAudioPlaybackPreference()
    }

    private func applyAudioPlaybackPreference() {
        for session in sessions {
            let audioEnabled = session.platform == .android
                ? audioPlaybackEnabled
                : iosAudioPlaybackAllowed
            session.mirrorSession.setAudioEnabled(audioEnabled)
        }
    }

    func enableAudioPlayback() async {
        if hasConnectedIOSDevice, permissionStatus != .authorized {
            await requestCameraPermission()
        }
        if needsIOSAudioPermission {
            await requestMicrophonePermission()
            if microphonePermissionStatus != .authorized {
                let androidCanPlayWithoutMicrophone = connectedSessions.contains {
                    $0.platform == .android
                }
                if !androidCanPlayWithoutMicrophone {
                    audioPlaybackEnabled = false
                    return
                }
            }
        }
        audioPlaybackEnabled = !hasConnectedIOSDevice || permissionStatus == .authorized
            || connectedSessions.contains { $0.platform == .android }
        refresh()
    }

    private var iosAudioPlaybackAllowed: Bool {
        permissionStatus == .authorized && Self.shouldCaptureAudio(
            playbackEnabled: audioPlaybackEnabled,
            authorizationStatus: microphonePermissionStatus
        )
    }

    nonisolated static func shouldDeferUSBForWireless(
        wirelessModeEnabled: Bool,
        usbUDID: String?,
        activeWirelessUDIDs: Set<String>
    ) -> Bool {
        guard wirelessModeEnabled, let usbUDID else { return false }
        return activeWirelessUDIDs.contains(usbUDID)
    }

    nonisolated static func shouldPreserveIOSSessionWhenWirelessDiscoveryFails(
        transport: DeviceTransport,
        platform: DevicePlatform,
        isAndroid: Bool
    ) -> Bool {
        platform == .iOS && !isAndroid && transport == .wireless
    }

    nonisolated static func shouldStartUSBThumbnailCapture(
        liveMirrorDesired: Bool,
        mirrorState: MirrorState,
        controlActive: Bool = false,
        tunnelRunning: Bool = false,
        preparingIPhone: Bool = false,
        isBackgroundProcess: Bool = false
    ) -> Bool {
        if liveMirrorDesired || controlActive || tunnelRunning || preparingIPhone || isBackgroundProcess {
            return false
        }
        switch mirrorState {
        case .starting, .running:
            return false
        case .stopped, .failed:
            return true
        }
    }

    nonisolated static func shouldCaptureAudio(
        playbackEnabled: Bool,
        authorizationStatus: AVAuthorizationStatus
    ) -> Bool {
        IOSUSBAudioRouting.shouldEnableMuxedAudioPorts(
            playbackEnabled: playbackEnabled,
            authorizationStatus: authorizationStatus
        )
    }

    var audioPlaybackToggle: Binding<Bool> {
        Binding(
            get: { self.audioPlaybackEnabled },
            set: { enabled in
                if enabled {
                    Task { await self.enableAudioPlayback() }
                } else {
                    self.audioPlaybackEnabled = false
                }
            }
        )
    }

    func refresh() {
        guard !isShuttingDown else { return }
        guard refreshTask == nil else {
            refreshRequestedWhileRunning = true
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let canDiscoverUSB = audioPlaybackEnabled && permissionStatus == .authorized
            && microphonePermissionStatus == .authorized
        let discoverWireless = wirelessMirroringEnabled
        refreshTask = Task { [weak self] in
            if canDiscoverUSB {
                AVFoundationMirrorBackend.warmUpDiscovery()
            }
            async let metadataTask = Task.detached(priority: .utility) {
                DeviceMetadataService.connectedDevices()
            }.value
            async let wirelessTask = Task.detached(priority: .utility) {
                discoverWireless
                    ? await WirelessDiscoveryService.discover()
                    : WirelessDiscoveryOutcome.available([])
            }.value
            async let androidTask = Task.detached(priority: .utility) {
                AndroidADBService.discoverDevices()
            }.value
            async let simulatorTask = Task.detached(priority: .utility) {
                SimulatorDiscoveryService.discover()
            }.value
            let devices = canDiscoverUSB ? AVFoundationMirrorBackend.discoverMuxedDevices() : []
            let metadata = await metadataTask
            let wirelessDiscovery = await wirelessTask
            let androidDiscovery = await androidTask
            let simulatorDiscovery = await simulatorTask
            guard let self else { return }
            guard self.refreshGeneration == generation else { return }
            guard !Task.isCancelled, !self.isShuttingDown else {
                self.finishRefresh(generation: generation)
                return
            }

            guard self.refreshGeneration == generation, !Task.isCancelled else { return }
            self.applyRefresh(
                devices: devices,
                metadata: metadata,
                wirelessDiscovery: wirelessDiscovery,
                androidDiscovery: androidDiscovery,
                simulatorDiscovery: simulatorDiscovery
            )
            self.finishRefresh(generation: generation)
        }
    }

    func refreshForAutomation() async throws {
        refresh()
        let deadline = ContinuousClock.now + .seconds(15)
        while refreshTask != nil {
            guard ContinuousClock.now < deadline else {
                throw DeviceAutomationError.timedOut("Device refresh timed out.")
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishRefresh(generation: UInt64) {
        guard refreshGeneration == generation else { return }
        refreshTask = nil
        guard refreshRequestedWhileRunning, !isShuttingDown else { return }
        refreshRequestedWhileRunning = false
        refresh()
    }

    private func applyRefresh(
        devices: [AVCaptureDevice],
        metadata: [DeviceMetadata],
        wirelessDiscovery: WirelessDiscoveryOutcome,
        androidDiscovery: AndroidADBService.DiscoveryOutcome,
        simulatorDiscovery: SimulatorDiscoveryService.Outcome
    ) {
        var remaining = sessions
        var nextSessions: [DeviceSession] = []
        var claimedIDs = Set<String>()
        var resumeIDs = Set<String>()
        var autoStartIDs = Set<String>()
        let now = Date()
        for record in metadata {
            WirelessDiscoveryService.IdentityCache.shared.remember(record)
        }
        let listedWirelessUDIDs: Set<String> = {
            guard case let .available(wirelessDevices) = wirelessDiscovery else { return [] }
            return Set(wirelessDevices.map(\.udid))
        }()
        // A plugged-in phone normally switches to USB. It stays on Wi-Fi while a
        // wireless session is in use, as long as that session can keep going.
        let activeWirelessUDIDs: Set<String> = {
            guard wirelessMirroringEnabled else { return [] }
            return Set(sessions.compactMap { session -> String? in
                guard session.isIOSWireless,
                      let udid = session.device.udid, !udid.isEmpty,
                      desiredMirrorIDs.contains(session.id)
                        || session.controlSession.isReady
                        || session.controlSession.isConnecting,
                      listedWirelessUDIDs.contains(udid) || IOSAgentService.hasRunningAgent(udid: udid)
                else { return nil }
                return udid
            })
        }()

        func claim(_ session: DeviceSession) {
            claimedIDs.insert(session.id)
            if let udid = session.device.udid, !udid.isEmpty {
                claimedIDs.insert(udid)
            }
            if let uniqueID = session.captureDevice?.uniqueID {
                claimedIDs.insert(uniqueID)
            }
            if let uniqueID = session.lastUSBCaptureUniqueID {
                claimedIDs.insert(uniqueID)
            }
        }

        for captureDevice in devices {
            let identity = usbIdentity(
                for: captureDevice,
                metadata: metadata,
                captureCount: devices.count,
                remaining: remaining
            )
            // Capture discovery can expose an unrelated or unresolved muxed
            // source. It is only an audio attachment to a known USB phone.
            guard let udid = identity.udid, metadata.contains(where: { $0.udid == udid }) else { continue }
            guard !isRemovedDevice(identity.id) else { continue }
            if Self.shouldDeferUSBForWireless(
                wirelessModeEnabled: wirelessMirroringEnabled,
                usbUDID: identity.udid,
                activeWirelessUDIDs: activeWirelessUDIDs
            ) {
                continue
            }
            guard claimedIDs.insert(identity.id).inserted else { continue }
            if let udid = identity.udid {
                claimedIDs.insert(udid)
            }
            claimedIDs.insert(captureDevice.uniqueID)
            if let udid = identity.udid {
                DeviceMetadataService.CaptureUDIDCache.remember(
                    uniqueID: captureDevice.uniqueID,
                    udid: udid
                )
            }

            if var existing = takeExisting(
                from: &remaining,
                id: identity.id,
                udid: identity.udid,
                captureUniqueID: captureDevice.uniqueID
            ) {
                let previousID = existing.id
                let shouldResume = shouldResumeAfterAdoption(
                    existing,
                    becomingConnected: identity.connectionState == .connected,
                    transport: .usb
                )
                if existing.transport != .usb {
                    cancelWirelessTransport(for: existing)
                    existing.controlSession.disconnect()
                }
                rebaseSession(&existing, to: identity)
                existing.adoptUSB(identity: identity, captureDevice: captureDevice)
                existing.device.connectionState = identity.connectionState
                configureUSBMirrorCallbacks(for: existing.mirrorSession)
                existing.mirrorSession.setAudioEnabled(iosAudioPlaybackAllowed)
                disconnectedSince[existing.id] = nil
                if shouldResume {
                    resumeIDs.insert(existing.id)
                }
                if previousID != existing.id {
                    MirrorWindowRegistry.shared.refreshContent(session: existing, store: self)
                }
                nextSessions.append(existing)
                claim(existing)
            } else {
                let session = DeviceSession(device: identity, captureDevice: captureDevice)
                configureUSBMirrorCallbacks(for: session.mirrorSession)
                session.mirrorSession.setAudioEnabled(iosAudioPlaybackAllowed)
                nextSessions.append(session)
                claim(session)
                if shouldAutoStartMirrors, identity.connectionState == .connected {
                    autoStartIDs.insert(session.id)
                }
            }
        }

        // A USB tunnel only needs the phone's identity. AVFoundation may be
        // unavailable or deliberately unused while sound stays on the phone.
        for record in metadata where !claimedIDs.contains(record.udid) {
            guard !isRemovedDevice(record.udid),
                  !Self.shouldDeferUSBForWireless(
                    wirelessModeEnabled: wirelessMirroringEnabled,
                    usbUDID: record.udid,
                    activeWirelessUDIDs: activeWirelessUDIDs
                  ) else { continue }
            let identity = DeviceIdentity(
                id: record.udid, udid: record.udid, name: record.name,
                productType: record.productType, osVersion: record.osVersion,
                connectionState: .connected, trustState: .trusted
            )
            if var existing = takeExisting(from: &remaining, id: record.udid, udid: record.udid, captureUniqueID: nil) {
                let shouldResume = shouldResumeAfterAdoption(existing, becomingConnected: true, transport: .usb)
                if existing.transport != .usb {
                    cancelWirelessTransport(for: existing)
                    existing.controlSession.disconnect()
                }
                rebaseSession(&existing, to: identity)
                existing.adoptUSB(identity: identity, captureDevice: nil)
                configureUSBMirrorCallbacks(for: existing.mirrorSession)
                existing.mirrorSession.setAudioEnabled(iosAudioPlaybackAllowed)
                disconnectedSince[existing.id] = nil
                if shouldResume { resumeIDs.insert(existing.id) }
                nextSessions.append(existing)
                claim(existing)
            } else {
                let session = DeviceSession(device: identity, captureDevice: nil)
                configureUSBMirrorCallbacks(for: session.mirrorSession)
                session.mirrorSession.setAudioEnabled(iosAudioPlaybackAllowed)
                nextSessions.append(session)
                claim(session)
                if shouldAutoStartMirrors { autoStartIDs.insert(session.id) }
            }
        }

        switch wirelessDiscovery {
        case let .available(wirelessDevices):
            // A plugged-in phone whose capture device could not be tied to a
            // UDID is still that phone: never show it a second time as Wi-Fi.
            let hasUnresolvedUSBCapture = nextSessions.contains {
                $0.platform == .iOS && $0.transport == .usb && $0.device.udid == nil
            }
            for wirelessDevice in wirelessDevices where !claimedIDs.contains(wirelessDevice.udid) {
                guard !isRemovedDevice(wirelessDevice.udid) else { continue }
                guard !(wirelessDevice.isAlsoOnUSB && hasUnresolvedUSBCapture) else { continue }
                let matchingSession = remaining.first {
                    $0.matchesDiscovery(
                        id: wirelessDevice.udid,
                        udid: wirelessDevice.udid,
                        captureUniqueID: nil
                    )
                }
                // usbmuxd lists the phone on the network, which is the path the
                // tunnel takes: it is connectable now, before any session starts.
                let knownIdentity = wirelessDevice.hasIdentity ? nil : matchingSession?.device
                let identity = DeviceIdentity(
                    id: wirelessDevice.udid,
                    udid: wirelessDevice.udid,
                    name: knownIdentity?.name ?? wirelessDevice.name,
                    productType: knownIdentity?.productType ?? wirelessDevice.productType,
                    osVersion: knownIdentity?.osVersion ?? wirelessDevice.osVersion,
                    connectionState: .connected,
                    trustState: .trusted
                )
                guard claimedIDs.insert(identity.id).inserted else { continue }

                if var existing = takeExisting(
                    from: &remaining,
                    id: identity.id,
                    udid: identity.udid,
                    captureUniqueID: nil
                ) ?? takeAmbiguousIOSSession(
                    from: &remaining,
                    wirelessCount: wirelessDevices.count
                ) {
                    let shouldResume = shouldResumeAfterAdoption(
                        existing,
                        becomingConnected: identity.connectionState == .connected,
                        transport: .wireless
                    )
                    if existing.transport != .wireless {
                        cancelWirelessTransport(for: existing)
                        existing.controlSession.disconnect()
                    }
                    rebaseSession(&existing, to: identity)
                    existing.adoptWireless(identity: identity, wirelessDevice: wirelessDevice)
                    disconnectedSince[existing.id] = nil
                    if shouldResume {
                        resumeIDs.insert(existing.id)
                    }
                    MirrorWindowRegistry.shared.refreshContent(session: existing, store: self)
                    nextSessions.append(existing)
                    claim(existing)
                } else {
                    let session = DeviceSession(device: identity, wirelessDevice: wirelessDevice)
                    nextSessions.append(session)
                    claim(session)
                    if shouldAutoStartMirrors, identity.connectionState == .connected {
                        autoStartIDs.insert(session.id)
                    }
                }
            }
        case .unavailable:
            // A failed usbmuxd poll is unknown, not "every wireless iPhone vanished".
            // USB sessions still follow the regular disconnect path.
            remaining.removeAll { session in
                guard Self.shouldPreserveIOSSessionWhenWirelessDiscoveryFails(
                    transport: session.transport,
                    platform: session.platform,
                    isAndroid: session.androidDevice != nil
                ) else { return false }
                guard !claimedIDs.contains(session.id) else { return false }
                nextSessions.append(session)
                claim(session)
                return true
            }
        }

        switch androidDiscovery {
        case let .available(androidDevices):
            for androidDevice in androidDevices {
                let identity = androidDevice.identity
                guard !isRemovedDevice(identity.id) else { continue }
                guard claimedIDs.insert(identity.id).inserted else { continue }

                if var existing = takeExisting(
                    from: &remaining,
                    id: identity.id,
                    udid: identity.udid,
                    captureUniqueID: nil
                ), existing.platform == .android {
                    let shouldResume = shouldResumeAfterAdoption(
                        existing,
                        becomingConnected: identity.connectionState == .connected,
                        transport: existing.transport
                    )
                    existing.device = identity
                    disconnectedSince[existing.id] = nil
                    existing.mirrorSession.setAudioEnabled(audioPlaybackEnabled)
                    if shouldResume {
                        resumeIDs.insert(existing.id)
                    }
                    nextSessions.append(existing)
                } else {
                    if let stale = takeExisting(
                        from: &remaining,
                        id: identity.id,
                        udid: identity.udid,
                        captureUniqueID: nil
                    ) {
                        retire(stale)
                    }
                    let session = DeviceSession(device: identity, androidDevice: androidDevice)
                    session.mirrorSession.setAudioEnabled(audioPlaybackEnabled)
                    nextSessions.append(session)
                    if shouldAutoStartMirrors, identity.connectionState == .connected {
                        autoStartIDs.insert(session.id)
                    }
                }
            }
        case .unavailable:
            remaining.removeAll { session in
                guard session.platform == .android else { return false }
                guard !claimedIDs.contains(session.id) else { return false }
                nextSessions.append(session)
                claim(session)
                return true
            }
        }

        switch simulatorDiscovery {
        case let .available(simulators):
            for simulator in simulators {
                let identity = simulator.identity
                guard !isRemovedDevice(identity.id) else { continue }
                guard claimedIDs.insert(identity.id).inserted else { continue }
                claimedIDs.insert(simulator.udid)

                if var existing = takeExisting(
                    from: &remaining,
                    id: identity.id,
                    udid: identity.udid,
                    captureUniqueID: nil
                ), existing.isIOSSimulator {
                    let shouldResume = shouldResumeAfterAdoption(
                        existing,
                        becomingConnected: true,
                        transport: .simulator
                    )
                    existing.device = identity
                    existing.controlSession.updateDevice(identity)
                    disconnectedSince[existing.id] = nil
                    if shouldResume {
                        resumeIDs.insert(existing.id)
                    }
                    nextSessions.append(existing)
                } else {
                    // Not auto-started: mirroring launches an XCTest runner
                    // into the simulator, which would collide with the
                    // developer's own UI-test runs there.
                    nextSessions.append(DeviceSession(device: identity, simulator: simulator))
                }
            }
            // A simulator that was shut down takes its runner with it.
            let booted = Set(simulators.map(\.udid))
            Task { await SimulatorAgentService.shared.retain(only: booted) }
        case .unavailable:
            remaining.removeAll { session in
                guard session.isIOSSimulator, !claimedIDs.contains(session.id) else { return false }
                nextSessions.append(session)
                claim(session)
                return true
            }
        }

        for staleSession in remaining where !claimedIDs.contains(staleSession.id) {
            // Device discovery can miss a phone for one poll while its
            // tunnel is still carrying video and control. The tunnel is
            // the authority: it ends on its own when the phone is really gone.
            if Self.shouldKeepLiveWirelessSession(
                isIOSWireless: staleSession.usesIOSAgentVideo,
                connectionState: staleSession.device.connectionState,
                tunnelRunning: staleSession.device.udid.map(IOSAgentService.hasRunningAgent(udid:)) ?? false
            ) {
                nextSessions.append(staleSession)
                claim(staleSession)
                continue
            }
            thumbnailCaptures[staleSession.id]?.cancel()
            thumbnailCaptures[staleSession.id] = nil

            let disappearedAt = disconnectedSince[staleSession.id] ?? now
            if Self.shouldKeepDisconnectedSession(
                previouslyConnected: staleSession.device.connectionState != .disconnected,
                disconnectedAt: disappearedAt,
                now: now,
                retention: Self.reconnectRetentionInterval
            ) {
                var disconnectedSession = staleSession
                if disconnectedSession.device.connectionState != .disconnected {
                    disconnectedSession.device.connectionState = .disconnected
                    disconnectedSession.mirrorSession.stop()
                }
                disconnectedSince[staleSession.id] = disappearedAt
                nextSessions.append(disconnectedSession)
            } else {
                retire(staleSession)
            }
        }

        let retainedDisconnectedIDs = Set(
            nextSessions
                .filter { $0.device.connectionState == .disconnected }
                .sorted {
                    (disconnectedSince[$0.id] ?? .distantPast) > (disconnectedSince[$1.id] ?? .distantPast)
                }
                .prefix(Self.maxRetainedDisconnectedSessions)
                .map(\.id)
        )
        nextSessions.removeAll { session in
            guard session.device.connectionState == .disconnected,
                  !retainedDisconnectedIDs.contains(session.id) else {
                return false
            }
            retire(session)
            return true
        }

        sessions = nextSessions.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
        requestMirrorStarts(autoStartIDs.union(resumeIDs), presentActivationWhenBlocked: false)
        reconcileUSBCaptureHolds()
        for session in connectedSessions where shouldResumeControl(for: session) {
            connectControl(for: session)
        }
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = sessions.first?.id
        } else if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }
        lastRefresh = Date()
        lastConnectedCount = connectedSessions.count
        lastReconnectingCount = reconnectingSessions.count
        statusMessage = localizedStatusMessage

        for session in connectedSessions
            where thumbnails[session.id] == nil
            && thumbnailCaptures[session.id] == nil
            && thumbnailErrors[session.id] == nil {
            captureThumbnail(for: session)
        }
    }

    private func usbIdentity(
        for captureDevice: AVCaptureDevice,
        metadata: [DeviceMetadata],
        captureCount: Int,
        remaining: [DeviceSession]
    ) -> DeviceIdentity {
        let match = DeviceMetadataService.bestMatch(
            for: captureDevice.localizedName,
            modelID: captureDevice.modelID,
            candidates: metadata
        ) ?? AVFoundationMirrorBackend.preferSoleMetadataMatch(
            captureCount: captureCount,
            metadata: metadata
        )
        let existing = remaining.first {
            $0.matchesDiscovery(
                id: match?.udid ?? captureDevice.uniqueID,
                udid: match?.udid,
                captureUniqueID: captureDevice.uniqueID
            )
        }
        return AVFoundationMirrorBackend.identity(
            for: captureDevice,
            metadata: match,
            cachedUDID: DeviceMetadataService.CaptureUDIDCache.udid(for: captureDevice.uniqueID),
            existingUDID: existing?.device.udid
        )
    }

    nonisolated static func shouldResumeAfterAdoption(
        wanted: Bool,
        previousConnectionState: DeviceConnectionState,
        previousTransport: DeviceTransport,
        newTransport: DeviceTransport,
        mirrorState: MirrorState,
        captureDeviceChanged: Bool = false
    ) -> Bool {
        guard wanted else { return false }
        if previousConnectionState != .connected || previousTransport != newTransport || captureDeviceChanged {
            return true
        }
        switch mirrorState {
        case .stopped:
            return true
        case .starting, .running, .failed:
            return false
        }
    }

    private func shouldResumeAfterAdoption(
        _ existing: DeviceSession,
        becomingConnected: Bool,
        transport: DeviceTransport,
        captureDeviceChanged: Bool = false
    ) -> Bool {
        guard becomingConnected else { return false }
        let wanted = desiredMirrorIDs.contains(existing.id)
            || (existing.device.udid.map { desiredMirrorIDs.contains($0) } ?? false)
        return Self.shouldResumeAfterAdoption(
            wanted: wanted,
            previousConnectionState: existing.device.connectionState,
            previousTransport: existing.transport,
            newTransport: transport,
            mirrorState: existing.mirrorSession.state,
            captureDeviceChanged: captureDeviceChanged
        )
    }

    nonisolated static func shouldResumeControl(
        wanted: Bool,
        connectionState: DeviceConnectionState,
        controlState: ControlState
    ) -> Bool {
        guard wanted, connectionState == .connected else { return false }
        switch controlState {
        case .unavailable, .failed:
            return true
        case .connecting, .ready:
            return false
        }
    }

    private func shouldResumeControl(for session: DeviceSession) -> Bool {
        let wanted = desiredControlIDs.contains(session.id)
            || (session.device.udid.map { desiredControlIDs.contains($0) } ?? false)
        return Self.shouldResumeControl(
            wanted: wanted,
            connectionState: session.device.connectionState,
            controlState: session.controlSession.state
        )
    }

    nonisolated static func shouldHoldUSBCapture(
        platform: DevicePlatform,
        transport: DeviceTransport,
        connectionState: DeviceConnectionState,
        controlWanted: Bool
    ) -> Bool {
        platform == .iOS && transport == .usb && connectionState == .connected && controlWanted
    }

    /// Only a legacy AVFoundation video source can request a capture hold.
    /// SRT and HID never open a media graph just to keep USB control alive.
    private func reconcileUSBCaptureHolds() {
        guard !isShuttingDown else { return }
        for session in sessions {
            let wanted = desiredControlIDs.contains(session.id)
                || (session.device.udid.map { desiredControlIDs.contains($0) } ?? false)
            session.mirrorSession.setUSBCaptureHold(session.videoSource == .avFoundation && Self.shouldHoldUSBCapture(
                platform: session.platform,
                transport: session.transport,
                connectionState: session.device.connectionState,
                controlWanted: wanted
            ))
        }
    }

    private func configureUSBMirrorCallbacks(for mirrorSession: MirrorCaptureSession) {
        mirrorSession.onAudioPlaybackFailure = { [weak self] message in
            self?.statusMessage = message
        }
        mirrorSession.onUSBCaptureInterrupted = { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.refresh()
            self.scheduleDiscoveryRetries()
        }
        mirrorSession.onUSBFrameAvailable = { [weak self, weak mirrorSession] in
            guard let self, !self.isShuttingDown,
                  let mirrorSession,
                  let current = self.session(owning: mirrorSession) else { return }
            if self.thumbnails[current.id] == nil {
                self.applyLiveUSBThumbnail(from: current)
            }
        }
    }

    private func takeExisting(
        from remaining: inout [DeviceSession],
        id: String,
        udid: String?,
        captureUniqueID: String?
    ) -> DeviceSession? {
        let indexes = remaining.indices.filter { index in
            remaining[index].matchesDiscovery(id: id, udid: udid, captureUniqueID: captureUniqueID)
        }
        guard !indexes.isEmpty else { return nil }
        let matches = indexes.map { remaining[$0] }
        var chosen = matches.max { lhs, rhs in
            DeviceSession.reusePreferenceScore(lhs) < DeviceSession.reusePreferenceScore(rhs)
        } ?? matches[0]
        for index in indexes.sorted(by: >) {
            remaining.remove(at: index)
        }
        for extra in matches where extra.id != chosen.id {
            migrateSessionID(from: extra.id, to: chosen.id)
            extra.mirrorSession.stop()
            extra.mirrorSession.dispose()
            if chosen.iosAgent == nil, extra.iosAgent != nil {
                chosen.iosAgent = extra.iosAgent
            } else {
                extra.iosAgent?.stop()
            }
            if extra.controlSession !== chosen.controlSession {
                extra.controlSession.disconnect()
            }
        }
        return chosen
    }

    private func takeAmbiguousIOSSession(
        from remaining: inout [DeviceSession],
        wirelessCount: Int
    ) -> DeviceSession? {
        guard wirelessCount == 1 else { return nil }
        let indexes = remaining.indices.filter { index in
            remaining[index].platform == .iOS
                && remaining[index].androidDevice == nil
                && remaining[index].device.udid == nil
        }
        guard indexes.count == 1, let index = indexes.first else { return nil }
        return remaining.remove(at: index)
    }

    private func rebaseSession(_ session: inout DeviceSession, to identity: DeviceIdentity) {
        let oldID = session.id
        session.device = identity
        session.controlSession.updateDevice(identity)
        guard oldID != identity.id else { return }
        session.id = identity.id
        migrateSessionID(from: oldID, to: identity.id)
        MirrorWindowRegistry.shared.refreshContent(session: session, store: self)
    }

    private func migrateSessionID(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        if desiredMirrorIDs.remove(oldID) != nil { desiredMirrorIDs.insert(newID) }
        if desiredControlIDs.remove(oldID) != nil { desiredControlIDs.insert(newID) }
        if embeddedPreviewIDs.remove(oldID) != nil { embeddedPreviewIDs.insert(newID) }
        if pendingActivationMirrorIDs.remove(oldID) != nil { pendingActivationMirrorIDs.insert(newID) }
        if floatingMirrorIDs.remove(oldID) != nil { floatingMirrorIDs.insert(newID) }
        if removedDeviceIDs.remove(oldID) != nil { removedDeviceIDs.insert(newID) }
        if selectedSessionID == oldID { selectedSessionID = newID }
        if let since = disconnectedSince.removeValue(forKey: oldID) {
            disconnectedSince[newID] = since
        }
        if let capture = thumbnailCaptures.removeValue(forKey: oldID) {
            thumbnailCaptures[newID] = capture
        }
        if let task = wirelessThumbnailTasks.removeValue(forKey: oldID) {
            wirelessThumbnailTasks[newID] = task
        }
        if let image = thumbnails.removeValue(forKey: oldID) {
            thumbnails[newID] = image
        }
        if let ratio = thumbnailAspectRatios.removeValue(forKey: oldID) {
            thumbnailAspectRatios[newID] = ratio
        }
        if let error = thumbnailErrors.removeValue(forKey: oldID) {
            thumbnailErrors[newID] = error
        }
        MirrorWindowRegistry.shared.rekey(from: oldID, to: newID)
    }

    nonisolated static func shouldKeepDisconnectedSession(
        previouslyConnected: Bool,
        disconnectedAt: Date,
        now: Date,
        retention: TimeInterval
    ) -> Bool {
        previouslyConnected || now.timeIntervalSince(disconnectedAt) < retention
    }

    private func clearThumbnail(for sessionID: String) {
        thumbnails[sessionID] = nil
        thumbnailAspectRatios[sessionID] = nil
        thumbnailErrors[sessionID] = nil
    }

    static func canReuseWirelessSession(
        _ existing: DeviceSession,
        for discovered: WirelessDeviceMetadata
    ) -> Bool {
        existing.transport == .wireless && existing.device.udid == discovered.udid
    }

    nonisolated static func shouldKeepLiveWirelessSession(
        isIOSWireless: Bool,
        connectionState: DeviceConnectionState,
        tunnelRunning: Bool
    ) -> Bool {
        isIOSWireless && connectionState == .connected && tunnelRunning
    }

    private func retire(_ session: DeviceSession) {
        desiredMirrorIDs.remove(session.id)
        desiredControlIDs.remove(session.id)
        if let udid = session.device.udid {
            desiredControlIDs.remove(udid)
        }
        pendingActivationMirrorIDs.remove(session.id)
        floatingMirrorIDs.remove(session.id)
        thumbnailCaptures[session.id]?.cancel()
        thumbnailCaptures[session.id] = nil
        wirelessThumbnailTasks[session.id]?.cancel()
        wirelessThumbnailTasks[session.id] = nil
        cancelWirelessTransport(for: session)
        clearThumbnail(for: session.id)
        disconnectedSince[session.id] = nil
        MirrorWindowRegistry.shared.close(session: session)
        session.mirrorSession.dispose()
        session.iosAgent?.stop()
        session.controlSession.disconnect()
        if session.isIOSSimulator, let udid = session.device.udid {
            Task { await SimulatorAgentService.shared.stop(udid: udid) }
        }
    }

    func removeDevice(_ session: DeviceSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        removedDeviceIDs.insert(session.id)
        retire(session)
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
        statusMessage = String(format: t("status.deviceRemoved"), session.device.name)
    }

    private func isRemovedDevice(_ id: String) -> Bool {
        removedDeviceIDs.contains(id)
    }

    private func beginConnectionAttemptIfNeeded(for requested: DeviceSession) -> DeviceSession? {
        guard let index = sessions.firstIndex(where: { $0.id == requested.id }),
              canAttemptConnection(sessions[index]) else { return nil }
        return sessions[index]
    }

    func start(_ session: DeviceSession) {
        guard let session = beginConnectionAttemptIfNeeded(for: session),
              !session.needsCameraPermission
                  || permissionStatus == .authorized else { return }
        select(session)
        requestMirrorStarts([session.id], showWindow: true)
    }

    func startAll() {
        requestMirrorStarts(Set(connectedSessions.map(\.id)), showWindow: true)
    }

    func presentActivation() {
        showActivation(for: [])
    }

    func presentSettings() {
        settingsTab = .general
        setActiveSheet(.settings)
    }

    func presentMCPSettings() {
        settingsTab = .mcp
        setActiveSheet(.settings)
    }

    func presentDiagnostics() {
        setActiveSheet(.diagnostics)
    }

    func toggleSettings() {
        settingsTab = .general
        setActiveSheet(DashboardSheet.toggling(.settings, from: activeSheet))
    }

    func toggleDiagnostics() {
        setActiveSheet(DashboardSheet.toggling(.diagnostics, from: activeSheet))
    }

    func setActiveSheet(_ sheet: DashboardSheet?) {
        if activeSheet == .activation, sheet != .activation {
            pendingActivationMirrorIDs.removeAll()
        }
        activeSheet = sheet
    }

    func cancelActivation() {
        setActiveSheet(nil)
    }

    func activateLicense(code: String) async throws {
        try await licenseManager.activate(code: code)
        finishSuccessfulLicenseChange()
    }

    func redeemLicense(code: String) async throws {
        try await licenseManager.redeem(code: code)
        finishSuccessfulLicenseChange()
    }

    func claimLicense() async throws {
        try await licenseManager.claimFromReceipt()
        finishSuccessfulLicenseChange()
    }

    func signInLicense(provider: LicenseAuthProvider) async throws {
        try await licenseManager.signIn(provider: provider)
    }

    func signInLicense(email: String, password: String) async throws {
        try await licenseManager.signIn(email: email, password: password)
    }

    func signOutLicense() async {
        await licenseManager.signOut()
    }

    private func finishSuccessfulLicenseChange() {
        let pending = pendingActivationMirrorIDs
        pendingActivationMirrorIDs.removeAll()
        setActiveSheet(nil)
        requestMirrorStarts(pending)
    }

    func stop(_ session: DeviceSession) {
        desiredMirrorIDs.remove(session.id)
        embeddedPreviewIDs.remove(session.id)
        pendingActivationMirrorIDs.remove(session.id)
        cancelWirelessTransport(for: session)
        MirrorWindowRegistry.shared.close(session: session)
    }

    func stopAll() {
        desiredMirrorIDs.removeAll()
        desiredControlIDs.removeAll()
        embeddedPreviewIDs.removeAll()
        pendingActivationMirrorIDs.removeAll()
        dismissActivationSheetIfPresented()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for session in sessions {
            cancelWirelessTransport(for: session)
            session.controlSession.disconnect()
        }
    }

    // Full teardown for app termination. Control sessions are deleted before
    // the Appium server is stopped, and AppKit waits for this method to finish.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        // Stop accepting automation first. In-flight MCP calls are allowed to
        // finish or are cancelled before the underlying WDA/Appium sessions.
        await mcpServer.shutdown()
        await automationService.shutdownPreview()
        await automationService.finishAllRecordings()
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileRunning = false
        pendingActivationMirrorIDs.removeAll()
        setActiveSheet(nil)
        licenseManager.checkpointTrustedTime()
        licenseManager.cancel()
        refreshTimer?.invalidate()
        refreshTimer = nil
        discoveryRetryTask?.cancel()
        discoveryRetryTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        desiredMirrorIDs.removeAll()
        desiredControlIDs.removeAll()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for capture in thumbnailCaptures.values {
            capture.cancel()
        }
        thumbnailCaptures.removeAll()
        for task in wirelessThumbnailTasks.values {
            task.cancel()
        }
        wirelessThumbnailTasks.removeAll()
        for entry in wirelessTransportTasks.values {
            entry.task.cancel()
        }
        wirelessTransportTasks.removeAll()
        thumbnails.removeAll()
        thumbnailAspectRatios.removeAll()
        thumbnailErrors.removeAll()

        iphoneSetupTask?.cancel()
        iphoneSetupTask = nil
        let activeSessions = sessions
        for session in activeSessions {
            session.mirrorSession.dispose()
            session.iosAgent?.stop()
        }
        // The control sessions close their WebDriverAgent sessions before the
        // tunnels they ride on go away.
        for session in activeSessions {
            await session.controlSession.shutdown()
        }
        // App shutdown is the one place the shared runner must actually be
        // terminated, so the agent does not keep running after the app exits.
        // The setup guide starts one over USB too, so this is not limited to
        // wireless sessions; it does nothing for a device without a runner.
        let udids = Set(activeSessions.compactMap { session -> String? in
            guard session.platform == .iOS, let udid = session.device.udid, !udid.isEmpty else { return nil }
            return udid
        })
        await withTaskGroup(of: Void.self) { group in
            for udid in udids {
                group.addTask { await IOSAgentService.terminateSharedAgent(udid: udid) }
            }
            group.addTask { await SimulatorAgentService.shared.stopAll() }
        }
        await appiumService.shutdown()

        sessions.removeAll()
        disconnectedSince.removeAll()
        floatingMirrorIDs.removeAll()
        selectedSessionID = nil
    }

    @discardableResult
    private func requestMirrorStarts(
        _ sessionIDs: Set<String>,
        presentActivationWhenBlocked: Bool = true,
        showWindow: Bool? = nil
    ) -> MirrorStartPolicyDecision {
        guard !isShuttingDown, !sessionIDs.isEmpty else {
            return MirrorStartPolicyDecision(allowedIDs: [], blockedIDs: [])
        }

        let requestedIDs = connectedSessions
            .filter { sessionIDs.contains($0.id) }
            .map(\.id)
        let activeIDs = Set(sessions.compactMap { session -> String? in
            if desiredMirrorIDs.contains(session.id) { return session.id }
            switch session.mirrorSession.state {
            case .starting, .running: return session.id
            case .stopped, .failed: return nil
            }
        })
        let decision = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: licenseManager.state.capabilities,
            activeIDs: activeIDs,
            requestedIDs: requestedIDs,
            preferredID: selectedSessionID
        )
        if let showWindow {
            if showWindow { embeddedPreviewIDs.subtract(decision.allowedIDs) }
            else { embeddedPreviewIDs.formUnion(decision.allowedIDs) }
        }
        performAuthorizedStarts(decision.allowedIDs, activateExistingWindow: showWindow ?? false)
        if !decision.blockedIDs.isEmpty {
            pendingActivationMirrorIDs.formUnion(decision.blockedIDs)
            statusMessage = t("status.activationDeviceLimit")
            if presentActivationWhenBlocked {
                showActivation(for: decision.blockedIDs)
            }
        }
        return decision
    }

    private func performAuthorizedStarts(_ sessionIDs: Set<String>, activateExistingWindow: Bool = true) {
        guard !isShuttingDown else { return }
        for sessionID in sessionIDs {
            guard let requested = sessions.first(where: { $0.id == sessionID }),
                  let session = beginConnectionAttemptIfNeeded(for: requested) else { continue }
            guard !session.needsCameraPermission
                    || permissionStatus == .authorized else { continue }
            desiredMirrorIDs.insert(session.id)
            thumbnailCaptures[session.id]?.cancel()
            thumbnailCaptures[session.id] = nil
            prepareWirelessTransportIfNeeded(for: session)
            if embeddedPreviewIDs.contains(session.id)
                || (!activateExistingWindow && MirrorWindowRegistry.shared.hasWindow(for: session.id)) {
                session.mirrorSession.start()
            } else {
                MirrorWindowRegistry.shared.openAuthorized(session: session, store: self)
            }
        }
    }

    private func enforceSimultaneousDeviceLimit(_ capabilities: LicenseCapabilities) {
        guard let limit = capabilities.maximumSimultaneousDevices else { return }
        let activeSessions = sessions.filter { session in
            if desiredMirrorIDs.contains(session.id) { return true }
            switch session.mirrorSession.state {
            case .starting, .running: return true
            case .stopped, .failed: return false
            }
        }
        guard activeSessions.count > limit else { return }

        let preferred = activeSessions.first { $0.id == selectedSessionID }
            ?? activeSessions.first
        let retainedIDs = Set([preferred].compactMap { $0?.id }.prefix(limit))
        for session in activeSessions where !retainedIDs.contains(session.id) {
            desiredMirrorIDs.remove(session.id)
            pendingActivationMirrorIDs.insert(session.id)
            MirrorWindowRegistry.shared.close(session: session)
        }
        statusMessage = t("status.activationDeviceLimit")
    }

    /// The session that currently owns a mirror. A session's ID can change
    /// while its mirror keeps running (a plugged-in phone first known by its
    /// capture device, later by its UDID), so long-running work follows the
    /// mirror object instead of an ID captured when it started.
    private func session(owning mirrorSession: MirrorCaptureSession) -> DeviceSession? {
        sessions.first { $0.mirrorSession === mirrorSession }
    }

    private func cancelWirelessTransport(for session: DeviceSession) {
        let key = ObjectIdentifier(session.mirrorSession)
        wirelessTransportTasks[key]?.task.cancel()
        wirelessTransportTasks[key] = nil
    }

    private func prepareWirelessTransportIfNeeded(for session: DeviceSession) {
        let mirrorSession = session.mirrorSession
        let key = ObjectIdentifier(mirrorSession)
        guard desiredMirrorIDs.contains(session.id),
              session.usesIOSAgentVideo,
              wirelessTransportTasks[key] == nil,
              let udid = session.device.udid, !udid.isEmpty,
              let iosAgent = session.iosAgent else { return }
        let physicalTransport = session.transport
        let transport: DeviceTunnelTransport = physicalTransport == .usb ? .usb : .network

        mirrorSession.onWirelessEndpointNeedsRefresh = { [weak self, weak mirrorSession] in
            guard let self, let mirrorSession,
                  let current = self.session(owning: mirrorSession) else {
                return
            }
            self.prepareWirelessTransportIfNeeded(for: current)
        }
        let token = UUID()
        let task = Task { @MainActor [weak self, weak iosAgent, weak mirrorSession] in
            await Task.yield()
            guard let self, let iosAgent, let mirrorSession, !self.isShuttingDown else { return }
            defer {
                // Only this task's own entry: a newer one may have replaced it.
                if self.wirelessTransportTasks[key]?.token == token {
                    self.wirelessTransportTasks[key] = nil
                }
            }
            let stillWanted: @MainActor @Sendable () -> Bool = {
                guard !Task.isCancelled, !self.isShuttingDown,
                      self.wirelessTransportTasks[key]?.token == token,
                      let current = self.session(owning: mirrorSession) else { return false }
                return self.desiredMirrorIDs.contains(current.id)
                    && current.usesIOSAgentVideo && current.device.udid == udid
                    && current.transport == physicalTransport
            }

            await self.detectSigningTeams()
            guard stillWanted() else { return }
            do {
                var resolvedEndpoint: IOSAgentEndpoint?
                var lastError: Error?
                for attempt in 0..<3 {
                    do {
                        resolvedEndpoint = try await iosAgent.ensureRunning(
                            udid: udid,
                            transport: transport,
                            configuration: self.iosControlConfiguration(),
                            progress: { [weak self] progress in
                                await MainActor.run {
                                    guard let self, stillWanted() else { return }
                                    let key = switch progress {
                                    case .checkingExistingAgent: "agent.start.checkingAgent"
                                    case .checkingDevice: "agent.start.checkingDevice"
                                    case .launchingAgent: "agent.start.launchingAgent"
                                    case .waitingForDevice: "agent.start.waitingForDevice"
                                    case .connectingVideo: "agent.start.connectingVideo"
                                    }
                                    let message = self.t(key)
                                    self.statusMessage = message
                                    mirrorSession.updateWirelessStartupDetail(message)
                                }
                            }
                        )
                        break
                    } catch {
                        lastError = error
                        guard attempt < 2,
                              self.shouldRetryAgentStart(error),
                              stillWanted() else {
                            throw error
                        }
                        let message = self.t("agent.start.retryingAgent")
                        self.statusMessage = message
                        mirrorSession.updateWirelessStartupDetail(message)
                        try await Task.sleep(for: .seconds(attempt + 1))
                    }
                }
                guard let resolvedEndpoint else {
                    throw lastError ?? IOSAgentError.launchFailed
                }
                guard stillWanted() else { return }
                guard resolvedEndpoint.transport == transport else {
                    throw IOSAgentError.deviceUnavailable
                }
                mirrorSession.connectWirelessVideo(
                    host: resolvedEndpoint.videoHost,
                    port: resolvedEndpoint.videoPort
                )
            } catch is CancellationError {
                return
            } catch {
                guard stillWanted() else { return }
                // A failed start says nothing about reachability: the phone
                // stays connected and the mirror shows why it did not start.
                let current = self.session(owning: mirrorSession)
                if let current {
                    self.desiredMirrorIDs.remove(current.id)
                }
                let localizedMessage = self.agentErrorMessage(error)
                mirrorSession.failWirelessStart(localizedMessage)
                self.statusMessage = localizedMessage
                if let current,
                   let agentError = error as? IOSAgentError,
                   agentError == .setupRequired || agentError == .developerModeDisabled {
                    self.presentIPhoneSetup(for: current)
                }
            }
        }
        wirelessTransportTasks[key] = (token, task)
    }

    private func shouldRetryAgentStart(_ error: Error) -> Bool {
        guard let agentError = error as? IOSAgentError else { return true }
        switch agentError {
        case .deviceUnavailable, .launchFailed, .timedOut:
            return true
        case .missingSigningTeam, .missingRuntime, .setupRequired, .buildFailed,
             .deviceLocked, .developerModeDisabled, .wifiConnectionsUnavailable, .developerImageMissing,
             .automationNotApproved:
            // These name a missing precondition, not a flaky attempt.
            return false
        }
    }

    private func agentErrorMessage(_ error: Error) -> String {
        guard let agentError = error as? IOSAgentError else {
            return error.localizedDescription
        }
        return t(agentError.copyKey)
    }

    private func showActivation(for sessionIDs: Set<String>) {
        pendingActivationMirrorIDs.formUnion(sessionIDs)
        DashboardWindowRegistry.shared.open(store: self)
        guard !isShuttingDown else { return }
        setActiveSheet(.activation)
    }

    private func dismissActivationSheetIfPresented() {
        pendingActivationMirrorIDs.removeAll()
        if activeSheet == .activation {
            activeSheet = nil
        }
    }

    func toggleFloating(for session: DeviceSession) {
        if floatingMirrorIDs.contains(session.id) {
            floatingMirrorIDs.remove(session.id)
        } else {
            floatingMirrorIDs.insert(session.id)
        }
        MirrorWindowRegistry.shared.setFloating(floatingMirrorIDs.contains(session.id), for: session)
    }

    func isFloating(_ session: DeviceSession) -> Bool {
        floatingMirrorIDs.contains(session.id)
    }

    /// Opens whatever can fix a failed control connection: the iPhone setup
    /// guide when the phone itself still needs preparing, diagnostics otherwise.
    private func presentControlRecovery(for session: DeviceSession, message: String) {
        if session.isIOSSimulator { return }
        if session.platform == .android {
            presentDiagnostics()
            return
        }
        let setupKeys: Set<String> = [
            IOSAgentError.setupRequired.copyKey,
            IOSAgentError.developerModeDisabled.copyKey,
            IOSAgentError.missingSigningTeam.copyKey,
            IOSAgentError.buildFailed.copyKey
        ]
        if setupKeys.contains(message) {
            presentIPhoneSetup(for: session)
        }
    }

    nonisolated static func shouldRetryControlConnection(_ error: Error) -> Bool {
        if let agentError = error as? IOSAgentError {
            switch agentError {
            case .deviceUnavailable, .launchFailed, .timedOut:
                return true
            case .missingSigningTeam, .missingRuntime, .setupRequired, .buildFailed,
                 .deviceLocked, .developerModeDisabled, .wifiConnectionsUnavailable, .developerImageMissing,
                 .automationNotApproved:
                return false
            }
        }
        return DeviceControlSession.isSessionLoss(error)
    }

    nonisolated static func shouldKeepDesiredControlAfterFailure(messageKey: String) -> Bool {
        let nonRetryableKeys: Set<String> = [
            IOSAgentError.missingSigningTeam.copyKey,
            IOSAgentError.missingRuntime.copyKey,
            IOSAgentError.setupRequired.copyKey,
            IOSAgentError.buildFailed.copyKey,
            IOSAgentError.deviceLocked.copyKey,
            IOSAgentError.developerModeDisabled.copyKey,
            IOSAgentError.wifiConnectionsUnavailable.copyKey,
            IOSAgentError.developerImageMissing.copyKey,
            IOSAgentError.automationNotApproved.copyKey,
            "control.error.unlockDevice",
            "control.error.developerMode",
            "control.error.uiAutomation",
            "control.error.trustDevice",
            "control.error.signing",
            "control.error.appiumUnavailable"
        ]
        return !nonRetryableKeys.contains(messageKey)
    }

    func connectControl(for session: DeviceSession) {
        if session.controlSession.touchIsUncertain {
            Task { @MainActor [weak self] in
                await session.controlSession.shutdown()
                self?.connectControl(for: session)
            }
            return
        }
        guard !isShuttingDown,
              let session = beginConnectionAttemptIfNeeded(for: session) else { return }
        guard canStartControl(for: session) else {
            statusMessage = t("status.activationControlRequired")
            showActivation(for: [])
            return
        }
        guard let udid = session.device.udid, !udid.isEmpty else {
            statusMessage = t("status.controlNoUDID")
            return
        }
        guard !session.controlSession.isReady, !session.controlSession.isConnecting else { return }
        desiredControlIDs.insert(session.id)
        thumbnailCaptures[session.id]?.cancel()
        thumbnailCaptures[session.id] = nil
        statusMessage = t("status.controlPreparingAgent")
        session.controlSession.onFailure = { [weak self] message in
            guard let self, !self.isShuttingDown else { return }
            // A simulator's runner fails for local reasons (Xcode, the build)
            // that a refresh-driven retry every few seconds cannot fix.
            if session.isIOSSimulator || !Self.shouldKeepDesiredControlAfterFailure(messageKey: message) {
                self.desiredControlIDs.remove(session.id)
                self.desiredControlIDs.remove(udid)
            }
            self.statusMessage = self.t(message)
            self.presentControlRecovery(for: session, message: message)
        }
        session.controlSession.connect(using: controlConnector(for: session, udid: udid))
    }

    /// Starting USB screen capture switches the iPhone to USB Configuration 7,
    /// which re-enumerates it and drops every usbmuxd connection. Control holds
    /// capture open, so wait for that held stream's first frame (and for
    /// usbmuxd to re-attach) before `smtunnel` opens its USB tunnel.
    private func waitForUSBCaptureToSettleIfNeeded(udid: String) async {
        func usbMirror() -> MirrorCaptureSession? {
            sessions.first {
                $0.platform == .iOS
                    && $0.transport == .usb
                    && $0.videoSource == .avFoundation
                    && $0.device.udid == udid
                    && $0.device.connectionState == .connected
            }?.mirrorSession
        }
        guard let initial = usbMirror(), !initial.hasLiveUSBStream else { return }
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            guard let current = usbMirror() else { break }
            if current.hasLiveUSBStream { break }
        }
        try? await Task.sleep(for: .milliseconds(1_000))
    }

    /// iOS chooses system HID before preparing a runner. Compatibility and
    /// semantic capabilities share a lazy WDA connection behind that session.
    private func controlConnector(for session: DeviceSession, udid: String) -> DeviceControlSession.Connector {
        let auxiliary = legacyControlConnector(for: session, udid: udid)
        guard session.platform == .iOS else { return auxiliary }
        let simulator = session.isIOSSimulator
        let profile = DeviceDisplayProfile.profile(for: session.device.productType, name: session.device.name)
        let sizeProvider: HIDControlBackend.SizeProvider = { [weak mirror = session.mirrorSession] in
            if let display = mirror?.simulatorDisplay {
                return DeviceScreenSize(width: display.logicalSize.width, height: display.logicalSize.height)
            }
            if let profile {
                let landscape = (mirror?.frameAspectRatio ?? profile.aspectRatio) > 1
                let width = Double(profile.logicalSize.width), height = Double(profile.logicalSize.height)
                return DeviceScreenSize(width: landscape ? max(width, height) : min(width, height),
                                        height: landscape ? min(width, height) : max(width, height))
            }
            // Coordinate gestures stay normalized until a backend consumes
            // them. No WDA launch is needed just to obtain a point-space size.
            return DeviceScreenSize(width: max(mirror?.frameAspectRatio ?? 1, 0.001), height: 1)
        }
        let touchConnector: HIDControlBackend.TouchConnector = {
            if simulator { return try await SimulatorHIDBackend.connect(udid: udid) }
            return try await PhysicalHIDBackend.connect(udid: udid)
        }
        return { report in
            let size = await sizeProvider() ?? DeviceScreenSize(width: 1, height: 1)
            return try await HIDControlBackend.connect(
                screenSize: size, sizeProvider: sizeProvider,
                touchConnector: touchConnector, auxiliaryConnector: auxiliary, report: report
            )
        }
    }

    private func legacyControlConnector(for session: DeviceSession, udid: String) -> DeviceControlSession.Connector {
        if session.platform == .android {
            let serverURL = appiumServerURL
            let appPackage = controlBundleID
            let configuration = AppiumControlConfiguration(
                platform: .android,
                platformVersion: session.androidDevice?.osVersion ?? ""
            ).isolated(forDeviceUDID: udid)
            let appiumService = self.appiumService
            return { report in
                await report(.startingService, nil)
                let ready = await appiumService.ensureRunning(serverURL: serverURL)
                guard ready else { throw ControlServiceUnavailableError() }
                return try await AppiumAndroidBackend.connect(
                    serverURL: serverURL,
                    udid: udid,
                    appPackage: appPackage,
                    configuration: configuration,
                    report: report
                )
            }
        }
        if session.isIOSSimulator {
            // A simulator needs no signing, tunnel or setup: the runner its
            // mirror uses is the control endpoint too.
            return { report in
                await report(.startingAgent, nil)
                let endpoint = try await SimulatorAgentService.shared.ensureRunning(udid: udid)
                await report(.connectingAgent, nil)
                let backend = try await WDAControlBackend.connect(baseURL: endpoint.controlURL)
                await report(.finishing, nil)
                return backend
            }
        }
        let agent = session.iosAgent ?? IOSAgentService()
        return { [weak self] report in
            guard let self else { throw CancellationError() }
            await self.detectSigningTeams()
            let configuration = await self.iosControlConfiguration()
            await report(.startingAgent, nil)

            var lastError: Error?
            for attempt in 0..<4 {
                try Task.checkCancellation()
                await self.waitForUSBCaptureToSettleIfNeeded(udid: udid)
                let transport: DeviceTunnelTransport = await MainActor.run {
                    guard let current = self.sessions.first(where: { $0.platform == .iOS && $0.device.udid == udid }) else {
                        return .auto
                    }
                    return current.transport == .usb ? .usb : .network
                }
                do {
                    let endpoint = try await agent.ensureRunning(
                        udid: udid,
                        transport: transport,
                        configuration: configuration
                    ) { [weak self] progress in
                        switch progress {
                        case .checkingExistingAgent, .checkingDevice, .launchingAgent:
                            await report(.startingAgent, nil)
                        case .waitingForDevice:
                            let message = await self?.t("agent.start.waitingForDevice")
                            await report(.startingAgent, message)
                        case .connectingVideo:
                            await report(.connectingAgent, nil)
                        }
                    }
                    await report(.connectingAgent, nil)
                    let backend = try await WDAControlBackend.connect(baseURL: endpoint.controlURL)
                    await report(.finishing, nil)
                    return backend
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    guard attempt < 3, Self.shouldRetryControlConnection(error) else {
                        throw error
                    }
                    let message = await self.t("agent.start.retryingAgent")
                    await report(.startingAgent, message)
                    try await Task.sleep(for: .milliseconds(1_000 + attempt * 750))
                }
            }
            throw lastError ?? IOSAgentError.launchFailed
        }
    }

    func connectControlForAutomation(for session: DeviceSession, resetUncertain: Bool = false) async throws {
        guard let session = beginConnectionAttemptIfNeeded(for: session) else {
            throw DeviceAutomationError.deviceUnavailable
        }
        guard canStartControl(for: session) else {
            showActivation(for: [])
            throw DeviceAutomationError.activationRequired
        }
        guard !isShuttingDown else {
            throw DeviceAutomationError.deviceUnavailable
        }
        guard let udid = session.device.udid, !udid.isEmpty else {
            throw DeviceAutomationError.deviceUnavailable
        }
        if session.controlSession.touchIsUncertain {
            guard resetUncertain else {
                throw DeviceAutomationError.controlFailed("The previous input has an uncertain result. Call connect_control to explicitly reconnect before sending another action.")
            }
            await session.controlSession.shutdown()
        }
        desiredControlIDs.insert(session.id)
        thumbnailCaptures[session.id]?.cancel()
        thumbnailCaptures[session.id] = nil
        if session.controlSession.isReady, await session.controlSession.verifyReady() {
            return
        }
        if !session.controlSession.isConnecting {
            session.controlSession.onFailure = { [weak self] message in
                guard let self, !self.isShuttingDown else { return }
                if !Self.shouldKeepDesiredControlAfterFailure(messageKey: message) {
                    self.desiredControlIDs.remove(session.id)
                    self.desiredControlIDs.remove(udid)
                }
                self.statusMessage = self.t(message)
            }
            session.controlSession.connect(using: controlConnector(for: session, udid: udid))
        }
        try await waitForControlConnection(session)
    }

    private func waitForControlConnection(_ session: DeviceSession) async throws {
        let deadline = ContinuousClock.now + .seconds(240)
        while !session.controlSession.isReady {
            if case let .failed(message) = session.controlSession.state {
                throw DeviceAutomationError.controlFailed(t(message))
            }
            guard ContinuousClock.now < deadline else {
                throw DeviceAutomationError.timedOut("Connecting device control timed out.")
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    func startMirrorForAutomation(
        for session: DeviceSession, showWindow: Bool = true, waitUntilRunning: Bool = true
    ) async throws {
        guard !isShuttingDown,
              let session = beginConnectionAttemptIfNeeded(for: session) else {
            throw DeviceAutomationError.deviceUnavailable
        }
        if session.mirrorSession.state == .running {
            if showWindow {
                embeddedPreviewIDs.remove(session.id)
                MirrorWindowRegistry.shared.openAuthorized(session: session, store: self)
            }
            return
        }
        if session.needsCameraPermission, permissionStatus != .authorized {
            throw DeviceAutomationError.mirrorFailed(t("permission.usbBanner.body"))
        }

        let decision = requestMirrorStarts([session.id], presentActivationWhenBlocked: showWindow, showWindow: showWindow)
        if decision.blockedIDs.contains(session.id) {
            throw DeviceAutomationError.activationRequired
        }
        // Embedded views poll the capture state while wireless setup proceeds.
        // Returning promptly keeps first-time WDA setup outside the host's tool timeout.
        guard waitUntilRunning else { return }

        // Physical iPhones open a tunnel first; a simulator may build its runner.
        let deadline = ContinuousClock.now + .seconds(
            session.usesIOSAgentVideo ? 120 : session.isIOSSimulator ? 200 : 20
        )
        while session.mirrorSession.state != .running {
            if case let .failed(message) = session.mirrorSession.state {
                throw DeviceAutomationError.mirrorFailed(message)
            }
            guard ContinuousClock.now < deadline else {
                throw DeviceAutomationError.timedOut("Starting mirror timed out.")
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func setFloatingForAutomation(_ floating: Bool, session: DeviceSession) {
        if floating {
            floatingMirrorIDs.insert(session.id)
        } else {
            floatingMirrorIDs.remove(session.id)
        }
        MirrorWindowRegistry.shared.setFloating(floating, for: session)
    }

    func detectSigningTeams() async {
        let detectionTask: Task<[XcodeSigningTeam], Never>
        if let runningTask = signingTeamDetectionTask {
            detectionTask = runningTask
        } else {
            let newTask = Task { await XcodeSigningTeamDetector.detect() }
            signingTeamDetectionTask = newTask
            isDetectingSigningTeams = true
            detectionTask = newTask
        }

        // All callers await and apply the shared result. Previously a second
        // caller returned immediately while detection was in flight, then tried
        // to start wireless mirroring with an empty Team ID.
        let teams = await detectionTask.value
        detectedSigningTeams = teams
        signingTeamDetectionTask = nil
        isDetectingSigningTeams = false

        controlXcodeOrgID = XcodeSigningTeamDetector.preferredTeamID(
            savedID: controlXcodeOrgID,
            applicationTeamID: XcodeSigningTeamDetector.currentApplicationTeamID(),
            teams: teams
        ) ?? ""
    }

    func selectSigningTeam(_ teamID: String) {
        guard detectedSigningTeams.contains(where: { $0.id == teamID }) else { return }
        controlXcodeOrgID = teamID
    }

    func stopControl(for session: DeviceSession) {
        forgetControlIntent(for: session)
        session.controlSession.disconnect()
    }

    /// Control is no longer wanted for this device, so a refresh must not
    /// reconnect it.
    func forgetControlIntent(for session: DeviceSession) {
        desiredControlIDs.remove(session.id)
        if let udid = session.device.udid {
            desiredControlIDs.remove(udid)
        }
    }

    /// The signing identity and per-device build directory used to prepare
    /// and name the iPhone screen agent.
    func iosControlConfiguration() -> AppiumControlConfiguration {
        AppiumControlConfiguration(
            platform: .iOS,
            xcodeOrgID: controlXcodeOrgID,
            xcodeSigningID: controlXcodeSigningID,
            wdaBundleID: controlWDABundleID,
            derivedDataPath: wdaDerivedDataPath
        )
    }

    private var wdaDerivedDataPath: String {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = baseURL
            .appendingPathComponent("StupidMirror", isDirectory: true)
            .appendingPathComponent("WebDriverAgentDerivedData", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private var effectiveControlWDABundleID: String {
        var configuration = AppiumControlConfiguration()
        configuration.xcodeOrgID = controlXcodeOrgID
        configuration.wdaBundleID = controlWDABundleID
        return configuration.installationWDABundleID
    }

    func tapControl(for session: DeviceSession, normalizedX: Double, normalizedY: Double) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.tap(CGPoint(x: normalizedX, y: normalizedY)))
    }

    func swipeControl(for session: DeviceSession, from start: CGPoint, to end: CGPoint, durationMS: Int) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.swipe(from: start, to: end, durationMS: durationMS))
    }

    func dragControl(for session: DeviceSession, path: [ControlPathSample]) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.drag(path: path))
    }

    func doubleTapControl(for session: DeviceSession, normalizedX: Double, normalizedY: Double) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.doubleTap(CGPoint(x: normalizedX, y: normalizedY)))
    }

    func longPressControl(for session: DeviceSession, normalizedX: Double, normalizedY: Double, durationMS: Int) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.longPress(CGPoint(x: normalizedX, y: normalizedY), durationMS: durationMS))
    }

    func pinchControl(for session: DeviceSession, center: CGPoint, scale: Double, velocity: Double) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.pinch(center: center, scale: scale, velocity: velocity))
    }

    func rotateControl(for session: DeviceSession, center: CGPoint, degrees: Double, velocity: Double) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.rotate(center: center, degrees: degrees, velocity: velocity))
    }

    /// The full gesture surface of the mirror, wired to one device session.
    func gestureHandlers(for session: DeviceSession) -> ControlGestureHandlers {
        let generation = session.controlSession.touchGeneration
        // One native mirror window per device. Keep this owner stable across
        // SwiftUI updates so a second click may queue behind the first UP.
        let source = "native:\(session.id)"
        let onTouch: ((TouchEvent) -> Void)? = session.controlSession.supportsContinuousTouch ? { [weak self] event in
            if event.phase == .down || event.phase == .move {
                guard self?.prepareQueuedControlAction(for: session) == true else { return }
            }
            session.controlSession.enqueueTouch(event, source: source, geometryGeneration: generation)
        } : nil
        return ControlGestureHandlers(
            onTap: { [weak self] point in
                self?.tapControl(for: session, normalizedX: point.x, normalizedY: point.y)
            },
            onDoubleTap: { [weak self] point in
                self?.doubleTapControl(for: session, normalizedX: point.x, normalizedY: point.y)
            },
            onLongPress: { [weak self] point, durationMS in
                self?.longPressControl(for: session, normalizedX: point.x, normalizedY: point.y, durationMS: durationMS)
            },
            onSwipe: { [weak self] start, end, durationMS in
                self?.swipeControl(for: session, from: start, to: end, durationMS: durationMS)
            },
            onDrag: { [weak self] path in
                self?.dragControl(for: session, path: path)
            },
            onPinch: { [weak self] center, scale, velocity in
                self?.pinchControl(for: session, center: center, scale: scale, velocity: velocity)
            },
            onRotate: { [weak self] center, degrees, velocity in
                self?.rotateControl(for: session, center: center, degrees: degrees, velocity: velocity)
            },
            onTouch: onTouch,
            touchGeneration: generation,
            supportsNativeGestures: session.controlSession.supportsNativeGestures
        )
    }

    func typeControlText(_ text: String, for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session), !text.isEmpty else { return }
        session.controlSession.enqueue(.typeText(text))
    }

    func pressHome(for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.press(.home))
    }

    func changePosture(_ posture: DevicePosture, for session: DeviceSession) {
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.setPosture(posture, for: session)
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    func setPosture(_ posture: DevicePosture, for session: DeviceSession) async throws -> SimulatorDisplayState {
        guard session.isIOSSimulator, session.device.formFactor == .foldable else {
            throw DeviceAutomationError.invalidArgument("Posture control requires a foldable iOS Simulator.")
        }
        try await startMirrorForAutomation(for: session, showWindow: false, waitUntilRunning: false)
        return try await session.controlSession.withTouchGeometryChange {
            try await session.mirrorSession.setSimulatorPosture(posture)
        }
    }

    func rotateSimulator(_ session: DeviceSession) {
        Task { @MainActor [weak self] in
            do { _ = try await self?.rotateSimulatorDisplay(for: session) }
            catch { self?.statusMessage = error.localizedDescription }
        }
    }

    func rotateSimulatorDisplay(for session: DeviceSession) async throws -> SimulatorDisplayState {
        guard session.isIOSSimulator else { throw DeviceAutomationError.invalidArgument("Rotation requires an iOS Simulator.") }
        try await startMirrorForAutomation(for: session, showWindow: false, waitUntilRunning: false)
        return try await session.controlSession.withTouchGeometryChange {
            try await session.mirrorSession.rotateSimulatorDisplay()
        }
    }

    func openAppSwitcher(for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.press(.appSwitcher))
    }

    func pressBack(for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.enqueue(.press(.back))
    }

    private func prepareQueuedControlAction(for session: DeviceSession) -> Bool {
        guard canUseControl else {
            statusMessage = t("status.activationControlRequired")
            showActivation(for: [])
            return false
        }
        guard session.controlSession.isReady else {
            statusMessage = t("control.state.unavailable")
            return false
        }
        return true
    }

    /// Whether this device may be controlled now: it already is, or a
    /// control slot is free. App management uses the same rule.
    func canStartControl(for session: DeviceSession) -> Bool {
        LicenseCapabilityPolicy.canStartControl(
            capabilities: licenseManager.state.capabilities,
            activeIDs: Set(sessions.compactMap { candidate in
                candidate.controlSession.isReady || candidate.controlSession.isConnecting
                    ? candidate.id
                    : nil
            }),
            targetID: session.id
        )
    }

    private func enforceSimultaneousControlLimit(_ capabilities: LicenseCapabilities) {
        guard let limit = capabilities.maximumSimultaneousControls else { return }
        let active = sessions.filter {
            $0.controlSession.isReady || $0.controlSession.isConnecting
        }
        guard active.count > limit else { return }
        let preferred = active.first { $0.id == selectedSessionID }
        let retainedIDs = Set(([preferred].compactMap { $0 } + active).prefix(limit).map(\.id))
        for session in active where !retainedIDs.contains(session.id) {
            desiredControlIDs.remove(session.id)
            if let udid = session.device.udid {
                desiredControlIDs.remove(udid)
            }
            session.controlSession.disconnect()
        }
        statusMessage = t("status.activationControlRequired")
    }

    func select(_ session: DeviceSession) {
        selectedSessionID = session.id
    }

    func refreshThumbnail(for session: DeviceSession) {
        guard session.device.connectionState == .connected else { return }
        thumbnails[session.id] = nil
        thumbnailAspectRatios[session.id] = nil
        thumbnailErrors[session.id] = nil
        captureThumbnail(for: session)
    }

    func displayAspectRatio(for session: DeviceSession) -> Double {
        // Live frame ratio wins so the window follows device rotation.
        if let live = session.mirrorSession.frameAspectRatio, live > 0 {
            return live
        }
        if let display = session.mirrorSession.simulatorDisplay {
            return display.logicalSize.width / max(display.logicalSize.height, 1)
        }
        if let aspect = thumbnailAspectRatios[session.id], aspect > 0 {
            return aspect
        }
        if let profile = DeviceDisplayProfile.profile(for: session.device.productType, name: session.device.name) {
            return profile.aspectRatio
        }
        if let aspect = session.controlSession.screenSize?.aspectRatio, aspect > 0 {
            return aspect
        }
        return 1260.0 / 2736.0
    }

    /// A phone's tunnel ended on its own: Wi-Fi dropped, the cable came out,
    /// or the runner died. Video and control both rode on it, and its loopback
    /// ports are gone, so both reconnect through a fresh tunnel.
    private func handleAgentExit(udid: String) {
        guard !isShuttingDown else { return }
        for session in sessions where session.platform == .iOS && session.device.udid == udid {
            session.controlSession.agentDidExit()
            guard desiredMirrorIDs.contains(session.id), session.usesIOSAgentVideo else { continue }
            session.mirrorSession.requestWirelessReconnect()
        }
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: IOSAgentService.agentDidExitNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let udid = notification.userInfo?[IOSAgentService.udidUserInfoKey] as? String else { return }
                Task { @MainActor in
                    self?.handleAgentExit(udid: udid)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // “Remove Device” only hides the current attachment. A new
                    // physical connection is an explicit request to show it again.
                    self?.removedDeviceIDs.removeAll()
                    self?.statusMessage = self?.t("status.deviceConnectedRefreshing") ?? ""
                    self?.refresh()
                    self?.scheduleDiscoveryRetries()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.statusMessage = self?.t("status.deviceDisconnectedRefreshing") ?? ""
                    self?.refresh()
                    self?.scheduleDiscoveryRetries()
                }
            }
        )
    }

    private func scheduleDiscoveryRetries() {
        discoveryRetryTask?.cancel()
        discoveryRetryTask = Task { @MainActor [weak self] in
            for delay in Self.discoveryRetryDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
                self.refresh()
            }
        }
    }

    private func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.periodicRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateCameraPermissionStatus(AVFoundationMirrorBackend.videoAuthorizationStatus())
                self.updateMicrophonePermissionStatus(AVFoundationMirrorBackend.audioAuthorizationStatus())
                self.refresh()
            }
        }
    }

    func t(_ key: String) -> String {
        AppCopy.text(key, language: language)
    }

    func connectionStateLabel(_ state: DeviceConnectionState) -> String {
        switch state {
        case .connected:
            t("connection.connected")
        case .disconnected:
            t("connection.disconnected")
        case .unavailable:
            t("connection.unavailable")
        }
    }

    func mirrorStateLabel(_ state: MirrorState) -> String {
        switch state {
        case .stopped:
            t("mirror.state.stopped")
        case .starting:
            t("mirror.state.starting")
        case .running:
            t("mirror.state.running")
        case .failed:
            t("mirror.state.failed")
        }
    }

    func controlStateLabel(_ state: ControlState) -> String {
        switch state {
        case .unavailable:
            t("control.state.unavailable")
        case .connecting:
            t("control.state.connecting")
        case .ready:
            t("control.state.ready")
        case .failed:
            t("control.state.failed")
        }
    }

    func appiumServiceStateLabel(_ state: AppiumServiceState) -> String {
        switch state {
        case .unknown:
            t("appium.state.unknown")
        case .checking:
            t("appium.state.checking")
        case .starting:
            t("appium.state.starting")
        case .running:
            t("appium.state.running")
        case .stopped:
            t("appium.state.stopped")
        case .missing:
            t("appium.state.missing")
        case .failed:
            t("appium.state.failed")
        }
    }

    func authorizationLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            t("auth.authorized")
        case .notDetermined:
            t("auth.notDetermined")
        case .denied:
            t("auth.denied")
        case .restricted:
            t("auth.restricted")
        @unknown default:
            t("auth.unknown")
        }
    }

    private var localizedStatusMessage: String {
        if lastConnectedCount == 0 && lastReconnectingCount == 0 {
            return t("status.noSources")
        }
        if lastReconnectingCount > 0 {
            let key = lastReconnectingCount == 1 ? "status.reconnecting" : "status.reconnectingMany"
            return String(format: t(key), lastReconnectingCount)
        }
        if lastConnectedCount == 1 {
            return t("status.foundOne")
        }
        return String(format: t("status.foundMany"), lastConnectedCount)
    }

    private func captureThumbnail(for session: DeviceSession) {
        if let androidDevice = session.androidDevice {
            let serial = androidDevice.serial
            captureHostScreenshotThumbnail(for: session) {
                try AndroidADBService.captureScreenshot(serial: serial)
            }
            return
        }
        if session.isIOSSimulator, let udid = session.device.udid {
            if let liveFrame = session.mirrorSession.latestWirelessFrame,
               session.mirrorSession.state == .running {
                applyWirelessImageThumbnail(liveFrame, for: session)
                return
            }
            captureHostScreenshotThumbnail(for: session) {
                try SimulatorDiscoveryService.screenshotPNG(udid: udid)
            }
            return
        }
        if session.usesIOSAgentVideo {
            if let liveFrame = session.mirrorSession.latestWirelessFrame,
               session.mirrorSession.state == .running || session.mirrorSession.state == .starting {
                applyWirelessImageThumbnail(liveFrame, for: session)
                return
            }
            captureWirelessThumbnail(for: session)
            return
        }
        if session.transport == .usb {
            let tunnelRunning = session.device.udid.map(IOSAgentService.hasRunningAgent(udid:)) ?? false
            let controlActive = session.controlSession.isReady
                || session.controlSession.isConnecting
                || desiredControlIDs.contains(session.id)
            if !Self.shouldStartUSBThumbnailCapture(
                liveMirrorDesired: desiredMirrorIDs.contains(session.id),
                mirrorState: session.mirrorSession.state,
                controlActive: controlActive,
                tunnelRunning: tunnelRunning,
                preparingIPhone: isPreparingIPhone,
                isBackgroundProcess: CommandLine.arguments.contains("--mcp-background")
            ) {
                if session.mirrorSession.state == .running
                    || session.mirrorSession.state == .starting
                    || session.mirrorSession.hasLiveUSBStream {
                    applyLiveUSBThumbnail(from: session)
                } else if session.controlSession.isReady {
                    captureWirelessThumbnail(for: session)
                }
                return
            }
        }
        if session.mirrorSession.state == .running || session.mirrorSession.state == .starting {
            applyLiveUSBThumbnail(from: session)
            return
        }
        guard thumbnailCaptures[session.id] == nil else { return }
        guard let captureDevice = session.captureDevice else { return }

        let capture = ThumbnailCapture { [weak self] result in
            guard let self else { return }
            self.thumbnailCaptures[session.id] = nil
            switch result {
            case let .success(image):
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    self.thumbnails[session.id] = image
                    self.thumbnailAspectRatios[session.id] = max(Double(image.size.width / max(image.size.height, 1)), 0.1)
                    self.thumbnailErrors[session.id] = nil
                }
                MirrorWindowRegistry.shared.updateAspectRatio(for: session, aspectRatio: self.displayAspectRatio(for: session))
            case let .failure(error):
                if (error as? ThumbnailCaptureError) != .cancelled {
                    self.thumbnailErrors[session.id] = error.localizedDescription
                }
            }
        }
        thumbnailCaptures[session.id] = capture

        do {
            try capture.start(device: captureDevice)
        } catch {
            thumbnailCaptures[session.id] = nil
            thumbnailErrors[session.id] = error.localizedDescription
        }
    }

    /// Copies the live frame into a bitmap off the main thread. Encoding and
    /// decoding a full-size PNG here used to hold the main thread for over
    /// 100 ms per USB iPhone, behind any PNG encode already running for MCP.
    private func applyLiveUSBThumbnail(from session: DeviceSession) {
        guard wirelessThumbnailTasks[session.id] == nil else { return }
        let sessionID = session.id
        let frameStore = session.mirrorSession.latestFrameStore
        wirelessThumbnailTasks[sessionID] = Task { @MainActor [weak self] in
            defer { self?.wirelessThumbnailTasks[sessionID] = nil }
            let rendered = await Task.detached(priority: .utility) { () -> RenderedThumbnail? in
                guard let snapshot = frameStore.snapshot(includePNG: false),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(snapshot.sampleBuffer),
                      let image = MirrorCaptureSession.previewImage(from: pixelBuffer) else { return nil }
                return RenderedThumbnail(image: image)
            }.value
            guard let self, !Task.isCancelled, let image = rendered?.image,
                  let session = self.sessions.first(where: { $0.id == sessionID }) else { return }
            self.applyWirelessImageThumbnail(image, for: session)
        }
    }

    /// A thumbnail from a host tool that screenshots the device directly:
    /// `adb` for Android, `simctl` for an iOS Simulator.
    private func captureHostScreenshotThumbnail(
        for session: DeviceSession,
        load: @escaping @Sendable () throws -> Data
    ) {
        guard wirelessThumbnailTasks[session.id] == nil else { return }
        let sessionID = session.id
        wirelessThumbnailTasks[sessionID] = Task { @MainActor [weak self] in
            defer { self?.wirelessThumbnailTasks[sessionID] = nil }
            guard let self else { return }
            do {
                let data = try await Task.detached(priority: .utility) {
                    try load()
                }.value
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else {
                    throw WirelessThumbnailError.invalidImage
                }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    self.thumbnails[sessionID] = image
                    self.thumbnailAspectRatios[sessionID] = max(
                        Double(image.size.width / max(image.size.height, 1)),
                        0.1
                    )
                    self.thumbnailErrors[sessionID] = nil
                }
                MirrorWindowRegistry.shared.updateAspectRatio(
                    for: session,
                    aspectRatio: self.displayAspectRatio(for: session)
                )
            } catch is CancellationError {
                return
            } catch {
                self.thumbnailErrors[sessionID] = error.localizedDescription
            }
        }
    }

    private func applyWirelessImageThumbnail(_ image: NSImage, for session: DeviceSession) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            thumbnails[session.id] = image
            thumbnailAspectRatios[session.id] = max(
                Double(image.size.width / max(image.size.height, 1)),
                0.1
            )
            thumbnailErrors[session.id] = nil
        }
        MirrorWindowRegistry.shared.updateAspectRatio(
            for: session,
            aspectRatio: displayAspectRatio(for: session)
        )
    }

    private func captureWirelessThumbnail(for session: DeviceSession) {
        guard session.controlSession.isReady,
              wirelessThumbnailTasks[session.id] == nil else { return }
        let sessionID = session.id
        wirelessThumbnailTasks[sessionID] = Task { @MainActor [weak self, weak controlSession = session.controlSession] in
            defer { self?.wirelessThumbnailTasks[sessionID] = nil }
            guard let self, let controlSession else { return }
            do {
                let data = try await controlSession.screenshot()
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else {
                    throw WirelessThumbnailError.invalidImage
                }
                guard let session = self.sessions.first(where: { $0.id == sessionID }) else { return }
                self.applyWirelessImageThumbnail(image, for: session)
            } catch is CancellationError {
                return
            } catch {
                self.thumbnailErrors[sessionID] = error.localizedDescription
            }
        }
    }
}

private struct RenderedThumbnail: @unchecked Sendable {
    let image: NSImage
}

private enum WirelessThumbnailError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "The wireless iPhone screenshot could not be decoded."
    }
}

struct DiagnosticItem: Identifiable {
    let id = UUID()
    let name: String
    let value: String
}

extension AVAuthorizationStatus {
    var label: String {
        switch self {
        case .authorized:
            "Authorized"
        case .notDetermined:
            "Not determined"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }
}
