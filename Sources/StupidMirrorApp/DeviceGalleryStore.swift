@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

enum DashboardSheet: String, Identifiable, Equatable, Sendable {
    case diagnostics
    case settings
    case activation
    case controlSetup
    case wirelessSetup
    case wirelessAccess

    var id: String { rawValue }

    static func toggling(_ target: DashboardSheet, from current: DashboardSheet?) -> DashboardSheet? {
        current == target ? nil : target
    }
}

enum WirelessSetupState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed(String)
}

enum CameraPermissionPresentation: Equatable {
    case hidden
    case fullPage
    case banner
}

enum DashboardSettingsTab: Hashable, Sendable {
    case general
    case mcp
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
    @Published private(set) var wirelessSetupState: WirelessSetupState = .idle
    @Published private(set) var activeSheet: DashboardSheet?
    @Published private(set) var settingsTab: DashboardSettingsTab = .general
    @Published var selectedSessionID: String?
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
    private var wirelessTransportTasks: [String: Task<Void, Never>] = [:]
    private var removedDeviceIDs = Set<String>()
    private var desiredMirrorIDs = Set<String>()
    private var pendingActivationMirrorIDs = Set<String>()
    private var disconnectedSince: [String: Date] = [:]
    private var lastConnectedCount = 0
    private var lastReconnectingCount = 0
    private var isShuttingDown = false

    private static let periodicRefreshInterval: TimeInterval = 10
    private static let reconnectRetentionInterval: TimeInterval = 30
    private static let maxRetainedDisconnectedSessions = 4

    private static let languageDefaultsKey = "StupidMirror.language"
    private static let autoStartMirrorsDefaultsKey = "StupidMirror.autoStartMirrors"
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
                value: wirelessMirroringEnabled
                    ? "USB: AVFoundation / Wireless: WDA H.264 over SRT"
                    : "CoreMediaIO + AVFoundation"
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

    var reconnectingSessions: [DeviceSession] {
        sessions.filter { $0.device.connectionState == .disconnected }
    }

    var canUseControl: Bool {
        licenseManager.state.capabilities.controlEnabled
    }

    var hasConnectedIOSDevice: Bool {
        connectedSessions.contains { $0.platform == .iOS }
    }

