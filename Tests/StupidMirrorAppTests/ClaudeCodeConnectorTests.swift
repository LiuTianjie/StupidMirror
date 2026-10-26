@testable import StupidMirrorApp
import XCTest

final class ClaudeCodeConnectorTests: XCTestCase {
    private let appPath = "/Applications/StupidMirror.app"
    private let endpoint = "http://127.0.0.1:17373/mcp"

    func testRegistersTheBundledHelperAtUserScopeWithoutAToken() {
        let arguments = ClaudeCodeMCPRegistration.addArguments(appPath: appPath)
        XCTAssertEqual(arguments, [
            "mcp", "add", "--scope", "user", "stupidmirror", "--",
            "/Applications/StupidMirror.app/Contents/Helpers/StupidMirrorMCPBridge", "--app", appPath,
        ])
        XCTAssertFalse(arguments.contains { $0.contains("Bearer") })
    }

    func testInstallsThePluginFromTheBundledMarketplace() {
        XCTAssertEqual(ClaudeCodeMCPRegistration.marketplaceAddArguments(appPath: appPath), [
            "plugin", "marketplace", "add", "/Applications/StupidMirror.app/Contents/Resources/ClaudePlugin",
        ])
        XCTAssertEqual(ClaudeCodeMCPRegistration.installArguments, ["plugin", "install", "stupidmirror@stupidmirror", "--scope", "user"])
    }

