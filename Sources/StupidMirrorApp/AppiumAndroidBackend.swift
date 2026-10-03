import CoreGraphics
import Foundation

/// Android control through Appium's UiAutomator2 driver. The local Appium
/// service is managed by `AppiumServiceManager`; this backend owns one
/// WebDriver session on it.
final class AppiumAndroidBackend: ControlBackend, @unchecked Sendable {
    let client: AppiumHTTPClient
    let sessionID: String
    private let sizeLock = NSLock()
    private var cachedScreenSize: DeviceScreenSize

    var screenSize: DeviceScreenSize {
        sizeLock.withLock { cachedScreenSize }
    }

    init(client: AppiumHTTPClient, sessionID: String, screenSize: DeviceScreenSize) {
        self.client = client
        self.sessionID = sessionID
        self.cachedScreenSize = screenSize
    }

    static func connect(
        serverURL: String,
        udid: String,
        appPackage: String,
        configuration: AppiumControlConfiguration,
        report: @escaping DeviceControlSession.ProgressReporter,
        dataLoader: @escaping AppiumHTTPClient.DataLoader = AppiumHTTPClient.defaultLoader
    ) async throws -> AppiumAndroidBackend {
        let client = AppiumHTTPClient(baseURL: serverURL, dataLoader: dataLoader)
        await report(.startingService, nil)
        try await client.status(timeout: 5)
        await report(.connectingAgent, nil)
        let sessionID = try await client.createSession(udid: udid, appPackage: appPackage, configuration: configuration)
        await report(.finishing, nil)
        _ = try await client.request("POST", "/session/\(sessionID)/appium/settings", payload: [
            "settings": [
                "waitForIdleTimeout": 0,
                "waitForSelectorTimeout": 2_000,
                "actionAcknowledgmentTimeout": 500
            ]
        ])
        let size = try await client.windowSize(sessionID: sessionID)
        return AppiumAndroidBackend(client: client, sessionID: sessionID, screenSize: size)
    }

    private func path(_ suffix: String) -> String { "/session/\(sessionID)\(suffix)" }

