import CoreGraphics
import Foundation

/// Talks to WebDriverAgent directly over HTTP. The runner is reached through
/// the device tunnel sidecar's loopback forward, so the same client serves
/// USB and Wi-Fi iPhones.
final class WDAControlBackend: ControlBackend, @unchecked Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let sessionID: String
    private let http: WDAHTTPClient
    private let sizeLock = NSLock()
    private var cachedScreenSize: DeviceScreenSize
    private let snapshotDepth: WDASnapshotDepth

    var screenSize: DeviceScreenSize {
        sizeLock.withLock { cachedScreenSize }
    }

    init(baseURL: URL, sessionID: String, screenSize: DeviceScreenSize, dataLoader: @escaping DataLoader = WDAHTTPClient.defaultLoader) {
        self.baseURL = baseURL
        self.sessionID = sessionID
        self.cachedScreenSize = screenSize
        let http = WDAHTTPClient(baseURL: baseURL, dataLoader: dataLoader)
        self.http = http
        self.snapshotDepth = WDASnapshotDepth(http: http, sessionID: sessionID)
    }

    /// Opens a WebDriverAgent session on a running runner, tunes it for live
    /// control, and reads the screen size.
    static func connect(
        baseURL: URL,
        dataLoader: @escaping DataLoader = WDAHTTPClient.defaultLoader
    ) async throws -> WDAControlBackend {
        let http = WDAHTTPClient(baseURL: baseURL, dataLoader: dataLoader)
        let created = try await http.request("POST", "/session", payload: [
            "capabilities": ["alwaysMatch": [:], "firstMatch": [[:]]]
        ], timeout: 60)
        guard let sessionID = (created["sessionId"] as? String)
                ?? ((created["value"] as? [String: Any])?["sessionId"] as? String) else {
            throw ControlBackendError.invalidResponse("WebDriverAgent did not return a session id.")
        }
        _ = try await http.request("POST", "/session/\(sessionID)/appium/settings", payload: [
            "settings": Self.liveControlSettings()
        ])
        let size = try await Self.windowSize(http, sessionID: sessionID)
        return WDAControlBackend(baseURL: baseURL, sessionID: sessionID, screenSize: size, dataLoader: dataLoader)
    }

    /// WebDriverAgent waits for animations and idle after every event by
    /// default. The live mirror is the visual confirmation, so those waits only
    /// add latency to interactive control.
    ///
    /// It also snapshots the foreground app's accessibility tree around every
    /// gesture. Coordinate gestures need only the root, and on an iPhone 15
    /// Pro (iOS 27) a shallow snapshot takes a tap from about 900 ms to about
    /// 400 ms and the window-size ping from 340 ms to 45 ms. Element lookups
    /// raise the depth for their duration (`WDASnapshotDepth`).
    nonisolated static func liveControlSettings() -> [String: Any] {
        [
            "animationCoolOffTimeout": 0.0,
            "waitForIdleTimeout": 0.0,
            "snapshotMaxDepth": WDASnapshotDepth.shallow,
            "useFirstMatch": true,
            "shouldUseCompactResponses": false,
            "elementResponseAttributes": "type,name,label,text,rect,enabled,displayed,selected"
        ]
    }

    /// Runs an element lookup with the full accessibility tree available.
    private func withElementTree<T>(_ body: () async throws -> T) async throws -> T {
        try await snapshotDepth.enter()
        do {
            let value = try await body()
            await snapshotDepth.leave()
            return value
        } catch {
            await snapshotDepth.leave()
            throw error
        }
    }

    private static func windowSize(_ http: WDAHTTPClient, sessionID: String) async throws -> DeviceScreenSize {
        let response = try await http.request("GET", "/session/\(sessionID)/window/size")
        guard let value = response["value"] as? [String: Any],
              let width = SemanticElementLocator.number(value["width"]),
              let height = SemanticElementLocator.number(value["height"]),
              width > 0, height > 0 else {
            throw ControlBackendError.invalidResponse("WebDriverAgent returned no window size.")
        }
        return DeviceScreenSize(width: width, height: height)
    }

    private func sessionPath(_ path: String) -> String {
        "/session/\(sessionID)\(path)"
    }

    // MARK: Gestures

    func tap(_ point: CGPoint) async throws {
        _ = try await http.request("POST", sessionPath("/wda/tap"), payload: ["x": point.x.rounded(), "y": point.y.rounded()])
    }

    func doubleTap(_ point: CGPoint) async throws {
        _ = try await http.request("POST", sessionPath("/wda/doubleTap"), payload: ["x": point.x.rounded(), "y": point.y.rounded()])
    }

    func longPress(_ point: CGPoint, durationSeconds: Double) async throws {
        _ = try await http.request("POST", sessionPath("/wda/touchAndHold"), payload: [
            "x": point.x.rounded(), "y": point.y.rounded(), "duration": durationSeconds
        ])
    }

    func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) async throws {
        _ = try await http.request("POST", sessionPath("/wda/pressAndDragWithVelocity"), payload: Self.dragPayload(from: start, to: end, durationMS: durationMS))
    }

    /// A straight finger movement that covers the distance in `durationMS`
    /// and lifts while still moving, so scroll views keep their momentum.
    /// (`/wda/dragfromtoforduration` cannot express speed: its duration is a
    /// hold before the move, and the move itself is a slow fixed-speed drag.)
    nonisolated static func dragPayload(from start: CGPoint, to end: CGPoint, durationMS: Int) -> [String: Any] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let seconds = max(Double(durationMS), 40) / 1_000
        return [
            "fromX": start.x.rounded(), "fromY": start.y.rounded(),
            "toX": end.x.rounded(), "toY": end.y.rounded(),
            "pressDuration": 0.0,
            "holdDuration": 0.0,
            "velocity": min(max(Double(distance) / seconds, 200), 6_000).rounded()
        ]
    }

    func dragPath(_ samples: [DevicePathSample]) async throws {
        guard samples.count >= 2 else {
            if let only = samples.first { try await tap(only.point) }
            return
        }
        _ = try await http.request("POST", sessionPath("/actions"), payload: W3CPointerAction.path(samples), timeout: 20)
    }

    /// Two fingers around `center`, so the zoom lands where the pointer is.
    /// (`/wda/pinch` always pinches around the middle of the app.)
    func pinch(at center: CGPoint, scale: Double, velocity: Double) async throws {
        let payload = W3CPointerAction.pinch(at: center, scale: scale, velocity: velocity, within: screenSize)
        _ = try await http.request("POST", sessionPath("/actions"), payload: payload, timeout: 20)
    }

    func rotate(at center: CGPoint, degrees: Double, velocity: Double) async throws {
        let payload = W3CPointerAction.rotate(at: center, degrees: degrees, velocity: velocity, within: screenSize)
        _ = try await http.request("POST", sessionPath("/actions"), payload: payload, timeout: 20)
    }

    func typeText(_ text: String) async throws {
        _ = try await http.request("POST", sessionPath("/wda/keys"), payload: [
            "value": text.map { String($0) },
            "frequency": 60
        ])
    }

    func press(_ button: DeviceButton) async throws {
        switch button {
        case .home:
            _ = try await http.request("POST", sessionPath("/wda/pressButton"), payload: ["name": "home"])
        case .volumeUp:
            _ = try await http.request("POST", sessionPath("/wda/pressButton"), payload: ["name": "volumeUp"])
        case .volumeDown:
            _ = try await http.request("POST", sessionPath("/wda/pressButton"), payload: ["name": "volumeDown"])
        case .back:
            // iOS has no back button; the system-wide gesture is a swipe from the
            // left screen edge.
            let size = screenSize
            try await drag(
                from: CGPoint(x: 2, y: size.height * 0.5),
                to: CGPoint(x: size.width * 0.6, y: size.height * 0.5),
                durationMS: 180
            )
        case .appSwitcher:
            // A short swipe up from the bottom edge that stops and holds opens
            // the app switcher on every modern iPhone.
            let size = screenSize
            _ = try await http.request("POST", sessionPath("/wda/pressAndDragWithVelocity"), payload: [
                "fromX": size.width / 2, "fromY": size.height - 1,
                "toX": size.width / 2, "toY": size.height * 0.45,
                "pressDuration": 0.0, "holdDuration": 0.6, "velocity": 900
            ])
        }
    }

    // MARK: Text editing

    func clearActiveText() async throws -> ControlTextEditResult {
        try await withElementTree { try await clearActiveTextInTree() }
    }

    func replaceActiveText(_ text: String) async throws -> ControlTextEditResult {
        try await withElementTree { try await replaceActiveTextInTree(text) }
    }

    private func clearActiveTextInTree() async throws -> ControlTextEditResult {
        let elementID = try await activeElementReference()
        _ = try await http.request("POST", sessionPath("/element/\(elementID)/clear"), payload: [:])
        let value = try await attribute("value", of: elementID)
        if let value, !value.isEmpty {
            // XCUITest reports a text field's placeholder as its value once it
            // is empty, so that is still success.
            let placeholder = try? await attribute("placeholderValue", of: elementID)
            guard value == placeholder else {
                throw ControlBackendError.rejected("The active field still contains text after clear.")
            }
        }
        return ControlTextEditResult(strategy: "wda_active_element_clear", value: "", verified: true)
    }

    private func replaceActiveTextInTree(_ text: String) async throws -> ControlTextEditResult {
        let elementID = try await activeElementReference()
        _ = try await http.request("POST", sessionPath("/element/\(elementID)/clear"), payload: [:])
        _ = try await http.request("POST", sessionPath("/element/\(elementID)/value"), payload: [
            "text": text,
            "value": text.map { String($0) }
        ])
        let value = try await attribute("value", of: elementID)
        guard value == text else {
            throw ControlBackendError.rejected("The active field value did not match the requested replacement.")
        }
        return ControlTextEditResult(strategy: "wda_active_element_clear_and_set", value: value, verified: true)
    }

    private func activeElementReference() async throws -> String {
        do {
            let response = try await http.request("GET", sessionPath("/element/active"))
            if let value = response["value"] as? [String: Any],
               let reference = SemanticElementLocator.elementReference(value) {
                return reference
            }
        } catch let error as ControlBackendError {
            // Some system text fields answer 404 even while focused. Fall back
            // to a predicate lookup of the focused editable control.
            guard case .rejected = error else { throw error }
        }
        if let value = try await findFirst(SemanticElementLocator.focusedIOSInputLocator),
           let reference = SemanticElementLocator.elementReference(value) {
            return reference
        }
        throw ControlBackendError.rejected("No focused input element. Focus a text field before editing text.")
    }

    private func attribute(_ name: String, of elementID: String) async throws -> String? {
        let response = try await http.request("GET", sessionPath("/element/\(elementID)/attribute/\(name)"))
        if response["value"] is NSNull { return nil }
        return response["value"] as? String
    }

    // MARK: Observation

    func screenshotPNG() async throws -> Data {
        let response = try await http.request("GET", sessionPath("/screenshot"), timeout: 20)
        guard let encoded = response["value"] as? String, let data = Data(base64Encoded: encoded) else {
            throw ControlBackendError.invalidResponse("Missing PNG screenshot data.")
        }
        return data
    }

    func uiTree() async throws -> String {
        try await withElementTree {
            let response = try await http.request("GET", sessionPath("/source"), timeout: 60)
            guard let source = response["value"] as? String else {
                throw ControlBackendError.invalidResponse("Missing accessibility source.")
            }
            return source
        }
    }

    func findTextElements(query: String, maximumMatches: Int) async throws -> [NativeElementMatch] {
        guard maximumMatches > 0 else { return [] }
        return try await withElementTree {
            guard let value = try await findFirst(SemanticElementLocator.textContainsLocator(query: query, platform: .iOS)),
                  let reference = SemanticElementLocator.elementReference(value) else { return [] }
            let element = SemanticElementLocator.publicElement(
                from: value,
                reference: reference,
                query: query,
                screenSize: screenSize
            )
            return [NativeElementMatch(reference: reference, query: query, element: element)]
        }
    }

    func click(elementReference: String) async throws {
        try await withElementTree {
            _ = try await http.request("POST", sessionPath("/element/\(elementReference)/click"), payload: [:])
        }
    }

    func click(semantic element: ScreenElement) async throws -> Bool {
        guard element.source == .accessibility else { return false }
        return try await withElementTree { try await clickSemanticInTree(element) }
    }

    private func clickSemanticInTree(_ element: ScreenElement) async throws -> Bool {
        for locator in SemanticElementLocator.locators(for: element, platform: .iOS) {
            let references = try await findAll(locator)
            guard !references.isEmpty else { continue }
            var candidates: [ResolvedNativeElement] = []
            for reference in references.prefix(12) {
                let rect = try? await elementRect(reference)
                candidates.append(ResolvedNativeElement(id: reference, frame: rect))
            }
            guard let selected = SemanticElementLocator.bestMatch(among: candidates, observedFrame: element.frame) else {
                continue
            }
            _ = try await http.request("POST", sessionPath("/element/\(selected.id)/click"), payload: [:])
            return true
        }
        return false
    }

    private func findFirst(_ locator: SemanticLocator) async throws -> [String: Any]? {
        do {
            let response = try await http.request("POST", sessionPath("/element"), payload: [
                "using": locator.using, "value": locator.value
            ])
            return response["value"] as? [String: Any]
        } catch let error as ControlBackendError {
            if case .rejected = error { return nil }
            throw error
        }
    }

    private func findAll(_ locator: SemanticLocator) async throws -> [String] {
        let response = try await http.request("POST", sessionPath("/elements"), payload: [
            "using": locator.using, "value": locator.value
        ])
        guard let values = response["value"] as? [[String: Any]] else { return [] }
        return values.compactMap(SemanticElementLocator.elementReference)
    }

    private func elementRect(_ elementID: String) async throws -> ScreenElementFrame {
        let response = try await http.request("GET", sessionPath("/element/\(elementID)/rect"))
        guard let frame = SemanticElementLocator.frame(response["value"]) else {
            throw ControlBackendError.invalidResponse("Missing element rectangle.")
        }
        return frame
    }

    // MARK: Apps

    func activateApp(_ identifier: String) async throws {
        _ = try await http.request("POST", sessionPath("/wda/apps/activate"), payload: ["bundleId": identifier])
    }

    func terminateApp(_ identifier: String) async throws -> Bool {
        let response = try await http.request("POST", sessionPath("/wda/apps/terminate"), payload: ["bundleId": identifier])
        return response["value"] as? Bool ?? true
    }

    // MARK: Lifecycle

    func ping() async throws -> DeviceScreenSize {
        let size = try await Self.windowSize(http, sessionID: sessionID)
        sizeLock.withLock { cachedScreenSize = size }
        return size
    }

    func close() async {
        _ = try? await http.request("DELETE", sessionPath(""), timeout: 5)
    }
}

