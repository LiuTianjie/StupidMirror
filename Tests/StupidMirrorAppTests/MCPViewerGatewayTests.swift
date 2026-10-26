import Foundation
import MCP
import XCTest
@testable import StupidMirrorApp

final class MCPViewerGatewayTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private final class Calls: @unchecked Sendable {
        var names: [String] = []
    }

    private let origin = "http://127.0.0.1:17373"

    private func makeGateway(clock: Clock = Clock(), calls: Calls = Calls()) -> MCPViewerGateway {
        MCPViewerGateway(
            port: 17_373,
            callTool: { name, _ in
                calls.names.append(name)
                return CallTool.Result(content: [], structuredContent: .object(["tool": .string(name)]), isError: false)
            },
            loadPage: { "<!doctype html><html><head><title>t</title></head><body></body></html>" },
            now: { clock.now }
        )
    }

    private func post(
        _ gateway: MCPViewerGateway, _ path: String, _ body: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> MCPViewerResponse {
        var all = ["Host": "127.0.0.1:17373", "Origin": origin, "Content-Type": "application/json"]
        all.merge(headers) { _, new in new }
        return await gateway.handle(
            method: "POST", path: path, headers: all,
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    private func ticket(from link: MCPViewerLink) throws -> String {
        let fragment = try XCTUnwrap(link.url.fragment)
        XCTAssertTrue(fragment.hasPrefix("ticket="))
        return String(fragment.dropFirst("ticket=".count))
    }

    private func session(_ gateway: MCPViewerGateway, deviceID: String? = "phone") async throws -> String {
        let response = try await post(gateway, "/viewer/api/session", ["ticket": try ticket(from: gateway.makeLink(deviceID: deviceID))])
        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try XCTUnwrap(object["session"] as? String)
    }

    private func json(_ response: MCPViewerResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testLinkKeepsTheTicketInTheFragmentOnLoopback() throws {
        let link = try makeGateway().makeLink(deviceID: nil)
        XCTAssertEqual(link.url.scheme, "http")
        XCTAssertEqual(link.url.host, "127.0.0.1")
        XCTAssertEqual(link.url.port, 17_373)
        XCTAssertEqual(link.url.path, "/viewer")
        XCTAssertNil(link.url.query)
        XCTAssertEqual(try ticket(from: link).count, 64)
    }

    func testPageIsMarkedStandaloneAndLockedDown() async throws {
        let response = await makeGateway().handle(method: "GET", path: "/viewer", headers: ["host": "127.0.0.1:17373"], body: nil)
        XCTAssertEqual(response.statusCode, 200)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("<head>" + MCPViewerGateway.pageMarker))
        let csp = try XCTUnwrap(response.headers["Content-Security-Policy"])
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("connect-src 'self'"))
        XCTAssertEqual(response.headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")

        let root = await makeGateway().handle(method: "GET", path: "/", headers: ["Host": "localhost:17373"], body: nil)
        XCTAssertEqual(root.statusCode, 302)
        XCTAssertEqual(root.headers["Location"], "/viewer")
    }

    func testForeignHostIsRejectedBeforeAnyRoute() async {
        let gateway = makeGateway()
        for host in ["evil.example:17373", "127.0.0.1:9999", ""] {
            let response = await gateway.handle(method: "GET", path: "/viewer", headers: ["Host": host], body: nil)
            XCTAssertEqual(response.statusCode, 403, host)
        }
        let missing = await gateway.handle(method: "GET", path: "/viewer", headers: [:], body: nil)
        XCTAssertEqual(missing.statusCode, 403)
    }

    func testTicketIsSingleUseAndBindsTheDevice() async throws {
        let gateway = makeGateway()
        let ticket = try ticket(from: gateway.makeLink(deviceID: "phone-1"))
        let first = try await post(gateway, "/viewer/api/session", ["ticket": ticket])
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(try json(first)["device_id"] as? String, "phone-1")
        let session = try XCTUnwrap(try json(first)["session"] as? String)
        XCTAssertNotEqual(session, ticket)

        let replay = try await post(gateway, "/viewer/api/session", ["ticket": ticket])
        XCTAssertEqual(replay.statusCode, 401)
        let unknown = try await post(gateway, "/viewer/api/session", ["ticket": String(repeating: "0", count: 64)])
        XCTAssertEqual(unknown.statusCode, 401)
    }

    func testTicketExpires() async throws {
        let clock = Clock()
        let gateway = makeGateway(clock: clock)
        let ticket = try ticket(from: gateway.makeLink(deviceID: nil))
        clock.now += MCPViewerGateway.ticketLifetime + 1
        let response = try await post(gateway, "/viewer/api/session", ["ticket": ticket])
        XCTAssertEqual(response.statusCode, 401)
    }

    func testToolCallsNeedASessionAndStayWithinThePanelTransport() async throws {
        let calls = Calls()
        let gateway = makeGateway(calls: calls)
        let anonymous = try await post(gateway, "/viewer/api/call", ["name": "screen_frame", "arguments": [:]])
        XCTAssertEqual(anonymous.statusCode, 401)
        let forged = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"], headers: ["X-StupidMirror-Viewer": "guess"])
        XCTAssertEqual(forged.statusCode, 401)

        let token = try await session(gateway)
        let header = ["X-StupidMirror-Viewer": token]
        for name in ["tap", "type_text", "install_app", "open_viewer", "list_devices"] {
            let response = try await post(gateway, "/viewer/api/call", ["name": name, "arguments": [:]], headers: header)
            XCTAssertEqual(response.statusCode, 403, name)
        }
        XCTAssertEqual(calls.names, [])

        for name in ["show_screen", "screen_frame", "screen_action", "screen_signal"] {
            let response = try await post(gateway, "/viewer/api/call", ["name": name, "arguments": ["device_id": "phone"]], headers: header)
            XCTAssertEqual(response.statusCode, 200, name)
            let result = try json(response)
            XCTAssertEqual((result["structuredContent"] as? [String: Any])?["tool"] as? String, name)
            XCTAssertEqual(result["isError"] as? Bool, false)
        }
        XCTAssertEqual(calls.names, ["show_screen", "screen_frame", "screen_action", "screen_signal"])
    }

    func testCrossOriginAndNonJSONRequestsAreRejected() async throws {
        let gateway = makeGateway()
        let token = try await session(gateway)
        for origin in ["https://evil.example", "http://127.0.0.1:9999", "null"] {
            let response = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"],
                                          headers: ["X-StupidMirror-Viewer": token, "Origin": origin])
            XCTAssertEqual(response.statusCode, 403, origin)
        }
        let noOrigin = await gateway.handle(
            method: "POST", path: "/viewer/api/session",
            headers: ["Host": "127.0.0.1:17373", "Content-Type": "application/json"], body: Data("{}".utf8)
        )
        XCTAssertEqual(noOrigin.statusCode, 403)
        let form = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"],
                                  headers: ["X-StupidMirror-Viewer": token, "Content-Type": "text/plain"])
        XCTAssertEqual(form.statusCode, 415)
    }

    func testSessionsExpireWhenIdleAndOnRevocation() async throws {
        let clock = Clock()
        let gateway = makeGateway(clock: clock)
        let idle = try await session(gateway)
        let active = try await session(gateway)
        clock.now += MCPViewerGateway.sessionIdleLifetime - 60
        let kept = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"], headers: ["X-StupidMirror-Viewer": active])
        XCTAssertEqual(kept.statusCode, 200)
        clock.now += 120
        let expired = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"], headers: ["X-StupidMirror-Viewer": idle])
        XCTAssertEqual(expired.statusCode, 401)
        let stillActive = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"], headers: ["X-StupidMirror-Viewer": active])
        XCTAssertEqual(stillActive.statusCode, 200)

        let pending = try ticket(from: gateway.makeLink(deviceID: nil))
        gateway.revokeAll()
        let revoked = try await post(gateway, "/viewer/api/call", ["name": "screen_frame"], headers: ["X-StupidMirror-Viewer": active])
        XCTAssertEqual(revoked.statusCode, 401)
        let revokedTicket = try await post(gateway, "/viewer/api/session", ["ticket": pending])
        XCTAssertEqual(revokedTicket.statusCode, 401)
    }

    func testOnlyViewerPathsAreRouted() {
        XCTAssertTrue(MCPViewerGateway.handles(path: "/"))
        XCTAssertTrue(MCPViewerGateway.handles(path: "/viewer"))
        XCTAssertTrue(MCPViewerGateway.handles(path: "/viewer/api/call"))
        XCTAssertFalse(MCPViewerGateway.handles(path: "/mcp"))
        XCTAssertFalse(MCPViewerGateway.handles(path: "/viewerx"))
    }
}

