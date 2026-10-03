import CoreGraphics
import Foundation
import XCTest
@testable import StupidMirrorApp

/// Answers WebDriverAgent requests from a script and records what was sent.
actor WDAStub {
    struct Request: Equatable, @unchecked Sendable {
        let method: String
        let path: String
        let body: [String: AnyHashable]?
        /// The whole decoded body, including nested arrays `body` drops.
        let json: [String: Any]?

        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.method == rhs.method && lhs.path == rhs.path && lhs.body == rhs.body
        }
    }

    private(set) var requests: [Request] = []
    /// Everything except the snapshot-depth switches around element lookups.
    var elementRequests: [Request] {
        requests.filter { !$0.path.hasSuffix("/appium/settings") }
    }
    var attributeValue: String?
    var placeholderValue: String?
    var activeStatus = 200

    init(attributeValue: String? = "", placeholderValue: String? = nil, activeStatus: Int = 200) {
        self.attributeValue = attributeValue
        self.placeholderValue = placeholderValue
        self.activeStatus = activeStatus
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.path
        var body: [String: AnyHashable]?
        var json: [String: Any]?
        if let data = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = object.compactMapValues { $0 as? AnyHashable }
            json = object
        }
        requests.append(Request(method: request.httpMethod ?? "", path: path, body: body, json: json))

        var status = 200
        var value: Any = [:]
        switch true {
        case path.hasSuffix("/session") && request.httpMethod == "POST":
            value = ["sessionId": "session-1", "capabilities": [:]]
        case path.hasSuffix("/window/size"):
            value = ["width": 390, "height": 844]
        case path.hasSuffix("/element/active"):
            status = activeStatus
            value = status == 200
                ? [SemanticElementLocator.w3cElementKey: "element-1"]
                : ["error": "no such element", "message": "no active element"]
        case path.hasSuffix("/element") && request.httpMethod == "POST":
            value = [SemanticElementLocator.w3cElementKey: "element-1"]
        case path.hasSuffix("/attribute/placeholderValue"):
            value = placeholderValue as Any
        case path.hasSuffix("/attribute/value"):
            value = attributeValue as Any
        default:
            value = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: ["value": value])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

final class WDAControlBackendTests: XCTestCase {
    private func backend(_ stub: WDAStub) -> WDAControlBackend {
        WDAControlBackend(
            baseURL: URL(string: "http://127.0.0.1:18100")!,
            sessionID: "session-1",
            screenSize: DeviceScreenSize(width: 390, height: 844)
        ) { request in
            try await stub.response(for: request)
        }
    }

    func testConnectCreatesASessionTunesItAndReadsTheScreen() async throws {
        let stub = WDAStub()
        let backend = try await WDAControlBackend.connect(baseURL: URL(string: "http://127.0.0.1:18100")!) { request in
            try await stub.response(for: request)
        }
        XCTAssertEqual(backend.sessionID, "session-1")
        XCTAssertEqual(backend.screenSize, DeviceScreenSize(width: 390, height: 844))
        let paths = await stub.requests.map(\.path)
        XCTAssertEqual(paths, ["/session", "/session/session-1/appium/settings", "/session/session-1/window/size"])
        let settings = await stub.requests[1].body?["settings"] as? [String: AnyHashable]
        XCTAssertEqual(settings?["animationCoolOffTimeout"], 0.0)
        XCTAssertEqual(settings?["waitForIdleTimeout"], 0.0)
    }

    func testClearTextUsesTheActiveElementAndTreatsPlaceholderAsEmpty() async throws {
        let stub = WDAStub(attributeValue: "请输入搜索内容", placeholderValue: "请输入搜索内容")
        let result = try await backend(stub).clearActiveText()
        XCTAssertEqual(result.value, "")
        XCTAssertTrue(result.verified)
        let paths = await stub.elementRequests.map(\.path)
        XCTAssertEqual(paths, [
            "/session/session-1/element/active",
            "/session/session-1/element/element-1/clear",
            "/session/session-1/element/element-1/attribute/value",
            "/session/session-1/element/element-1/attribute/placeholderValue"
        ])
    }

    func testReplaceTextClearsSetsAndVerifies() async throws {
        let stub = WDAStub(attributeValue: "瑞幸咖啡")
        let result = try await backend(stub).replaceActiveText("瑞幸咖啡")
        XCTAssertEqual(result.value, "瑞幸咖啡")
        XCTAssertEqual(result.strategy, "wda_active_element_clear_and_set")
        let requests = await stub.elementRequests
        XCTAssertEqual(requests.map(\.path), [
            "/session/session-1/element/active",
            "/session/session-1/element/element-1/clear",
            "/session/session-1/element/element-1/value",
            "/session/session-1/element/element-1/attribute/value"
        ])
        XCTAssertEqual(requests[2].body?["text"], "瑞幸咖啡")
    }

    func testReplaceTextRejectsAMismatchedValue() async throws {
        let stub = WDAStub(attributeValue: "旧值")
        do {
            _ = try await backend(stub).replaceActiveText("新值")
            XCTFail("expected a verification failure")
        } catch let ControlBackendError.rejected(message) {
            XCTAssertTrue(message.contains("did not match"))
        }
    }

    func testActiveElementFallsBackToTheFocusedInputPredicate() async throws {
        let stub = WDAStub(attributeValue: "回退成功", activeStatus: 404)
        let result = try await backend(stub).replaceActiveText("回退成功")
        XCTAssertEqual(result.value, "回退成功")
        let requests = await stub.elementRequests
        XCTAssertEqual(requests[0].path, "/session/session-1/element/active")
        XCTAssertEqual(requests[1].path, "/session/session-1/element")
        XCTAssertEqual(requests[1].body?["using"], "predicate string")
    }

