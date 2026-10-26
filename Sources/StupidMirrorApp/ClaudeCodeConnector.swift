import AppKit
import Combine
import Foundation

/// Connects Claude Code in one step: the user-scope MCP server `stupidmirror`,
/// which runs the bundled stdio helper, and the skills plugin read in place
/// from the app bundle's marketplace. The helper reads connection.json itself,
/// so port changes and token rotation need no reconfiguration and no token is
/// written to Claude Code's config.
enum ClaudeCodeMCPRegistration {
    static let serverName = "stupidmirror"
    static let helperSuffix = "/Contents/Helpers/StupidMirrorMCPBridge"
    static let marketplaceName = "stupidmirror"
    static let pluginID = "stupidmirror@stupidmirror"
    static let pluginResources = "Contents/Resources/ClaudePlugin"

    enum ExistingEntry: Equatable {
        case none
        /// Already runs this app's helper.
        case current
        /// Runs the helper of another StupidMirror copy (moved or replaced app).
        case otherHelper
        /// The HTTP command the manual guide generates for this endpoint.
        case generatedHTTP
        /// Someone else's entry under our name; kept as it is.
        case conflicting
    }

    static func helperPath(appPath: String) -> String { appPath + helperSuffix }

    static func marketplaceRoot(appPath: String) -> String { "\(appPath)/\(pluginResources)" }

    static func addArguments(appPath: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", helperPath(appPath: appPath), "--app", appPath]
    }

    static let removeArguments = ["mcp", "remove", "--scope", "user", serverName]

    static func marketplaceAddArguments(appPath: String) -> [String] {
        ["plugin", "marketplace", "add", marketplaceRoot(appPath: appPath)]
    }

    static let marketplaceRemoveArguments = ["plugin", "marketplace", "remove", marketplaceName]
    static let installArguments = ["plugin", "install", pluginID, "--scope", "user"]

    /// Claude Code keeps user-scope servers in `.claude.json` and enabled
    /// plugins in `settings.json`; `CLAUDE_CONFIG_DIR` moves both.
    static func configFiles(home: String, environment: [String: String]) -> (servers: String, settings: String) {
        if let directory = environment["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
            let root = directory as NSString
            return (root.appendingPathComponent(".claude.json"), root.appendingPathComponent("settings.json"))
        }
        let root = home as NSString
        return (root.appendingPathComponent(".claude.json"), root.appendingPathComponent(".claude/settings.json"))
    }

    static func classify(userConfig data: Data?, appPath: String, endpoint: String) -> ExistingEntry {
        guard let entry = object(data)?["mcpServers"].flatMap({ $0 as? [String: Any] })?[serverName] as? [String: Any] else {
            return .none
        }
        switch entry["type"] as? String ?? "stdio" {
        case "stdio":
            guard let command = entry["command"] as? String, command.hasSuffix(helperSuffix) else { return .conflicting }
            let arguments = entry["args"] as? [String] ?? []
            return command == helperPath(appPath: appPath) && arguments == ["--app", appPath] ? .current : .otherHelper
        case "http":
            return entry["url"] as? String == endpoint ? .generatedHTTP : .conflicting
        default:
            return .conflicting
        }
    }

    static func isPluginEnabled(settings data: Data?) -> Bool {
        (object(data)?["enabledPlugins"] as? [String: Any])?[pluginID] as? Bool == true
    }

    /// A GUI app gets a minimal PATH, so the usual install locations come first,
    /// then PATH, then the copies the Claude desktop app keeps for itself.
    static func cliCandidates(home: String, path: String?, desktopVersions: [String]) -> [String] {
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        candidates += (path ?? "").split(separator: ":").map { "\($0)/claude" }
        let desktopRoot = "\(home)/Library/Application Support/Claude/claude-code"
        candidates += desktopVersions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(desktopRoot)/\($0)/claude.app/Contents/MacOS/claude" }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The version `claude --version` prints first, e.g. `2.1.308 (Claude Code)`.
    static func version(fromOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first.map(String.init).flatMap { word in
            word.first?.isNumber == true && word.contains(".") ? word : nil
        }
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

@MainActor
final class ClaudeCodeConnector: ObservableObject {
    enum Failure: Equatable {
        case cliMissing
        case helperMissing
        case pluginMissing
        case commandFailed(String)
    }

    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    /// An MCP entry named stupidmirror that StupidMirror did not write was left in place.
    @Published private(set) var keptExistingServer = false
    @Published private(set) var failure: Failure?

    private let appPath = Bundle.main.bundleURL.path

    func refresh(endpoint: String) {
        let state = Self.state(appPath: appPath, endpoint: endpoint)
        keptExistingServer = state.server == .conflicting
        isConnected = state.pluginEnabled && (state.server == .current || state.server == .conflicting)
    }

    func connect(endpoint: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        failure = nil
        defer { isConnecting = false }
        let appPath = appPath
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.connect(appPath: appPath, endpoint: endpoint)
            }.value
        } catch let error as ConnectorError {
            failure = error.failure
        } catch {
            failure = .commandFailed(error.localizedDescription)
        }
        refresh(endpoint: endpoint)
    }

    func openClaude() {
        let root = FileManager.default.homeDirectoryForCurrentUser
        for url in [URL(fileURLWithPath: "/Applications/Claude.app"), root.appendingPathComponent("Applications/Claude.app")]
        where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return
        }
        NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
    }

