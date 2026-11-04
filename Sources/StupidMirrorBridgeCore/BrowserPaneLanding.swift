import Foundation

/// The page Claude's Browser pane starts on before it is sent to a viewer link.
/// The pane only previews servers it starts itself, and the app already holds
/// its own port, so the helper serves this placeholder on a port of its own.
/// It is static: viewer links carry single-use tickets that only an MCP tool
/// call can mint, so nothing here can open a viewer.
public enum BrowserPaneLanding {
    public static let defaultPort = 17_374
    public static let maximumRequestSize = 16 * 1_024

    public struct Response: Equatable, Sendable {
        public let statusCode: Int
        public let reason: String
        public let headers: [(String, String)]
        public let body: Data

        public static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.statusCode == rhs.statusCode && lhs.body == rhs.body
                && lhs.headers.map { "\($0.0)=\($0.1)" } == rhs.headers.map { "\($0.0)=\($0.1)" }
        }

        /// The full HTTP/1.1 message; the connection closes after it.
        public var serialized: Data {
            var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
            for (name, value) in headers + [("Content-Length", String(body.count)), ("Connection", "close")] {
                head += "\(name): \(value)\r\n"
            }
            return Data((head + "\r\n").utf8) + body
        }
    }

    /// Parses `--browser-pane [--port N]`. Returns nil when the arguments ask for something else.
    public static func port(fromArguments arguments: [String]) -> Int? {
        guard arguments.first == "--browser-pane" else { return nil }
        let rest = Array(arguments.dropFirst())
        if rest.isEmpty { return defaultPort }
        guard rest.count == 2, rest[0] == "--port" || rest[0] == "-p",
              let port = Int(rest[1]), (1_024...65_535).contains(port) else { return nil }
        return port
    }

    /// Whether `buffer` holds a complete request head.
    public static func headIsComplete(_ buffer: Data) -> Bool {
        buffer.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    public static func response(forRequest buffer: Data, port: Int) -> Response {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            return plain(400, "Bad Request")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count == 3 else { return plain(400, "Bad Request") }
        let host = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        }.first
        // DNS rebinding: a foreign name that resolves to loopback gets nothing.
        guard let host, ["localhost:\(port)", "127.0.0.1:\(port)"].contains(host) else {
            return plain(403, "Forbidden")
        }
        let method = requestLine[0].uppercased()
        let path = requestLine[1].split(separator: "?").first.map(String.init) ?? ""
        guard method == "GET" || method == "HEAD" else { return plain(405, "Method Not Allowed") }
        guard path == "/" else { return plain(404, "Not Found") }
        return Response(statusCode: 200, reason: "OK", headers: pageHeaders, body: method == "HEAD" ? Data() : page)
    }

    private static let pageHeaders: [(String, String)] = [
        ("Content-Type", "text/html; charset=utf-8"),
        ("Cache-Control", "no-store"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'")
    ]

    private static let page = Data("""
    <!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><title>StupidMirror</title>
    <meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body style="margin:0;height:100vh;display:grid;place-items:center;font:14px -apple-system,system-ui,sans-serif;color:#666;background:#f5f5f4">
    <p>正在打开 StupidMirror 手机画面… / Waiting for a StupidMirror viewer link…</p></body></html>
    """.utf8)

    private static func plain(_ statusCode: Int, _ reason: String) -> Response {
        Response(statusCode: statusCode, reason: reason,
                 headers: [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store")],
                 body: Data(reason.utf8))
    }
}
