@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

enum DashboardSheet: String, Identifiable, Equatable, Sendable {
    case diagnostics
    case settings
    case activation

    var id: String { rawValue }

    static func toggling(_ target: DashboardSheet, from current: DashboardSheet?) -> DashboardSheet? {
        current == target ? nil : target
    }
}

@MainActor
final class DeviceGalleryStore: ObservableObject {
    let licenseManager: LicenseManager

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
        fallback: "com.apple.Preferences"
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
    @Published var controlUsePrebuiltWDA = DeviceGalleryStore.boolDefault(
        DeviceGalleryStore.controlUsePrebuiltWDADefaultsKey,
        env: "STUPIDMIRROR_USE_PREBUILT_WDA",
        info: "StupidMirrorDefaultUsePrebuiltWDA",
        fallback: false
    ) {
        didSet { UserDefaults.standard.set(controlUsePrebuiltWDA, forKey: Self.controlUsePrebuiltWDADefaultsKey) }
    }
    @Published private(set) var activeSheet: DashboardSheet?
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
    private static let appiumServerURLDefaultsKey = "StupidMirror.appiumServerURL"
    private static let controlBundleIDDefaultsKey = "StupidMirror.controlBundleID"
    private static let controlXcodeOrgIDDefaultsKey = "StupidMirror.controlXcodeOrgID"
    private static let controlXcodeSigningIDDefaultsKey = "StupidMirror.controlXcodeSigningID"
    private static let controlWDABundleIDDefaultsKey = "StupidMirror.controlWDABundleID"
    private static let controlUsePrebuiltWDADefaultsKey = "StupidMirror.controlUsePrebuiltWDA"

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

    private static func boolDefault(_ key: String, env: String, info: String, fallback: Bool) -> Bool {
        if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: info) as? Bool {
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
            DiagnosticItem(name: t("diagnostic.controlBundle"), value: controlBundleID),
            DiagnosticItem(name: t("diagnostic.xcodeTeam"), value: controlXcodeOrgID.isEmpty ? t("common.notSet") : controlXcodeOrgID),
            DiagnosticItem(name: t("diagnostic.wdaBundle"), value: controlWDABundleID.isEmpty ? t("common.default") : controlWDABundleID),
            DiagnosticItem(name: t("diagnostic.libimobiledevice"), value: DeviceMetadataService.isAvailable ? t("connection.connected") : t("appium.state.missing"))
        ]
    }

    var connectedSessions: [DeviceSession] {
        sessions.filter { $0.device.connectionState == .connected }
    }

    var reconnectingSessions: [DeviceSession] {
        sessions.filter { $0.device.connectionState == .disconnected }
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
            await self?.licenseManager.bootstrap()
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
        _ = await AVFoundationMirrorBackend.requestAudioAccess()
        updateMicrophonePermissionStatus(AVFoundationMirrorBackend.audioAuthorizationStatus())
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
        guard microphonePermissionStatus != status else { return }
        microphonePermissionStatus = status
        let audioEnabled = status == .authorized
        for session in sessions {
            session.mirrorSession.setAudioEnabled(audioEnabled)
        }
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
                session.mirrorSession.setAudioEnabled(microphonePermissionStatus == .authorized)
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
        setActiveSheet(.settings)
    }

    func presentDiagnostics() {
        setActiveSheet(.diagnostics)
    }

    func toggleSettings() {
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
              !session.controlSession.isConnecting else {
            return
        }

        session.controlSession.prepare(
            serverURL: appiumServerURL,
            bundleID: controlBundleID,
            configuration: AppiumControlConfiguration(
                xcodeOrgID: controlXcodeOrgID,
                xcodeSigningID: controlXcodeSigningID,
                wdaBundleID: controlWDABundleID,
                usePrebuiltWDA: controlUsePrebuiltWDA,
                useNewWDA: false,
                derivedDataPath: wdaDerivedDataPath
            )
        )
    }

    func connectControl(for session: DeviceSession) {
        guard !isShuttingDown,
              session.device.connectionState == .connected else { return }
        guard session.device.udid?.isEmpty == false else {
            statusMessage = t("status.controlNoUDID")
            return
        }
        guard !session.controlSession.isReady, !session.controlSession.isConnecting else {
            return
        }

        statusMessage = t("status.controlPreparingAgent")
        Task {
            let ready = await appiumService.ensureRunning(serverURL: appiumServerURL)
            guard !isShuttingDown else { return }
            if ready {
                prepareControl(for: session)
            } else {
                statusMessage = t("status.controlAppiumUnavailable")
            }
        }
    }

    func stopControl(for session: DeviceSession) {
        session.controlSession.stop(serverURL: appiumServerURL)
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

    func tapControl(for session: DeviceSession, normalizedX: Double, normalizedY: Double) {
        print("StupidMirror control tap \(session.device.name): \(normalizedX), \(normalizedY)")
        session.controlSession.tapNormalized(x: normalizedX, y: normalizedY, serverURL: appiumServerURL)
    }

    func swipeControl(for session: DeviceSession, from start: CGPoint, to end: CGPoint, durationMS: Int) {
        session.controlSession.swipeNormalized(from: start, to: end, durationMS: durationMS, serverURL: appiumServerURL)
    }

    func typeControlText(_ text: String, for session: DeviceSession) {
        session.controlSession.typeText(text, serverURL: appiumServerURL)
    }

    func pressHome(for session: DeviceSession) {
        session.controlSession.pressHome(serverURL: appiumServerURL)
    }

    func openAppSwitcher(for session: DeviceSession) {
        session.controlSession.openAppSwitcher(serverURL: appiumServerURL)
    }

    func pressBack(for session: DeviceSession) {
        session.controlSession.pressBack(serverURL: appiumServerURL)
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
