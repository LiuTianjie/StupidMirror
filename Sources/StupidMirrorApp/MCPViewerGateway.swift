import Foundation
import MCP
import Security

struct MCPViewerLink: Sendable {
    let url: URL
    let expiresAt: Date
}

struct MCPViewerResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

/// Serves the phone panel as an ordinary local page for hosts that cannot
/// render MCP Apps, such as Claude Code's Browser pane. The page is public
/// static content; every tool call needs a viewer session minted from a
/// single-use ticket. The long-lived MCP bearer token never reaches a URL.
final class MCPViewerGateway: @unchecked Sendable {
    typealias ToolCaller = @Sendable (String, [String: Value]?) async -> CallTool.Result

    static let path = "/viewer"
    static let sessionHeader = "x-stupidmirror-viewer"
    static let pageMarker = #"<meta name="stupidmirror-viewer" content="standalone">"#
    /// Only the panel's own transport. Automation tools stay behind the bearer token.
    static let allowedTools: Set<String> = ["show_screen", "screen_frame", "screen_action", "screen_signal"]
    static let ticketLifetime: TimeInterval = 600
    static let sessionIdleLifetime: TimeInterval = 12 * 3_600
    private static let maximumTickets = 32
    private static let maximumSessions = 16

    private struct Ticket { let deviceID: String?; let expiresAt: Date }
    private struct Session { let deviceID: String?; var lastUsedAt: Date }

    let port: Int
    private let callTool: ToolCaller
    private let loadPage: @Sendable () throws -> String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var tickets: [String: Ticket] = [:]
    private var sessions: [String: Session] = [:]

    init(
        port: Int,
        callTool: @escaping ToolCaller,
        loadPage: @escaping @Sendable () throws -> String = MCPViewerGateway.bundledPage,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.port = port
        self.callTool = callTool
        self.loadPage = loadPage
        self.now = now
    }

    static func handles(path: String) -> Bool {
        path == "/" || path == Self.path || path.hasPrefix(Self.path + "/")
    }

