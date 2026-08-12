import Foundation

struct AppiumControlConfiguration: Hashable, Sendable {
    var xcodeOrgID: String = ""
    var xcodeSigningID: String = "Apple Development"
    var wdaBundleID: String = ""
    var preferInstalledWDA: Bool = true
    var usePreinstalledWDA: Bool = false
    var usePrebuiltWDA: Bool = false
    var useNewWDA: Bool = false
    var derivedDataPath: String = ""
    var wdaLocalPort: Int = 8100
    var mjpegServerPort: Int = 9100
    var wdaStartupRetries: Int = 1
    var wdaStartupRetryIntervalMS: Int = 0
    var wdaLaunchTimeoutMS: Int = 90_000
    var wdaConnectionTimeoutMS: Int = 45_000
    var sessionStartupTimeoutSeconds: TimeInterval = 125
    var preinstalledWDAStartupTimeoutSeconds: TimeInterval = 15
    var newCommandTimeoutSeconds: Int = 300
    var allowProvisioningDeviceRegistration: Bool = true
    var directDeviceHost: String = ""
    var platformVersion: String = ""
    var webDriverAgentURL: String = ""
    var xcodeConfigFile: String = ""

    var installationWDABundleID: String {
        let configured = wdaBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }

        let team = xcodeOrgID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !team.isEmpty else { return "" }
        return "com.stupidmirror.wda.\(team)"
    }

    /// Launching an already-installed WDA should never spill into the full
    /// source-build budget. Keep one Appium-owned attempt and leave enough
    /// HTTP headroom for Appium to report the result before our request times
    /// out. This prevents a fallback build from overlapping a still-running
    /// preinstalled-WDA request on the same device.
    var preinstalledProbeConfiguration: Self {
        var result = self
        result.usePreinstalledWDA = true
        result.usePrebuiltWDA = false
        result.useNewWDA = false
        result.wdaStartupRetries = 1
        result.wdaStartupRetryIntervalMS = 0
        result.wdaLaunchTimeoutMS = min(result.wdaLaunchTimeoutMS, 12_000)
        result.wdaConnectionTimeoutMS = min(result.wdaConnectionTimeoutMS, 10_000)
        result.sessionStartupTimeoutSeconds = min(
            result.sessionStartupTimeoutSeconds,
            result.preinstalledWDAStartupTimeoutSeconds
        )
        return result
    }

    /// Appium's default WDA ports and a shared DerivedData directory cannot be
    /// used safely by simultaneous devices. Keep the two port ranges disjoint
    /// and derive a stable per-device directory from the complete UDID.
    func isolated(forDeviceUDID udid: String) -> Self {
        let normalizedUDID = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUDID.isEmpty else { return self }

        let hash = StableDeviceHash.fnv1a64(normalizedUDID)
        let slot = Int(hash % 20_000)
        var result = self
        if directDeviceHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.wdaLocalPort = 10_000 + slot
            result.mjpegServerPort = 30_000 + slot
        } else {
            // Direct Wi-Fi connections are isolated by device hostname, so all
            // devices can use WDA's standard remote ports without Mac-side forwarding.
            result.wdaLocalPort = 8_100
            result.mjpegServerPort = 9_100
        }

        let basePath = derivedDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL
        if basePath.isEmpty {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            baseURL = applicationSupport
                .appendingPathComponent("StupidMirror", isDirectory: true)
                .appendingPathComponent("WebDriverAgentDerivedData", isDirectory: true)
        } else {
            baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
        }
        result.derivedDataPath = baseURL
            .appendingPathComponent(String(format: "device-%016llx", hash), isDirectory: true)
            .path
        return result
    }
}

private enum StableDeviceHash {
    static func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

@MainActor
final class AppiumControlSession: ObservableObject, @unchecked Sendable {
    @Published private(set) var state: ControlState = .unavailable
    @Published private(set) var screenSize: DeviceScreenSize?
    @Published private(set) var statusMessage: String = "Control not connected"
    @Published private(set) var connectionPhase: ControlConnectionPhase?
    @Published private(set) var connectionStartedAt: Date?

    private let device: DeviceIdentity
    private var sessionID: String?
    private var sessionServerURL: String?
    private var connectionTask: Task<Void, Never>?
    private var connectionRequest: ConnectionRequest?
    private var cleanupTask: Task<Void, Never>?
    private var actionPumpTask: Task<Void, Never>?
    private var warmDisconnectedAt: Date?
    private var pendingActions = ControlActionBuffer()
    private var generation: UInt64 = 0

    init(device: DeviceIdentity) {
        self.device = device
    }

    var isReady: Bool {
        if case .ready = state {
            true
        } else {
            false
        }
    }

    var isConnecting: Bool {
        if case .connecting = state {
            true
        } else {
            false
        }
    }

    func beginPreparingService() {
        guard sessionID == nil, connectionTask == nil else { return }
        state = .connecting
        connectionPhase = .startingService
        connectionStartedAt = Date()
        statusMessage = "Checking local Appium service..."
    }

    func failPreparation(_ message: String) {
        guard sessionID == nil, connectionTask == nil else { return }
        state = .failed(message)
        connectionPhase = nil
        connectionStartedAt = nil
        statusMessage = message
    }

    #if DEBUG
    func showConnectionPreview(phase: ControlConnectionPhase, elapsedSeconds: TimeInterval) {
        state = .connecting
        connectionPhase = phase
        connectionStartedAt = Date().addingTimeInterval(-elapsedSeconds)
        statusMessage = "Control connection preview"
    }

    func installWarmSessionForTesting(
        serverURL: String,
        bundleID: String,
        configuration: AppiumControlConfiguration,
        screenSize: DeviceScreenSize
    ) {
        guard let udid = device.udid else { return }
        let request = ConnectionRequest(
            serverURL: AppiumHTTPClient.normalizedBaseURLString(serverURL),
            bundleID: bundleID,
            configuration: configuration.isolated(forDeviceUDID: udid)
        )
        connectionRequest = request
        sessionID = "warm-test-session"
        sessionServerURL = request.serverURL
        self.screenSize = screenSize
        state = .ready
    }
    #endif

