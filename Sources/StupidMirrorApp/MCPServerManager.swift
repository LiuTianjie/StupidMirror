import Combine
import Foundation
import LocalAuthentication
import MCP
import Security

enum MCPServerStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct MCPCallLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let tool: String
    let durationMilliseconds: Int
    let succeeded: Bool
    let errorCode: String?
}

private actor MCPServerEventSink {
    weak var manager: MCPServerManager?

    init(manager: MCPServerManager) {
        self.manager = manager
    }

    func recordCall(
        tool: String,
        durationMilliseconds: Int,
        succeeded: Bool,
        errorCode: String?
    ) async {
        await manager?.recordCall(
            tool: tool,
            durationMilliseconds: durationMilliseconds,
            succeeded: succeeded,
            errorCode: errorCode
        )
    }

    func setClientCount(_ count: Int) async {
        await manager?.setConnectedClientCount(count)
    }

    func markRunning(generation: UInt64) async {
        await manager?.markRunning(generation: generation)
    }
}

final class MCPTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: [UInt8]

    init(token: String) {
        self.token = Array(token.utf8)
    }

    func replace(with token: String) {
        lock.lock()
        self.token = Array(token.utf8)
        lock.unlock()
    }

    func matches(authorizationHeader: String?) -> Bool {
        let prefix = "Bearer "
        let candidate = authorizationHeader.flatMap { header -> [UInt8]? in
            guard header.hasPrefix(prefix) else { return nil }
            return Array(header.dropFirst(prefix.count).utf8)
        } ?? []

        lock.lock()
        let expected = token
        lock.unlock()

        let count = max(expected.count, candidate.count)
        var difference = UInt(expected.count ^ candidate.count)
        for index in 0..<count {
            let left = index < expected.count ? expected[index] : 0
            let right = index < candidate.count ? candidate[index] : 0
            difference |= UInt(left ^ right)
        }
        return difference == 0
    }
}

struct MCPBearerTokenValidator: HTTPRequestValidator {
    let tokenBox: MCPTokenBox

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard tokenBox.matches(authorizationHeader: request.header("Authorization")) else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: valid Bearer token required"),
                sessionID: context.sessionID
            )
        }
        return nil
    }
}

final class MCPTokenStore: @unchecked Sendable {
    static let service = "com.gaojiua.StupidMirror.mcp.v1"
    private static let account = "bearer-token"

    func loadOrCreate() throws -> String {
        if let token = try load() { return token }
        let token = try Self.generate()
        try save(token)
        return token
    }

    func rotate() throws -> String {
        let token = try Self.generate()
        try save(token)
        return token
    }