    func tap(_ point: CGPoint) async throws {
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.tap(at: point))
    }

    func doubleTap(_ point: CGPoint) async throws {
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.doubleTap(at: point))
    }

    func longPress(_ point: CGPoint, durationSeconds: Double) async throws {
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.longPress(at: point, durationSeconds: durationSeconds))
    }

    func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) async throws {
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.drag(from: start, to: end, durationMS: durationMS))
    }

    func pinch(at center: CGPoint, scale: Double, velocity: Double) async throws {
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.pinch(at: center, scale: scale, velocity: velocity, within: screenSize))
    }

    func rotate(at center: CGPoint, degrees: Double, velocity: Double) async throws {
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.rotate(at: center, degrees: degrees, velocity: velocity, within: screenSize))
    }

    func dragPath(_ samples: [DevicePathSample]) async throws {
        guard samples.count >= 2 else {
            if let only = samples.first { try await tap(only.point) }
            return
        }
        _ = try await client.request("POST", path("/actions"), payload: W3CPointerAction.path(samples))
    }

    func typeText(_ text: String) async throws {
        _ = try await client.request("POST", path("/keys"), payload: ["text": text, "value": text.map { String($0) }])
    }

    func press(_ button: DeviceButton) async throws {
        let keycode: Int
        switch button {
        case .home: keycode = 3
        case .back: keycode = 4
        case .volumeUp: keycode = 24
        case .volumeDown: keycode = 25
        case .appSwitcher: keycode = 187
        }
        try await client.executeMobile(sessionID: sessionID, script: "mobile: pressKey", arguments: ["keycode": keycode])
    }

    func clearActiveText() async throws -> ControlTextEditResult {
        let elementID = try await activeElementReference()
        _ = try await client.request("POST", path("/element/\(elementID)/clear"), payload: [:])
        let value = try await attribute("text", of: elementID)
        if let value, !value.isEmpty {
            throw ControlBackendError.rejected("The active field still contains text after clear.")
        }
        return ControlTextEditResult(strategy: "uiautomator2_active_element_clear", value: value ?? "", verified: true)
    }

    func replaceActiveText(_ text: String) async throws -> ControlTextEditResult {
        let elementID = try await activeElementReference()
        _ = try await client.request("POST", path("/element/\(elementID)/clear"), payload: [:])
        _ = try await client.request("POST", path("/element/\(elementID)/value"), payload: ["text": text, "value": text.map { String($0) }])
        let value = try await attribute("text", of: elementID)
        guard value == text else {
            throw ControlBackendError.rejected("The active field value did not match the requested replacement.")
        }
        return ControlTextEditResult(strategy: "uiautomator2_active_element_clear_and_set", value: value, verified: true)
    }

    private func activeElementReference() async throws -> String {
        do {
            let response = try await client.request("GET", path("/element/active"))
            if let value = response["value"] as? [String: Any],
               let reference = SemanticElementLocator.elementReference(value) {
                return reference
            }
        } catch let error as ControlBackendError {
            guard case .rejected = error else { throw error }
        }
        if let value = try await findFirst(SemanticElementLocator.focusedAndroidInputLocator),
           let reference = SemanticElementLocator.elementReference(value) {
            return reference
        }
        throw ControlBackendError.rejected("No focused input element. Focus a text field before editing text.")
    }

    private func attribute(_ name: String, of elementID: String) async throws -> String? {
        let response = try await client.request("GET", path("/element/\(elementID)/attribute/\(name)"))
        if response["value"] is NSNull { return nil }
        return response["value"] as? String
    }

    func screenshotPNG() async throws -> Data {
        let response = try await client.request("GET", path("/screenshot"), timeout: 20)
        guard let encoded = response["value"] as? String, let data = Data(base64Encoded: encoded) else {
            throw ControlBackendError.invalidResponse("Missing PNG screenshot data.")
        }
        return data
    }

    func uiTree() async throws -> String {
        let response = try await client.request("GET", path("/source"), timeout: 45)
        guard let source = response["value"] as? String else {
            throw ControlBackendError.invalidResponse("Missing accessibility source.")
        }
        return source
    }

    func findTextElements(query: String, maximumMatches: Int) async throws -> [NativeElementMatch] {
        guard maximumMatches > 0,
              let value = try await findFirst(SemanticElementLocator.textContainsLocator(query: query, platform: .android)),
              let reference = SemanticElementLocator.elementReference(value) else { return [] }
        let element = SemanticElementLocator.publicElement(from: value, reference: reference, query: query, screenSize: screenSize)
        return [NativeElementMatch(reference: reference, query: query, element: element)]
    }

    func click(elementReference: String) async throws {
        _ = try await client.request("POST", path("/element/\(elementReference)/click"), payload: [:])
    }

    func click(semantic element: ScreenElement) async throws -> Bool {
        guard element.source == .accessibility else { return false }
        for locator in SemanticElementLocator.locators(for: element, platform: .android) {
            let response = try await client.request("POST", path("/elements"), payload: ["using": locator.using, "value": locator.value])
            let references = ((response["value"] as? [[String: Any]]) ?? []).compactMap(SemanticElementLocator.elementReference)
            guard !references.isEmpty else { continue }
            var candidates: [ResolvedNativeElement] = []
            for reference in references.prefix(12) {
                let rect = try? await client.request("GET", path("/element/\(reference)/rect"))
                candidates.append(ResolvedNativeElement(id: reference, frame: SemanticElementLocator.frame(rect?["value"])))
            }
            guard let selected = SemanticElementLocator.bestMatch(among: candidates, observedFrame: element.frame) else { continue }
            try await click(elementReference: selected.id)
            return true
        }
        return false
    }

    private func findFirst(_ locator: SemanticLocator) async throws -> [String: Any]? {
        do {
            let response = try await client.request("POST", path("/element"), payload: ["using": locator.using, "value": locator.value])
            return response["value"] as? [String: Any]
        } catch let error as ControlBackendError {
            if case .rejected = error { return nil }
            throw error
        }
    }

    func activateApp(_ identifier: String) async throws {
        try await client.executeMobile(sessionID: sessionID, script: "mobile: activateApp", arguments: ["appId": identifier])
    }

    func terminateApp(_ identifier: String) async throws -> Bool {
        let response = try await client.request("POST", path("/execute/sync"), payload: [
            "script": "mobile: terminateApp",
            "args": [["appId": identifier]]
        ])
        return response["value"] as? Bool ?? true
    }

    func ping() async throws -> DeviceScreenSize {
        let size = try await client.windowSize(sessionID: sessionID)
        sizeLock.withLock { cachedScreenSize = size }
        return size
    }

    func close() async {
        _ = try? await client.request("DELETE", "/session/\(sessionID)", timeout: 5)
    }
}