    func prepare(
        serverURL: String,
        bundleID: String,
        configuration: AppiumControlConfiguration = AppiumControlConfiguration(),
        onSetupRequired: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        guard let udid = device.udid, !udid.isEmpty else {
            state = .failed("No UDID mapped for this mirror source.")
            statusMessage = "No UDID mapped for this mirror source."
            return
        }

        let isolatedConfiguration = configuration.isolated(forDeviceUDID: udid)
        let request = ConnectionRequest(
            serverURL: AppiumHTTPClient.normalizedBaseURLString(serverURL),
            bundleID: bundleID,
            configuration: isolatedConfiguration
        )
        if connectionTask != nil, connectionRequest == request {
            return
        }
        if sessionID != nil, sessionServerURL == request.serverURL, connectionRequest == request {
            state = .ready
            connectionPhase = nil
            connectionStartedAt = nil
            statusMessage = screenSize.map {
                "Control ready: \(Int($0.width)) x \(Int($0.height))"
            } ?? "Control ready"
            return
        }

        let previousConnection = connectionTask
        previousConnection?.cancel()
        let previousCleanup = cleanupTask
        let previousPump = actionPumpTask
        previousPump?.cancel()
        let previousSessionID = sessionID
        let previousServerURL = sessionServerURL

        generation &+= 1
        let taskGeneration = generation
        sessionID = nil
        sessionServerURL = nil
        screenSize = nil
        pendingActions.removeAll()
        actionPumpTask = nil
        cleanupTask = nil
        connectionRequest = request
        state = .connecting
        connectionPhase = .startingService
        connectionStartedAt = connectionStartedAt ?? Date()
        statusMessage = "Checking local Appium service..."
        connectionTask = Task { [weak self] in
            if let previousConnection {
                await previousConnection.value
            }
            if let previousPump {
                await previousPump.value
            }
            if let previousCleanup {
                await previousCleanup.value
            }
            if let previousSessionID, let previousServerURL {
                await Self.deleteSessionIgnoringCancellation(
                    serverURL: previousServerURL,
                    sessionID: previousSessionID
                )
            }

            guard let self, self.generation == taskGeneration else { return }
            var createdSessionID: String?
            let client = AppiumHTTPClient(baseURL: request.serverURL)
            do {
                self.setProgress(
                    "Checking local Appium service...",
                    phase: .startingService,
                    generation: taskGeneration
                )
                try await client.status(timeout: 5)
                try Task.checkCancellation()
                let sessionID = try await self.createReusableSession(
                    client: client,
                    udid: udid,
                    bundleID: request.bundleID,
                    configuration: request.configuration,
                    generation: taskGeneration
                )
                createdSessionID = sessionID
                try Task.checkCancellation()
                guard self.generation == taskGeneration else { throw CancellationError() }
                self.setProgress(
                    "Optimizing control latency...",
                    phase: .finishing,
                    generation: taskGeneration
                )
                try await client.configureLowLatencyControl(sessionID: sessionID)
                try Task.checkCancellation()
                guard self.generation == taskGeneration else { throw CancellationError() }
                self.setProgress(
                    "Reading device screen size...",
                    phase: .finishing,
                    generation: taskGeneration
                )
                let size = try await client.windowSize(sessionID: sessionID)
                try Task.checkCancellation()
                guard self.generation == taskGeneration else { throw CancellationError() }
                self.sessionID = sessionID
                self.sessionServerURL = request.serverURL
                self.screenSize = size
                self.warmDisconnectedAt = nil
                self.state = .ready
                self.connectionPhase = nil
                self.connectionStartedAt = nil
                self.statusMessage = "Control ready: \(Int(size.width)) x \(Int(size.height))"
                createdSessionID = nil
            } catch is CancellationError {
                if self.generation == taskGeneration {
                    self.sessionID = nil
                    self.sessionServerURL = nil
                    self.screenSize = nil
                    self.state = .unavailable
                    self.connectionPhase = nil
                    self.connectionStartedAt = nil
                    self.statusMessage = "Control not connected"
                }
            } catch {
                if self.generation == taskGeneration {
                    let message = AppiumError.controlFailureMessage(for: error)
                    self.state = .failed(message)
                    self.connectionPhase = nil
                    self.connectionStartedAt = nil
                    self.statusMessage = message
                    onSetupRequired?(message)
                }
            }
            if let createdSessionID {
                await Self.deleteSessionIgnoringCancellation(
                    serverURL: request.serverURL,
                    sessionID: createdSessionID
                )
            }
            if self.generation == taskGeneration {
                self.connectionTask = nil
            }
        }
    }

    private func createReusableSession(
        client: AppiumHTTPClient,
        udid: String,
        bundleID: String,
        configuration: AppiumControlConfiguration,
        generation: UInt64
    ) async throws -> String {
        if configuration.preferInstalledWDA {
            do {
                let installedConfiguration = configuration.preinstalledProbeConfiguration
                setProgress(
                    "Reusing installed WebDriverAgent control agent...",
                    phase: .reusingAgent,
                    generation: generation
                )
                return try await startSession(
                    client: client,
                    udid: udid,
                    bundleID: bundleID,
                    configuration: installedConfiguration
                )
            } catch {
                guard AppiumError.shouldFallbackToWDAInstall(afterInstalledWDAError: error) else {
                    throw error
                }
                try Task.checkCancellation()
                setProgress(
                    "Installed WebDriverAgent is not reusable; installing control agent...",
                    phase: .installingAgent,
                    generation: generation
                )
            }
        } else {
            setProgress(
                configuration.usePrebuiltWDA
                    ? "Starting installed WebDriverAgent control agent..."
                    : "Installing and starting WebDriverAgent control agent...",
                phase: configuration.usePrebuiltWDA ? .reusingAgent : .installingAgent,
                generation: generation
            )
        }

        var installConfiguration = configuration
        installConfiguration.usePreinstalledWDA = false
        guard !installConfiguration.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppiumError.signingConfigurationRequired
        }
        installConfiguration.wdaBundleID = installConfiguration.installationWDABundleID
        installConfiguration.useNewWDA = false
        return try await startSession(
            client: client,
            udid: udid,
            bundleID: bundleID,
            configuration: installConfiguration
        )
    }

    private func startSession(
        client: AppiumHTTPClient,
        udid: String,
        bundleID: String,
        configuration: AppiumControlConfiguration
    ) async throws -> String {
        try await client.createSession(
            udid: udid,
            bundleID: bundleID,
            configuration: configuration
        )
    }

    func stop(serverURL: String) {
        _ = beginShutdown(serverURL: serverURL)
    }

    /// Detaches the UI from control while keeping the Appium/WDA session warm.
    /// A later `prepare` with the same request resumes immediately. Device
    /// retirement and app termination still call `stop`/`shutdown` to DELETE
    /// the session and reap WDA/xcodebuild.
    func disconnectKeepingAgentWarm() {
        guard sessionID != nil else {
            state = .unavailable
            connectionPhase = nil
            connectionStartedAt = nil
            statusMessage = "Control not connected"
            return
        }

        generation &+= 1
        actionPumpTask?.cancel()
        actionPumpTask = nil
        pendingActions.removeAll()
        warmDisconnectedAt = Date()
        state = .unavailable
        connectionPhase = nil
        connectionStartedAt = nil
        statusMessage = "Control disconnected; agent kept warm"
    }