    private func load() throws -> String? {
        var query = Self.nonInteractiveQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw error(status)
        }
        return token
    }

    private func save(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            Self.nonInteractiveQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw error(updateStatus) }
        var attributes = Self.itemIdentity
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw error(addStatus) }
    }

    private static var itemIdentity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static var nonInteractiveQuery: [String: Any] {
        var query = itemIdentity
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func error(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return NSError(
            domain: "StupidMirror.MCPTokenStore",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
final class MCPServerManager: ObservableObject {
    static let defaultPort = 17_373
    static let enabledDefaultsKey = "StupidMirror.mcp.enabled"
    static let portDefaultsKey = "StupidMirror.mcp.port"

    @Published private(set) var status: MCPServerStatus = .stopped
    @Published private(set) var bearerToken = ""
    @Published private(set) var connectedClientCount = 0
    @Published private(set) var callLog: [MCPCallLogEntry] = []
    @Published private(set) var enabled: Bool
    @Published private(set) var port: Int

    private let automation: DeviceAutomationService
    private let tokenStore: MCPTokenStore
    private var tokenBox: MCPTokenBox?
    private var application: MCPHTTPApplication?
    private var serverTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isShuttingDown = false

    init(
        automation: DeviceAutomationService,
        tokenStore: MCPTokenStore = MCPTokenStore(),
        defaults: UserDefaults = .standard
    ) {
        self.automation = automation
        self.tokenStore = tokenStore
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            defaults.set(true, forKey: Self.enabledDefaultsKey)
        }
        enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        let savedPort = defaults.integer(forKey: Self.portDefaultsKey)
        port = (1_024...65_535).contains(savedPort) ? savedPort : Self.defaultPort
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    func startIfEnabled() async {
        guard enabled else { return }
        await start()
    }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { await start() } else { await stop() }
    }

    func setPort(_ newPort: Int) async throws {
        guard (1_024...65_535).contains(newPort) else {
            throw DeviceAutomationError.invalidArgument("MCP port must be between 1024 and 65535.")
        }
        guard newPort != port else { return }
        port = newPort
        UserDefaults.standard.set(newPort, forKey: Self.portDefaultsKey)
        if enabled {
            await stop()
            await start()
        }
    }

    func start() async {
        guard !isShuttingDown, application == nil else { return }
        status = .starting
        generation &+= 1
        let currentGeneration = generation
        do {
            let token = try tokenStore.loadOrCreate()
            bearerToken = token
            let tokenBox = MCPTokenBox(token: token)
            self.tokenBox = tokenBox
            let validation = StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                MCPBearerTokenValidator(tokenBox: tokenBox),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator()
            ])
            let router = StupidMirrorMCPToolRouter(automation: automation)
            let eventSink = MCPServerEventSink(manager: self)
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development"
            let app = MCPHTTPApplication(
                host: "127.0.0.1",
                port: port,
                endpoint: "/mcp",
                validationPipeline: validation,
                serverFactory: { _ in
                    let server = Server(
                        name: "stupidmirror",
                        version: appVersion,
                        title: "StupidMirror iPhone Automation",
                        instructions: Self.instructions,
                        capabilities: .init(tools: .init(listChanged: false))
                    )
                    await server.withMethodHandler(ListTools.self) { _ in
                        ListTools.Result(tools: StupidMirrorMCPToolCatalog.tools)
                    }
                    await server.withMethodHandler(CallTool.self) { request in
                        let startedAt = ContinuousClock.now
                        let result = await router.call(name: request.name, arguments: request.arguments)
                        let duration = startedAt.duration(to: .now)
                        let milliseconds = Int(duration.components.seconds * 1_000)
                            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
                        await eventSink.recordCall(
                            tool: request.name,
                            durationMilliseconds: max(0, milliseconds),
                            succeeded: result.isError != true,
                            errorCode: result.isError == true ? "tool_error" : nil
                        )
                        return result
                    }
                    return server
                },
                sessionCountHandler: { count in
                    await eventSink.setClientCount(count)
                },
                startedHandler: {
                    await eventSink.markRunning(generation: currentGeneration)
                }
            )
            application = app
            serverTask = Task { [weak self] in
                do {
                    try await app.start()
                    self?.serverExited(generation: currentGeneration, error: nil)
                } catch {
                    self?.serverExited(generation: currentGeneration, error: error)
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        generation &+= 1
        let app = application
        application = nil
        await app?.stop()
        await serverTask?.value
        serverTask = nil
        connectedClientCount = 0
        if !isShuttingDown { status = .stopped }
    }

    func shutdown() async {
        isShuttingDown = true
        await stop()
        status = .stopped
    }

    func rotateToken() throws {
        let token = try tokenStore.rotate()
        bearerToken = token
        tokenBox?.replace(with: token)
    }

    var codexConfiguration: String {
        """
        [mcp_servers.stupidmirror]
        url = "\(endpoint)"
        http_headers = { Authorization = "Bearer \(bearerToken)" }
        tool_timeout_sec = 240
        """
    }

    var claudeCommand: String {
        "claude mcp add --transport http --scope user --header \"Authorization: Bearer \(bearerToken)\" stupidmirror \(endpoint)"
    }

    fileprivate func markRunning(generation: UInt64) {
        guard generation == self.generation, !isShuttingDown else { return }
        status = .running
    }

    private func serverExited(generation: UInt64, error: Error?) {
        guard generation == self.generation else { return }
        application = nil
        serverTask = nil
        connectedClientCount = 0
        if let error, !isShuttingDown {
            status = .failed("MCP could not listen on 127.0.0.1:\(port): \(error.localizedDescription)")
        } else if !isShuttingDown {
            status = .stopped
        }
    }

    fileprivate func setConnectedClientCount(_ count: Int) {
        connectedClientCount = count
    }

    fileprivate func recordCall(
        tool: String,
        durationMilliseconds: Int,
        succeeded: Bool,
        errorCode: String?
    ) {
        callLog.insert(
            MCPCallLogEntry(
                id: UUID(),
                date: Date(),
                tool: tool,
                durationMilliseconds: durationMilliseconds,
                succeeded: succeeded,
                errorCode: errorCode
            ),
            at: 0
        )
        if callLog.count > 100 { callLog.removeLast(callLog.count - 100) }
    }

    nonisolated private static let instructions = """
    Automate iPhones through StupidMirror. Start with list_devices. With multiple devices always pass device_id. Unactivated installations can mirror one device at a time; control tools require activation. Call connect_control before control tools. Use screenshot or get_ui_tree to inspect state, then use normalized coordinates from 0 to 1. After every action, take another screenshot to verify the result.
    """
}
