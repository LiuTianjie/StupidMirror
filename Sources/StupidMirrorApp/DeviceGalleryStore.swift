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

    var id: String { rawValue }

    static func toggling(_ target: DashboardSheet, from current: DashboardSheet?) -> DashboardSheet? {
        current == target ? nil : target
    }
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
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var shutdownTask: Task<Void, Never>?
    private var refreshRequestedWhileRunning = false
    private var thumbnailCaptures: [String: ThumbnailCapture] = [:]
    private var desiredMirrorIDs = Set<String>()
    private var pendingAuthorizationMirrorIDs = Set<String>()
    private var pendingActivationMirrorIDs = Set<String>()
    private var startAuthorizationTask: Task<Void, Never>?
    private var startAuthorizationGeneration: UInt64 = 0
    private var disconnectedSince: [String: Date] = [:]
    private var lastConnectedCount = 0
    private var lastReconnectingCount = 0
    private var isShuttingDown = false

    private static let periodicRefreshInterval: TimeInterval = 10
    private static let reconnectRetentionInterval: TimeInterval = 30
    private static let maxRetainedDisconnectedSessions = 4

    private static let languageDefaultsKey = "StupidMirror.language"
    private static let autoStartMirrorsDefaultsKey = "StupidMirror.autoStartMirrors"
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
        [
            DiagnosticItem(name: t("diagnostic.camera"), value: authorizationLabel(permissionStatus)),
            DiagnosticItem(name: t("diagnostic.microphone"), value: authorizationLabel(microphonePermissionStatus)),
            DiagnosticItem(name: t("diagnostic.backend"), value: "CoreMediaIO + AVFoundation"),
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
            DiagnosticItem(name: t("diagnostic.libimobiledevice"), value: DeviceMetadataService.isAvailable ? t("connection.connected") : t("appium.state.missing"))
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
        installDeviceObservers()
        startPeriodicRefresh()
        refreshIfCameraAuthorized()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.licenseManager.bootstrap()
            await self.mcpServer.startIfEnabled()
        }
    }

    func refreshIfCameraAuthorized() {
        permissionStatus = AVFoundationMirrorBackend.videoAuthorizationStatus()
        microphonePermissionStatus = AVFoundationMirrorBackend.audioAuthorizationStatus()
        guard permissionStatus == .authorized else {
            statusMessage = t("status.permissionRequired")
            return
        }
        refresh()
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
        let previous = permissionStatus
        permissionStatus = status
        guard previous == .authorized, status != .authorized else { return }

        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileRunning = false
        desiredMirrorIDs.removeAll()
        pendingAuthorizationMirrorIDs.removeAll()
        pendingActivationMirrorIDs.removeAll()
        startAuthorizationTask?.cancel()
        startAuthorizationTask = nil
        startAuthorizationGeneration &+= 1
        dismissActivationSheetIfPresented()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for session in sessions {
            session.mirrorSession.dispose()
            session.controlSession.stop(serverURL: appiumServerURL)
        }
        for capture in thumbnailCaptures.values {
            capture.cancel()
        }
        thumbnailCaptures.removeAll()
        thumbnails.removeAll()
        thumbnailAspectRatios.removeAll()
        thumbnailErrors.removeAll()
        disconnectedSince.removeAll()
        floatingMirrorIDs.removeAll()
        sessions.removeAll()
        selectedSessionID = nil
        lastConnectedCount = 0
        lastReconnectingCount = 0
        statusMessage = t("status.permissionRequired")
    }

    private func updateMicrophonePermissionStatus(_ status: AVAuthorizationStatus) {
        microphonePermissionStatus = status
        applyAudioPlaybackPreference()
    }

    private func applyAudioPlaybackPreference() {
        let audioEnabled = Self.shouldCaptureAudio(
            playbackEnabled: audioPlaybackEnabled,
            authorizationStatus: microphonePermissionStatus
        )
        for session in sessions {
            session.mirrorSession.setAudioEnabled(audioEnabled)
        }
    }

    nonisolated static func shouldCaptureAudio(
        playbackEnabled: Bool,
        authorizationStatus: AVAuthorizationStatus
    ) -> Bool {
        playbackEnabled && authorizationStatus == .authorized
    }

    func refresh() {
        guard permissionStatus == .authorized, !isShuttingDown else { return }
        guard refreshTask == nil else {
            refreshRequestedWhileRunning = true
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            let metadata = await Task.detached(priority: .utility) {
                DeviceMetadataService.connectedDevices()
            }.value
            guard let self else { return }
            guard self.refreshGeneration == generation else { return }
            guard !Task.isCancelled, self.permissionStatus == .authorized, !self.isShuttingDown else {
                self.finishRefresh(generation: generation)
                return
            }

            let devices = AVFoundationMirrorBackend.discoverMuxedDevices()
            guard self.refreshGeneration == generation, !Task.isCancelled else { return }
            self.applyRefresh(devices: devices, metadata: metadata)
            self.finishRefresh(generation: generation)
        }
    }

    func refreshForAutomation() async throws {
        guard permissionStatus == .authorized else {
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

    private func applyRefresh(devices: [AVCaptureDevice], metadata: [DeviceMetadata]) {
        let existingByID = Self.latestValueByID(sessions) { $0.id }
        var nextSessions: [DeviceSession] = []
        var connectedIDs = Set<String>()
        var autoStartIDs = Set<String>()
        let now = Date()

        for captureDevice in devices {
            let match = DeviceMetadataService.bestMatch(
                for: captureDevice.localizedName,
                modelID: captureDevice.modelID,
                candidates: metadata
            )
            let identity = AVFoundationMirrorBackend.identity(for: captureDevice, metadata: match)
            guard connectedIDs.insert(identity.id).inserted else { continue }

            if let existing = existingByID[identity.id],
               existing.captureDevice.uniqueID == captureDevice.uniqueID,
               existing.device.connectionState == .connected {
                disconnectedSince[identity.id] = nil
                var updatedSession = existing
                updatedSession.device = identity
                nextSessions.append(updatedSession)
            } else {
                let existing = existingByID[identity.id]
                let wasReconnecting = existing?.device.connectionState == .disconnected
                existing?.mirrorSession.stop()
                existing?.controlSession.stop(serverURL: appiumServerURL)
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

        for staleSession in sessions where !connectedIDs.contains(staleSession.id) {
            thumbnailCaptures[staleSession.id]?.cancel()
            thumbnailCaptures[staleSession.id] = nil

            if desiredMirrorIDs.contains(staleSession.id) || staleSession.mirrorSession.state == .running {
                desiredMirrorIDs.remove(staleSession.id)
                MirrorWindowRegistry.shared.close(session: staleSession)
                staleSession.mirrorSession.dispose()
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
        requestMirrorStarts(autoStartIDs)
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

    private func retire(_ session: DeviceSession) {
        desiredMirrorIDs.remove(session.id)
        pendingAuthorizationMirrorIDs.remove(session.id)
        pendingActivationMirrorIDs.remove(session.id)
        floatingMirrorIDs.remove(session.id)
        thumbnailCaptures[session.id]?.cancel()
        thumbnailCaptures[session.id] = nil
        clearThumbnail(for: session.id)
        disconnectedSince[session.id] = nil
        MirrorWindowRegistry.shared.close(session: session)
        session.mirrorSession.dispose()
        session.controlSession.stop(serverURL: appiumServerURL)
    }

    func start(_ session: DeviceSession) {
        guard permissionStatus == .authorized,
              session.device.connectionState == .connected else { return }
        select(session)
        requestMirrorStarts([session.id])
    }

    func startAll() {
        guard permissionStatus == .authorized else { return }
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
        pendingAuthorizationMirrorIDs.remove(session.id)
        pendingActivationMirrorIDs.remove(session.id)
        MirrorWindowRegistry.shared.close(session: session)
    }

    func stopAll() {
        desiredMirrorIDs.removeAll()
        pendingAuthorizationMirrorIDs.removeAll()
        pendingActivationMirrorIDs.removeAll()
        startAuthorizationTask?.cancel()
        startAuthorizationTask = nil
        startAuthorizationGeneration &+= 1
        dismissActivationSheetIfPresented()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for session in sessions {
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
        startAuthorizationTask?.cancel()
        startAuthorizationTask = nil
        startAuthorizationGeneration &+= 1
        pendingAuthorizationMirrorIDs.removeAll()
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
        thumbnails.removeAll()
        thumbnailAspectRatios.removeAll()
        thumbnailErrors.removeAll()

        let activeSessions = sessions
        let serverURL = appiumServerURL
        for session in activeSessions {
            session.mirrorSession.dispose()
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

    private func requestMirrorStarts(_ sessionIDs: Set<String>) {
        guard !isShuttingDown, permissionStatus == .authorized, !sessionIDs.isEmpty else { return }

        let connectedIDs = Set(connectedSessions.map(\.id))
        pendingAuthorizationMirrorIDs.formUnion(sessionIDs.intersection(connectedIDs))
        guard !pendingAuthorizationMirrorIDs.isEmpty, startAuthorizationTask == nil else { return }

        startAuthorizationGeneration &+= 1
        let generation = startAuthorizationGeneration
        startAuthorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let authorization = await self.licenseManager.authorizeMirrorStart()
            guard generation == self.startAuthorizationGeneration else { return }
            guard !Task.isCancelled, !self.isShuttingDown else {
                self.startAuthorizationTask = nil
                return
            }

            let requestedIDs = self.pendingAuthorizationMirrorIDs
            self.pendingAuthorizationMirrorIDs.removeAll()
            self.startAuthorizationTask = nil

            switch authorization {
            case .allowed:
                self.performAuthorizedStarts(requestedIDs)
            case .activationRequired:
                self.showActivation(for: requestedIDs)
            case let .unavailable(message):
                self.statusMessage = message
            }
        }
    }

    private func performAuthorizedStarts(_ sessionIDs: Set<String>) {
        guard permissionStatus == .authorized, !isShuttingDown else { return }
        for session in sessions where sessionIDs.contains(session.id)
            && session.device.connectionState == .connected {
            desiredMirrorIDs.insert(session.id)
            MirrorWindowRegistry.shared.openAuthorized(session: session, store: self)
        }
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

    func prepareControl(for session: DeviceSession) {
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
            configuration: controlConfiguration(for: session)
        ) { [weak self] message in
            guard let self, !self.isShuttingDown else { return }
            self.statusMessage = self.t(message)
            self.presentControlSetup(for: session)
        }
    }

    func connectControl(for session: DeviceSession) {
        guard !isShuttingDown,
              session.device.connectionState == .connected else { return }
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
                await detectSigningTeams()
                guard session.controlSession.isConnecting else { return }
                prepareControl(for: session)
            } else {
                statusMessage = t("status.controlAppiumUnavailable")
                session.controlSession.failPreparation("control.error.appiumUnavailable")
                presentControlSetup(for: session)
            }
        }
    }

    func connectControlForAutomation(for session: DeviceSession) async throws {
        guard !isShuttingDown, session.device.connectionState == .connected else {
            throw DeviceAutomationError.deviceUnavailable
        }
        guard session.device.udid?.isEmpty == false else {
            throw DeviceAutomationError.deviceUnavailable
        }
        if session.controlSession.isReady { return }
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
        await detectSigningTeams()
        guard session.controlSession.isConnecting else { throw CancellationError() }
        prepareControl(for: session)

        let deadline = ContinuousClock.now + .seconds(240)
        while !session.controlSession.isReady {
            if case let .failed(message) = session.controlSession.state {
                throw DeviceAutomationError.controlFailed(t(message))
            }
            guard ContinuousClock.now < deadline else {
                throw DeviceAutomationError.timedOut("Connecting iPhone control timed out.")
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

        switch await licenseManager.authorizeMirrorStart() {
        case .allowed:
            performAuthorizedStarts([session.id])
        case .activationRequired:
            showActivation(for: [session.id])
            throw DeviceAutomationError.activationRequired
        case let .unavailable(message):
            throw DeviceAutomationError.licenseUnavailable(message)
        }

        let deadline = ContinuousClock.now + .seconds(20)
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
        guard !isDetectingSigningTeams else { return }
        isDetectingSigningTeams = true
        let teams = await XcodeSigningTeamDetector.detect()
        detectedSigningTeams = teams
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
        let hasCachedBuild = hasCachedWDABuild(for: session.device.udid)
        return AppiumControlConfiguration(
            xcodeOrgID: controlXcodeOrgID,
            xcodeSigningID: controlXcodeSigningID,
            wdaBundleID: effectiveControlWDABundleID,
            // On this Mac, a cached build is the fastest reliable restart:
            // xcodebuild uses test-without-building and avoids the RemoteXPC
            // preinstalled probe, which can otherwise wait for its full timeout.
            preferInstalledWDA: !hasCachedBuild,
            usePrebuiltWDA: hasCachedBuild,
            useNewWDA: false,
            derivedDataPath: wdaDerivedDataPath
        )
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
        performControlAction {
            try await self.automationService.tap(
                deviceID: session.id, x: normalizedX, y: normalizedY
            )
        }
    }

    func swipeControl(for session: DeviceSession, from start: CGPoint, to end: CGPoint, durationMS: Int) {
        performControlAction {
            try await self.automationService.swipe(
                deviceID: session.id,
                startX: start.x,
                startY: start.y,
                endX: end.x,
                endY: end.y,
                durationMS: durationMS
            )
        }
    }

    func flickControl(for session: DeviceSession, direction: ControlFlickDirection) {
        performControlAction {
            try await self.automationService.flick(deviceID: session.id, direction: direction)
        }
    }

    func typeControlText(_ text: String, for session: DeviceSession) {
        performControlAction {
            try await self.automationService.typeText(deviceID: session.id, text: text)
        }
    }

    func pressHome(for session: DeviceSession) {
        performControlAction {
            try await self.automationService.pressButton(deviceID: session.id, name: "home")
        }
    }

    func openAppSwitcher(for session: DeviceSession) {
        performControlAction {
            try await self.automationService.appSwitcher(deviceID: session.id)
        }
    }

    func pressBack(for session: DeviceSession) {
        performControlAction {
            try await self.automationService.back(deviceID: session.id)
        }
    }

    private func performControlAction(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do {
                try await action()
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
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
                guard self.permissionStatus == .authorized else { return }
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
        guard thumbnailCaptures[session.id] == nil else { return }

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
            try capture.start(device: session.captureDevice)
        } catch {
            thumbnailCaptures[session.id] = nil
            thumbnailErrors[session.id] = error.localizedDescription
        }
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