    /// Returns true when a live session for exactly this request was resumed.
    func resumeWarmSession(
        serverURL: String,
        bundleID: String,
        configuration: AppiumControlConfiguration
    ) -> Bool {
        guard let udid = device.udid, !udid.isEmpty, sessionID != nil else { return false }
        if let warmDisconnectedAt,
           Date().timeIntervalSince(warmDisconnectedAt) >= 240 {
            _ = beginShutdown(serverURL: serverURL)
            return false
        }
        let request = ConnectionRequest(
            serverURL: AppiumHTTPClient.normalizedBaseURLString(serverURL),
            bundleID: bundleID,
            configuration: configuration.isolated(forDeviceUDID: udid)
        )
        guard sessionServerURL == request.serverURL, connectionRequest == request else { return false }
        state = .ready
        warmDisconnectedAt = nil
        connectionPhase = nil
        connectionStartedAt = nil
        statusMessage = screenSize.map {
            "Control ready: \(Int($0.width)) x \(Int($0.height))"
        } ?? "Control ready"
        return true
    }

    /// Awaitable teardown for app termination and tests. The connection task
    /// owns any session it creates until adoption, so waiting it also waits for
    /// cancellation-time DELETE cleanup.
    func shutdown(serverURL: String) async {
        let task = beginShutdown(serverURL: serverURL)
        await task.value
    }

    func tapNormalized(x: Double, y: Double, serverURL: String) {
        guard let sessionID, let screenSize else { return }
        let point = CGPoint(x: x * screenSize.width, y: y * screenSize.height)
        enqueueAction(.tap(point), sessionID: sessionID, serverURL: serverURL)
    }

    func swipeNormalized(from start: CGPoint, to end: CGPoint, durationMS: Int, serverURL: String) {
        guard let sessionID, let screenSize else { return }
        let startPoint = CGPoint(x: start.x * screenSize.width, y: start.y * screenSize.height)
        let endPoint = CGPoint(x: end.x * screenSize.width, y: end.y * screenSize.height)
        enqueueAction(.swipe(startPoint, endPoint, durationMS: durationMS), sessionID: sessionID, serverURL: serverURL)
    }

    func flick(_ direction: ControlFlickDirection, serverURL: String) {
        guard let sessionID, let screenSize else { return }
        let points = Self.flickPoints(direction: direction, size: screenSize)
        enqueueAction(
            .swipe(points.start, points.end, durationMS: 120),
            sessionID: sessionID,
            serverURL: serverURL
        )
    }

    func typeText(_ text: String, serverURL: String) {
        guard let sessionID, !text.isEmpty else { return }
        enqueueAction(.typeText(text), sessionID: sessionID, serverURL: serverURL)
    }

    func pressHome(serverURL: String) {
        guard let sessionID else { return }
        enqueueAction(.pressButton("home"), sessionID: sessionID, serverURL: serverURL)
    }

    func openAppSwitcher(serverURL: String) {
        guard let sessionID else { return }
        enqueueAction(.appSwitcher, sessionID: sessionID, serverURL: serverURL)
    }

    func pressBack(serverURL: String) {
        guard let sessionID, let screenSize else { return }
        let point = CGPoint(x: screenSize.width * 0.09, y: screenSize.height * 0.075)
        enqueueAction(.tap(point), sessionID: sessionID, serverURL: serverURL)
    }

    func tapNormalizedAwaiting(x: Double, y: Double, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.tap(
            sessionID: context.sessionID,
            point: CGPoint(x: x * context.size.width, y: y * context.size.height)
        )
    }

    func doubleTapNormalizedAwaiting(x: Double, y: Double, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.doubleTap(
            sessionID: context.sessionID,
            point: CGPoint(x: x * context.size.width, y: y * context.size.height)
        )
    }