    var cameraPermissionPresentation: CameraPermissionPresentation {
        Self.cameraPermissionPresentation(
            authorizationStatus: permissionStatus,
            hasCameraIndependentConnectedDevice: connectedSessions.contains {
                $0.platform == .android || $0.transport == .wireless
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
        if permissionStatus != .authorized && !wirelessMirroringEnabled {
            statusMessage = t("status.permissionRequired")
        }
        refresh()
    }

    func discoverWirelessDevices() {
        wirelessMirroringEnabled = true
        guard UserDefaults.standard.bool(forKey: Self.wirelessSetupGuideSeenDefaultsKey) else {
            presentWirelessSetup()
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

    func presentWirelessSetup() {
        if let usb = wirelessSetupUSBSession {
            select(usb)
            wirelessSetupState = hasCachedWDABuild(for: usb.device.udid) ? .ready : .idle
        } else {
            wirelessSetupState = .idle
        }
        setActiveSheet(.wirelessSetup)
    }

    func prepareWirelessSetup() async {
        guard let session = wirelessSetupUSBSession,
              let udid = session.device.udid, !udid.isEmpty else {
            wirelessSetupState = .failed(t("wireless.setup.error.connectUSB"))
            return
        }
        await detectSigningTeams()
        guard !controlXcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            wirelessSetupState = .failed(t("wireless.error.missingSigningTeam"))
            return
        }

        wirelessSetupState = .preparing
        statusMessage = t("wireless.setup.preparing")
        do {
            try await WirelessWDAService.prepareInitialUSBSetup(
                udid: udid,
                configuration: controlConfiguration(for: session)
            )
            guard hasCachedWDABuild(for: udid) else {
                throw WirelessWDAError.buildFailed
            }
            UserDefaults.standard.set(true, forKey: Self.wirelessSetupGuideSeenDefaultsKey)
            wirelessSetupState = .ready
            statusMessage = t("wireless.setup.ready")
        } catch is CancellationError {
            wirelessSetupState = .idle
        } catch {
            let message = wirelessWDAErrorMessage(error)
            wirelessSetupState = .failed(message)
            statusMessage = message
        }
    }

    func finishWirelessSetupAndDiscover() {
        UserDefaults.standard.set(true, forKey: Self.wirelessSetupGuideSeenDefaultsKey)
        setActiveSheet(nil)
        continueWirelessDiscovery()
    }

    var wirelessSetupUSBSession: DeviceSession? {
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

    func openLocalNetworkPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        ) else { return }
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
        let previous = permissionStatus
        permissionStatus = status
        guard previous == .authorized, status != .authorized else { return }

        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileRunning = false
        let usbIDs = Set(sessions.filter {
            $0.platform == .iOS && $0.transport == .usb
        }.map(\.id))
        desiredMirrorIDs.subtract(usbIDs)
        pendingActivationMirrorIDs.subtract(usbIDs)
        dismissActivationSheetIfPresented()
        let usbSessions = sessions.filter {
            $0.platform == .iOS && $0.transport == .usb
        }
        MirrorWindowRegistry.shared.closeAll(sessions: usbSessions)
        for session in usbSessions {
            session.mirrorSession.dispose()
            session.wirelessWDA?.stop()
            session.controlSession.stop(serverURL: appiumServerURL)
        }
        for capture in thumbnailCaptures.values {
            capture.cancel()
        }
        thumbnailCaptures.removeAll()
        for id in usbIDs {
            clearThumbnail(for: id)
            disconnectedSince[id] = nil
            floatingMirrorIDs.remove(id)
        }
        sessions.removeAll { $0.platform == .iOS && $0.transport == .usb }
        if selectedSessionID.map(usbIDs.contains) == true {
            selectedSessionID = sessions.first?.id
        }
        statusMessage = wirelessMirroringEnabled ? localizedStatusMessage : t("status.permissionRequired")
        refresh()
    }

    private func updateMicrophonePermissionStatus(_ status: AVAuthorizationStatus) {
        microphonePermissionStatus = status
        applyAudioPlaybackPreference()
    }

    private func applyAudioPlaybackPreference() {
        for session in sessions {
            let audioEnabled = session.platform == .android
                ? audioPlaybackEnabled
                : Self.shouldCaptureAudio(
                    playbackEnabled: audioPlaybackEnabled,
                    authorizationStatus: microphonePermissionStatus
                )
            session.mirrorSession.setAudioEnabled(audioEnabled)
        }
    }

    func enableAudioPlayback() async {
        audioPlaybackEnabled = true
        guard needsIOSAudioPermission else { return }
        await requestMicrophonePermission()
    }

    nonisolated static func shouldCaptureAudio(
        playbackEnabled: Bool,
        authorizationStatus: AVAuthorizationStatus
    ) -> Bool {
        playbackEnabled && authorizationStatus == .authorized
    }

    func refresh() {
        guard !isShuttingDown else { return }
        guard refreshTask == nil else {
            refreshRequestedWhileRunning = true
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        let canDiscoverUSB = permissionStatus == .authorized
        let discoverWireless = wirelessMirroringEnabled
        refreshTask = Task { [weak self] in
            async let metadataTask = Task.detached(priority: .utility) {
                canDiscoverUSB ? DeviceMetadataService.connectedDevices() : []
            }.value
            async let wirelessTask = Task.detached(priority: .utility) {
                discoverWireless ? CoreDeviceDiscoveryService.wirelessDevices() : []
            }.value
            async let androidTask = Task.detached(priority: .utility) {
                AndroidADBService.discoverDevices()
            }.value
            let metadata = await metadataTask
            let wirelessDevices = await wirelessTask
            let androidDevices = await androidTask
            guard let self else { return }
            guard self.refreshGeneration == generation else { return }
            guard !Task.isCancelled, !self.isShuttingDown else {
                self.finishRefresh(generation: generation)
                return
            }

            let devices = canDiscoverUSB ? AVFoundationMirrorBackend.discoverMuxedDevices() : []
            guard self.refreshGeneration == generation, !Task.isCancelled else { return }
            self.applyRefresh(
                devices: devices,
                metadata: metadata,
                wirelessDevices: wirelessDevices,
                androidDevices: androidDevices
            )
            self.finishRefresh(generation: generation)
        }
    }

    func refreshForAutomation() async throws {
        guard permissionStatus == .authorized
                || wirelessMirroringEnabled
                || AndroidRuntime.adbExecutablePath() != nil else {
            throw DeviceAutomationError.permissionRequired
        }
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
        wirelessDevices: [WirelessDeviceMetadata],
        androidDevices: [AndroidDeviceMetadata]
    ) {
        let existingByID = Self.latestValueByID(sessions) { $0.id }
        var nextSessions: [DeviceSession] = []
        var connectedIDs = Set<String>()
        var autoStartIDs = Set<String>()
        var resumeAuthorizedIDs = Set<String>()
        let now = Date()

        for captureDevice in devices {
            let match = DeviceMetadataService.bestMatch(
                for: captureDevice.localizedName,
                modelID: captureDevice.modelID,
                candidates: metadata
            )
            let identity = AVFoundationMirrorBackend.identity(for: captureDevice, metadata: match)
            guard !isRemovedDevice(identity.id) else { continue }
            guard connectedIDs.insert(identity.id).inserted else { continue }

            if let existing = existingByID[identity.id],
               existing.transport == .usb,
               existing.captureDevice?.uniqueID == captureDevice.uniqueID,
               existing.device.connectionState == .connected {
                disconnectedSince[identity.id] = nil
                var updatedSession = existing
                updatedSession.device = identity
                nextSessions.append(updatedSession)
            } else {
                let existing = existingByID[identity.id]
                let wasReconnecting = existing?.device.connectionState == .disconnected
                if let existing {
                    MirrorWindowRegistry.shared.close(session: existing)
                    existing.mirrorSession.dispose()
                    wirelessTransportTasks[existing.id]?.cancel()
                    wirelessTransportTasks[existing.id] = nil
                    existing.wirelessWDA?.stop()
                    existing.controlSession.stop(serverURL: appiumServerURL)
                    if desiredMirrorIDs.contains(identity.id) {
                        resumeAuthorizedIDs.insert(identity.id)
                    }
                }
                disconnectedSince[identity.id] = nil
                let session = DeviceSession(device: identity, captureDevice: captureDevice)
                session.mirrorSession.setAudioEnabled(Self.shouldCaptureAudio(
                    playbackEnabled: audioPlaybackEnabled,
                    authorizationStatus: microphonePermissionStatus
                ))
                nextSessions.append(session)
                if autoStartMirrors && !wasReconnecting {
                    autoStartIDs.insert(session.id)
                }
            }
        }

        // A USB screen source always wins for quality and latency. Only create
        // a wireless session when the same UDID was not discovered by AVFoundation.
        for wirelessDevice in wirelessDevices where !connectedIDs.contains(wirelessDevice.udid) {
            guard !isRemovedDevice(wirelessDevice.udid) else { continue }
            let identity = DeviceIdentity(
                id: wirelessDevice.udid,
                udid: wirelessDevice.udid,
                name: wirelessDevice.name,
                productType: wirelessDevice.productType,
                osVersion: wirelessDevice.osVersion,
                connectionState: wirelessDevice.isTunnelConnected ? .connected : .unavailable,
                trustState: .trusted
            )
            guard connectedIDs.insert(identity.id).inserted else { continue }

            if let existing = existingByID[identity.id],
               Self.canReuseWirelessSession(existing, for: wirelessDevice) {
                disconnectedSince[identity.id] = nil
                var updatedSession = existing
                updatedSession.device = identity
                // CoreDevice tunnel addresses and hostname ordering can change
                // between periodic discoveries. They are endpoint updates for
                // the same UDID, not a new mirror/control session. Replacing the
                // session here stops WDA and tears down a healthy SRT stream.
                updatedSession.wirelessDevice = wirelessDevice
                nextSessions.append(updatedSession)
            } else {
                let existing = existingByID[identity.id]
                let wasReconnecting = existing?.device.connectionState == .disconnected
                if let existing {
                    MirrorWindowRegistry.shared.close(session: existing)
                    existing.mirrorSession.dispose()
                    wirelessTransportTasks[existing.id]?.cancel()
                    wirelessTransportTasks[existing.id] = nil
                    existing.wirelessWDA?.stop()
                    existing.controlSession.stop(serverURL: appiumServerURL)
                    if desiredMirrorIDs.contains(identity.id) {
                        resumeAuthorizedIDs.insert(identity.id)
                    }
                }
                disconnectedSince[identity.id] = nil
                let session = DeviceSession(device: identity, wirelessDevice: wirelessDevice)
                nextSessions.append(session)
                if autoStartMirrors && !wasReconnecting {
                    autoStartIDs.insert(session.id)
                }
            }
        }


        for androidDevice in androidDevices {
            let identity = androidDevice.identity
            guard !isRemovedDevice(identity.id) else { continue }
            guard connectedIDs.insert(identity.id).inserted else { continue }

            if let existing = existingByID[identity.id],
               existing.platform == .android,
               existing.androidDevice == androidDevice,
               existing.device.connectionState == identity.connectionState {
                disconnectedSince[identity.id] = nil
                var updatedSession = existing
                updatedSession.device = identity
                nextSessions.append(updatedSession)
            } else {
                let existing = existingByID[identity.id]
                let wasReconnecting = existing?.device.connectionState == .disconnected
                if let existing {
                    MirrorWindowRegistry.shared.close(session: existing)
                    existing.mirrorSession.dispose()
                    existing.controlSession.stop(serverURL: appiumServerURL)
                    if desiredMirrorIDs.contains(identity.id) {
                        resumeAuthorizedIDs.insert(identity.id)
                    }
                }
                disconnectedSince[identity.id] = nil
                let session = DeviceSession(device: identity, androidDevice: androidDevice)
                session.mirrorSession.setAudioEnabled(audioPlaybackEnabled)
                nextSessions.append(session)
                if autoStartMirrors,
                   identity.connectionState == .connected,
                   !wasReconnecting {
                    autoStartIDs.insert(session.id)
                }
            }
        }

        for staleSession in sessions where !connectedIDs.contains(staleSession.id) {
            thumbnailCaptures[staleSession.id]?.cancel()
            thumbnailCaptures[staleSession.id] = nil

            if desiredMirrorIDs.contains(staleSession.id) || staleSession.mirrorSession.state == .running {
                desiredMirrorIDs.remove(staleSession.id)
                MirrorWindowRegistry.shared.close(session: staleSession)
                staleSession.mirrorSession.dispose()
                wirelessTransportTasks[staleSession.id]?.cancel()
                wirelessTransportTasks[staleSession.id] = nil
                staleSession.wirelessWDA?.stop()
                staleSession.controlSession.stop(serverURL: appiumServerURL)
                clearThumbnail(for: staleSession.id)
                disconnectedSince[staleSession.id] = disconnectedSince[staleSession.id] ?? now
                var disconnectedSession = staleSession
                disconnectedSession.device.connectionState = .disconnected
                nextSessions.append(disconnectedSession)
            } else if staleSession.device.connectionState == .disconnected,
                      now.timeIntervalSince(disconnectedSince[staleSession.id] ?? now) < Self.reconnectRetentionInterval {
                disconnectedSince[staleSession.id] = disconnectedSince[staleSession.id] ?? now
                nextSessions.append(staleSession)
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
        requestMirrorStarts(autoStartIDs, presentActivationWhenBlocked: false)
        for session in sessions where resumeAuthorizedIDs.contains(session.id) {
            prepareWirelessTransportIfNeeded(for: session)
            MirrorWindowRegistry.shared.openAuthorized(session: session, store: self)
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

    private func retire(_ session: DeviceSession) {
        desiredMirrorIDs.remove(session.id)
        pendingActivationMirrorIDs.remove(session.id)
        floatingMirrorIDs.remove(session.id)
        thumbnailCaptures[session.id]?.cancel()
        thumbnailCaptures[session.id] = nil
        wirelessThumbnailTasks[session.id]?.cancel()
        wirelessThumbnailTasks[session.id] = nil
        wirelessTransportTasks[session.id]?.cancel()
        wirelessTransportTasks[session.id] = nil
        clearThumbnail(for: session.id)
        disconnectedSince[session.id] = nil
        MirrorWindowRegistry.shared.close(session: session)
        session.mirrorSession.dispose()
        session.wirelessWDA?.stop()
        session.controlSession.stop(serverURL: appiumServerURL)
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

    func start(_ session: DeviceSession) {
        guard session.device.connectionState == .connected,
              session.platform == .android
                || session.transport == .wireless
                || permissionStatus == .authorized else { return }
        select(session)
        requestMirrorStarts([session.id])
    }

    func startAll() {
        requestMirrorStarts(Set(connectedSessions.map(\.id)))
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

    func presentControlSetup(for session: DeviceSession) {
        select(session)
        setActiveSheet(.controlSetup)
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
        let pending = pendingActivationMirrorIDs
        pendingActivationMirrorIDs.removeAll()
        setActiveSheet(nil)
        requestMirrorStarts(pending)
    }

    func stop(_ session: DeviceSession) {
        desiredMirrorIDs.remove(session.id)
        pendingActivationMirrorIDs.remove(session.id)
        wirelessTransportTasks[session.id]?.cancel()
        wirelessTransportTasks[session.id] = nil
        session.wirelessWDA?.stop()
        MirrorWindowRegistry.shared.close(session: session)
    }

    func stopAll() {
        desiredMirrorIDs.removeAll()
        pendingActivationMirrorIDs.removeAll()
        dismissActivationSheetIfPresented()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for session in sessions {
            wirelessTransportTasks[session.id]?.cancel()
            wirelessTransportTasks[session.id] = nil
            session.wirelessWDA?.stop()
            session.controlSession.stop(serverURL: appiumServerURL)
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
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        desiredMirrorIDs.removeAll()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for capture in thumbnailCaptures.values {
            capture.cancel()
        }
        thumbnailCaptures.removeAll()
        for task in wirelessThumbnailTasks.values {
            task.cancel()
        }
        wirelessThumbnailTasks.removeAll()
        for task in wirelessTransportTasks.values {
            task.cancel()
        }
        wirelessTransportTasks.removeAll()
        thumbnails.removeAll()
        thumbnailAspectRatios.removeAll()
        thumbnailErrors.removeAll()

        let activeSessions = sessions
        let serverURL = appiumServerURL
        for session in activeSessions {
            session.mirrorSession.dispose()
            session.wirelessWDA?.stop()
        }
        for session in activeSessions {
            await session.controlSession.shutdown(serverURL: serverURL)
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
        presentActivationWhenBlocked: Bool = true
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
        performAuthorizedStarts(decision.allowedIDs)
        if !decision.blockedIDs.isEmpty {
            pendingActivationMirrorIDs.formUnion(decision.blockedIDs)
            statusMessage = t("status.activationDeviceLimit")
            if presentActivationWhenBlocked {
                showActivation(for: decision.blockedIDs)
            }
        }
        return decision
    }

    private func performAuthorizedStarts(_ sessionIDs: Set<String>) {
        guard !isShuttingDown else { return }
        for session in sessions where sessionIDs.contains(session.id)
            && session.device.connectionState == .connected {
            guard session.platform == .android
                    || session.transport == .wireless
                    || permissionStatus == .authorized else { continue }
            desiredMirrorIDs.insert(session.id)
            prepareWirelessTransportIfNeeded(for: session)
            MirrorWindowRegistry.shared.openAuthorized(session: session, store: self)
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

    private func prepareWirelessTransportIfNeeded(for session: DeviceSession) {
        guard session.transport == .wireless,
              wirelessTransportTasks[session.id] == nil,
              let wirelessDevice = session.wirelessDevice,
              let wirelessWDA = session.wirelessWDA else { return }

        let sessionID = session.id
        let mirrorSession = session.mirrorSession
        wirelessTransportTasks[sessionID] = Task { @MainActor [weak self, weak wirelessWDA, weak mirrorSession] in
            await Task.yield()
            guard let self, let wirelessWDA, let mirrorSession, !self.isShuttingDown else { return }
            defer { self.wirelessTransportTasks[sessionID] = nil }

            await self.detectSigningTeams()
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            do {
                var resolvedEndpoint: WirelessWDAEndpoint?
                var lastError: Error?
                for attempt in 0..<3 {
                    do {
                        resolvedEndpoint = try await wirelessWDA.ensureRunning(
                            device: wirelessDevice,
                            configuration: self.controlConfiguration(for: session),
                            progress: { [weak self] progress in
                                await MainActor.run {
                                    guard let self else { return }
                                    let key = switch progress {
                                    case .checkingExistingAgent: "wireless.start.checkingAgent"
                                    case .connectingDevice: "wireless.start.connectingDevice"
                                    case .launchingInstalledAgent: "wireless.start.launchingAgent"
                                    case .preparingAgent: "wireless.start.preparingAgent"
                                    case .installingAgent: "wireless.start.installingAgent"
                                    case .waitingForAgent: "wireless.start.waitingForAgent"
                                    case .connectingVideo: "wireless.start.connectingVideo"
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
                              self.shouldRetryWirelessWDA(error),
                              self.desiredMirrorIDs.contains(sessionID),
                              !Task.isCancelled else {
                            throw error
                        }
                        let message = self.t("wireless.start.retryingAgent")
                        self.statusMessage = message
                        mirrorSession.updateWirelessStartupDetail(message)
                        try await Task.sleep(for: .seconds(attempt + 1))
                    }
                }
                guard let resolvedEndpoint else {
                    throw lastError ?? WirelessWDAError.launchFailed
                }
                guard !Task.isCancelled,
                      self.desiredMirrorIDs.contains(sessionID),
                      self.sessions.contains(where: {
                          $0.id == sessionID && $0.mirrorSession === mirrorSession
                      }) else { return }
                mirrorSession.connectWirelessVideo(host: resolvedEndpoint.videoHost)
            } catch is CancellationError {
                return
            } catch {
                let localizedMessage = self.wirelessWDAErrorMessage(error)
                mirrorSession.failWirelessStart(localizedMessage)
                if error as? WirelessWDAError == .localNetworkDenied {
                    self.statusMessage = self.t("status.wirelessLocalNetworkDenied")
                    self.setActiveSheet(.wirelessAccess)
                } else if error as? WirelessWDAError == .deviceLocked {
                    self.statusMessage = self.t("status.wirelessUnlockRequired")
                } else if error as? WirelessWDAError == .deviceUnavailable {
                    self.statusMessage = self.t("status.wirelessUnavailable")
                } else if error as? WirelessWDAError == .firstUSBSetupRequired {
                    self.statusMessage = localizedMessage
                    self.setActiveSheet(.wirelessSetup)
                } else {
                    self.statusMessage = localizedMessage
                }
            }
        }
    }

    private func shouldRetryWirelessWDA(_ error: Error) -> Bool {
        guard let wirelessError = error as? WirelessWDAError else { return true }
        return switch wirelessError {
        case .deviceUnavailable, .launchFailed, .timedOut:
            true
        case .missingSigningTeam, .missingRuntime, .firstUSBSetupRequired,
             .deviceLocked, .localNetworkDenied, .buildFailed:
            false
        }
    }

    private func wirelessWDAErrorMessage(_ error: Error) -> String {
        guard let wirelessError = error as? WirelessWDAError else {
            return error.localizedDescription
        }
        let key = switch wirelessError {
        case .missingSigningTeam: "wireless.error.missingSigningTeam"
        case .missingRuntime: "wireless.error.missingRuntime"
        case .firstUSBSetupRequired: "wireless.error.firstUSBSetupRequired"
        case .buildFailed: "wireless.error.buildFailed"
        case .launchFailed: "wireless.error.launchFailed"
        case .localNetworkDenied: "wireless.error.localNetworkDenied"
        case .deviceLocked: "wireless.error.deviceLocked"
        case .deviceUnavailable: "wireless.error.deviceUnavailable"
        case .timedOut: "wireless.error.timedOut"
        }
        return t(key)
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

    func prepareControl(
        for session: DeviceSession,
        configuration: AppiumControlConfiguration? = nil
    ) {
        guard !isShuttingDown,
              session.device.connectionState == .connected,
              session.device.udid?.isEmpty == false,
              !session.controlSession.isReady,
              session.controlSession.isConnecting else {
            return
        }

        session.controlSession.prepare(
            serverURL: appiumServerURL,
            bundleID: controlBundleID,
            configuration: configuration ?? controlConfiguration(for: session)
        ) { [weak self] message in
            guard let self, !self.isShuttingDown else { return }
            self.statusMessage = self.t(message)
            self.presentControlRecovery(for: session)
        }
    }

    private func presentControlRecovery(for session: DeviceSession) {
        if session.platform == .android {
            presentDiagnostics()
        } else {
            presentControlSetup(for: session)
        }
    }

    func connectControl(for session: DeviceSession) {
        guard !isShuttingDown,
              session.device.connectionState == .connected else { return }
        guard canStartControl(for: session) else {
            statusMessage = t("status.activationControlRequired")
            showActivation(for: [])
            return
        }
        guard session.device.udid?.isEmpty == false else {
            statusMessage = t("status.controlNoUDID")
            presentControlSetup(for: session)
            return
        }
        guard !session.controlSession.isReady, !session.controlSession.isConnecting else {
            return
        }
        if session.controlSession.resumeWarmSession(
            serverURL: appiumServerURL,
            bundleID: controlBundleID,
            configuration: controlConfiguration(for: session)
        ) {
            statusMessage = t("control.state.ready")
            return
        }
        statusMessage = t("status.controlPreparingAgent")
        session.controlSession.beginPreparingService()
        Task {
            let ready = await appiumService.ensureRunning(serverURL: appiumServerURL)
            guard !isShuttingDown else { return }
            if ready {
                guard session.controlSession.isConnecting else { return }
                if session.platform == .android {
                    prepareControl(for: session)
                    return
                }
                await detectSigningTeams()
                guard session.controlSession.isConnecting else { return }
                do {
                    let configuration = try await preparedControlConfiguration(for: session)
                    guard session.controlSession.isConnecting else { return }
                    prepareControl(for: session, configuration: configuration)
                } catch {
                    session.controlSession.failPreparation(error.localizedDescription)
                    statusMessage = error.localizedDescription
                    presentControlRecovery(for: session)
                }
            } else {
                statusMessage = t("status.controlAppiumUnavailable")
                session.controlSession.failPreparation("control.error.appiumUnavailable")
                presentControlRecovery(for: session)
            }
        }
    }

    func connectControlForAutomation(for session: DeviceSession) async throws {
        guard canStartControl(for: session) else {
            showActivation(for: [])
            throw DeviceAutomationError.activationRequired
        }
        guard !isShuttingDown, session.device.connectionState == .connected else {
            throw DeviceAutomationError.deviceUnavailable
        }
        guard session.device.udid?.isEmpty == false else {
            throw DeviceAutomationError.deviceUnavailable
        }
        if session.controlSession.isReady,
           await session.controlSession.verifyReadySession(serverURL: appiumServerURL) {
            return
        }
        if session.controlSession.resumeWarmSession(
            serverURL: appiumServerURL,
            bundleID: controlBundleID,
            configuration: controlConfiguration(for: session)
        ) {
            return
        }

        session.controlSession.beginPreparingService()
        let ready = await appiumService.ensureRunning(serverURL: appiumServerURL)
        guard !isShuttingDown else { throw CancellationError() }
        guard session.controlSession.isConnecting else { throw CancellationError() }
        guard ready else {
            session.controlSession.failPreparation("control.error.appiumUnavailable")
            throw DeviceAutomationError.appiumUnavailable
        }
        if session.platform == .android {
            prepareControl(for: session)
            try await waitForControlConnection(session)
            return
        }
        await detectSigningTeams()
        guard session.controlSession.isConnecting else { throw CancellationError() }
        let configuration = try await preparedControlConfiguration(for: session)
        guard session.controlSession.isConnecting else { throw CancellationError() }
        prepareControl(for: session, configuration: configuration)

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

    func startMirrorForAutomation(for session: DeviceSession) async throws {
        guard !isShuttingDown, session.device.connectionState == .connected else {
            throw DeviceAutomationError.deviceUnavailable
        }
        if session.mirrorSession.state == .running { return }

        let decision = requestMirrorStarts([session.id])
        if decision.blockedIDs.contains(session.id) {
            throw DeviceAutomationError.activationRequired
        }

        let deadline = ContinuousClock.now + .seconds(
            session.isIOSWireless ? 120 : 20
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
        session.controlSession.disconnectKeepingAgentWarm()
    }

    private func controlConfiguration(for session: DeviceSession) -> AppiumControlConfiguration {
        if session.platform == .android {
            return AppiumControlConfiguration(
                platform: .android,
                platformVersion: session.androidDevice?.osVersion ?? ""
            )
        }
        let hasCachedBuild = hasCachedWDABuild(for: session.device.udid)
        return AppiumControlConfiguration(
            platform: .iOS,
            xcodeOrgID: controlXcodeOrgID,
            xcodeSigningID: controlXcodeSigningID,
            wdaBundleID: effectiveControlWDABundleID,
            // On this Mac, a cached build is the fastest reliable restart:
            // xcodebuild uses test-without-building and avoids the RemoteXPC
            // preinstalled probe, which can otherwise wait for its full timeout.
            preferInstalledWDA: !hasCachedBuild,
            usePrebuiltWDA: hasCachedBuild,
            useNewWDA: false,
            derivedDataPath: wdaDerivedDataPath,
            directDeviceHost: session.wirelessDevice.map {
                $0.formattedPreferredEndpointHost
            } ?? "",
            platformVersion: session.wirelessDevice?.osVersion ?? "",
            xcodeConfigFile: srtXcodeConfigPath
        )
    }

    private var srtXcodeConfigPath: String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("StupidMirror/AppiumHome/stupidmirror-srt", isDirectory: true)
            .appendingPathComponent("StupidMirrorSRT.xcconfig")
            .path
    }

    private func preparedControlConfiguration(
        for session: DeviceSession
    ) async throws -> AppiumControlConfiguration {
        var configuration = controlConfiguration(for: session)
        guard let wirelessDevice = session.wirelessDevice,
              let wirelessWDA = session.wirelessWDA else {
            return configuration
        }
        // A running wireless mirror is direct evidence that this WDA instance
        // and endpoint are alive. Reuse that exact data plane for Appium
        // control; probing and falling through to install can replace the
        // runner that is currently producing the mirror stream.
        let endpoint: WirelessWDAEndpoint
        if session.mirrorSession.state == .running,
           let activeEndpoint = wirelessWDA.activeEndpoint {
            endpoint = activeEndpoint
        } else {
            endpoint = try await wirelessWDA.ensureRunning(
                device: wirelessDevice,
                configuration: configuration
            )
        }
        configuration.webDriverAgentURL = endpoint.controlURL.absoluteString
        configuration.preferInstalledWDA = false
        configuration.usePrebuiltWDA = false
        return configuration
    }

    private func hasCachedWDABuild(for udid: String?) -> Bool {
        guard let udid, !udid.isEmpty else { return false }
        return Self.hasCachedWDABuild(udid: udid, derivedDataPath: wdaDerivedDataPath)
    }

    nonisolated static func hasCachedWDABuild(udid: String, derivedDataPath: String) -> Bool {
        guard !udid.isEmpty else { return false }
        var base = AppiumControlConfiguration(derivedDataPath: derivedDataPath)
        base = base.isolated(forDeviceUDID: udid)
        let products = URL(fileURLWithPath: base.derivedDataPath, isDirectory: true)
            .appendingPathComponent("Build/Products", isDirectory: true)
        let runner = products
            .appendingPathComponent("Debug-iphoneos", isDirectory: true)
            .appendingPathComponent("WebDriverAgentRunner-Runner.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: runner.path) else { return false }
        let h264ServerBinary = runner
            .appendingPathComponent("PlugIns/WebDriverAgentRunner.xctest/Frameworks/WebDriverAgentLib.framework")
            .appendingPathComponent("WebDriverAgentLib")
        guard let binaryData = try? Data(contentsOf: h264ServerBinary, options: .mappedIfSafe),
              binaryData.range(of: Data("StupidMirror SRT/H.264 stream".utf8)) != nil else {
            return false
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.pathExtension == "xctestrun" }
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
        session.controlSession.tapNormalized(
            x: normalizedX,
            y: normalizedY,
            serverURL: appiumServerURL
        )
    }

    func swipeControl(for session: DeviceSession, from start: CGPoint, to end: CGPoint, durationMS: Int) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.swipeNormalized(
            from: start,
            to: end,
            durationMS: durationMS,
            serverURL: appiumServerURL
        )
    }

    func flickControl(for session: DeviceSession, direction: ControlFlickDirection) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.flick(direction, serverURL: appiumServerURL)
    }

    func typeControlText(_ text: String, for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session), !text.isEmpty else { return }
        session.controlSession.typeText(text, serverURL: appiumServerURL)
    }

    func pressHome(for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.pressHome(serverURL: appiumServerURL)
    }

    func openAppSwitcher(for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.openAppSwitcher(serverURL: appiumServerURL)
    }

    func pressBack(for session: DeviceSession) {
        guard prepareQueuedControlAction(for: session) else { return }
        session.controlSession.pressBack(serverURL: appiumServerURL)
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

    private func canStartControl(for session: DeviceSession) -> Bool {
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
            session.controlSession.stop(serverURL: appiumServerURL)
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
        if let profile = DeviceDisplayProfile.profile(for: session.device.productType, name: session.device.name) {
            return profile.aspectRatio
        }
        if let aspect = thumbnailAspectRatios[session.id], aspect > 0 {
            return aspect
        }
        if let aspect = session.controlSession.screenSize?.aspectRatio, aspect > 0 {
            return aspect
        }
        return 1260.0 / 2736.0
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
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
                }
            }
        )
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
            captureAndroidThumbnail(for: session, serial: androidDevice.serial)
            return
        }
        if session.transport == .wireless {
            captureWirelessThumbnail(for: session)
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

    private func captureAndroidThumbnail(for session: DeviceSession, serial: String) {
        guard wirelessThumbnailTasks[session.id] == nil else { return }
        let sessionID = session.id
        wirelessThumbnailTasks[sessionID] = Task { @MainActor [weak self] in
            defer { self?.wirelessThumbnailTasks[sessionID] = nil }
            guard let self else { return }
            do {
                let data = try await Task.detached(priority: .utility) {
                    try AndroidADBService.captureScreenshot(serial: serial)
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

    private func captureWirelessThumbnail(for session: DeviceSession) {
        guard session.controlSession.isReady,
              wirelessThumbnailTasks[session.id] == nil else { return }
        let sessionID = session.id
        let serverURL = appiumServerURL
        wirelessThumbnailTasks[sessionID] = Task { @MainActor [weak self, weak controlSession = session.controlSession] in
            defer { self?.wirelessThumbnailTasks[sessionID] = nil }
            guard let self, let controlSession else { return }
            do {
                let data = try await controlSession.screenshot(serverURL: serverURL)
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
            } catch is CancellationError {
                return
            } catch {
                self.thumbnailErrors[sessionID] = error.localizedDescription
            }
        }
    }
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