/// JSON client for an Appium server.
struct AppiumHTTPClient: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let defaultLoader: DataLoader = { request in
        try await URLSession.shared.data(for: request)
    }

    let baseURL: URL
    private let dataLoader: DataLoader

    init(baseURL: String, dataLoader: @escaping DataLoader = AppiumHTTPClient.defaultLoader) {
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
        _ = try await request("GET", "/status", timeout: timeout)
    }

    func createSession(udid: String, appPackage: String, configuration: AppiumControlConfiguration) async throws -> String {
        let response = try await request("POST", "/session", payload: [
            "capabilities": [
                "alwaysMatch": AppiumSessionCapabilities.android(udid: udid, appPackage: appPackage, configuration: configuration),
                "firstMatch": [[:]]
            ]
        ], timeout: configuration.sessionStartupTimeoutSeconds + 15)
        if let sessionID = response["sessionId"] as? String { return sessionID }
        if let value = response["value"] as? [String: Any], let sessionID = value["sessionId"] as? String {
            return sessionID
        }
        throw ControlBackendError.invalidResponse("Appium did not return a session id.")
    }

    func windowSize(sessionID: String) async throws -> DeviceScreenSize {
        let response: [String: Any]
        do {
            response = try await request("GET", "/session/\(sessionID)/window/rect")
        } catch ControlBackendError.rejected {
            response = try await request("GET", "/session/\(sessionID)/window/size")
        }
        guard let value = response["value"] as? [String: Any],
              let width = SemanticElementLocator.number(value["width"]),
              let height = SemanticElementLocator.number(value["height"]),
              width > 0, height > 0 else {
            throw ControlBackendError.invalidResponse("Invalid window size.")
        }
        return DeviceScreenSize(width: width, height: height)
    }

    func executeMobile(sessionID: String, script: String, arguments: [String: Any]) async throws {
        _ = try await request("POST", "/session/\(sessionID)/execute/sync", payload: ["script": script, "args": [arguments]])
    }

    func request(
        _ method: String,
        _ path: String,
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
                throw ControlBackendError.invalidResponse("Invalid Appium URL.")
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(request)
        } catch let error as URLError {
            if DeviceControlSession.isSessionLoss(error) {
                throw ControlBackendError.sessionLost("Appium is unreachable: \(error.localizedDescription)")
            }
            throw error
        }
        let object = data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.classify(status: http.statusCode, body: object, raw: data)
        }
        return object
    }

    /// Appium reports a reaped or crashed session with distinctive messages;
    /// those mean "rebuild", everything else means "this request failed".
    static func classify(status: Int, body: [String: Any], raw: Data) -> ControlBackendError {
        let value = body["value"] as? [String: Any]
        let message = (value?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (value?["error"] as? String)
            ?? (body["message"] as? String)
            ?? String(data: raw, encoding: .utf8)
            ?? ""
        let haystack = message.lowercased()
        let lost = haystack.contains("invalid session")
            || haystack.contains("no such driver")
            || haystack.contains("session does not exist")
            || haystack.contains("session is either terminated or not started")
            || haystack.contains("session was terminated")
            || haystack.contains("session not found")
            || haystack.contains("no active session")
            || haystack.contains("econnrefused")
            || haystack.contains("socket hang up")
            || haystack.contains("instrumentation process is not running")
        if lost {
            return .sessionLost("Appium session ended: \(message)")
        }
        return .rejected("Appium HTTP \(status): \(message)")
    }
}

enum AppiumSessionCapabilities {
    static func android(udid: String, appPackage: String, configuration: AppiumControlConfiguration) -> [String: Any] {
        var capabilities: [String: Any] = [
            "platformName": "Android",
            "appium:automationName": "UiAutomator2",
            "appium:udid": udid,
            "appium:noReset": true,
            "appium:newCommandTimeout": configuration.newCommandTimeoutSeconds,
            "appium:systemPort": configuration.uiautomator2SystemPort,
            "appium:mjpegServerPort": configuration.mjpegServerPort,
            "appium:adbExecTimeout": configuration.adbExecTimeoutMS,
            "appium:uiautomator2ServerInstallTimeout": configuration.uiautomator2ServerInstallTimeoutMS,
            "appium:uiautomator2ServerLaunchTimeout": configuration.uiautomator2ServerLaunchTimeoutMS
        ]
        let platformVersion = configuration.platformVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !platformVersion.isEmpty {
            capabilities["appium:platformVersion"] = platformVersion
        }
        let package = appPackage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !package.isEmpty {
            capabilities["appium:appPackage"] = package
            capabilities["appium:dontStopAppOnReset"] = true
        }
        return capabilities
    }
}

/// W3C pointer action payloads: every gesture on Android, and timed paths
/// and multi-touch on iOS.
enum W3CPointerAction {
    static func tap(at point: CGPoint) -> [String: Any] {
        payload(actions: [
            move(to: point),
            ["type": "pointerDown", "button": 0],
            ["type": "pointerUp", "button": 0]
        ])
    }

    static func doubleTap(at point: CGPoint) -> [String: Any] {
        payload(actions: [
            move(to: point),
            ["type": "pointerDown", "button": 0],
            ["type": "pointerUp", "button": 0],
            ["type": "pause", "duration": 80],
            ["type": "pointerDown", "button": 0],
            ["type": "pointerUp", "button": 0]
        ])
    }

