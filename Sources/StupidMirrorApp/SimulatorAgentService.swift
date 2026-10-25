import Darwin
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.stupidmirror.app", category: "SimulatorAgent")

/// A booted iOS Simulator, as `simctl` lists it.
struct SimulatorDevice: Equatable, Sendable {
    let udid: String
    let name: String
    let productType: String
    let osVersion: String

    var identity: DeviceIdentity {
        DeviceIdentity(
            id: "simulator:\(udid)",
            udid: udid,
            platform: .iOS,
            name: name,
            productType: productType,
            osVersion: osVersion,
            connectionState: .connected,
            trustState: .trusted
        )
    }
}

enum SimulatorDiscoveryService {
    enum Outcome: Equatable, Sendable {
        case available([SimulatorDevice])
        /// Xcode is missing or `simctl` did not answer: nothing is known.
        case unavailable
    }

    static func discover() -> Outcome {
        // Without Xcode there are no simulators, and `/usr/bin/xcrun` would
        // offer to install the command-line tools on every refresh.
        guard simctlAvailable() else { return .available([]) }
        guard let result = try? HostCommand.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "booted", "--json"],
            timeout: 10
        ), result.status == 0 else {
            return .unavailable
        }
        guard let devices = parseBootedDevices(result.stdout) else { return .unavailable }
        return .available(devices)
    }

    /// Whether the selected developer directory is a full Xcode with
    /// `simctl`. `xcode-select -p` only reads the selection; it never prompts.
    static func simctlAvailable() -> Bool {
        guard let result = try? HostCommand.run("/usr/bin/xcode-select", arguments: ["-p"], timeout: 5),
              result.status == 0 else { return false }
        let developer = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !developer.isEmpty else { return false }
        return FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/simctl")
    }

    /// A PNG of the simulator's screen, for the device card. `simctl` no
    /// longer writes screenshots to stdout, so it goes through a file.
    static func screenshotPNG(udid: String) throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupidmirror-simulator-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try HostCommand.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "io", udid, "screenshot", "--type=png", file.path],
            timeout: 15
        )
        guard result.status == 0 else { throw SimulatorAgentError.launchFailed(result.message) }
        return try Data(contentsOf: file)
    }

    /// Booted iOS (iPhone and iPad) simulators. watchOS, tvOS and visionOS
    /// runtimes cannot run the screen agent and are left out.
    /// Nil when the output is not the list `simctl` normally prints, so an
    /// odd answer is treated as unknown rather than as "nothing booted".
    static func parseBootedDevices(_ data: Data) -> [SimulatorDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return nil }
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in runtimes {
            guard let osVersion = iOSVersion(runtimeIdentifier: runtime) else { continue }
            for entry in entries {
                guard entry["state"] as? String == "Booted",
                      entry["isAvailable"] as? Bool ?? true,
                      let udid = entry["udid"] as? String, !udid.isEmpty,
                      let name = entry["name"] as? String else { continue }
                devices.append(SimulatorDevice(
                    udid: udid,
                    name: name,
                    productType: productType(deviceTypeIdentifier: entry["deviceTypeIdentifier"] as? String),
                    osVersion: osVersion
                ))
            }
        }
        return devices.sorted { $0.udid < $1.udid }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `27.0`.
    static func iOSVersion(runtimeIdentifier: String) -> String? {
        guard let marker = runtimeIdentifier.range(of: ".SimRuntime.iOS-") else { return nil }
        let version = runtimeIdentifier[marker.upperBound...].replacingOccurrences(of: "-", with: ".")
        return version.isEmpty ? nil : version
    }

    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro` → `iPhone 17 Pro`.
    static func productType(deviceTypeIdentifier: String?) -> String {
        guard let identifier = deviceTypeIdentifier,
              let last = identifier.split(separator: ".").last, !last.isEmpty else { return "iOS Simulator" }
        return last.replacingOccurrences(of: "-", with: " ")
    }
}

struct SimulatorAgentEndpoint: Equatable, Sendable {
    let controlURL: URL
    let mjpegURL: URL
}

enum SimulatorAgentError: LocalizedError, Equatable {
    case xcodeUnavailable
    case missingRuntime
    case buildFailed(String)
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .xcodeUnavailable:
            "iOS Simulator support needs Xcode. Install Xcode and select it with xcode-select."
        case .missingRuntime:
            "The bundled screen agent source is missing. Reinstall StupidMirror."
        case let .buildFailed(detail):
            "The simulator screen agent could not be built. \(detail)"
        case let .launchFailed(detail):
            "The simulator screen agent did not start. \(detail)"
        case .timedOut:
            "The simulator screen agent did not answer in time. Keep the simulator booted and try again."
        }
    }
}

/// Runs WebDriverAgent inside booted iOS Simulators: one runner per
/// simulator, shared by its mirror (WDA's MJPEG stream) and its control
/// session. Nothing is signed. The runner is built once per Xcode and
/// StupidMirror version and reused for every simulator.
///
/// Every port listens on 127.0.0.1 only: a simulator's runner runs on the
/// Mac itself, and WDA has no authentication of its own.
actor SimulatorAgentService {
    static let shared = SimulatorAgentService()

    static let runnerBundleID = "com.stupidmirror.wda.simulator"
    static let mjpegFrameRate = 60
    static let mjpegQuality = 70
    static let startTimeout: Duration = .seconds(120)
    static let buildTimeout: TimeInterval = 900

    private struct Agent {
        let process: Process
        let endpoint: SimulatorAgentEndpoint
        /// The screen height this runner was launched to capture (nil = main screen).
        let screenHeight: Int?
    }

    private var agents: [String: Agent] = [:]
    private var starting: [String: Task<SimulatorAgentEndpoint, Error>] = [:]
    /// Runners launched but not yet answering, so a stop can still end them.
    private var launching: [String: Process] = [:]
    /// The screen each running runner was launched to capture (nominal pixel
    /// height). A foldable can switch screens; a change restarts its runner.
    private var screenHeights: [String: Int] = [:]
    /// Bumped by every stop; a start that sees it change gives up.
    private var stopGenerations: [String: Int] = [:]
    /// Everyone waiting on a start hears its progress, not just the first.
    private var progressListeners: [String: [UUID: @Sendable (String) async -> Void]] = [:]
    private var build: Task<URL, Error>?

    /// Starts the runner for a simulator, or returns the running one.
    /// `progress` receives short status lines for the mirror's startup view.
    /// `screenHeight` selects which screen a foldable captures (nominal pixel
    /// height of the target screen); nil or 0 keeps the device's main screen,
    /// which is every standard device's only screen. Changing it restarts the
    /// runner so the new screen takes effect.
    func ensureRunning(
        udid: String,
        screenHeight: Int? = nil,
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> SimulatorAgentEndpoint {
        // nil / 0 means "no preference": the control connector asks without a
        // height and must not undo the screen the mirror chose. Only an explicit
        // height that differs from the running runner's restarts it.
        if let screenHeight, screenHeight > 0 {
            if let agent = agents[udid], agent.screenHeight != screenHeight {
                logger.info("Simulator agent for \(udid, privacy: .public) switching screen; restarting it")
                stop(udid: udid)
            }
            screenHeights[udid] = screenHeight
        }
        if let agent = agents[udid] {
            if await Self.isAlive(agent) {
                return agent.endpoint
            }
            // The answer may have come late; only replace the runner when
            // the one on record is still the one that failed to answer.
            if agents[udid]?.process === agent.process {
                logger.info("Simulator agent for \(udid, privacy: .public) stopped answering; restarting it")
                stop(udid: udid)
            } else if let current = agents[udid] {
                return current.endpoint
            }
        }
        let listener = UUID()
        progressListeners[udid, default: [:]][listener] = progress
        defer { progressListeners[udid]?[listener] = nil }
        if let task = starting[udid] {
            return try await task.value
        }
        let generation = stopGenerations[udid, default: 0]
        let task = Task { try await start(udid: udid, generation: generation) }
        starting[udid] = task
        defer {
            if starting[udid] == task { starting[udid] = nil }
        }
        return try await task.value
    }

    /// A runner that is busy answers `/status` late: WDA serves every route
    /// on its main queue, so a long hierarchy dump holds it up. One that has
    /// exited is dead at once; one that is running gets a longer second try.
    private static func isAlive(_ agent: Agent) async -> Bool {
        guard agent.process.isRunning else { return false }
        if await IOSAgentService.isReady(agent.endpoint.controlURL, timeout: 2) { return true }
        guard agent.process.isRunning else { return false }
        return await IOSAgentService.isReady(agent.endpoint.controlURL, timeout: 8)
    }

    /// Ends the simulator's runner, including one still starting.
    func stop(udid: String) {
        guard endProcesses(udid: udid) else { return }
        DispatchQueue.global(qos: .utility).async { Self.terminateRunnerApp(udid: udid) }
    }

    /// For app shutdown: waits until each runner app is told to quit, so none
    /// outlives StupidMirror.
    func stopAll() async {
        let udids = Set(agents.keys).union(launching.keys).union(starting.keys)
            .filter { endProcesses(udid: $0) }
        await withTaskGroup(of: Void.self) { group in
            for udid in udids {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            Self.terminateRunnerApp(udid: udid)
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    /// Cancels a start in progress and ends the xcodebuild processes; true
    /// when there was a runner to end.
    private func endProcesses(udid: String) -> Bool {
        stopGenerations[udid, default: 0] += 1
        let wasStarting = starting.removeValue(forKey: udid).map { $0.cancel() } != nil
        let processes = [agents.removeValue(forKey: udid)?.process, launching.removeValue(forKey: udid)]
            .compactMap { $0 }
        processes.forEach(Self.terminate)
        return wasStarting || !processes.isEmpty
    }

    /// Stops the runners of simulators that are no longer booted.
    func retain(only udids: Set<String>) {
        for udid in Set(agents.keys).union(launching.keys).union(starting.keys) where !udids.contains(udid) {
            stop(udid: udid)
        }
    }

    // MARK: Start

    private func report(_ udid: String, _ detail: String) async {
        for listener in progressListeners[udid, default: [:]].values {
            await listener(detail)
        }
    }

    /// Throws once a stop for this simulator came in after the start began.
    private func checkStillWanted(_ udid: String, generation: Int) throws {
        if Task.isCancelled || stopGenerations[udid, default: 0] != generation {
            throw CancellationError()
        }
    }

    private func start(udid: String, generation: Int) async throws -> SimulatorAgentEndpoint {
        let launchedHeight = screenHeights[udid]
        let xctestrun = try await builtRunner { [weak self] detail in
            await self?.report(udid, detail)
        }
        try checkStillWanted(udid, generation: generation)
        await report(udid, "Starting the simulator screen agent…")

        // A runner left behind by an earlier launch holds its ports and the
        // test slot; end it first.
        _ = try? await HostCommand.runDetached(
            "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", udid, Self.runnerBundleID + ".xctrunner"],
            timeout: 10
        )
        try checkStillWanted(udid, generation: generation)

        let controlPort = try Self.freeLoopbackPort()
        let mjpegPort = try Self.freeLoopbackPort(excluding: [controlPort])
        // xcodebuild keeps a result bundle per test run; one per simulator,
        // replaced each launch, keeps them from piling up.
        let results = Self.resultBundleURL(udid: udid)
        try? FileManager.default.removeItem(at: results)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrun.path,
            "-destination", "id=\(udid)",
            "-resultBundlePath", results.path
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            Self.launchEnvironment(controlPort: controlPort, mjpegPort: mjpegPort, screenHeight: launchedHeight)
        ) { _, new in new }
        let log = Self.logURL(udid: udid)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SimulatorAgentError.launchFailed(error.localizedDescription)
        }
        try? handle?.close()
        launching[udid] = process
        defer {
            if launching[udid] === process { launching[udid] = nil }
        }

        let endpoint = SimulatorAgentEndpoint(
            controlURL: URL(string: "http://127.0.0.1:\(controlPort)")!,
            mjpegURL: URL(string: "http://127.0.0.1:\(mjpegPort)")!
        )
        let deadline = ContinuousClock.now + Self.startTimeout
        while ContinuousClock.now < deadline {
            do {
                try checkStillWanted(udid, generation: generation)
            } catch {
                Self.terminate(process)
                throw error
            }
            guard process.isRunning else {
                throw SimulatorAgentError.launchFailed(Self.logTail(log))
            }
            if await IOSAgentService.isReady(endpoint.controlURL, timeout: 2) {
                do {
                    try checkStillWanted(udid, generation: generation)
                } catch {
                    Self.terminate(process)
                    throw error
                }
                agents[udid] = Agent(process: process, endpoint: endpoint, screenHeight: launchedHeight)
                logger.info("Simulator agent ready for \(udid, privacy: .public) on \(controlPort)/\(mjpegPort)")
                return endpoint
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        Self.terminate(process)
        throw SimulatorAgentError.timedOut
    }

    nonisolated static func launchEnvironment(
        controlPort: Int,
        mjpegPort: Int,
        screenHeight: Int? = nil
    ) -> [String: String] {
        // xcodebuild hands TEST_RUNNER_-prefixed variables to the runner
        // without the prefix.
        var environment = [
            "TEST_RUNNER_USE_IP": "127.0.0.1",
            "TEST_RUNNER_USE_PORT": "\(controlPort)",
            "TEST_RUNNER_MJPEG_SERVER_PORT": "\(mjpegPort)",
            "TEST_RUNNER_MJPEG_SERVER_FRAMERATE": "\(mjpegFrameRate)",
            "TEST_RUNNER_MJPEG_SERVER_SCREENSHOT_QUALITY": "\(mjpegQuality)",
            // The runner's H.264 encoder produces no frames inside a
            // simulator; port 0 leaves its SRT listener off.
            "TEST_RUNNER_STUPIDMIRROR_H264_PORT": "0"
        ]
        // A foldable lights only the screen matching its physical posture, and
        // the dark one captures as black. Absent an explicit choice the runner
        // streams whichever screen has content, so the mirror follows the
        // device as it is folded or opened. A height pins one specific screen.
        environment["TEST_RUNNER_STUPIDMIRROR_SCREEN_SELECT"] =
            (screenHeight ?? 0) > 0 ? "\(screenHeight!)" : "lit"
        return environment
    }

    // MARK: Build

    /// The runner's `.xctestrun`, building it first when this Xcode and
    /// StupidMirror have not built one yet.
    private func builtRunner(progress: @escaping @Sendable (String) async -> Void) async throws -> URL {
        if let build {
            return try await build.value
        }
        let task = Task { try await Self.buildRunnerIfNeeded(progress: progress) }
        build = task
        do {
            return try await task.value
        } catch {
            // A failed build is tried again next time.
            build = nil
            throw error
        }
    }

    private static func buildRunnerIfNeeded(
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> URL {
        guard let xcode = try? await HostCommand.runDetached("/usr/bin/xcrun", arguments: ["xcodebuild", "-version"], timeout: 30),
              xcode.status == 0 else {
            throw SimulatorAgentError.xcodeUnavailable
        }
        guard let project = IOSAgentService.webDriverAgentProjectURL(),
              let srtConfig = IOSAgentService.srtXcodeConfigURL(for: project) else {
            throw SimulatorAgentError.missingRuntime
        }
        let root = supportDirectory()
        let derivedData = root.appendingPathComponent("DerivedData", isDirectory: true)
        let stampURL = root.appendingPathComponent("build-stamp")
        let stamp = buildStamp(xcodeVersion: String(decoding: xcode.stdout, as: UTF8.self))
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp,
           let existing = xctestrun(in: derivedData) {
            return existing
        }

        await progress("Building the simulator screen agent. The first time takes about two minutes…")
        try? FileManager.default.removeItem(at: derivedData)
        try? FileManager.default.removeItem(at: stampURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let arguments = [
            "xcodebuild", "-quiet",
            "-project", project.path,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path,
            "-xcconfig", srtConfig.path,
            "CODE_SIGNING_ALLOWED=NO",
            "PRODUCT_BUNDLE_IDENTIFIER=\(runnerBundleID)",
            "ONLY_ACTIVE_ARCH=YES",
            // The bundled simulator libsrt is arm64 only, like the app.
            "ARCHS=arm64",
            "build-for-testing"
        ]
        let result: HostCommand.Result
        do {
            result = try await HostCommand.runDetached(
                "/usr/bin/env",
                arguments: ["STUPIDMIRROR_SKIP_WDA_ICON_EMBED=1", "/usr/bin/xcrun"] + arguments,
                timeout: buildTimeout
            )
        } catch HostCommand.Failure.timedOut {
            throw SimulatorAgentError.buildFailed("The build did not finish within 15 minutes.")
        } catch {
            throw SimulatorAgentError.buildFailed(error.localizedDescription)
        }
        guard result.status == 0, let built = xctestrun(in: derivedData) else {
            // -quiet still prints warnings; the failure is the last error line
            // in either stream.
            let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            logger.error("Simulator agent build failed: \(String(output.suffix(4_000)), privacy: .public)")
            throw SimulatorAgentError.buildFailed(lastErrorLine(output))
        }
        try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return built
    }

    /// Changes whenever Xcode, StupidMirror or the bundled runner source does.
    nonisolated static func buildStamp(xcodeVersion: String) -> String {
        let info = Bundle.main.infoDictionary
        let appVersion = [
            info?["CFBundleShortVersionString"] as? String,
            info?["CFBundleVersion"] as? String
        ].compactMap { $0 }.joined(separator: "+")
        var sourceDate = 0.0
        if let project = IOSAgentService.webDriverAgentProjectURL() {
            let lib = project.deletingLastPathComponent().appendingPathComponent("WebDriverAgentLib")
            for file in ["Utilities/FBMjpegServer.m", "Utilities/FBStupidMirrorH264Server.inc", "Routing/FBTCPSocket.m", "Routing/FBWebServer.m"] {
                let date = (try? FileManager.default.attributesOfItem(
                    atPath: lib.appendingPathComponent(file).path
                )[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                sourceDate = max(sourceDate, date)
            }
        }
        let xcode = xcodeVersion.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\(xcode)|\(appVersion)|\(Int(sourceDate))"
    }

    private static func xctestrun(in derivedData: URL) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains("iphonesimulator") }
    }

    /// The most specific failure line: a compiler or linker error, else any
    /// line mentioning an error.
    static func lastErrorLine(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.last { $0.contains("error:") && !$0.contains("linker command failed") }
            ?? lines.last { $0.hasPrefix("ld:") && !$0.contains("warning") }
            ?? lines.last { $0.localizedCaseInsensitiveContains("error") }
        guard let line else { return "See the system log for details." }
        return String(line.suffix(400))
    }

    // MARK: Helpers

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("StupidMirror/SimulatorAgent", isDirectory: true)
    }

    private static func logURL(udid: String) -> URL {
        let directory = supportDirectory().appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(udid).log")
    }

    private static func logTail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return lastErrorLine(String(text.suffix(4_000)))
    }

    private static func resultBundleURL(udid: String) -> URL {
        supportDirectory().appendingPathComponent("Results/\(udid).xcresult", isDirectory: true)
    }

    /// Ending xcodebuild normally ends the test, but the runner app inside the
    /// simulator is ended too so nothing keeps the ports or the test slot.
    private static func terminateRunnerApp(udid: String) {
        _ = try? HostCommand.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", udid, runnerBundleID + ".xctrunner"],
            timeout: 10
        )
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// A port nothing on 127.0.0.1 is listening on, chosen by the kernel.
    private static func freeLoopbackPort(excluding excluded: Set<Int> = []) throws -> Int {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { continue }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else { continue }
            let port = Int(UInt16(bigEndian: address.sin_port))
            if !excluded.contains(port) { return port }
        }
        throw SimulatorAgentError.launchFailed("No free local port is available.")
    }
}