    /// The ticket travels in the fragment, so it is never sent to the server
    /// with the page request, logged, or leaked through a Referer header.
    func makeLink(deviceID: String?) throws -> MCPViewerLink {
        let ticket = try Self.randomToken()
        let expiresAt = now().addingTimeInterval(Self.ticketLifetime)
        lock.withLock {
            pruneLocked()
            if tickets.count >= Self.maximumTickets,
               let oldest = tickets.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                tickets.removeValue(forKey: oldest)
            }
            tickets[ticket] = Ticket(deviceID: deviceID, expiresAt: expiresAt)
        }
        return MCPViewerLink(url: URL(string: "http://127.0.0.1:\(port)\(Self.path)#ticket=\(ticket)")!, expiresAt: expiresAt)
    }

    /// Rotating the MCP token also ends every open viewer.
    func revokeAll() {
        lock.withLock {
            tickets.removeAll()
            sessions.removeAll()
        }
    }

    func handle(method: String, path: String, headers: [String: String], body: Data?) async -> MCPViewerResponse {
        let headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        // DNS rebinding: a foreign name that resolves to loopback must not reach the page or API.
        guard let host = headers["host"], allowedHosts.contains(host.lowercased()) else {
            return Self.error(403, "forbidden_host", "Open the viewer at 127.0.0.1.")
        }
        switch (method.uppercased(), path) {
        case ("GET", "/"):
            return MCPViewerResponse(statusCode: 302, headers: ["Location": Self.path, "Cache-Control": "no-store"], body: Data())
        case ("GET", Self.path):
            return page()
        case ("POST", Self.path + "/api/session"):
            if let rejection = rejectCrossOrigin(headers) { return rejection }
            return exchange(body)
        case ("POST", Self.path + "/api/call"):
            if let rejection = rejectCrossOrigin(headers) { return rejection }
            return await call(headers: headers, body: body)
        default:
            return Self.error(404, "not_found", "Not Found")
        }
    }

    private var allowedHosts: Set<String> { ["127.0.0.1:\(port)", "localhost:\(port)"] }

    private func rejectCrossOrigin(_ headers: [String: String]) -> MCPViewerResponse? {
        // Browsers always send Origin on fetch POST. Requiring our own origin
        // and a JSON body keeps other pages and simple forms out.
        guard let origin = headers["origin"]?.lowercased(),
              allowedHosts.contains(where: { origin == "http://\($0)" }) else {
            return Self.error(403, "forbidden_origin", "Requests must come from the viewer page.")
        }
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return Self.error(415, "unsupported_media_type", "Content-Type must be application/json.")
        }
        return nil
    }

    private func page() -> MCPViewerResponse {
        do {
            let html = try loadPage()
            guard let head = html.range(of: "<head>") else { throw CocoaError(.fileReadCorruptFile) }
            var marked = html
            marked.insert(contentsOf: Self.pageMarker, at: head.upperBound)
            return MCPViewerResponse(statusCode: 200, headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                // The bundle is self-contained. Only this server is reachable;
                // WebRTC media is not governed by connect-src.
                "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src blob: mediastream:; connect-src 'self'; base-uri 'none'; form-action 'none'"
            ], body: Data(marked.utf8))
        } catch {
            return Self.error(500, "viewer_missing", "The screen component is missing. Install an updated StupidMirror app.")
        }
    }

    private func exchange(_ body: Data?) -> MCPViewerResponse {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ticket = object["ticket"] as? String, !ticket.isEmpty else {
            return Self.error(400, "invalid_request", "Missing ticket.")
        }
        let minted: (token: String, deviceID: String?)? = lock.withLock {
            pruneLocked()
            // Single use: a copied or replayed link cannot open a second viewer.
            guard let entry = tickets.removeValue(forKey: ticket), entry.expiresAt > now() else { return nil }
            guard let token = try? Self.randomToken() else { return nil }
            if sessions.count >= Self.maximumSessions,
               let oldest = sessions.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })?.key {
                sessions.removeValue(forKey: oldest)
            }
            sessions[token] = Session(deviceID: entry.deviceID, lastUsedAt: now())
            return (token, entry.deviceID)
        }
        guard let minted else {
            return Self.error(401, "viewer_link_expired", "This viewer link was already used or has expired.")
        }
        var payload: [String: Any] = ["session": minted.token]
        if let deviceID = minted.deviceID { payload["device_id"] = deviceID }
        return Self.json(200, payload)
    }

    private func call(headers: [String: String], body: Data?) async -> MCPViewerResponse {
        let authorized: Bool = lock.withLock {
            pruneLocked()
            guard let token = headers[Self.sessionHeader], let session = sessions[token] else { return false }
            sessions[token] = Session(deviceID: session.deviceID, lastUsedAt: now())
            return true
        }
        guard authorized else {
            return Self.error(401, "viewer_session_expired", "This viewer session has ended.")
        }
        guard let body,
              let request = try? JSONDecoder().decode(ViewerToolCall.self, from: body) else {
            return Self.error(400, "invalid_request", "Expected {\"name\", \"arguments\"}.")
        }
        guard Self.allowedTools.contains(request.name) else {
            return Self.error(403, "tool_not_allowed", "The viewer cannot call \(request.name).")
        }
        let result = await callTool(request.name, request.arguments)
        guard let data = try? JSONEncoder.stupidMirrorMCP.encode(result) else {
            return Self.error(500, "encoding_failed", "Could not encode the tool result.")
        }
        return MCPViewerResponse(statusCode: 200, headers: Self.jsonHeaders, body: data)
    }

    private func pruneLocked() {
        let current = now()
        tickets = tickets.filter { $0.value.expiresAt > current }
        let cutoff = current.addingTimeInterval(-Self.sessionIdleLifetime)
        sessions = sessions.filter { $0.value.lastUsedAt > cutoff }
    }

    private struct ViewerToolCall: Decodable {
        let name: String
        let arguments: [String: Value]?
    }

    private static let jsonHeaders = ["Content-Type": "application/json", "Cache-Control": "no-store"]

    private static func json(_ statusCode: Int, _ payload: [String: Any]) -> MCPViewerResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return MCPViewerResponse(statusCode: statusCode, headers: jsonHeaders, body: data)
    }

    private static func error(_ statusCode: Int, _ code: String, _ message: String) -> MCPViewerResponse {
        json(statusCode, ["error": ["code": code, "message": message]])
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    @Sendable static func bundledPage() throws -> String {
        guard let url = StupidMirrorScreenResource.pageURL else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