    func longPressNormalizedAwaiting(
        x: Double,
        y: Double,
        durationSeconds: Double,
        serverURL: String
    ) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.longPress(
            sessionID: context.sessionID,
            point: CGPoint(x: x * context.size.width, y: y * context.size.height),
            durationSeconds: durationSeconds
        )
    }

    func swipeNormalizedAwaiting(
        from start: CGPoint,
        to end: CGPoint,
        durationMS: Int,
        serverURL: String
    ) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.swipe(
            sessionID: context.sessionID,
            from: CGPoint(x: start.x * context.size.width, y: start.y * context.size.height),
            to: CGPoint(x: end.x * context.size.width, y: end.y * context.size.height),
            durationMS: durationMS
        )
    }

    func flickAwaiting(direction: ControlFlickDirection, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        let points = Self.flickPoints(direction: direction, size: context.size)
        try await context.client.swipe(
            sessionID: context.sessionID,
            from: points.start,
            to: points.end,
            durationMS: 120
        )
    }

    nonisolated static func flickPoints(
        direction: ControlFlickDirection,
        size: DeviceScreenSize
    ) -> (start: CGPoint, end: CGPoint) {
        let left = size.width * 0.15
        let right = size.width * 0.85
        let top = size.height * 0.18
        let bottom = size.height * 0.82
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        switch direction {
        case .left:
            return (CGPoint(x: right, y: center.y), CGPoint(x: left, y: center.y))
        case .right:
            return (CGPoint(x: left, y: center.y), CGPoint(x: right, y: center.y))
        case .up:
            return (CGPoint(x: center.x, y: bottom), CGPoint(x: center.x, y: top))
        case .down:
            return (CGPoint(x: center.x, y: top), CGPoint(x: center.x, y: bottom))
        }
    }

    func typeTextAwaiting(_ text: String, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.typeText(sessionID: context.sessionID, text: text)
    }

    func clearTextAwaiting(serverURL: String) async throws -> AppiumTextEditResult {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.clearActiveText(sessionID: context.sessionID)
    }

    func replaceTextAwaiting(_ text: String, serverURL: String) async throws -> AppiumTextEditResult {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.replaceActiveText(sessionID: context.sessionID, text: text)
    }

    func pressButtonAwaiting(_ name: String, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.pressButton(sessionID: context.sessionID, name: name)
    }

    func pressBackAwaiting(serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.tap(
            sessionID: context.sessionID,
            point: CGPoint(x: context.size.width * 0.09, y: context.size.height * 0.075)
        )
    }

    func openAppSwitcherAwaiting(serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.pressButton(sessionID: context.sessionID, name: "home")
        try await Task.sleep(for: .milliseconds(180))
        try await context.client.pressButton(sessionID: context.sessionID, name: "home")
    }

    func screenshot(serverURL: String) async throws -> Data {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.screenshot(sessionID: context.sessionID)
    }

    func pageSource(serverURL: String) async throws -> String {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.pageSource(sessionID: context.sessionID)
    }

    /// Uses WDA's native predicate lookup without serializing the complete
    /// accessibility hierarchy. Routine agent navigation should prefer this
    /// path; `/source` remains available for explicit deep-tree inspection.
    func findSemanticTextElementsAwaiting(
        query: String,
        maximumMatches: Int = 12,
        serverURL: String
    ) async throws -> [AppiumNativeElementMatch] {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.findSemanticTextElements(
            sessionID: context.sessionID,
            query: query,
            screenSize: context.size,
            maximumMatches: maximumMatches
        )
    }

    func clickElementReferenceAwaiting(_ reference: String, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.clickElementReference(
            sessionID: context.sessionID,
            elementID: reference
        )
    }

    /// Resolves a fresh XCUIElement reference and asks WDA to click it. This is
    /// more resilient to rotation and layout changes than replaying old pixels.
    func clickSemanticElementAwaiting(_ element: ScreenElement, serverURL: String) async throws -> Bool {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.clickSemanticElement(
            sessionID: context.sessionID,
            element: element
        )
    }

    func activateApp(bundleID: String, serverURL: String) async throws {
        let context = try readyContext(serverURL: serverURL)
        try await context.client.activateApp(sessionID: context.sessionID, bundleID: bundleID)
    }

    func terminateApp(bundleID: String, serverURL: String) async throws -> Bool {
        let context = try readyContext(serverURL: serverURL)
        return try await context.client.terminateApp(sessionID: context.sessionID, bundleID: bundleID)
    }

    private func readyContext(serverURL: String) throws -> (
        client: AppiumHTTPClient,
        sessionID: String,
        size: DeviceScreenSize
    ) {
        guard let sessionID, let screenSize, isReady else {
            throw AppiumError.controlNotReady
        }
        return (
            AppiumHTTPClient(baseURL: sessionServerURL ?? serverURL),
            sessionID,
            screenSize
        )
    }

    private func enqueueAction(_ action: ControlAction, sessionID: String, serverURL: String) {
        pendingActions.append(action)
        pumpActions(sessionID: sessionID, serverURL: serverURL, generation: generation)
    }

    private func pumpActions(sessionID: String, serverURL: String, generation taskGeneration: UInt64) {
        guard actionPumpTask == nil else { return }
        actionPumpTask = Task { [weak self] in
            guard let self else { return }
            let client = AppiumHTTPClient(baseURL: serverURL)
            while true {
                guard !Task.isCancelled else { break }
                guard self.generation == taskGeneration, self.sessionID == sessionID else { break }
                guard !self.pendingActions.isEmpty else { break }
                guard let action = self.pendingActions.popFirst() else { break }
                guard self.generation == taskGeneration, self.sessionID == sessionID else {
                    break
                }
                do {
                    switch action {
                    case let .tap(point):
                        try await client.tap(sessionID: sessionID, point: point)
                        if self.generation == taskGeneration, self.sessionID == sessionID {
                            self.statusMessage = "Tap \(Int(point.x)), \(Int(point.y))"
                        }
                    case let .swipe(start, end, durationMS):
                        try await client.swipe(sessionID: sessionID, from: start, to: end, durationMS: durationMS)
                    case let .typeText(text):
                        try await client.typeText(sessionID: sessionID, text: text)
                        if self.generation == taskGeneration, self.sessionID == sessionID {
                            self.statusMessage = "Typed \(text.count) character\(text.count == 1 ? "" : "s")"
                        }
                    case let .pressButton(name):
                        try await client.pressButton(sessionID: sessionID, name: name)
                        if self.generation == taskGeneration, self.sessionID == sessionID {
                            self.statusMessage = "Pressed \(name.capitalized)"
                        }
                    case .appSwitcher:
                        try await client.pressButton(sessionID: sessionID, name: "home")
                        try await Task.sleep(nanoseconds: 180_000_000)
                        try await client.pressButton(sessionID: sessionID, name: "home")
                        if self.generation == taskGeneration, self.sessionID == sessionID {
                            self.statusMessage = "Sent best-effort App Switcher gesture"
                        }
                    }
                } catch {
                    if self.generation == taskGeneration, self.sessionID == sessionID {
                        let message = AppiumError.controlFailureMessage(for: error)
                        self.statusMessage = message
                        if AppiumError.shouldInvalidateActiveSession(afterActionError: error) {
                            self.sessionID = nil
                            self.sessionServerURL = nil
                            self.screenSize = nil
                            self.pendingActions.removeAll()
                            self.state = .failed(message)
                        }
                    }
                }
            }
            if self.generation == taskGeneration {
                self.actionPumpTask = nil
                if !Task.isCancelled, !self.pendingActions.isEmpty, self.sessionID == sessionID {
                    self.pumpActions(
                        sessionID: sessionID,
                        serverURL: serverURL,
                        generation: taskGeneration
                    )
                }
            }
        }
    }

    private func setProgress(
        _ message: String,
        phase: ControlConnectionPhase,
        generation taskGeneration: UInt64
    ) {
        guard generation == taskGeneration else { return }
        connectionPhase = phase
        statusMessage = message
    }

    private func beginShutdown(serverURL: String) -> Task<Void, Never> {
        generation &+= 1
        let previousConnection = connectionTask
        previousConnection?.cancel()
        let previousPump = actionPumpTask
        previousPump?.cancel()
        let previousCleanup = cleanupTask
        let activeSessionID = sessionID
        let activeServerURL = sessionServerURL ?? AppiumHTTPClient.normalizedBaseURLString(serverURL)

        connectionTask = nil
        connectionRequest = nil
        actionPumpTask = nil
        sessionID = nil
        sessionServerURL = nil
        screenSize = nil
        warmDisconnectedAt = nil
        pendingActions.removeAll()
        state = .unavailable
        connectionPhase = nil
        connectionStartedAt = nil
        statusMessage = "Control not connected"

        let task = Task {
            if let previousConnection {
                await previousConnection.value
            }
            if let previousPump {
                await previousPump.value
            }
            if let previousCleanup {
                await previousCleanup.value
            }
            if let activeSessionID {
                await Self.deleteSessionIgnoringCancellation(
                    serverURL: activeServerURL,
                    sessionID: activeSessionID
                )
            }
        }
        cleanupTask = task
        return task
    }

    private nonisolated static func deleteSessionIgnoringCancellation(serverURL: String, sessionID: String) async {
        let cleanup = Task.detached(priority: .utility) {
            try? await AppiumHTTPClient(baseURL: serverURL).deleteSession(
                sessionID: sessionID,
                timeout: 5
            )
        }
        await cleanup.value
    }
}

