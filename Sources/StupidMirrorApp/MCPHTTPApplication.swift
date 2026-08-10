import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

actor MCPHTTPApplication {
    typealias ServerFactory = @Sendable (String) async throws -> Server
    typealias SessionCountHandler = @Sendable (Int) async -> Void
    typealias StartedHandler = @Sendable () async -> Void

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccessedAt: Date
    }

    private let host: String
    private let port: Int
    private let endpoint: String
    private let validationPipeline: any HTTPRequestValidationPipeline
    private let serverFactory: ServerFactory
    private let sessionCountHandler: SessionCountHandler
    private let startedHandler: StartedHandler
    private var channel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sessions: [String: SessionContext] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(
        host: String,
        port: Int,
        endpoint: String,
        validationPipeline: any HTTPRequestValidationPipeline,
        serverFactory: @escaping ServerFactory,
        sessionCountHandler: @escaping SessionCountHandler,
        startedHandler: @escaping StartedHandler
    ) {
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.validationPipeline = validationPipeline
        self.serverFactory = serverFactory
        self.sessionCountHandler = sessionCountHandler
        self.startedHandler = startedHandler
    }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        eventLoopGroup = group
        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(MCPHTTPHandler(app: self))
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

            let channel = try await bootstrap.bind(host: host, port: port).get()
            self.channel = channel
            await startedHandler()
            cleanupTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await self?.removeExpiredSessions()
                }
            }
            try await channel.closeFuture.get()
        } catch {
            cleanupTask?.cancel()
            cleanupTask = nil
            try? await group.shutdownGracefully()
            eventLoopGroup = nil
            throw error
        }

        cleanupTask?.cancel()
        cleanupTask = nil
        try? await group.shutdownGracefully()
        eventLoopGroup = nil
    }

    func stop() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
    }

    func endpointPath() -> String { endpoint }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)
        let isInitialization = request.method.uppercased() == "POST" && isInitializeRequest(request.body)
        let perimeterContext = HTTPValidationContext(
            httpMethod: request.method.uppercased(),
            sessionID: sessionID,
            isInitializationRequest: isInitialization
        )
        // Authenticate and apply DNS-rebinding protection before revealing
        // whether any session or route state exists. The transport validates a
        // second time with its authoritative session context.
        if let rejection = validationPipeline.validate(request, context: perimeterContext) {
            return rejection
        }
        if let sessionID, var context = sessions[sessionID] {
            context.lastAccessedAt = Date()
            sessions[sessionID] = context
            let response = await context.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }

        if isInitialization {
            return await createSessionAndHandle(request)
        }
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: MCP session expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline
        )
        do {
            let server = try await serverFactory(sessionID)
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                lastAccessedAt: Date()
            )
            await sessionCountHandler(sessions.count)
            let response = await transport.handleRequest(request)
            if response.statusCode >= 400 {
                await closeSession(sessionID)
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to initialize StupidMirror MCP: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let context = sessions.removeValue(forKey: sessionID) else { return }
        await context.server.stop()
        await context.transport.disconnect()
        await sessionCountHandler(sessions.count)
    }

    private func closeAllSessions() async {
        let ids = Array(sessions.keys)
        for id in ids { await closeSession(id) }
    }

    private func removeExpiredSessions() async {
        let cutoff = Date().addingTimeInterval(-3_600)
        let ids = sessions.compactMap { id, context in
            context.lastAccessedAt < cutoff ? id : nil
        }
        for id in ids { await closeSession(id) }
    }

    private func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "initialize" && object["id"] != nil
    }
}

private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestState {
        let head: HTTPRequestHead
        var body: ByteBuffer
        var isTooLarge: Bool
    }

    private let app: MCPHTTPApplication
    private var state: RequestState?
    private let maximumBodySize = 4 * 1_024 * 1_024

    init(app: MCPHTTPApplication) {
        self.app = app
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            state = RequestState(
                head: head,
                body: context.channel.allocator.buffer(capacity: 0),
                isTooLarge: false
            )
        case var .body(buffer):
            guard var state else { return }
            if state.body.readableBytes + buffer.readableBytes > maximumBodySize {
                state.isTooLarge = true
            } else if !state.isTooLarge {
                state.body.writeBuffer(&buffer)
            }
            self.state = state
        case .end:
            guard let state else { return }
            self.state = nil
            let safeContext = MCPChannelContext(context)
            Task {
                await self.handle(state, context: safeContext.value)
            }
        }
    }

    private func handle(_ state: RequestState, context: ChannelHandlerContext) async {
        if state.isTooLarge {
            await write(
                .error(statusCode: 413, .invalidRequest("Request body exceeds 4 MiB")),
                version: state.head.version,
                context: context
            )
            return
        }
        let path = state.head.uri.split(separator: "?").first.map(String.init) ?? state.head.uri
        let endpointPath = await app.endpointPath()
        guard path == endpointPath else {
            await write(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: state.head.version,
                context: context
            )
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let bytes = state.body.getBytes(at: 0, length: state.body.readableBytes) ?? []
        let request = HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: bytes.isEmpty ? nil : Data(bytes)
        )
        let response = await app.handle(request)
        await write(response, version: state.head.version, context: context)
    }

    private func write(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let safeContext = context
        switch response {
        case let .stream(stream, responseHeaders):
            safeContext.eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in responseHeaders { head.headers.add(name: name, value: value) }
                head.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
                safeContext.write(self.wrapOutboundOut(.head(head)), promise: nil)
                safeContext.flush()
            }
            do {
                for try await chunk in stream {
                    safeContext.eventLoop.execute {
                        var buffer = safeContext.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        safeContext.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil
                        )
                    }
                }
            } catch {
                // The MCP transport closes the stream on cancellation or disconnect.
            }
            safeContext.eventLoop.execute {
                safeContext.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        default:
            let body = response.bodyData ?? Data()
            safeContext.eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers { head.headers.add(name: name, value: value) }
                head.headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
                safeContext.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if !body.isEmpty {
                    var buffer = safeContext.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    safeContext.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                safeContext.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

private final class MCPChannelContext: @unchecked Sendable {
    let value: ChannelHandlerContext

    init(_ value: ChannelHandlerContext) {
        self.value = value
    }
}
