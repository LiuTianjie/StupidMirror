import Foundation
import MCP
@testable import StupidMirrorConnection
import XCTest

final class MCPCompatibilityTransportTests: XCTestCase, @unchecked Sendable {
    private let initialize = Data(#"{"jsonrpc":"2.0","id":"codex-init","method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"codex","version":"test"},"capabilities":{"experimental":{"codex/auth-change":{},"openai/visibility":{"enabled":true},"legacy":"retained"},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}},"roots":{"listChanged":true}}}}"#.utf8)

    func testStructuredExperimentalCapabilitiesNoLongerFailSDKDecoding() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(Request<Initialize>.self, from: initialize))
        let compatible = MCPCompatibilityTransport.compatibleInitialization(initialize)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: compatible)
        XCTAssertEqual(request.id, "codex-init")
        XCTAssertEqual(request.params.capabilities.experimental, ["legacy": "retained"])
        XCTAssertEqual(request.params.capabilities.roots?.listChanged, true)

        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: initialize) as? [String: Any])
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: compatible) as? [String: Any])
        let beforeParams = try XCTUnwrap(before["params"] as? [String: Any])
        let afterParams = try XCTUnwrap(after["params"] as? [String: Any])
        let beforeCapabilities = try XCTUnwrap(beforeParams["capabilities"] as? [String: Any])
        let afterCapabilities = try XCTUnwrap(afterParams["capabilities"] as? [String: Any])
        XCTAssertEqual(beforeCapabilities["extensions"] as? NSDictionary, afterCapabilities["extensions"] as? NSDictionary)
        XCTAssertEqual(beforeParams["clientInfo"] as? NSDictionary, afterParams["clientInfo"] as? NSDictionary)
        XCTAssertEqual(beforeParams["protocolVersion"] as? String, afterParams["protocolVersion"] as? String)
    }

    func testOrdinaryTrafficAndInvalidRequestsRemainByteForByteUnchanged() {
        for text in [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"legacy":"value"}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tap","arguments":{"experimental":{"nested":{}}}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"structuredContent":{"experimental":{"nested":{}}}}}"#,
            "not JSON"
        ] {
            let data = Data(text.utf8)
            XCTAssertEqual(MCPCompatibilityTransport.compatibleInitialization(data), data)
        }
    }

    func testRawClientCanInitializeAndListToolsThroughCompatibilityTransport() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "test", version: "1", capabilities: .init(tools: .init()), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [Tool(name: "list_devices", description: "Devices", inputSchema: ["type": "object"])])
        }
        try await server.start(transport: MCPCompatibilityTransport(pair.server))
        try await pair.client.connect()
        let completed = expectation(description: "initialize and tools/list return results")
        let reader = Task {
            do {
                var responses = (await pair.client.receive()).makeAsyncIterator()
                try await pair.client.send(initialize)
                let firstData = try await responses.next()
                let first = try JSONDecoder().decode(Response<Initialize>.self, from: XCTUnwrap(firstData))
                XCTAssertEqual(try first.result.get().serverInfo.name, "test")
                try await pair.client.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
                try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8))
                let secondData = try await responses.next()
                let second = try JSONDecoder().decode(Response<ListTools>.self, from: XCTUnwrap(secondData))
                XCTAssertEqual(try second.result.get().tools.map(\.name), ["list_devices"])
            } catch {
                XCTFail("Raw client handshake failed: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        reader.cancel()
        await server.stop()
        await pair.client.disconnect()
    }
}
