@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class DeviceGalleryStore: ObservableObject {
    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var permissionStatus: AVAuthorizationStatus = AVFoundationMirrorBackend.authorizationStatus()
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
    @Published var showsDiagnostics = false
    @Published var showsSettings = false
    @Published var selectedSessionID: String?
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey)
            statusMessage = localizedStatusMessage
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var thumbnailCaptures: [String: ThumbnailCapture] = [:]
    private var desiredMirrorIDs = Set<String>()
    private var lastConnectedCount = 0
    private var lastReconnectingCount = 0

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

    init() {
        language = Self.initialLanguage
        let status = AVFoundationMirrorBackend.allowScreenCaptureDevices()
        statusMessage = "CoreMediaIO screen capture devices enabled: \(status)"
        installDeviceObservers()
        startPeriodicRefresh()
        Task {
            await ensureAccessAndRefresh()
        }
    }

    func ensureAccessAndRefresh() async {
        let granted = await AVFoundationMirrorBackend.requestVideoAccess()
        permissionStatus = AVFoundationMirrorBackend.authorizationStatus()
        guard granted else {
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

    func recheckCameraPermission() {
        permissionStatus = AVFoundationMirrorBackend.authorizationStatus()
        if permissionStatus == .authorized {
            refresh()
        } else {
            statusMessage = t("status.permissionRequired")
        }
    }

    func refresh() {
        guard permissionStatus == .authorized else { return }
        AVFoundationMirrorBackend.warmUpDiscovery()
        let devices = AVFoundationMirrorBackend.discoverMuxedDevices()
        let metadata = DeviceMetadataService.connectedDevices()
        let existingByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var nextSessions: [DeviceSession] = []
        var connectedIDs = Set<String>()

        for captureDevice in devices {
            let match = DeviceMetadataService.bestMatch(
                for: captureDevice.localizedName,
                modelID: captureDevice.modelID,
                candidates: metadata
            )
            let identity = AVFoundationMirrorBackend.identity(for: captureDevice, metadata: match)
            connectedIDs.insert(identity.id)

            if let existing = existingByID[identity.id],
               existing.captureDevice.uniqueID == captureDevice.uniqueID,
               existing.device.connectionState == .connected {
                var updatedSession = existing
                updatedSession.device = identity
                nextSessions.append(updatedSession)
            } else {
                let existing = existingByID[identity.id]
                let wasReconnecting = existing?.device.connectionState == .disconnected
                existing?.mirrorSession.stop()
                let session = DeviceSession(device: identity, captureDevice: captureDevice)
                nextSessions.append(session)
                if autoStartMirrors && !wasReconnecting {
                    desiredMirrorIDs.insert(session.id)
                    MirrorWindowRegistry.shared.open(session: session, store: self)
                }
            }
        }

        for staleSession in sessions where !connectedIDs.contains(staleSession.id) {
            thumbnailCaptures[staleSession.id]?.cancel()
            thumbnailCaptures[staleSession.id] = nil

            if desiredMirrorIDs.contains(staleSession.id) || staleSession.mirrorSession.state == .running {
                desiredMirrorIDs.remove(staleSession.id)
                MirrorWindowRegistry.shared.close(session: staleSession)
                var disconnectedSession = staleSession
                disconnectedSession.device.connectionState = .disconnected
                nextSessions.append(disconnectedSession)
            } else if staleSession.device.connectionState == .disconnected {
                nextSessions.append(staleSession)
            } else {
                staleSession.mirrorSession.stop()
                thumbnails[staleSession.id] = nil
                thumbnailAspectRatios[staleSession.id] = nil
                thumbnailErrors[staleSession.id] = nil
            }
        }

        sessions = nextSessions.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = sessions.first?.id
        } else if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }
        lastRefresh = Date()
        lastConnectedCount = connectedSessions.count
        lastReconnectingCount = reconnectingSessions.count
        statusMessage = localizedStatusMessage

        for session in connectedSessions where thumbnails[session.id] == nil && thumbnailCaptures[session.id] == nil {
            captureThumbnail(for: session)
        }
    }

    func start(_ session: DeviceSession) {
        guard session.device.connectionState == .connected else { return }
        select(session)
        desiredMirrorIDs.insert(session.id)
        MirrorWindowRegistry.shared.open(session: session, store: self)
    }

    func stop(_ session: DeviceSession) {
        desiredMirrorIDs.remove(session.id)
        MirrorWindowRegistry.shared.close(session: session)
    }

    func stopAll() {
        desiredMirrorIDs.removeAll()
        MirrorWindowRegistry.shared.closeAll(sessions: sessions)
        for session in sessions {
            session.controlSession.stop(serverURL: appiumServerURL)
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
        guard session.device.connectionState == .connected,
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
        guard session.device.connectionState == .connected else { return }
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

    func swipeControl(for session: DeviceSession, from start: CGPoint, to end: CGPoint) {
        print("StupidMirror control swipe \(session.device.name): \(start) -> \(end)")
        session.controlSession.swipeNormalized(from: start, to: end, serverURL: appiumServerURL)
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.permissionStatus = AVFoundationMirrorBackend.authorizationStatus()
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
