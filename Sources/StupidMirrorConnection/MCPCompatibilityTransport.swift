import Foundation
import Logging
import MCP

/// Adapts client initialization for Swift MCP SDK 0.12.1 without changing tool traffic.
/// Remove once Client.Capabilities.experimental supports arbitrary JSON values:
/// https://github.com/modelcontextprotocol/swift-sdk/issues/287
public actor MCPCompatibilityTransport: Transport {
    private let wrapped: any Transport

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
        try await wrapped.send(data)
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
