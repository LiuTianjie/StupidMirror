import Foundation
import MCP
import StupidMirrorConnection

/// Reuses the app's tools, schemas, annotations, images and structured results.
/// Only initialization may be retried; a failed phone action is never replayed.
public actor MCPBridge {
    public typealias ConnectionProvider = @Sendable () async throws -> MCPConnectionRecord
    public typealias TransportFactory = @Sendable (MCPConnectionRecord) -> any Transport

    private struct Connection: Sendable {
        let id: UUID
        let client: Client
        let initialization: Initialize.Result
    }

    private let connectionProvider: ConnectionProvider
    private let transportFactory: TransportFactory
    private var pending: (id: UUID, record: MCPConnectionRecord, task: Task<Connection, Error>)?

    public init(
        connectionProvider: @escaping ConnectionProvider,
        transportFactory: @escaping TransportFactory = MCPBridge.httpTransport
    ) {
        self.connectionProvider = connectionProvider
        self.transportFactory = transportFactory
    }

    public nonisolated static func httpTransport(_ record: MCPConnectionRecord) -> any Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 245
        configuration.connectionProxyDictionary = [:]
        return HTTPClientTransport(
            endpoint: record.endpoint, configuration: configuration, streaming: false,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer \(record.bearerToken)", forHTTPHeaderField: "Authorization")
                if let data = request.httpBody,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["method"] as? String == "initialize" {
                    request.timeoutInterval = 3
                }
                return request
            }
        )
    }

    public func makeServer() async throws -> Server {
        let connection = try await connected()
        let info = connection.initialization.serverInfo
        let server = Server(
            name: info.name, version: info.version, title: info.title,
            instructions: connection.initialization.instructions,
            capabilities: .init(resources: connection.initialization.capabilities.resources, tools: .init(listChanged: false))
        )
        if connection.initialization.capabilities.resources != nil {
            await server.withMethodHandler(ListResources.self) { [self] parameters in
                try await forward(ListResources.request(parameters))
            }
            await server.withMethodHandler(ReadResource.self) { [self] parameters in
                try await forward(ReadResource.request(parameters))
            }
        }
        await server.withMethodHandler(ListTools.self) { [self] parameters in
            try await forward(ListTools.request(parameters))
        }
        await server.withMethodHandler(CallTool.self) { [self] parameters in
            do {
                return try await forward(CallTool.request(parameters))
            } catch {
                // A response can be lost after execution. Return an explicit uncertain
                // outcome so the next step observes state rather than repeating the action.
                return CallTool.Result(
                    content: [.text("StupidMirror connection failed. The action may have executed; it was not retried. Reconnect and observe the device before deciding the next action. \(error.localizedDescription)")],
                    isError: true
                )
            }
        }
        return server
    }

    private func connected() async throws -> Connection {
        let record = try await connectionProvider()
        try record.validate()
        if let pending, pending.record == record {
            return try await pending.task.value
        }
        let previous = pending
        let factory = transportFactory
        let id = UUID()
        let task = Task {
            if let connection = try? await previous?.task.value {
                await connection.client.disconnect()
            }
            let client = Client(name: "stupidmirror-codex-bridge", version: "0.1.0")
            do {
                let initialization = try await client.connect(transport: factory(record))
                return Connection(id: id, client: client, initialization: initialization)
            } catch {
                await client.disconnect()
                throw error
            }
        }
        // Install the pending connection before yielding. Simultaneous tool
        // calls must share one handshake, including after token rotation.
        pending = (id, record, task)
        do { return try await task.value }
        catch {
            if pending?.id == id { pending = nil }
            throw error
        }
    }

    private func forward<M: MCP.Method>(_ request: Request<M>) async throws -> M.Result {
        let connection = try await connected()
        do {
            // Use send() to retain structuredContent and result metadata, which
            // the SDK's convenience callTool() tuple does not include.
            let context = try await connection.client.send(request)
            return try await withTaskCancellationHandler {
                try await context.value
            } onCancel: {
                Task { try? await connection.client.cancelRequest(context.requestID) }
            }
        } catch {
            if pending?.id == connection.id { await disconnect() }
            throw error
        }
    }

    public func disconnect() async {
        let previous = pending
        pending = nil
        if let connection = try? await previous?.task.value {
            await connection.client.disconnect()
        }
    }
}