private struct ConnectionRequest: Hashable, Sendable {
    let serverURL: String
    let bundleID: String
    let configuration: AppiumControlConfiguration
}

enum ControlAction {
    case tap(CGPoint)
    case swipe(CGPoint, CGPoint, durationMS: Int)
    case typeText(String)
    case pressButton(String)
    case appSwitcher

    var isSwipe: Bool {
        if case .swipe = self {
            true
        } else {
            false
        }
    }

    var isTap: Bool {
        if case .tap = self {
            true
        } else {
            false
        }
    }
}

struct ControlActionBuffer {
    private(set) var actions: [ControlAction] = []
    let maximumCount: Int

    init(maximumCount: Int = 4) {
        self.maximumCount = max(1, maximumCount)
    }

    var count: Int { actions.count }
    var isEmpty: Bool { actions.isEmpty }

    mutating func append(_ action: ControlAction) {
        if action.isSwipe {
            actions.removeAll { $0.isSwipe }
            actions.append(action)
        } else if action.isTap, actions.last?.isTap == true {
            actions[actions.count - 1] = action
        } else {
            actions.append(action)
        }
        if actions.count > maximumCount {
            actions.removeFirst(actions.count - maximumCount)
        }
    }

    mutating func popFirst() -> ControlAction? {
        guard !actions.isEmpty else { return nil }
        return actions.removeFirst()
    }

    mutating func removeAll() {
        actions.removeAll(keepingCapacity: true)
    }
}

