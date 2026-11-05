import AppKit
import Foundation
import Network

/// GitHub / Google sign-in the way LinkShell does it: the authorize page opens as a tab in the
/// person's own browser, and the browser comes back to `http://127.0.0.1:<port>/linkshell/callback`
/// on a listener this process holds for the length of one sign-in. No sign-in window of our own,
/// so nothing here runs on AuthenticationServices' queues.
///
/// The callback carries a one-time code that is useless without the PKCE verifier, which never
/// leaves the app. The path must match the Supabase redirect allowlist entry
/// `http://127.0.0.1:*/linkshell/callback`, shared by every iTool desktop app.
///
/// The same file is used by Transeen, StupidMirror and Saylane; keep the copies identical.
enum LoopbackOAuthError: Error, Equatable, Sendable {
    case cancelled
    case timedOut
    /// The listener could not start.
    case unavailable
}

final class LoopbackOAuth: @unchecked Sendable {
    static let callbackPath = "/linkshell/callback"
    static let defaultTimeout: TimeInterval = 300

    /// Starts the listener, opens `authorize(redirect)` and returns the URL the browser came back
    /// to (its query holds `code`, or `error` / `error_code` / `error_description`).
    static func run(
        productName: String,
        timeout: TimeInterval = defaultTimeout,
        open: @escaping @Sendable (URL) -> Void = LoopbackOAuth.openInBrowser,
        authorize: @escaping @Sendable (URL) -> URL
    ) async throws -> URL {
        let flow = LoopbackOAuth(productName: productName)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                flow.attach(continuation)
                flow.queue.async { flow.start(timeout: timeout, open: open, authorize: authorize) }
            }
        } onCancel: {
            flow.finish(.failure(LoopbackOAuthError.cancelled))
        }
    }

    /// A new tab in the default browser, as `open URL` does.
    static func openInBrowser(_ url: URL) {
        // For automated checks of a built app: write the URL instead of opening a browser.
        if let path = ProcessInfo.processInfo.environment["ITOOL_OAUTH_CAPTURE"], !path.isEmpty {
            try? Data(url.absoluteString.utf8).write(to: URL(filePath: path), options: .atomic)
            return
        }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    private let productName: String
    private let queue = DispatchQueue(label: "tech.itool.loopback-oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var early: Result<URL, any Error>?
    private var finished = false

    private init(productName: String) {
        self.productName = productName
    }

    private func attach(_ continuation: CheckedContinuation<URL, any Error>) {
        lock.lock()
        if let early {
            self.early = nil
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { early = result }
        let listener = self.listener
        lock.unlock()
        continuation?.resume(with: result)
        // The browser is still loading the outcome page: let it, then free the port.
        queue.asyncAfter(deadline: .now() + 2) { listener?.cancel() }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func start(timeout: TimeInterval, open: @escaping @Sendable (URL) -> Void, authorize: @escaping @Sendable (URL) -> URL) {
        guard !isFinished else { return }
        let parameters = NWParameters.tcp
        // An IP literal rather than `localhost` (RFC 8252 §7.3), and nothing but loopback.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            finish(.failure(LoopbackOAuthError.unavailable))
            return
        }
        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.serve(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener?.port?.rawValue,
                      let redirect = URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)") else {
                    self.finish(.failure(LoopbackOAuthError.unavailable))
                    return
                }
                open(authorize(redirect))
            case .failed:
                self.finish(.failure(LoopbackOAuthError.unavailable))
            default:
                break
            }
        }
        listener.start(queue: queue)
        // Holds the flow until it ends one way or another.
        queue.asyncAfter(deadline: .now() + timeout) {
            self.finish(.failure(LoopbackOAuthError.timedOut))
        }
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: buffer[..<end.lowerBound])
            } else if isComplete || error != nil || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let requestLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let url = URL(string: "http://127.0.0.1" + parts[1]),
              url.path == Self.callbackPath else {
            send(connection, status: "404 Not Found", body: "")
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let present = { (name: String) in items.contains { $0.name == name && !($0.value ?? "").isEmpty } }
        if present("code") {
            send(connection, status: "200 OK", body: page(.ok))
            finish(.success(url))
        } else if present("error") || present("error_code") {
            send(connection, status: "200 OK", body: page(.failed))
            finish(.success(url))
        } else {
            // Supabase can put an error in the fragment, which never reaches a server.
            send(connection, status: "200 OK", body: page(.forward))
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Cache-Control: no-store\r
        Referrer-Policy: no-referrer\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum Page { case ok, failed, forward }

    private func page(_ state: Page) -> String {
        let name = productName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let script: String
        switch state {
        case .forward:
            script = """
            var f = new URLSearchParams(location.hash.slice(1)), q = new URLSearchParams();
            ["error", "error_code", "error_description"].forEach(function (k) { var v = f.get(k); if (v) q.set(k, v); });
            if (!q.toString()) q.set("error", "no_code");
            location.replace("\(Self.callbackPath)?" + q);
            """
        case .ok, .failed:
            script = ""
        }
        let ok = state == .ok
        return """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer">
        <title>\(name)</title>
        <style>
        :root{color-scheme:light dark}body{margin:0;min-height:100vh;display:grid;place-items:center;
        font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;background:Canvas;color:CanvasText}
        main{text-align:center;padding:24px}h1{margin:0 0 6px;font-size:20px;font-weight:600}p{margin:0;opacity:.65}
        </style></head><body><main><h1 id="t"></h1><p id="b"></p></main>
        <script>
        \(script)
        var zh = /^zh/i.test(navigator.language || "");
        var ok = \(ok ? "true" : "false"), forward = \(state == .forward ? "true" : "false");
        var t = forward ? (zh ? "正在完成登录" : "Finishing sign-in") : ok ? (zh ? "已完成授权" : "Authorized") : (zh ? "登录未完成" : "Sign-in didn't finish");
        var b = forward ? "" : ok ? (zh ? "可以关闭此页，回到 \(name)。" : "You can close this tab and return to \(name).")
                                  : (zh ? "回到 \(name) 查看原因并重试。" : "Return to \(name) to see why and try again.");
        document.getElementById("t").textContent = t; document.getElementById("b").textContent = b; document.title = t + " · \(name)";
        </script></body></html>
        """
    }
}
