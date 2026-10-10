import AppKit
import Combine
import Foundation

@MainActor
final class CodexPluginInstaller: ObservableObject {
    @Published private(set) var isInstalling = false
    @Published private(set) var installedThisSession = false
    @Published private(set) var error: String?

    func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        error = nil
        defer { isInstalling = false }
        guard let resources = Bundle.main.resourceURL else {
            error = "The Codex plugin is missing from this app build."
            return
        }
        let script = resources.appendingPathComponent("CodexPlugin/scripts/install-codex-plugin.sh")
        let appPath = Bundle.main.bundleURL.path
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.runInstaller(script: script, appPath: appPath)
            }.value
            installedThisSession = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openCodex() {
        let names = ["Codex", "ChatGPT"]
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            for name in names {
                let url = root.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    return
                }
            }
        }
        NSWorkspace.shared.open(URL(string: "https://developers.openai.com/codex/app/")!)
    }

    nonisolated private static func runInstaller(script: URL, appPath: String) throws {
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw InstallerError("This StupidMirror build does not include the Codex plugin. Install an updated app build.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["STUPIDMIRROR_APP"] = appPath
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw InstallerError(String(detail.suffix(2_000)))
        }
    }
}

private struct InstallerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
