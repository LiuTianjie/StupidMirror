import Foundation
import MCP
import StupidMirrorBridgeCore
import StupidMirrorConnection
import XCTest

final class MCPBridgeTests: XCTestCase, @unchecked Sendable {
    func testForwardsInstructionsSchemasImagesStructuredContentAndMetadata() async throws {
        let backendPair = await InMemoryTransport.createConnectedPair()
        let backend = Server(name: "stupidmirror", version: "test", instructions: "Use the embedded screen.", capabilities: .init(resources: .init(), tools: .init()))
        let tool = Tool(name: "observe_screen", description: "Observe", inputSchema: ["type": "object"], annotations: .init(readOnlyHint: true))
        let expected = CallTool.Result(
            content: [.image(data: "cG5n", mimeType: "image/png")],
            structuredContent: .object(["observation_id": "fresh"]), isError: false,
            _meta: Metadata(additionalFields: ["example": "retained"])
        )
        await backend.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: [tool]) }
        let resource = Resource(name: "screen", uri: "ui://stupidmirror/screen.html", mimeType: "text/html;profile=mcp-app")
        await backend.withMethodHandler(ListResources.self) { _ in ListResources.Result(resources: [resource]) }
        await backend.withMethodHandler(ReadResource.self) { parameters in
            XCTAssertEqual(parameters.uri, resource.uri)
            return ReadResource.Result(contents: [.text("<main>Phone</main>", uri: resource.uri, mimeType: resource.mimeType)])
        }
        await backend.withMethodHandler(CallTool.self) { parameters in
            XCTAssertEqual(parameters.arguments?["include_image"], true)
            return expected
        }
        try await backend.start(transport: backendPair.server)
        let record = MCPConnectionRecord(endpoint: URL(string: "http://127.0.0.1:17373/mcp")!, bearerToken: "test")
        let bridge = MCPBridge(connectionProvider: { record }, transportFactory: { _ in backendPair.client })
        let server = try await bridge.makeServer()
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        let client = Client(name: "test", version: "1")
        let initialized = try await client.connect(transport: pair.client)
        XCTAssertEqual(initialized.instructions, "Use the embedded screen.")
        XCTAssertNotNil(initialized.capabilities.resources)
        XCTAssertEqual(initialized.capabilities.resources?.listChanged, true)
        XCTAssertEqual(initialized.capabilities.tools?.listChanged, true)
        let resources = try await client.listResources()
        XCTAssertEqual(resources.resources, [resource])
        let contents = try await client.readResource(uri: resource.uri)
        XCTAssertEqual(contents.first?.text, "<main>Phone</main>")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.tools, [tool])
        let call = try await client.send(CallTool.request(.init(name: "observe_screen", arguments: ["include_image": true])))
        let result = try await call.value
        XCTAssertEqual(result, expected)
        await client.disconnect()
        await server.stop()
        await bridge.disconnect()
        await backend.stop()
    }

    func testTokenRotationReconnectsBeforeNextCallAndFailureDoesNotReplay() async throws {
        let first = await InMemoryTransport.createConnectedPair()
        let second = await InMemoryTransport.createConnectedPair()
        let state = TestState()
        let oldBackend = Server(name: "stupidmirror", version: "1", capabilities: .init(resources: .init(), tools: .init()))
        let newBackend = Server(name: "stupidmirror", version: "1", capabilities: .init(resources: .init(), tools: .init()))
        await oldBackend.withMethodHandler(CallTool.self) { _ in
            XCTFail("Rotation must stop use of the old connection")
            return CallTool.Result()
        }
        await newBackend.withMethodHandler(CallTool.self) { _ in
            await state.recordCall()
            throw MCPError.internalError("Connection lost after phone action")
        }
        try await oldBackend.start(transport: first.server)
        try await newBackend.start(transport: second.server)
        let bridge = MCPBridge(connectionProvider: { await state.record }, transportFactory: { record in
            record.bearerToken == "first" ? first.client : second.client
        })
        let server = try await bridge.makeServer()
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        let client = Client(name: "test", version: "1")
        let toolsChanged = expectation(description: "Reconnection refreshes tool metadata")
        let resourcesChanged = expectation(description: "Reconnection refreshes widget resources")
        await client.onNotification(ToolListChangedNotification.self) { _ in toolsChanged.fulfill() }
        await client.onNotification(ResourceListChangedNotification.self) { _ in resourcesChanged.fulfill() }
        try await client.connect(transport: pair.client)
        await state.rotate()
        let call = try await client.send(CallTool.request(.init(name: "tap")))
        let result = try await call.value
        XCTAssertEqual(result.isError, true)
        let count = await state.calls
        XCTAssertEqual(count, 1)
        guard case let .text(text, _, _) = result.content.first else { return XCTFail("Expected recovery instruction") }
        XCTAssertTrue(text.contains("may have executed"))
        await fulfillment(of: [toolsChanged, resourcesChanged], timeout: 2)
        await client.disconnect()
        await server.stop()
        await bridge.disconnect()
        await oldBackend.stop()
        await newBackend.stop()
    }
}

private actor TestState {
    var record = MCPConnectionRecord(endpoint: URL(string: "http://127.0.0.1:17373/mcp")!, bearerToken: "first")
    var calls = 0
    func recordCall() { calls += 1 }
    func rotate() { record = MCPConnectionRecord(endpoint: record.endpoint, bearerToken: "second") }
}
