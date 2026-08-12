import Foundation
@testable import StupidMirrorApp
import XCTest

final class AppiumTextInputTests: XCTestCase {
    func testClearTextUsesActiveElementAndVerifiesEmptyValue() async throws {
        let stub = AppiumTextHTTPStub(attributeValue: "")
        let client = AppiumHTTPClient(baseURL: "http://127.0.0.1:4723") { request in
            try await stub.response(for: request)
        }

        let result = try await client.clearActiveText(sessionID: "session-1")

        XCTAssertEqual(result.strategy, "wda_active_element_clear")
        XCTAssertEqual(result.value, "")
        XCTAssertTrue(result.verified)
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "GET"])
        XCTAssertEqual(requests.map(\.path), [
            "/session/session-1/element/active",
            "/session/session-1/element/element-1/clear",
            "/session/session-1/element/element-1/attribute/value"
        ])
    }

    func testReplaceTextClearsSetsAndVerifiesUnicodeValue() async throws {
        let stub = AppiumTextHTTPStub(attributeValue: "瑞幸咖啡")
        let client = AppiumHTTPClient(baseURL: "http://127.0.0.1:4723") { request in
            try await stub.response(for: request)
        }

        let result = try await client.replaceActiveText(
            sessionID: "session-2",
            text: "瑞幸咖啡"
        )

        XCTAssertEqual(result.strategy, "wda_active_element_clear_and_set")
        XCTAssertEqual(result.value, "瑞幸咖啡")
        XCTAssertTrue(result.verified)
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "POST", "GET"])
        XCTAssertEqual(requests.map(\.path), [
            "/session/session-2/element/active",
            "/session/session-2/element/element-1/clear",
            "/session/session-2/element/element-1/value",
            "/session/session-2/element/element-1/attribute/value"
        ])
        let body = try XCTUnwrap(requests[2].body)
        XCTAssertEqual(body["text"] as? String, "瑞幸咖啡")
    }

    func testClearTextTreatsPlaceholderValueAsEmptyContent() async throws {
        let stub = AppiumTextHTTPStub(
            attributeValue: "请输入搜索内容",
            placeholderValue: "请输入搜索内容"
        )
        let client = AppiumHTTPClient(baseURL: "http://127.0.0.1:4723") { request in
            try await stub.response(for: request)
        }

        let result = try await client.clearActiveText(sessionID: "session-placeholder")

        XCTAssertEqual(result.value, "")
        XCTAssertTrue(result.verified)
        let requests = await stub.requests
        XCTAssertEqual(requests.last?.path, "/session/session-placeholder/element/element-1/attribute/placeholderValue")
    }

    func testReplaceTextRejectsUnverifiedValue() async throws {
        let stub = AppiumTextHTTPStub(attributeValue: "旧值")
        let client = AppiumHTTPClient(baseURL: "http://127.0.0.1:4723") { request in
            try await stub.response(for: request)
        }

        do {
            _ = try await client.replaceActiveText(sessionID: "session-3", text: "新值")
            XCTFail("Expected replacement verification to fail")
        } catch let AppiumError.invalidResponse(message) {
            XCTAssertTrue(message.contains("did not match"))
        }
    }

    func testReplaceTextFallsBackToFocusedInputPredicateWhenActiveEndpointReturns404() async throws {
        let stub = AppiumTextHTTPStub(attributeValue: "回退成功", activeStatusCode: 404)
        let client = AppiumHTTPClient(baseURL: "http://127.0.0.1:4723") { request in
            try await stub.response(for: request)
        }

        let result = try await client.replaceActiveText(
            sessionID: "session-fallback",
            text: "回退成功"
        )

        XCTAssertEqual(result.value, "回退成功")
        let requests = await stub.requests
        XCTAssertEqual(requests[0].path, "/session/session-fallback/element/active")
        XCTAssertEqual(requests[1].path, "/session/session-fallback/element")
        XCTAssertEqual(requests[1].body?["using"] as? String, "-ios predicate string")
        XCTAssertTrue((requests[1].body?["value"] as? String)?.contains("focused == 1") == true)
    }
}

private actor AppiumTextHTTPStub {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let bodyData: Data?

        var body: [String: Any]? {
            guard let bodyData else { return nil }
            return try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        }
    }

    private(set) var requests: [RecordedRequest] = []
    private let attributeValue: String
    private let placeholderValue: String?
    private let activeStatusCode: Int

    init(
        attributeValue: String,
        placeholderValue: String? = nil,
        activeStatusCode: Int = 200
    ) {
        self.attributeValue = attributeValue
        self.placeholderValue = placeholderValue
        self.activeStatusCode = activeStatusCode
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        requests.append(RecordedRequest(
            method: request.httpMethod ?? "",
            path: path,
            bodyData: request.httpBody
        ))
        let value: Any
        let statusCode: Int
        if path.hasSuffix("/element/active") {
            value = [AppiumSemanticElementResolver.w3cElementKey: "element-1"]
            statusCode = activeStatusCode
        } else if path.hasSuffix("/element") {
            value = [AppiumSemanticElementResolver.w3cElementKey: "element-1"]
            statusCode = 200
        } else if path.hasSuffix("/attribute/value") {
            value = attributeValue
            statusCode = 200
        } else if path.hasSuffix("/attribute/placeholderValue") {
            value = placeholderValue ?? NSNull()
            statusCode = 200
        } else {
            value = NSNull()
            statusCode = 200
        }
        let data = try JSONSerialization.data(withJSONObject: ["value": value])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}