struct AppiumHTTPClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    private let dataLoader: DataLoader

    init(
        baseURL: String,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.baseURL = URL(string: Self.normalizedBaseURLString(baseURL))!
        self.dataLoader = dataLoader
    }

    static func normalizedBaseURLString(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "http://127.0.0.1:4723"
        guard let url = URL(string: cleaned.isEmpty ? fallback : cleaned),
              let scheme = url.scheme,
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return fallback
        }
        return url.absoluteString
    }

    func status(timeout: TimeInterval = 30) async throws {
        _ = try await jsonRequest(method: "GET", path: "/status", timeout: timeout)
    }

    func createSession(
        udid: String,
        bundleID: String,
        configuration: AppiumControlConfiguration = AppiumControlConfiguration()
    ) async throws -> String {
        let capabilities = AppiumSessionCapabilities.make(
            udid: udid,
            bundleID: bundleID,
            configuration: configuration
        )
        let payload: [String: Any] = [
            "capabilities": [
                "alwaysMatch": capabilities,
                "firstMatch": [[:]]
            ]
        ]
        let response = try await jsonRequest(
            method: "POST",
            path: "/session",
            payload: payload,
            timeout: configuration.sessionStartupTimeoutSeconds + 15
        )
        if let sessionID = response["sessionId"] as? String {
            return sessionID
        }
        if let value = response["value"] as? [String: Any], let sessionID = value["sessionId"] as? String {
            return sessionID
        }
        throw AppiumError.missingSessionID
    }

    func windowSize(sessionID: String) async throws -> DeviceScreenSize {
        let response: [String: Any]
        do {
            response = try await jsonRequest(method: "GET", path: "/session/\(sessionID)/window/rect")
        } catch AppiumError.httpStatus(404, _) {
            response = try await jsonRequest(method: "GET", path: "/session/\(sessionID)/window/size")
        }
        guard let value = response["value"] as? [String: Any] else {
            throw AppiumError.invalidResponse("Missing window size value.")
        }
        let width = value["width"] as? Double ?? Double(value["width"] as? Int ?? 0)
        let height = value["height"] as? Double ?? Double(value["height"] as? Int ?? 0)
        guard width > 0, height > 0 else {
            throw AppiumError.invalidResponse("Invalid window size.")
        }
        return DeviceScreenSize(width: width, height: height)
    }

    func configureLowLatencyControl(sessionID: String) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/appium/settings",
            payload: AppiumControlSettings.lowLatencyPayload()
        )
    }

    func tap(sessionID: String, point: CGPoint) async throws {
        try await executeMobile(
            sessionID: sessionID,
            script: "mobile: tap",
            arguments: [
                "x": Double(point.x.rounded()),
                "y": Double(point.y.rounded())
            ]
        )
    }

    func swipe(sessionID: String, from start: CGPoint, to end: CGPoint, durationMS: Int = 150) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/actions",
            payload: AppiumPointerAction.dragPayload(
                from: start,
                to: end,
                durationMS: durationMS
            )
        )
    }

    func typeText(sessionID: String, text: String) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/keys",
            payload: [
                "text": text,
                "value": text.map { String($0) }
            ]
        )
    }

    func clearActiveText(sessionID: String) async throws -> AppiumTextEditResult {
        let elementID = try await activeElementReference(sessionID: sessionID)
        try await clearElement(sessionID: sessionID, elementID: elementID)
        let value = try await elementAttribute(
            sessionID: sessionID,
            elementID: elementID,
            name: "value"
        )
        var verifiedValue = value
        if value?.isEmpty == false {
            let placeholder = try? await elementAttribute(
                sessionID: sessionID,
                elementID: elementID,
                name: "placeholderValue"
            )
            guard value == placeholder else {
                throw AppiumError.invalidResponse("The active field still contains text after clear.")
            }
            // XCUITest exposes a text field's placeholder as its value after
            // clearing. Report the semantic content, which is empty.
            verifiedValue = ""
        }
        return AppiumTextEditResult(
            strategy: "wda_active_element_clear",
            value: verifiedValue,
            verified: true
        )
    }

    func replaceActiveText(sessionID: String, text: String) async throws -> AppiumTextEditResult {
        let elementID = try await activeElementReference(sessionID: sessionID)
        try await clearElement(sessionID: sessionID, elementID: elementID)
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/element/\(elementID)/value",
            payload: [
                "text": text,
                "value": text.map { String($0) }
            ]
        )
        let value = try await elementAttribute(
            sessionID: sessionID,
            elementID: elementID,
            name: "value"
        )
        guard value == text else {
            throw AppiumError.invalidResponse(
                "The active field value did not match the requested replacement."
            )
        }
        return AppiumTextEditResult(
            strategy: "wda_active_element_clear_and_set",
            value: value,
            verified: true
        )
    }

    private func activeElementReference(sessionID: String) async throws -> String {
        do {
            let response = try await jsonRequest(
                method: "GET",
                path: "/session/\(sessionID)/element/active"
            )
            if let value = response["value"] as? [String: Any],
               let reference = Self.elementReference(value) {
                return reference
            }
        } catch AppiumError.httpStatus(404, _) {
            // XCUITest Driver forwards /element/active to WDA, but some iOS
            // system fields return 404 even while visibly focused. Resolve the
            // focused editable control directly without serializing /source.
        }
        let focusedInput = AppiumSemanticLocator(
            using: "-ios predicate string",
            value: "focused == 1 AND (type == 'XCUIElementTypeTextField' OR type == 'XCUIElementTypeSecureTextField' OR type == 'XCUIElementTypeSearchField' OR type == 'XCUIElementTypeTextView')"
        )
        if let value = try await findFirstElementValue(
            sessionID: sessionID,
            locator: focusedInput
        ), let reference = Self.elementReference(value) {
            return reference
        }
        throw AppiumError.invalidResponse(
            "No focused input element. Focus a text field before editing text."
        )
    }

    private func clearElement(sessionID: String, elementID: String) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/element/\(elementID)/clear",
            payload: [:]
        )
    }

    private func elementAttribute(
        sessionID: String,
        elementID: String,
        name: String
    ) async throws -> String? {
        let response = try await jsonRequest(
            method: "GET",
            path: "/session/\(sessionID)/element/\(elementID)/attribute/\(name)"
        )
        if response["value"] is NSNull { return nil }
        return response["value"] as? String
    }

    func pressButton(sessionID: String, name: String) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/execute/sync",
            payload: [
                "script": "mobile: pressButton",
                "args": [
                    ["name": name]
                ]
            ]
        )
    }

    func doubleTap(sessionID: String, point: CGPoint) async throws {
        try await executeMobile(
            sessionID: sessionID,
            script: "mobile: doubleTap",
            arguments: [
                "x": Double(point.x.rounded()),
                "y": Double(point.y.rounded())
            ]
        )
    }

    func longPress(
        sessionID: String,
        point: CGPoint,
        durationSeconds: Double
    ) async throws {
        try await executeMobile(
            sessionID: sessionID,
            script: "mobile: touchAndHold",
            arguments: [
                "x": Double(point.x.rounded()),
                "y": Double(point.y.rounded()),
                "duration": durationSeconds
            ]
        )
    }

    func screenshot(sessionID: String) async throws -> Data {
        let response = try await jsonRequest(
            method: "GET",
            path: "/session/\(sessionID)/screenshot"
        )
        guard let encoded = response["value"] as? String,
              let data = Data(base64Encoded: encoded) else {
            throw AppiumError.invalidResponse("Missing PNG screenshot data.")
        }
        return data
    }

    func pageSource(sessionID: String) async throws -> String {
        let response = try await jsonRequest(
            method: "GET",
            path: "/session/\(sessionID)/source"
        )
        guard let source = response["value"] as? String else {
            throw AppiumError.invalidResponse("Missing accessibility source.")
        }
        return source
    }

    func findSemanticTextElements(
        sessionID: String,
        query: String,
        screenSize: DeviceScreenSize,
        maximumMatches: Int = 12
    ) async throws -> [AppiumNativeElementMatch] {
        let locator = AppiumSemanticElementResolver.textContainsLocator(query: query)
        guard maximumMatches > 0,
              let value = try await findFirstElementValue(
                  sessionID: sessionID,
                  locator: locator
              ),
              let reference = Self.elementReference(value) else { return [] }
        let frame = Self.frame(value["rect"])
        let normalizedFrame = frame?.normalized(width: screenSize.width, height: screenSize.height)
        let publicID = String(
            format: "native-%016llx-00",
            StableDeviceHash.fnv1a64(reference)
        )
        let element = ScreenElement(
            id: publicID,
            type: value["type"] as? String ?? "NativeTextMatch",
            name: value["name"] as? String ?? query,
            label: value["label"] as? String ?? query,
            value: value["text"] as? String,
            enabled: value["enabled"] as? Bool ?? true,
            visible: value["displayed"] as? Bool ?? true,
            accessible: true,
            selected: value["selected"] as? Bool,
            index: 0,
            frame: frame,
            frameSpace: frame == nil ? nil : .screenPoints,
            normalizedFrame: normalizedFrame,
            path: "native/0"
        )
        return [AppiumNativeElementMatch(
            reference: reference,
            query: query,
            element: element
        )]
    }

    func clickElementReference(sessionID: String, elementID: String) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/element/\(elementID)/click",
            payload: [:]
        )
    }

    func clickSemanticElement(sessionID: String, element: ScreenElement) async throws -> Bool {
        guard element.source == .accessibility else { return false }
        for locator in AppiumSemanticElementResolver.locators(for: element) {
            let references = try await findElementReferences(
                sessionID: sessionID,
                locator: locator
            )
            guard !references.isEmpty else { continue }

            var candidates: [AppiumResolvedElement] = []
            candidates.reserveCapacity(min(references.count, 12))
            for reference in references.prefix(12) {
                let rect = try? await elementRect(sessionID: sessionID, elementID: reference)
                candidates.append(AppiumResolvedElement(id: reference, frame: rect))
            }
            guard let selected = AppiumSemanticElementResolver.bestMatch(
                among: candidates,
                observedFrame: element.frame
            ) else { continue }
            _ = try await jsonRequest(
                method: "POST",
                path: "/session/\(sessionID)/element/\(selected.id)/click",
                payload: [:]
            )
            return true
        }
        return false
    }

    private func findElementReferences(
        sessionID: String,
        locator: AppiumSemanticLocator
    ) async throws -> [String] {
        let response = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/elements",
            payload: ["using": locator.using, "value": locator.value]
        )
        guard let values = response["value"] as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            Self.elementReference(value)
        }
    }

    private func findFirstElementValue(
        sessionID: String,
        locator: AppiumSemanticLocator
    ) async throws -> [String: Any]? {
        do {
            let response = try await jsonRequest(
                method: "POST",
                path: "/session/\(sessionID)/element",
                payload: ["using": locator.using, "value": locator.value]
            )
            return response["value"] as? [String: Any]
        } catch AppiumError.httpStatus(404, _) {
            return nil
        }
    }

    private static func elementReference(_ value: [String: Any]) -> String? {
        value[AppiumSemanticElementResolver.w3cElementKey] as? String
            ?? value["ELEMENT"] as? String
    }

    private static func frame(_ value: Any?) -> ScreenElementFrame? {
        guard let value = value as? [String: Any],
              let x = number(value["x"]),
              let y = number(value["y"]),
              let width = number(value["width"]),
              let height = number(value["height"]),
              width > 0, height > 0 else { return nil }
        return ScreenElementFrame(x: x, y: y, width: width, height: height)
    }

    private func elementRect(sessionID: String, elementID: String) async throws -> ScreenElementFrame {
        let response = try await jsonRequest(
            method: "GET",
            path: "/session/\(sessionID)/element/\(elementID)/rect"
        )
        guard let value = response["value"] as? [String: Any],
              let x = Self.number(value["x"]),
              let y = Self.number(value["y"]),
              let width = Self.number(value["width"]),
              let height = Self.number(value["height"]),
              width > 0, height > 0 else {
            throw AppiumError.invalidResponse("Missing element rectangle.")
        }
        return ScreenElementFrame(x: x, y: y, width: width, height: height)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    func activateApp(sessionID: String, bundleID: String) async throws {
        try await executeMobile(
            sessionID: sessionID,
            script: "mobile: activateApp",
            arguments: ["bundleId": bundleID]
        )
    }

    func terminateApp(sessionID: String, bundleID: String) async throws -> Bool {
        let response = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/execute/sync",
            payload: [
                "script": "mobile: terminateApp",
                "args": [["bundleId": bundleID]]
            ]
        )
        return response["value"] as? Bool ?? true
    }

    private func executeMobile(sessionID: String, script: String, arguments: [String: Any]) async throws {
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sessionID)/execute/sync",
            payload: [
                "script": script,
                "args": [arguments]
            ]
        )
    }

    func deleteSession(sessionID: String, timeout: TimeInterval = 30) async throws {
        _ = try await jsonRequest(
            method: "DELETE",
            path: "/session/\(sessionID)",
            timeout: timeout
        )
    }

    private func jsonRequest(
        method: String,
        path: String,
        payload: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        var url = baseURL
        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            url = baseURL.appendingPathComponent(requestPath)
        } else {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/" + [basePath, requestPath].filter { !$0.isEmpty }.joined(separator: "/")
            guard let componentURL = components?.url else {
                throw AppiumError.invalidResponse("Invalid Appium URL.")
            }
            url = componentURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let (data, response) = try await dataLoader(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppiumError.httpStatus(http.statusCode, body)
        }
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw AppiumError.invalidResponse("Expected JSON object.")
        }
        return dictionary
    }
}