    static func longPress(at point: CGPoint, durationSeconds: Double) -> [String: Any] {
        let duration = min(max(Int((durationSeconds * 1_000).rounded()), 100), 10_000)
        return payload(actions: [
            move(to: point),
            ["type": "pointerDown", "button": 0],
            ["type": "pause", "duration": duration],
            ["type": "pointerUp", "button": 0]
        ])
    }

    static func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) -> [String: Any] {
        let duration = min(max(durationMS, 50), 5_000)
        return payload(actions: [
            move(to: start),
            ["type": "pointerDown", "button": 0],
            [
                "type": "pointerMove", "duration": duration,
                "origin": "viewport", "x": Int(end.x.rounded()), "y": Int(end.y.rounded())
            ],
            ["type": "pointerUp", "button": 0]
        ])
    }

    /// A finger-down at the first sample, a timed move to every later sample,
    /// then a lift. The device derives release velocity from the last segment.
    static func path(_ samples: [DevicePathSample]) -> [String: Any] {
        guard let first = samples.first else { return payload(actions: []) }
        var actions: [[String: Any]] = [
            move(to: first.point),
            ["type": "pointerDown", "button": 0]
        ]
        var previousOffset = first.offsetMS
        for sample in samples.dropFirst() {
            let duration = max(sample.offsetMS - previousOffset, 1)
            previousOffset = sample.offsetMS
            actions.append([
                "type": "pointerMove", "duration": duration,
                "origin": "viewport", "x": Int(sample.point.x.rounded()), "y": Int(sample.point.y.rounded())
            ])
        }
        actions.append(["type": "pointerUp", "button": 0])
        return payload(actions: actions)
    }

    /// Two fingers on opposite sides of `center` moving apart (scale > 1) or
    /// together (scale < 1). `velocity` is the scale change per second.
    static func pinch(at center: CGPoint, scale: Double, velocity: Double, within size: DeviceScreenSize) -> [String: Any] {
        let clampedScale = min(max(scale, 0.2), 5)
        let reach = min(size.width, size.height) * 0.4
        let startRadius = clampedScale >= 1 ? reach / clampedScale : reach
        let endRadius = clampedScale >= 1 ? reach : reach * clampedScale
        let duration = gestureDuration(change: abs(clampedScale - 1), rate: abs(velocity))
        let angle = Double.pi / 4
        return twoFingers(
            center: center,
            within: size,
            duration: duration,
            start: (startRadius, angle),
            end: (endRadius, angle)
        )
    }

    /// Two fingers turning around `center`. Degrees are clockwise on screen;
    /// `velocity` is degrees per second.
    static func rotate(at center: CGPoint, degrees: Double, velocity: Double, within size: DeviceScreenSize) -> [String: Any] {
        let radius = min(size.width, size.height) * 0.25
        let duration = gestureDuration(change: abs(degrees), rate: abs(velocity))
        let start = -Double.pi / 2
        return twoFingers(
            center: center,
            within: size,
            duration: duration,
            start: (radius, start),
            end: (radius, start + degrees * .pi / 180)
        )
    }

    private static func gestureDuration(change: Double, rate: Double) -> Int {
        guard rate > 0.001 else { return 300 }
        return min(max(Int((change / rate * 1_000).rounded()), 150), 1_000)
    }

    private static func twoFingers(
        center: CGPoint,
        within size: DeviceScreenSize,
        duration: Int,
        start: (radius: Double, angle: Double),
        end: (radius: Double, angle: Double)
    ) -> [String: Any] {
        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(
                x: min(max(center.x + radius * cos(angle), 1), size.width - 1),
                y: min(max(center.y + radius * sin(angle), 1), size.height - 1)
            )
        }
        func finger(_ id: String, offset: Double) -> [String: Any] {
            let from = point(start.radius, start.angle + offset)
            let to = point(end.radius, end.angle + offset)
            return [
                "type": "pointer",
                "id": id,
                "parameters": ["pointerType": "touch"],
                "actions": [
                    move(to: from),
                    ["type": "pointerDown", "button": 0],
                    [
                        "type": "pointerMove", "duration": duration,
                        "origin": "viewport", "x": Int(to.x.rounded()), "y": Int(to.y.rounded())
                    ],
                    ["type": "pointerUp", "button": 0]
                ]
            ]
        }
        return ["actions": [finger("stupidmirror-finger-1", offset: 0), finger("stupidmirror-finger-2", offset: .pi)]]
    }

    private static func move(to point: CGPoint) -> [String: Any] {
        ["type": "pointerMove", "duration": 0, "origin": "viewport", "x": Int(point.x.rounded()), "y": Int(point.y.rounded())]
    }

    private static func payload(actions: [[String: Any]]) -> [String: Any] {
        [
            "actions": [[
                "type": "pointer",
                "id": "stupidmirror-finger",
                "parameters": ["pointerType": "touch"],
                "actions": actions
            ]]
        ]
    }
}