    nonisolated private static func state(appPath: String, endpoint: String) -> (server: ClaudeCodeMCPRegistration.ExistingEntry, pluginEnabled: Bool) {
        let files = ClaudeCodeMCPRegistration.configFiles(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
        return (
            ClaudeCodeMCPRegistration.classify(
                userConfig: FileManager.default.contents(atPath: files.servers), appPath: appPath, endpoint: endpoint
            ),
            ClaudeCodeMCPRegistration.isPluginEnabled(settings: FileManager.default.contents(atPath: files.settings))
        )
    }

    nonisolated private static func connect(appPath: String, endpoint: String) throws {
        guard FileManager.default.isExecutableFile(atPath: ClaudeCodeMCPRegistration.helperPath(appPath: appPath)) else {
            throw ConnectorError(.helperMissing)
        }
        let marketplace = ClaudeCodeMCPRegistration.marketplaceRoot(appPath: appPath)
        guard FileManager.default.fileExists(atPath: "\(marketplace)/.claude-plugin/marketplace.json") else {
            throw ConnectorError(.pluginMissing)
        }
        guard let cli = findCLI() else { throw ConnectorError(.cliMissing) }

        // MCP first, skipped when an entry is already there; only StupidMirror's
        // own outdated entries are replaced.
        switch state(appPath: appPath, endpoint: endpoint).server {
        case .current, .conflicting:
            break
        case .otherHelper, .generatedHTTP:
            try run(cli, ClaudeCodeMCPRegistration.removeArguments)
            try run(cli, ClaudeCodeMCPRegistration.addArguments(appPath: appPath))
        case .none:
            try run(cli, ClaudeCodeMCPRegistration.addArguments(appPath: appPath))
        }

        // Both are no-ops when already done. Newer CLIs repoint a moved
        // marketplace in place; older ones refuse, so drop it and add again.
        do {
            try run(cli, ClaudeCodeMCPRegistration.marketplaceAddArguments(appPath: appPath))
        } catch {
            try? run(cli, ClaudeCodeMCPRegistration.marketplaceRemoveArguments)
            try run(cli, ClaudeCodeMCPRegistration.marketplaceAddArguments(appPath: appPath))
        }
        try run(cli, ClaudeCodeMCPRegistration.installArguments)
    }

    /// The newest working CLI: a stale native install can sit ahead of a
    /// current Homebrew one, and both share the same configuration.
    nonisolated private static func findCLI() -> String? {
        let home = NSHomeDirectory()
        let desktopRoot = "\(home)/Library/Application Support/Claude/claude-code"
        let candidates = ClaudeCodeMCPRegistration.cliCandidates(
            home: home,
            path: ProcessInfo.processInfo.environment["PATH"],
            desktopVersions: (try? FileManager.default.contentsOfDirectory(atPath: desktopRoot)) ?? []
        )
        let working = candidates.compactMap { candidate -> (path: String, version: String)? in
            guard FileManager.default.isExecutableFile(atPath: candidate),
                  let output = try? run(candidate, ["--version"], timeout: 20),
                  let version = ClaudeCodeMCPRegistration.version(fromOutput: output),
                  (try? run(candidate, ["plugin", "marketplace", "add", "--help"], timeout: 20)) != nil
            else { return nil }
            return (candidate, version)
        }
        // max(by:) keeps the first of equal versions, so install order breaks ties.
        return working.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.path
    }

    @discardableResult
    nonisolated private static func run(_ cli: String, _ arguments: [String], timeout: TimeInterval = 90) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // An npm install starts with `#!/usr/bin/env node`; give it the usual Node locations.
        let directory = (cli as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ConnectorError(.commandFailed(String(output.suffix(2_000))))
        }
        return output
    }
}

private struct ConnectorError: Error {
    let failure: ClaudeCodeConnector.Failure
    init(_ failure: ClaudeCodeConnector.Failure) { self.failure = failure }
}