final class MCPViewerHTTPRoutingTests: XCTestCase {
    func testViewerRoutesAreServedBesideTheAuthenticatedMCPEndpoint() async throws {
        let port = Int.random(in: 41_000...48_000)
        let gateway = MCPViewerGateway(
            port: port,
            callTool: { name, _ in CallTool.Result(content: [], structuredContent: .object(["tool": .string(name)]), isError: false) },
            loadPage: { "<html><head></head><body>viewer</body></html>" }
        )
        let started = expectation(description: "listening")
        let application = MCPHTTPApplication(
            host: "127.0.0.1", port: port, endpoint: "/mcp",
            validationPipeline: StandardValidationPipeline(validators: [
                MCPBearerTokenValidator(tokenBox: MCPTokenBox(token: "secret"))
            ]),
            serverFactory: { _ in Server(name: "routing-test", version: "1") },
            sessionCountHandler: { _ in }, startedHandler: { started.fulfill() },
            viewer: gateway
        )
        let server = Task { try await application.start() }
        await fulfillment(of: [started], timeout: 5)
        defer { server.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .ephemeral)

        let (page, pageResponse) = try await session.data(from: base.appendingPathComponent("viewer"))
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains(MCPViewerGateway.pageMarker))

        let mcp = try await session.data(for: URLRequest(url: base.appendingPathComponent("mcp")))
        XCTAssertEqual((mcp.1 as? HTTPURLResponse)?.statusCode, 401, "MCP still needs the bearer token")

        let link = try gateway.makeLink(deviceID: "phone")
        var exchange = URLRequest(url: base.appendingPathComponent("viewer/api/session"))
        exchange.httpMethod = "POST"
        exchange.setValue("application/json", forHTTPHeaderField: "Content-Type")
        exchange.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        exchange.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": String(link.url.fragment!.dropFirst(7))])
        let (exchanged, exchangeResponse) = try await session.data(for: exchange)
        XCTAssertEqual((exchangeResponse as? HTTPURLResponse)?.statusCode, 200)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: exchanged) as? [String: Any])?["session"] as? String)

        var call = URLRequest(url: base.appendingPathComponent("viewer/api/call"))
        call.httpMethod = "POST"
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        call.setValue(token, forHTTPHeaderField: "X-StupidMirror-Viewer")
        call.httpBody = Data(#"{"name":"screen_frame","arguments":{"after_seq":0}}"#.utf8)
        let (result, callResponse) = try await session.data(for: call)
        XCTAssertEqual((callResponse as? HTTPURLResponse)?.statusCode, 200)
        let structured = (try JSONSerialization.jsonObject(with: result) as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(structured?["tool"] as? String, "screen_frame")
        await application.stop()
    }
}
