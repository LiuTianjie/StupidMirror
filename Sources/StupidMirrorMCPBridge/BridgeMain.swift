import AppKit
import Foundation
import MCP
import StupidMirrorBridgeCore
import StupidMirrorConnection

@main
enum BridgeMain {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--app" else {
                throw HostError("Usage: StupidMirrorMCPBridge --app /Applications/StupidMirror.app")
            }
            let host = AppHost(appURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            let bridge = MCPBridge(connectionProvider: { try await host.connection() })
            // Retry the handshake while the app binds its socket. No tool call has
            // been sent at this point, so this cannot replay an operation.
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            var server: Server?
            while server == nil {
                do { server = try await bridge.makeServer() }
                catch {
                    if ContinuousClock.now >= deadline { throw error }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            guard let server else { return }
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
            await server.stop()
            await bridge.disconnect()
        } catch {
            // stdout belongs exclusively to MCP JSON-RPC.
            FileHandle.standardError.write(Data("StupidMirror: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private struct HostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private actor AppHost {
    let appURL: URL
    private let file = MCPConnectionFile()
    private var lastLaunch: ContinuousClock.Instant?

    init(appURL: URL) { self.appURL = appURL }

    func connection() async throws -> MCPConnectionRecord {
        if let record = try? file.read(), record.processIsRunning { return record }
        if lastLaunch == nil || lastLaunch!.duration(to: .now) > .seconds(20) {
            guard FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path) else {
                throw HostError("Install StupidMirror in Applications, then reconnect the Codex chat.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", appURL.path, "--args", "--mcp-background"]
            process.standardOutput = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw HostError("Could not open StupidMirror.") }
            lastLaunch = .now
        }
        throw HostError("Waiting for StupidMirror. Enable Settings → MCP, then reconnect the Codex chat if needed.")
    }
}