/// Holds WebDriverAgent's `snapshotMaxDepth` shallow for coordinate
/// gestures and deep while any element lookup runs. Changes are applied in
/// order, each reading the current number of lookups when it runs, so the
/// last request sent always matches what is in flight.
actor WDASnapshotDepth {
    static let shallow = 1
    static let deep = 50

    private let http: WDAHTTPClient
    private let sessionID: String
    private var users = 0
    private var applied = WDASnapshotDepth.shallow
    private var chain: Task<Void, Error>?

    init(http: WDAHTTPClient, sessionID: String) {
        self.http = http
        self.sessionID = sessionID
    }

    func enter() async throws {
        users += 1
        do {
            try await apply()
        } catch {
            users -= 1
            throw error
        }
    }

    func leave() async {
        users = max(users - 1, 0)
        try? await apply()
    }

    private func apply() async throws {
        let previous = chain
        let task = Task {
            _ = await previous?.result
            try await self.sendIfNeeded()
        }
        chain = task
        try await task.value
    }

    private func sendIfNeeded() async throws {
        let wanted = users > 0 ? Self.deep : Self.shallow
        guard wanted != applied else { return }
        _ = try await http.request("POST", "/session/\(sessionID)/appium/settings", payload: [
            "settings": ["snapshotMaxDepth": wanted]
        ])
        applied = wanted
    }
}

