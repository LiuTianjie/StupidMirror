import Foundation
import Logging
import MCP

/// Works around Swift MCP SDK 0.12.1 capability decoding and reentrant stdio writes.
/// https://github.com/modelcontextprotocol/swift-sdk/issues/287
/// https://github.com/modelcontextprotocol/swift-sdk/issues/263
public actor MCPCompatibilityTransport: Transport {
    private let wrapped: any Transport
    private var pendingSend: (id: UUID, task: Task<Void, Error>)?

    public nonisolated let logger: Logger

    public init(_ wrapped: any Transport) async {
        self.wrapped = wrapped
        self.logger = await wrapped.logger
    }

    public func connect() async throws {
        try await wrapped.connect()
    }

    public func disconnect() async {
        await wrapped.disconnect()
    }

    public func send(_ data: Data) async throws {
        // The SDK yields when stdout fills, allowing another send to splice its
        // bytes into a partially written JSON line. Queue whole messages before
        // yielding. An individual request's cancellation must not truncate a line.
        let previous = pendingSend?.task
        let id = UUID()
        let task = Task { [wrapped] in
            _ = try? await previous?.value
            try await wrapped.send(data)
        }
        pendingSend = (id, task)
        do {
            try await task.value
            if pendingSend?.id == id { pendingSend = nil }
        } catch {
            if pendingSend?.id == id { pendingSend = nil }
            throw error
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let incoming = await wrapped.receive()
                    for try await data in incoming {
                        continuation.yield(Self.compatibleInitialization(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func compatibleInitialization(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["method"] as? String == "initialize",
              request["id"] != nil,
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any] else {
            return data
        }

        // The SDK incorrectly expects [String: String]. StupidMirror does not
        // consume these experimental features, so ignore unsupported entries;
        // retain legacy string entries and every other capability unchanged.
        let supported = experimental.filter { $0.value is String }
        guard supported.count != experimental.count else { return data }
        capabilities["experimental"] = supported
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? data
    }
}