    func testGesturesUseWebDriverAgentsOwnEndpoints() async throws {
        let stub = WDAStub()
        let backend = backend(stub)
        try await backend.tap(CGPoint(x: 10.4, y: 20.6))
        try await backend.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), durationMS: 220)
        try await backend.typeText("hi")
        try await backend.press(.home)
        try await backend.press(.back)
        try await backend.press(.appSwitcher)
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.path), [
            "/session/session-1/wda/tap",
            "/session/session-1/wda/pressAndDragWithVelocity",
            "/session/session-1/wda/keys",
            "/session/session-1/wda/pressButton",
            "/session/session-1/wda/pressAndDragWithVelocity",
            "/session/session-1/wda/pressAndDragWithVelocity"
        ])
        XCTAssertEqual(requests[0].body?["x"], 10.0)
        XCTAssertEqual(requests[0].body?["y"], 21.0)
        // A swipe lifts while moving at the speed it was made with: no hold
        // before or after, ~141 points in 220 ms.
        XCTAssertEqual(requests[1].body?["pressDuration"], 0.0)
        XCTAssertEqual(requests[1].body?["holdDuration"], 0.0)
        XCTAssertEqual((requests[1].body?["velocity"] as? Double) ?? 0, 643, accuracy: 1)
        XCTAssertEqual(requests[2].body?["value"], ["h", "i"])
        XCTAssertEqual(requests[3].body?["name"], "home")
        // The back gesture starts at the left screen edge.
        XCTAssertEqual(requests[4].body?["fromX"], 2.0)
        XCTAssertEqual(requests[5].body?["holdDuration"], 0.6)
    }

    func testDragVelocityIsBoundedForTinyAndInstantMoves() {
        let instant = WDAControlBackend.dragPayload(from: .zero, to: CGPoint(x: 0, y: 800), durationMS: 0)
        XCTAssertEqual(instant["velocity"] as? Double, 6_000)
        let crawl = WDAControlBackend.dragPayload(from: .zero, to: CGPoint(x: 0, y: 4), durationMS: 1_000)
        XCTAssertEqual(crawl["velocity"] as? Double, 200)
    }

    func testLiveSettingsKeepSnapshotsShallow() {
        XCTAssertEqual(WDAControlBackend.liveControlSettings()["snapshotMaxDepth"] as? Int, WDASnapshotDepth.shallow)
    }

    func testElementLookupsRunWithTheFullTreeAndRestoreTheShallowOne() async throws {
        let stub = WDAStub(attributeValue: "x")
        _ = try await backend(stub).replaceActiveText("x")
        let requests = await stub.requests
        let settings = requests.filter { $0.path.hasSuffix("/appium/settings") }
        XCTAssertEqual(settings.count, 2)
        XCTAssertEqual((settings[0].body?["settings"] as? [String: AnyHashable])?["snapshotMaxDepth"], WDASnapshotDepth.deep)
        XCTAssertEqual((settings[1].body?["settings"] as? [String: AnyHashable])?["snapshotMaxDepth"], WDASnapshotDepth.shallow)
        XCTAssertEqual(requests.first?.path, "/session/session-1/appium/settings")
        XCTAssertEqual(requests.last?.path, "/session/session-1/appium/settings")
    }

    func testPinchAndRotateUseTwoFingersAroundThePointer() async throws {
        let stub = WDAStub()
        let backend = backend(stub)
        try await backend.pinch(at: CGPoint(x: 100, y: 200), scale: 2, velocity: 4)
        try await backend.rotate(at: CGPoint(x: 100, y: 200), degrees: 90, velocity: 180)
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.path), ["/session/session-1/actions", "/session/session-1/actions"])
        for request in requests {
            let fingers = try XCTUnwrap(request.json?["actions"] as? [[String: Any]])
            XCTAssertEqual(fingers.count, 2)
            let starts = fingers.compactMap { ($0["actions"] as? [[String: Any]])?.first }
            let midX = starts.compactMap { $0["x"] as? Int }.reduce(0, +) / 2
            let midY = starts.compactMap { $0["y"] as? Int }.reduce(0, +) / 2
            XCTAssertEqual(Double(midX), 100, accuracy: 2)
            XCTAssertEqual(Double(midY), 200, accuracy: 2)
        }
        // Zooming in: the fingers end farther apart than they started.
        let pinch = try XCTUnwrap(requests[0].json?["actions"] as? [[String: Any]])
        let moves = pinch.compactMap { ($0["actions"] as? [[String: Any]]) }
        let startGap = abs((moves[0][0]["x"] as? Int ?? 0) - (moves[1][0]["x"] as? Int ?? 0))
        let endGap = abs((moves[0][2]["x"] as? Int ?? 0) - (moves[1][2]["x"] as? Int ?? 0))
        XCTAssertGreaterThan(endGap, startGap)
        XCTAssertEqual(moves[0][2]["duration"] as? Int, 250)
    }

    func testInvalidSessionResponsesAreSessionLosses() {
        let lost = WDAHTTPClient.classify(
            status: 404,
            body: ["value": ["error": "invalid session id", "message": "Session does not exist"]],
            raw: Data()
        )
        XCTAssertTrue(lost.isSessionLoss)
        let rejected = WDAHTTPClient.classify(
            status: 404,
            body: ["value": ["error": "no such element", "message": "unable to find"]],
            raw: Data()
        )
        XCTAssertFalse(rejected.isSessionLoss)
        XCTAssertTrue(DeviceControlSession.isSessionLoss(URLError(.cannotConnectToHost)))
        XCTAssertFalse(DeviceControlSession.isSessionLoss(URLError(.badServerResponse)))
    }
}