struct AppiumTextEditResult: Equatable, Sendable {
    let strategy: String
    let value: String?
    let verified: Bool
}

struct AppiumSemanticLocator: Equatable, Sendable {
    let using: String
    let value: String
}

struct AppiumResolvedElement: Equatable, Sendable {
    let id: String
    let frame: ScreenElementFrame?
}

struct AppiumNativeElementMatch: Equatable, Sendable {
    let reference: String
    let query: String
    let element: ScreenElement
}

enum AppiumSemanticElementResolver {
    static let w3cElementKey = "element-6066-11e4-a52e-4f735466cecf"

    static func textContainsLocator(query: String) -> AppiumSemanticLocator {
        let literal = predicateLiteral(query)
        return AppiumSemanticLocator(
            using: "-ios predicate string",
            value: "visible == 1 AND (name CONTAINS[c] '\(literal)' OR label CONTAINS[c] '\(literal)' OR value CONTAINS[c] '\(literal)')"
        )
    }

    static func locators(for element: ScreenElement) -> [AppiumSemanticLocator] {
        guard element.source == .accessibility else { return [] }
        var locators: [AppiumSemanticLocator] = []
        var predicates: [String] = []
        if isElementType(element.type) {
            predicates.append("type == '\(predicateLiteral(element.type))'")
        }
        if let name = usableValue(element.name) {
            predicates.append("name == '\(predicateLiteral(name))'")
        }
        if let label = usableValue(element.label) {
            predicates.append("label == '\(predicateLiteral(label))'")
        }
        if let value = usableValue(element.value) {
            predicates.append("value == '\(predicateLiteral(value))'")
        }
        if !predicates.isEmpty {
            locators.append(AppiumSemanticLocator(
                using: "-ios predicate string",
                value: predicates.joined(separator: " AND ")
            ))
        }
        if let name = usableValue(element.name) {
            locators.append(AppiumSemanticLocator(using: "accessibility id", value: name))
        }
        if element.name == nil, let label = usableValue(element.label) {
            locators.append(AppiumSemanticLocator(using: "accessibility id", value: label))
        }
        return locators.reduce(into: []) { result, locator in
            guard !result.contains(locator) else { return }
            result.append(locator)
        }
    }

    static func bestMatch(
        among candidates: [AppiumResolvedElement],
        observedFrame: ScreenElementFrame?
    ) -> AppiumResolvedElement? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        guard let observedFrame else { return nil }
        return candidates.compactMap { candidate -> (AppiumResolvedElement, Double)? in
            guard let frame = candidate.frame else { return nil }
            let centerDistance = hypot(
                frame.centerX - observedFrame.centerX,
                frame.centerY - observedFrame.centerY
            )
            let sizeDistance = abs(frame.width - observedFrame.width)
                + abs(frame.height - observedFrame.height)
            return (candidate, centerDistance + sizeDistance * 0.2)
        }.min { $0.1 < $1.1 }?.0
    }

    private static func usableValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 500 else { return nil }
        return value
    }

    private static func isElementType(_ value: String) -> Bool {
        value.hasPrefix("XCUIElementType")
            && value.dropFirst("XCUIElementType".count).allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func predicateLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\u{0}", with: "")
    }
}

enum AppiumPointerAction {
    static func dragPayload(from start: CGPoint, to end: CGPoint, durationMS: Int) -> [String: Any] {
        let duration = min(max(durationMS, 50), 5_000)
        return [
            "actions": [[
                "type": "pointer",
                "id": "stupidmirror-finger",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    [
                        "type": "pointerMove", "duration": 0,
                        "origin": "viewport", "x": rounded(start.x), "y": rounded(start.y)
                    ],
                    ["type": "pointerDown", "button": 0],
                    [
                        "type": "pointerMove", "duration": duration,
                        "origin": "viewport", "x": rounded(end.x), "y": rounded(end.y)
                    ],
                    ["type": "pointerUp", "button": 0]
                ]
            ]]
        ]
    }

    private static func rounded(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
}

enum AppiumControlSettings {
    static func lowLatencyPayload() -> [String: Any] { [
        "settings": [
            // WDA defaults to waiting up to two seconds for animations after
            // every event. The live stream is the visual confirmation.
            "animationCoolOffTimeout": 0.0,
            // Retain a small allowance for source queries without the default
            // ten-second quiescence wait.
            "waitForIdleTimeout": 0.0,
            // A semantic lookup usually needs one actionable element. WDA's
            // first-match path avoids walking every duplicate descendant.
            "useFirstMatch": true,
            // Return the element geometry with the lookup so the harness can
            // highlight and click it without one extra /rect request.
            "shouldUseCompactResponses": false,
            "elementResponseAttributes": "type,name,label,text,rect,enabled,displayed,selected"
        ]
    ] }
}

