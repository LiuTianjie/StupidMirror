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
    var wdaStartupRetries: Int = 3
    var wdaStartupRetryIntervalMS: Int = 15_000
    var wdaLaunchTimeoutMS: Int = 180_000
    var wdaConnectionTimeoutMS: Int = 180_000
    var sessionStartupTimeoutSeconds: TimeInterval = 210
    var preinstalledWDAStartupTimeoutSeconds: TimeInterval = 35
    var newCommandTimeoutSeconds: Int = 300

    /// Appium's default WDA ports and a shared DerivedData directory cannot be
    /// used safely by simultaneous devices. Keep the two port ranges disjoint
    /// and derive a stable per-device directory from the complete UDID.
    func isolated(forDeviceUDID udid: String) -> Self {
        let normalizedUDID = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUDID.isEmpty else { return self }

        let hash = StableDeviceHash.fnv1a64(normalizedUDID)
        let slot = Int(hash % 20_000)
        var result = self
        result.wdaLocalPort = 10_000 + slot
        result.mjpegServerPort = 30_000 + slot

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

    private let device: DeviceIdentity
    private var sessionID: String?
    private var sessionServerURL: String?
    private var connectionTask: Task<Void, Never>?
    private var connectionRequest: ConnectionRequest?
    private var cleanupTask: Task<Void, Never>?
    private var actionPumpTask: Task<Void, Never>?
    private var pendingActions: [ControlAction] = []
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
                self.setStatus("Checking local Appium service...", generation: taskGeneration)
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
                self.setStatus("Reading device screen size...", generation: taskGeneration)
                let size = try await client.windowSize(sessionID: sessionID)
                try Task.checkCancellation()
                guard self.generation == taskGeneration else { throw CancellationError() }
                self.sessionID = sessionID
                self.sessionServerURL = request.serverURL
                self.screenSize = size
                self.state = .ready
                self.statusMessage = "Control ready: \(Int(size.width)) x \(Int(size.height))"
                createdSessionID = nil
            } catch is CancellationError {
                if self.generation == taskGeneration {
                    self.sessionID = nil
                    self.sessionServerURL = nil
                    self.screenSize = nil
                    self.state = .unavailable
                    self.statusMessage = "Control not connected"
                }
            } catch {
                if self.generation == taskGeneration {
                    let message = AppiumError.controlFailureMessage(for: error)
                    self.state = .failed(message)
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
                var installedConfiguration = configuration
                installedConfiguration.usePreinstalledWDA = true
                installedConfiguration.usePrebuiltWDA = false
                installedConfiguration.useNewWDA = false
                installedConfiguration.sessionStartupTimeoutSeconds = min(
                    configuration.sessionStartupTimeoutSeconds,
                    configuration.preinstalledWDAStartupTimeoutSeconds
                )
                setStatus("Reusing installed WebDriverAgent control agent...", generation: generation)
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
                setStatus(
                    "Installed WebDriverAgent is not reusable; installing control agent...",
                    generation: generation
                )
            }
        } else {
            setStatus(
                configuration.usePrebuiltWDA
                    ? "Starting installed WebDriverAgent control agent..."
                    : "Installing and starting WebDriverAgent control agent...",
                generation: generation
            )
        }

        var installConfiguration = configuration
        installConfiguration.usePreinstalledWDA = false
        guard !installConfiguration.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppiumError.signingConfigurationRequired
        }
        do {
            return try await startSession(
                client: client,
                udid: udid,
                bundleID: bundleID,
                configuration: installConfiguration
            )
        } catch {
            guard AppiumError.shouldRetryWithFreshWDA(afterSessionError: error) else {
                throw error
            }
            try Task.checkCancellation()
            var freshConfiguration = installConfiguration
            freshConfiguration.useNewWDA = true
            freshConfiguration.usePrebuiltWDA = false
            setStatus("Restarting WebDriverAgent control agent...", generation: generation)
            return try await startSession(
                client: client,
                udid: udid,
                bundleID: bundleID,
                configuration: freshConfiguration
            )
        }
    }

    private func startSession(
        client: AppiumHTTPClient,
        udid: String,
        bundleID: String,
        configuration: AppiumControlConfiguration
    ) async throws -> String {
        try await withTimeout(seconds: configuration.sessionStartupTimeoutSeconds) {
            try await client.createSession(
                udid: udid,
                bundleID: bundleID,
                configuration: configuration
            )
        }
    }

    func stop(serverURL: String) {
        _ = beginShutdown(serverURL: serverURL)
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

    private func enqueueAction(_ action: ControlAction, sessionID: String, serverURL: String) {
        if action.isSwipe {
            pendingActions.removeAll { $0.isSwipe }
            pendingActions.append(action)
        } else if case .tap = action, pendingActions.last?.isTap == true {
            pendingActions[pendingActions.count - 1] = action
        } else {
            pendingActions.append(action)
        }
        if pendingActions.count > 4 {
            pendingActions.removeFirst(pendingActions.count - 4)
        }
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
                let action = self.pendingActions.removeFirst()
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

    private func setStatus(_ message: String, generation taskGeneration: UInt64) {
        guard generation == taskGeneration else { return }
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
        pendingActions.removeAll()
        state = .unavailable
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

private enum ControlAction {
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

struct AppiumHTTPClient: Sendable {
    let baseURL: URL

    init(baseURL: String) {
        self.baseURL = URL(string: Self.normalizedBaseURLString(baseURL))!
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

        let (data, response) = try await URLSession.shared.data(for: request)
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

enum AppiumPointerAction {
    static func dragPayload(from start: CGPoint, to end: CGPoint, durationMS: Int) -> [String: Any] {
        let duration = min(max(durationMS, 0), 300)
        return [
            "actions": [
                [
                    "type": "pointer",
                    "id": "stupidmirror-finger",
                    "parameters": [
                        "pointerType": "touch"
                    ],
                    "actions": [
                        [
                            "type": "pointerMove",
                            "duration": 0,
                            "origin": "viewport",
                            "x": rounded(start.x),
                            "y": rounded(start.y)
                        ],
                        [
                            "type": "pointerDown",
                            "button": 0
                        ],
                        [
                            "type": "pointerMove",
                            "duration": duration,
                            "origin": "viewport",
                            "x": rounded(end.x),
                            "y": rounded(end.y)
                        ],
                        [
                            "type": "pointerUp",
                            "button": 0
                        ]
                    ]
                ]
            ]
        ]
    }

    private static func rounded(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
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
            "appium:bundleId": bundleID,
            "appium:noReset": true,
            "appium:wdaLocalPort": configuration.wdaLocalPort,
            "appium:mjpegServerPort": configuration.mjpegServerPort,
            "appium:useNewWDA": configuration.useNewWDA,
            "appium:wdaStartupRetries": configuration.wdaStartupRetries,
            "appium:wdaStartupRetryInterval": configuration.wdaStartupRetryIntervalMS,
            "appium:wdaLaunchTimeout": configuration.wdaLaunchTimeoutMS,
            "appium:wdaConnectionTimeout": configuration.wdaConnectionTimeoutMS,
            "appium:newCommandTimeout": configuration.newCommandTimeoutSeconds
        ]
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
        return capabilities
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
            throw AppiumError.timeout("Timed out while starting WebDriverAgent after \(Int(seconds))s.")
        }
        guard let value = try await group.next() else {
            throw AppiumError.timeout("Timed out while starting WebDriverAgent.")
        }
        group.cancelAll()
        return value
    }
}

enum AppiumError: LocalizedError {
    case missingSessionID
    case invalidResponse(String)
    case httpStatus(Int, String)
    case timeout(String)
    case signingConfigurationRequired

    static func controlFailureMessage(for error: Error) -> String {
        if case AppiumError.signingConfigurationRequired = error {
            return "control.error.signingSetupRequired"
        }
        let haystack = [String(describing: error), error.localizedDescription]
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("unlock") && (haystack.contains("to continue") || haystack.contains("device is locked")) {
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

    static func shouldRetryWithFreshWDA(afterSessionError error: Error) -> Bool {
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
            || haystack.contains("code signing")
            || haystack.contains("requires a development team") {
            return false
        }
        return haystack.contains("connection was refused")
            || haystack.contains("econnrefused")
            || haystack.contains("8100")
            || haystack.contains("did not become ready")
            || haystack.contains("wda is not listening")
            || haystack.contains("timed out while starting webdriveragent")
            || haystack.contains("xctestmanager")
            || haystack.contains("socket hang up")
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
        case .missingSessionID:
            "Appium did not return a session id."
        case let .invalidResponse(message):
            message
        case let .httpStatus(status, body):
            "Appium HTTP \(status): \(Self.compactResponseBody(body))"
        case let .timeout(message):
            message
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