/// Minimal JSON-over-HTTP client for WebDriverAgent. Errors are classified
/// so the session knows whether to retry on a fresh session or report them.
struct WDAHTTPClient: Sendable {
    static let defaultLoader: WDAControlBackend.DataLoader = { request in
        try await URLSession.shared.data(for: request)
    }

    let baseURL: URL
    let dataLoader: WDAControlBackend.DataLoader

    func request(
        _ method: String,
        _ path: String,
        payload: [String: Any]? = nil,
        timeout: TimeInterval = 15
    ) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
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
                throw ControlBackendError.sessionLost("WebDriverAgent is unreachable: \(error.localizedDescription)")
            }
            throw error
        }
        let object = data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.classify(status: http.statusCode, body: object, raw: data)
        }
        return object
    }

    /// WebDriverAgent answers a dead session with `invalid session id`, and a
    /// runner that is gone with a connection failure. Everything else is the
    /// device refusing one request.
    static func classify(status: Int, body: [String: Any], raw: Data) -> ControlBackendError {
        let value = body["value"] as? [String: Any]
        let errorName = (value?["error"] as? String) ?? ""
        let message = (value?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (body["message"] as? String)
            ?? String(data: raw, encoding: .utf8)
            ?? ""
        if errorName == "invalid session id" || message.lowercased().contains("invalid session id") {
            return .sessionLost("WebDriverAgent session ended: \(message)")
        }
        return .rejected("WebDriverAgent HTTP \(status): \(message)")
    }
}