enum AppiumSessionCapabilities {
    static func make(
        udid: String,
        bundleID: String,
        configuration: AppiumControlConfiguration = AppiumControlConfiguration()
    ) -> [String: Any] {
        var capabilities: [String: Any] = [
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": udid,
            "appium:noReset": true,
            "appium:wdaLocalPort": configuration.wdaLocalPort,
            "appium:useNewWDA": configuration.useNewWDA,
            "appium:wdaStartupRetries": configuration.wdaStartupRetries,
            "appium:wdaStartupRetryInterval": configuration.wdaStartupRetryIntervalMS,
            "appium:wdaLaunchTimeout": configuration.wdaLaunchTimeoutMS,
            "appium:wdaConnectionTimeout": configuration.wdaConnectionTimeoutMS,
            "appium:newCommandTimeout": configuration.newCommandTimeoutSeconds,
            "appium:allowProvisioningDeviceRegistration": configuration.allowProvisioningDeviceRegistration
        ]
        let platformVersion = configuration.platformVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !platformVersion.isEmpty {
            capabilities["appium:platformVersion"] = platformVersion
        }
        let webDriverAgentURL = configuration.webDriverAgentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !webDriverAgentURL.isEmpty {
            capabilities["appium:webDriverAgentUrl"] = webDriverAgentURL
        }
        let directDeviceHost = configuration.directDeviceHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if directDeviceHost.isEmpty {
            capabilities["appium:mjpegServerPort"] = configuration.mjpegServerPort
        } else {
            capabilities["appium:wdaBaseUrl"] = "http://\(directDeviceHost)"
            capabilities["appium:wdaRemotePort"] = configuration.wdaLocalPort
        }
        let launchBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !launchBundleID.isEmpty {
            capabilities["appium:bundleId"] = launchBundleID
        }
        if configuration.usePreinstalledWDA {
            capabilities["appium:usePreinstalledWDA"] = true
        } else {
            capabilities["appium:usePrebuiltWDA"] = configuration.usePrebuiltWDA
        }
        let derivedDataPath = configuration.derivedDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !derivedDataPath.isEmpty {
            capabilities["appium:derivedDataPath"] = derivedDataPath
        }
        let xcodeOrgID = configuration.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !xcodeOrgID.isEmpty {
            capabilities["appium:xcodeOrgId"] = xcodeOrgID
        }
        let xcodeSigningID = configuration.xcodeSigningID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !xcodeSigningID.isEmpty {
            capabilities["appium:xcodeSigningId"] = xcodeSigningID
        }
        let wdaBundleID = configuration.wdaBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wdaBundleID.isEmpty {
            capabilities["appium:updatedWDABundleId"] = wdaBundleID
        }
        let xcodeConfigFile = configuration.xcodeConfigFile
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !xcodeConfigFile.isEmpty {
            capabilities["appium:xcodeConfigFile"] = xcodeConfigFile
        }
        return capabilities
    }
}

enum AppiumError: LocalizedError {
    case controlNotReady
    case missingSessionID
    case invalidResponse(String)
    case httpStatus(Int, String)
    case signingConfigurationRequired

    static func controlFailureMessage(for error: Error) -> String {
        if case AppiumError.signingConfigurationRequired = error {
            return "control.error.signingSetupRequired"
        }
        let haystack = [String(describing: error), error.localizedDescription]
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("unlock")
            || haystack.contains("reason: locked")
            || haystack.contains("device is locked") {
            return "control.error.unlockDevice"
        }
        if haystack.contains("developer mode") {
            return "control.error.developerMode"
        }
        if haystack.contains("enable ui automation") || haystack.contains("ui automation") {
            return "control.error.uiAutomation"
        }
        if haystack.contains("not trusted") || haystack.contains("trust this computer") || haystack.contains("pairing") {
            return "control.error.trustDevice"
        }
        if haystack.contains("provisioning profile")
            || haystack.contains("requires a development team")
            || haystack.contains("code signing")
            || haystack.contains("xcodebuild failed") {
            return "control.error.signing"
        }
        if haystack.contains("connection was refused") && haystack.contains("8100") {
            return "control.error.wdaNotReady"
        }
        return error.localizedDescription
    }

    static func shouldFallbackToWDAInstall(afterInstalledWDAError error: Error) -> Bool {
        let haystack = [String(describing: error), error.localizedDescription]
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("unlock")
            || haystack.contains("developer mode")
            || haystack.contains("ui automation")
            || haystack.contains("not trusted")
            || haystack.contains("trust this computer")
            || haystack.contains("pairing")
            || haystack.contains("provisioning profile")
            || haystack.contains("code signing") {
            return false
        }
        return haystack.contains("usepreinstalledwda")
            || haystack.contains("preinstalled")
            || haystack.contains("not installed")
            || haystack.contains("is not installed")
            || haystack.contains("does not exist")
            || haystack.contains("not found")
            || haystack.contains("not supported")
            || haystack.contains("could not launch")
            || haystack.contains("failed to launch")
            || haystack.contains("connection was refused")
            || haystack.contains("econnrefused")
            || haystack.contains("did not become ready")
            || haystack.contains("wda is not listening")
            || haystack.contains("timed out while starting webdriveragent")
            || haystack.contains("devicectl")
    }

    static func shouldInvalidateActiveSession(afterActionError error: Error) -> Bool {
        let haystack = [String(describing: error), error.localizedDescription]
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("invalid session")
            || haystack.contains("no such driver")
            || haystack.contains("session does not exist")
            || haystack.contains("connection was refused")
            || haystack.contains("econnrefused")
            || haystack.contains("socket hang up")
            || haystack.contains("wda")
            || haystack.contains("xctestmanager")
    }

    var errorDescription: String? {
        switch self {
        case .controlNotReady:
            "iPhone control is not connected. Call connect_control first."
        case .missingSessionID:
            "Appium did not return a session id."
        case let .invalidResponse(message):
            message
        case let .httpStatus(status, body):
            "Appium HTTP \(status): \(Self.compactResponseBody(body))"
        case .signingConfigurationRequired:
            "Installing WebDriverAgent requires an Apple Development signing team."
        }
    }

    private static func compactResponseBody(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body
        }
        if let value = object["value"] as? [String: Any] {
            if let message = value["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = value["error"] as? String, !error.isEmpty {
                return error
            }
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return body
    }
}
