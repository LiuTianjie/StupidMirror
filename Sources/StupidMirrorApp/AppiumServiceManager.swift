import Foundation

@MainActor
final class AppiumServiceManager: ObservableObject {
    @Published private(set) var state: AppiumServiceState = .unknown
    @Published private(set) var message = "Not checked"

    private var process: Process?
    private var logFileHandle: FileHandle?

    var isRunning: Bool {
        if case .running = state {
            true
        } else {
            false
        }
    }

    var canStartLocally: Bool {
        findExecutable(named: "appium") != nil
    }

    @discardableResult
    func checkNow(serverURL: String) async -> Bool {
        state = .checking
        message = "Checking Appium..."
        do {
            try await AppiumHTTPClient(baseURL: serverURL).status()
            state = .running
            message = "Appium is reachable at \(serverURL)"
            return true
        } catch {
            state = .stopped
            message = "Appium is not reachable."
            return false
        }
    }

    @discardableResult
    func ensureRunning(serverURL: String) async -> Bool {
        if await checkNow(serverURL: serverURL) {
            return true
        }

        guard canStartLocally else {
            state = .missing
            message = "Appium is not installed. Run `make setup-appium`."
            return false
        }

        start(serverURL: serverURL)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        return await checkNow(serverURL: serverURL)
    }

    func check(serverURL: String) {
        state = .checking
        message = "Checking Appium..."
        Task {
            do {
                try await AppiumHTTPClient(baseURL: serverURL).status()
                self.state = .running
                self.message = "Appium is reachable at \(serverURL)"
            } catch {
                self.state = .stopped
                self.message = "Appium is not reachable."
            }
        }
    }

    func start(serverURL: String) {
        if let process, process.isRunning {
            state = .running
            message = "Appium is already managed by StupidMirror."
            return
        }

        guard let appiumPath = findExecutable(named: "appium") else {
            state = .missing
            message = "Appium is not installed. Run `make setup-appium`."
            return
        }

        let endpoint = URL(string: serverURL)
        let host = endpoint?.host ?? "127.0.0.1"
        let port = endpoint?.port ?? 4723

        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: appiumPath)
        launched.arguments = ["--address", host, "--port", "\(port)"]
        launched.environment = ProcessInfo.processInfo.environment.merging([
            "STUPIDMIRROR_SKIP_WDA_ICON_EMBED": "1"
        ]) { _, new in new }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("StupidMirror-Appium.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        launched.standardOutput = handle
        launched.standardError = handle

        do {
            try launched.run()
            process = launched
            logFileHandle = handle
            state = .starting
            message = "Starting Appium at http://\(host):\(port)... Log: \(logURL.path)"

            launched.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self, self.process === process else { return }
                    self.process = nil
                    try? self.logFileHandle?.close()
                    self.logFileHandle = nil
                    self.state = .stopped
                    self.message = "Appium exited with status \(process.terminationStatus). Log: \(logURL.path)"
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.check(serverURL: serverURL)
            }
        } catch {
            state = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
    }

    func stop() {
        guard let process else {
            state = .stopped
            message = "No managed Appium process."
            return
        }

        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        try? logFileHandle?.close()
        logFileHandle = nil
        state = .stopped
        message = "Managed Appium process stopped."
    }

    private func findExecutable(named name: String) -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Appium/bin/\(name)")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(NSHomeDirectory())/.nvm/versions/node/v22.21.0/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum AppiumServiceState: Equatable {
    case unknown
    case checking
    case starting
    case running
    case stopped
    case missing
    case failed(String)

    var label: String {
        switch self {
        case .unknown:
            "Unknown"
        case .checking:
            "Checking"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopped:
            "Stopped"
        case .missing:
            "Missing"
        case .failed:
            "Failed"
        }
    }
}