    func testRepositoryMarketplaceListsThePluginTheAppInstalls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marketplace = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        ) as? [String: Any])
        XCTAssertEqual(marketplace["name"] as? String, ClaudeCodeMCPRegistration.marketplaceName)
        let entry = try XCTUnwrap((marketplace["plugins"] as? [[String: Any]])?.first)
        let source = try XCTUnwrap(entry["source"] as? String)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(source).appendingPathComponent(".claude-plugin/plugin.json"))
        ) as? [String: Any])
        XCTAssertEqual("\(manifest["name"] ?? "")@\(marketplace["name"] ?? "")", ClaudeCodeMCPRegistration.pluginID)
        XCTAssertNil(manifest["mcpServers"], "The MCP server is registered at user scope, not by the plugin, so it is never listed twice")
    }

    func testClassifiesExistingUserScopeEntries() {
        XCTAssertEqual(classify(nil), .none)
        XCTAssertEqual(classify(#"{"mcpServers":{"figma":{"type":"http","url":"https://example.com"}}}"#), .none)
        XCTAssertEqual(classify(#"{"mcpServers":{"stupidmirror":{"type":"stdio","command":"/Applications/StupidMirror.app/Contents/Helpers/StupidMirrorMCPBridge","args":["--app","/Applications/StupidMirror.app"],"env":{}}}}"#), .current)
        XCTAssertEqual(classify(#"{"mcpServers":{"stupidmirror":{"command":"/Users/me/Applications/StupidMirror.app/Contents/Helpers/StupidMirrorMCPBridge","args":["--app","/Users/me/Applications/StupidMirror.app"]}}}"#), .otherHelper)
        XCTAssertEqual(classify(#"{"mcpServers":{"stupidmirror":{"type":"http","url":"http://127.0.0.1:17373/mcp","headers":{"Authorization":"Bearer old"}}}}"#), .generatedHTTP)
        XCTAssertEqual(classify(#"{"mcpServers":{"stupidmirror":{"type":"http","url":"https://example.com/mcp"}}}"#), .conflicting)
        XCTAssertEqual(classify(#"{"mcpServers":{"stupidmirror":{"type":"stdio","command":"npx","args":["something-else"]}}}"#), .conflicting)
        XCTAssertEqual(classify("not json"), .none)
    }

    func testReadsWhetherThePluginIsEnabled() {
        XCTAssertTrue(ClaudeCodeMCPRegistration.isPluginEnabled(settings: Data(#"{"enabledPlugins":{"stupidmirror@stupidmirror":true}}"#.utf8)))
        XCTAssertFalse(ClaudeCodeMCPRegistration.isPluginEnabled(settings: Data(#"{"enabledPlugins":{"stupidmirror@stupidmirror":false}}"#.utf8)))
        XCTAssertFalse(ClaudeCodeMCPRegistration.isPluginEnabled(settings: Data(#"{"enabledPlugins":{"other@stupidmirror":true}}"#.utf8)))
        XCTAssertFalse(ClaudeCodeMCPRegistration.isPluginEnabled(settings: nil))
    }

    func testHonorsClaudeConfigDirectory() {
        let standard = ClaudeCodeMCPRegistration.configFiles(home: "/Users/me", environment: [:])
        XCTAssertEqual(standard.servers, "/Users/me/.claude.json")
        XCTAssertEqual(standard.settings, "/Users/me/.claude/settings.json")
        let moved = ClaudeCodeMCPRegistration.configFiles(home: "/Users/me", environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude"])
        XCTAssertEqual(moved.servers, "/tmp/claude/.claude.json")
        XCTAssertEqual(moved.settings, "/tmp/claude/settings.json")
    }

    func testCLICandidatesCoverInstallsPathAndDesktopCopies() {
        let candidates = ClaudeCodeMCPRegistration.cliCandidates(
            home: "/Users/me", path: "/usr/bin:/opt/homebrew/bin", desktopVersions: ["2.1.9", "2.1.284", "2.1.28"]
        )
        XCTAssertEqual(candidates.first, "/Users/me/.local/bin/claude")
        XCTAssertEqual(candidates.filter { $0 == "/opt/homebrew/bin/claude" }.count, 1)
        XCTAssertTrue(candidates.contains("/usr/bin/claude"))
        let desktop = candidates.filter { $0.contains("Application Support/Claude/claude-code") }
        XCTAssertEqual(desktop.map { ($0 as NSString).pathComponents[7] }, ["2.1.284", "2.1.28", "2.1.9"])
        XCTAssertEqual(candidates.suffix(3), desktop[...])
    }

    func testParsesTheCLIVersion() {
        XCTAssertEqual(ClaudeCodeMCPRegistration.version(fromOutput: "2.1.308 (Claude Code)\n"), "2.1.308")
        XCTAssertNil(ClaudeCodeMCPRegistration.version(fromOutput: "error: unknown option"))
        XCTAssertNil(ClaudeCodeMCPRegistration.version(fromOutput: ""))
    }

    func testRefreshesTheCachedPluginOnlyWhenTheBundledVersionChanged() {
        let installed = Data(#"{"version":2,"plugins":{"stupidmirror@stupidmirror":[{"scope":"user","version":"0.1.0","installPath":"/x"}]}}"#.utf8)
        XCTAssertEqual(ClaudeCodeMCPRegistration.installedPluginVersion(installedPlugins: installed), "0.1.0")
        XCTAssertNil(ClaudeCodeMCPRegistration.installedPluginVersion(installedPlugins: Data(#"{"plugins":{}}"#.utf8)))
        XCTAssertNil(ClaudeCodeMCPRegistration.installedPluginVersion(installedPlugins: nil))
        XCTAssertEqual(ClaudeCodeMCPRegistration.bundledPluginVersion(manifest: Data(#"{"name":"stupidmirror","version":"0.1.1"}"#.utf8)), "0.1.1")

        XCTAssertTrue(ClaudeCodeMCPRegistration.needsPluginUpdate(installed: "0.1.0", bundled: "0.1.1"))
        XCTAssertFalse(ClaudeCodeMCPRegistration.needsPluginUpdate(installed: "0.1.1", bundled: "0.1.1"))
        XCTAssertFalse(ClaudeCodeMCPRegistration.needsPluginUpdate(installed: nil, bundled: "0.1.1"), "Never installs for someone who did not connect")
        XCTAssertEqual(ClaudeCodeMCPRegistration.updateArguments, ["plugin", "update", "stupidmirror@stupidmirror", "--scope", "user"])
        XCTAssertEqual(
            ClaudeCodeMCPRegistration.installedPluginsFile(home: "/Users/me", environment: [:]),
            "/Users/me/.claude/plugins/installed_plugins.json"
        )
    }

    func testBundledManifestVersionIsReadable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("plugins/stupidmirror-claude/.claude-plugin/plugin.json"))
        XCTAssertNotNil(ClaudeCodeMCPRegistration.bundledPluginVersion(manifest: data))
    }

    func testCopyExistsInBothLanguages() {
        for key in ["mcp.clients.title", "mcp.clients.intro", "mcp.clients.step2", "mcp.clients.copyPrompt",
                    "mcp.codex.tagline", "mcp.codex.cardIntro", "mcp.claude.tagline", "mcp.claude.intro",
                    "mcp.claude.connect", "mcp.claude.reconnect", "mcp.claude.connecting", "mcp.claude.connected",
                    "mcp.claude.keptServer", "mcp.claude.prompt", "mcp.claude.open", "mcp.claude.cliMissing",
                    "mcp.claude.helperMissing", "mcp.claude.pluginMissing"] {
            XCTAssertNotEqual(AppCopy.text(key, language: .en), key)
            XCTAssertNotEqual(AppCopy.text(key, language: .zhHans), key)
        }
    }

    private func classify(_ json: String?) -> ClaudeCodeMCPRegistration.ExistingEntry {
        ClaudeCodeMCPRegistration.classify(userConfig: json.map { Data($0.utf8) }, appPath: appPath, endpoint: endpoint)
    }
}
