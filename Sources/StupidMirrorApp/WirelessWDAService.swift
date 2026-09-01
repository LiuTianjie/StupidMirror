import CryptoKit
import Darwin
import Foundation
import Network
import OSLog

enum WirelessWDAError: LocalizedError, Equatable {
    case missingSigningTeam
    case missingRuntime
    case firstUSBSetupRequired
    case buildFailed
    case launchFailed
    case localNetworkDenied
    case iphoneLocalNetworkDenied
    case deviceLocked
    case deviceUnavailable
    case agentBackgroundingUnsupported
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingSigningTeam:
            "Select an Apple development team before starting wireless mirroring."
        case .missingRuntime:
            "The bundled WebDriverAgent runtime is unavailable."
        case .firstUSBSetupRequired:
            "Connect this iPhone by USB once to finish wireless mirror setup."
        case .buildFailed:
            "WebDriverAgent could not be prepared for this iPhone."
        case .launchFailed:
            "WebDriverAgent could not be launched over Wi-Fi."
        case .localNetworkDenied:
            "Local network access is disabled for StupidMirror."
        case .iphoneLocalNetworkDenied:
            "Allow Local Network access for WebDriverAgentRunner-Runner on the iPhone, then try again."
        case .deviceLocked:
            "Unlock the iPhone and keep its screen on, then try again."
        case .deviceUnavailable:
            "The iPhone is not available over Wi-Fi. Unlock it and check that both devices are on the same network."
        case .agentBackgroundingUnsupported:
            "This iOS version stops the screen agent before it can start. Reconnect USB to prepare it again."
        case .timedOut:
            "The wireless screen agent did not respond. Retry, or reconnect USB if it continues."
        }
    }
}

enum WirelessWDAProgress: Equatable, Sendable {
    case checkingExistingAgent
    case connectingDevice
    case launchingInstalledAgent
    case preparingAgent
    case installingAgent
    case waitingForAgent
    case connectingVideo
}

struct WirelessWDAEndpoint: Equatable, Sendable {
    let controlURL: URL
    let videoHost: String
}

/// Launches a USB-prepared WebDriverAgent with Apple's public CoreDevice CLI,
/// then reads WDA through the iPhone's verified LAN address. CoreDevice's
/// command tunnel is intentionally kept alive while the runner is active, but
/// its `*.coredevice.local` names are not assumed to be general-purpose HTTP
/// endpoints. iOS 17 and newer cannot launch the legacy embedded XCTest
/// framework bundle directly, so a signed compatibility copy is installed
/// before the first wireless launch.
final class WirelessWDAService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "WirelessWDA")
    private static let runnerName = "WebDriverAgentRunner-Runner.app"
    private static let incompatibleFrameworks = [
        "XCUnit.framework",
        "XCTAutomationSupport.framework",
        "XCUIAutomation.framework",
        "XCTestSupport.framework",
        "XCTest.framework",
        "XCTestCore.framework"
    ]

    final class RemoteProcess: @unchecked Sendable {
        let udid: String
        let consoleProcess: Process
        let outputPipe: Pipe
        let serverURL: URL

        init(
            udid: String,
            consoleProcess: Process,
            outputPipe: Pipe,
            serverURL: URL
        ) {
            self.udid = udid
            self.consoleProcess = consoleProcess
            self.outputPipe = outputPipe
            self.serverURL = serverURL
        }

        func stop() {
            guard consoleProcess.isRunning else {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            consoleProcess.interrupt()
            consoleProcess.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private struct CommandFailure: Error {
        let output: String
    }

    /// Lets a termination handler installed before the `RemoteProcess` exists
    /// reach it once it does.
    private final class RemoteProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: RemoteProcess?

        var value: RemoteProcess? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private final class ConsoleLaunchMonitor: @unchecked Sendable {
        private let condition = NSCondition()
        private var output = ""
        private var serverURL: URL?
        private var finished = false

        func append(_ data: Data) {
            condition.lock()
            if data.isEmpty {
                finished = true
            } else if serverURL == nil,
                      let chunk = String(data: data, encoding: .utf8) {
                output.append(chunk)
                if output.utf8.count > 65_536 {
                    output = String(output.suffix(65_536))
                }
                serverURL = WirelessWDAService.serverURL(fromConsoleOutput: output)
            }
            condition.broadcast()
            condition.unlock()
        }

        func markFinished() {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        func waitForServerURL(timeout: TimeInterval) -> URL? {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while serverURL == nil, !finished, condition.wait(until: deadline) {}
            return serverURL
        }

        var capturedOutput: String {
            condition.withLock { output }
        }
    }

    /// One live `devicectl process launch` per device, shared across every
    /// caller in this process.
    ///
    /// Launching passes `--terminate-existing`, so two launches for the same
    /// bundle ID kill each other's runner. The loser's console never prints
    /// `ServerURLHere`, its wait times out, and the caller concludes the runner
    /// is broken and reinstalls it — which is slow and fixes nothing, because
    /// the runner was fine. Mirroring, control, and retries all reach this code
    /// for the same UDID, so the collision is routine rather than exotic.
    ///
    /// Keeping one registered launch per UDID removes the race: later callers
    /// reuse the running agent instead of restarting it.
    final class LaunchRegistry: @unchecked Sendable {
        static let shared = LaunchRegistry()

        private let lock = NSLock()
        private var processes: [String: RemoteProcess] = [:]

        /// Returns the live launch for this device, dropping it if it has exited.
        func existing(udid: String) -> RemoteProcess? {
            lock.withLock {
                guard let process = processes[udid] else { return nil }
                guard process.consoleProcess.isRunning else {
                    processes[udid] = nil
                    return nil
                }
                return process
            }
        }

        /// Publishes a launch, returning any already-registered live launch so
        /// the caller can discard its own and adopt the winner.
        func register(_ process: RemoteProcess, udid: String) -> RemoteProcess? {
            let incumbent: RemoteProcess? = lock.withLock {
                if let current = processes[udid], current.consoleProcess.isRunning {
                    return current
                }
                processes[udid] = process
                return nil
            }
            return incumbent
        }

        func remove(udid: String, if process: RemoteProcess) {
            lock.withLock {
                if processes[udid] === process { processes[udid] = nil }
            }
        }
    }

    // A runner that has printed its LAN URL has already bound its socket, so
    // /status normally answers within a second or two. Waiting a minute past
    // that only stretches the two failures we can actually hit — the agent is
    // not running, or iOS is refusing inbound connections — and neither gets
    // better with time. Keep enough headroom for a slow first launch, then fail
    // fast with an error that names the real cause.
    static let installedLaunchReadyTimeout: Duration = .seconds(12)
    static let extraReadyTimeout: Duration = .seconds(8)
    static let existingProcessReadyTimeout: Duration = .seconds(12)

    private let lock = NSLock()
    private var remoteProcess: RemoteProcess?
    private var cachedEndpoint: WirelessWDAEndpoint?

    var activeEndpoint: WirelessWDAEndpoint? {
        lock.withLock { cachedEndpoint }
    }

    deinit { stop() }

    /// Builds, installs, launches, and probes the patched WDA runner while the
    /// iPhone is connected by USB. The guide only reports success after the
    /// Mac can reach WDA through the iPhone's LAN address, so unplugging USB no
    /// longer reveals an untested local-network permission or routing failure.
    static func prepareInitialUSBSetup(
        udid: String,
        configuration: AppiumControlConfiguration
    ) async throws {
        let isolated = configuration.isolated(forDeviceUDID: udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw WirelessWDAError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw WirelessWDAError.missingSigningTeam }
        guard let project = webDriverAgentProjectURL() else {
            throw WirelessWDAError.missingRuntime
        }
        guard let srtXcodeConfig = srtXcodeConfigURL(for: project) else {
            throw WirelessWDAError.missingRuntime
        }
        try await Task.detached(priority: .userInitiated) {
            var arguments = [
                "xcodebuild", "-quiet",
                "-project", project.path,
                "-scheme", "WebDriverAgentRunner",
                "-destination", "id=\(udid)",
                "-derivedDataPath", isolated.derivedDataPath,
                "-xcconfig", srtXcodeConfig.path,
                "-allowProvisioningUpdates"
            ]
            if isolated.allowProvisioningDeviceRegistration {
                arguments.append("-allowProvisioningDeviceRegistration")
            }
            arguments.append(contentsOf: [
                "DEVELOPMENT_TEAM=\(team)",
                "CODE_SIGN_STYLE=Automatic",
                "CODE_SIGN_IDENTITY=\(isolated.xcodeSigningID)",
                "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
                "build-for-testing"
            ])
            do {
                _ = try run(
                    "/usr/bin/xcrun",
                    arguments: arguments,
                    environment: ["STUPIDMIRROR_SKIP_WDA_ICON_EMBED": "1"]
                )
            } catch let failure as CommandFailure {
                if outputIndicatesLockedDevice(failure.output) {
                    throw WirelessWDAError.deviceLocked
                }
                logger.error("Initial wireless WDA build failed: \(failure.output, privacy: .public)")
                throw WirelessWDAError.buildFailed
            } catch let error as WirelessWDAError {
                throw error
            } catch {
                throw WirelessWDAError.buildFailed
            }
        }.value

        let launched = try await Task.detached(priority: .userInitiated) {
            let runner = try prepareCompatibleRunner(
                derivedDataPath: isolated.derivedDataPath,
                bundleID: bundleID
            )
            return try installAndLaunch(runner: runner, udid: udid, bundleID: bundleID)
        }.value
        defer {
            DispatchQueue.global(qos: .utility).async {
                launched.stop()
            }
        }
        // The runner has already printed its LAN URL by now, so /status answers
        // in milliseconds when it answers at all. A long wait here only delays
        // naming the real cause.
        guard await waitUntilReady([launched.serverURL], timeout: .seconds(15)) != nil else {
            throw await unreachableAgentError(
                host: launched.serverURL.host ?? ""
            )
        }
    }

    func ensureRunning(
        device: WirelessDeviceMetadata,
        configuration: AppiumControlConfiguration,
        progress: @escaping @Sendable (WirelessWDAProgress) async -> Void = { _ in }
    ) async throws -> WirelessWDAEndpoint {
        try await WirelessWDAEnsureGate.shared.run(udid: device.udid) {
            try await self.ensureRunningUniquely(
                device: device,
                configuration: configuration,
                progress: progress
            )
        }
    }

    private func ensureRunningUniquely(
        device: WirelessDeviceMetadata,
        configuration: AppiumControlConfiguration,
        progress: @escaping @Sendable (WirelessWDAProgress) async -> Void
    ) async throws -> WirelessWDAEndpoint {
        // CoreDevice endpoints are dynamic. Prefer the current tunnel address,
        // but retain every devicectl-provided hostname as a generic fallback.
        // `devicectl list devices` commonly reports a paired local-network
        // iPhone as `disconnected` before any command has tried to wake it.
        // The details/launch commands below are what establish that channel,
        // so requiring an already-connected tunnel here creates a deadlock.
        guard device.canAttemptConnection else { throw WirelessWDAError.deviceUnavailable }
        let baseURLs = probeURLs(for: device)
        guard !baseURLs.isEmpty else { throw WirelessWDAError.deviceUnavailable }
        if await Self.isLocalNetworkDenied(hostname: device.preferredEndpointHost) {
            throw WirelessWDAError.localNetworkDenied
        }
        await progress(.checkingExistingAgent)
        if let endpoint = await Self.firstReadyEndpoint(baseURLs) {
            remember(endpoint)
            await progress(.connectingVideo)
            return endpoint
        }

        await progress(.connectingDevice)
        try await Task.detached(priority: .userInitiated) {
            try Self.wakeDevice(udid: device.udid)
        }.value
        if let endpoint = await Self.firstReadyEndpoint(baseURLs) {
            remember(endpoint)
            await progress(.connectingVideo)
            return endpoint
        }

        if lock.withLock({ remoteProcess }) != nil {
            await progress(.waitingForAgent)
            if let endpoint = await Self.waitUntilReady(
                probeURLs(for: device),
                timeout: Self.existingProcessReadyTimeout
            ) {
                remember(endpoint)
                await progress(.connectingVideo)
                return endpoint
            }
        }

        let isolated = configuration.isolated(forDeviceUDID: device.udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw WirelessWDAError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw WirelessWDAError.missingSigningTeam }

        await progress(.launchingInstalledAgent)
        let launched: RemoteProcess?
        do {
            launched = try await Task.detached(priority: .userInitiated, operation: {
                try Self.launchInstalledRunner(udid: device.udid, bundleID: bundleID)
            }).value
            lock.withLock { remoteProcess = launched }
        } catch let error as WirelessWDAError where !Self.isWorthReinstalling(error) {
            // Reinstalling cannot fix a locked device, an unreachable one, or an
            // OS that refuses this launch path — it just repeats the same wait
            // after a slow install.
            throw error
        } catch {
            launched = nil
        }

        if let launched {
            await progress(.waitingForAgent)
            if let endpoint = await waitForReadyWithoutReinstalling(probeURLs(for: device)) {
                remember(endpoint)
                await progress(.connectingVideo)
                return endpoint
            }
            // A launched runner that has not answered /status is still starting.
            // Reinstalling it kills the process the video plane is waiting on.
            throw await Self.unreachableAgentError(
                host: launched.serverURL.host ?? device.preferredEndpointHost
            )
        }

        await progress(.preparingAgent)
        let preparedRunner = try await Task.detached(priority: .userInitiated) {
            try Self.prepareCompatibleRunner(
                derivedDataPath: isolated.derivedDataPath,
                bundleID: bundleID
            )
        }.value
        await progress(.installingAgent)
        let installed = try await Task.detached(priority: .userInitiated) {
            try Self.installAndLaunch(
                runner: preparedRunner,
                udid: device.udid,
                bundleID: bundleID
            )
        }.value
        lock.withLock { remoteProcess = installed }
        await progress(.waitingForAgent)

        if let endpoint = await waitForReadyWithoutReinstalling(probeURLs(for: device)) {
            remember(endpoint)
            await progress(.connectingVideo)
            return endpoint
        }
        throw await Self.unreachableAgentError(
            host: installed.serverURL.host ?? device.preferredEndpointHost
        )
    }

    /// Distinguishes "the agent is not listening" from "iOS is refusing inbound
    /// connections to it".
    ///
    /// A listening socket that iOS is blocking swallows the SYN, so the connect
    /// times out. A port with no listener answers with RST, which surfaces as a
    /// refused connection. Reporting both as a local-network denial sends users
    /// to a Settings toggle that is not the problem; reporting both as a launch
    /// failure hides the toggle that is.
    private static func unreachableAgentError(host: String) async -> WirelessWDAError {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .iphoneLocalNetworkDenied }
        switch await probeConnectability(host: trimmed, port: 8_100) {
        case .refused:
            return .launchFailed
        case .timedOut:
            return .iphoneLocalNetworkDenied
        case .connected:
            // Reachable but not answering /status yet: still starting up.
            return .timedOut
        }
    }

    private enum Connectability: Sendable {
        case connected
        case refused
        case timedOut
    }

    private static func probeConnectability(
        host: String,
        port: UInt16
    ) async -> Connectability {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let completion = ConnectabilityProbeCompletion(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(.connected)
                case let .failed(error):
                    // ECONNREFUSED means the host answered: nothing is listening.
                    if case let .posix(code) = error, code == .ECONNREFUSED {
                        completion.finish(.refused)
                    } else {
                        completion.finish(.timedOut)
                    }
                case .cancelled:
                    completion.finish(.timedOut)
                case .waiting, .setup, .preparing:
                    break
                @unknown default:
                    completion.finish(.timedOut)
                }
            }
            let queue = DispatchQueue(label: "stupidmirror.wireless.connectability-probe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) {
                completion.finish(.timedOut)
            }
        }
    }

    /// Whether a failed launch could plausibly be fixed by reinstalling the
    /// runner. Only a genuinely broken or missing installation qualifies.
    nonisolated static func isWorthReinstalling(_ error: WirelessWDAError) -> Bool {
        switch error {
        case .launchFailed, .firstUSBSetupRequired, .buildFailed, .timedOut:
            true
        case .deviceLocked, .deviceUnavailable, .agentBackgroundingUnsupported,
             .localNetworkDenied, .iphoneLocalNetworkDenied,
             .missingSigningTeam, .missingRuntime:
            false
        }
    }

    private func waitForReadyWithoutReinstalling(_ baseURLs: [URL]) async -> WirelessWDAEndpoint? {
        if let endpoint = await Self.waitUntilReady(baseURLs, timeout: Self.installedLaunchReadyTimeout) {
            return endpoint
        }
        return await Self.waitUntilReady(baseURLs, timeout: Self.extraReadyTimeout)
    }

    private func probeURLs(for device: WirelessDeviceMetadata) -> [URL] {
        var urls = Self.candidateBaseURLs(for: device)
        if let launched = lock.withLock({ remoteProcess }),
           !urls.contains(launched.serverURL) {
            urls.insert(launched.serverURL, at: 0)
        }
        if let cached = lock.withLock({ cachedEndpoint }) {
            if !urls.contains(cached.controlURL) {
                urls.insert(cached.controlURL, at: 0)
            }
            if let videoControl = Self.controlURL(host: cached.videoHost),
               !urls.contains(videoControl) {
                urls.append(videoControl)
            }
        }
        return urls
    }

    nonisolated static func controlURL(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmed.contains(":") && !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            ? "[\(trimmed)]"
            : trimmed
        components.port = 8_100
        return components.url
    }

    /// Releases this session's reference to the shared runner.
    ///
    /// The launch is registered per device and may be shared with another
    /// session, so stopping one mirror must not terminate a runner the others
    /// are still streaming from. `LaunchRegistry` drops the entry when the
    /// process actually exits.
    func stop() {
        lock.withLock {
            remoteProcess = nil
            cachedEndpoint = nil
        }
    }

    /// Terminates the shared runner for a device. Only for app shutdown, where
    /// leaving an orphaned `devicectl` console behind would keep the agent
    /// running after the last mirror closed.
    static func terminateSharedRunner(udid: String) {
        guard let running = LaunchRegistry.shared.existing(udid: udid) else { return }
        LaunchRegistry.shared.remove(udid: udid, if: running)
        DispatchQueue.global(qos: .utility).async { running.stop() }
    }

    private func remember(_ endpoint: WirelessWDAEndpoint) {
        lock.withLock { cachedEndpoint = endpoint }
    }

    static func lanHostname(from coreDeviceHostname: String) -> String {
        coreDeviceHostname
    }

    nonisolated static func candidateBaseURLs(for device: WirelessDeviceMetadata) -> [URL] {
        device.endpointURLs(port: 8_100)
    }

    nonisolated static func outputIndicatesLockedDevice(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("Unlock ")
            || output.localizedCaseInsensitiveContains("device is locked")
    }

    nonisolated static func outputIndicatesUnavailableDevice(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("Device is busy")
            || output.localizedCaseInsensitiveContains("Timed out waiting for all destinations")
            || output.localizedCaseInsensitiveContains("destination is not ready")
            || output.localizedCaseInsensitiveContains("device was not found")
    }

    /// Detects the iOS 27 regression where a runner launched through `devicectl`
    /// cannot enter the background, so XCTest aborts it before WDA's HTTP server
    /// starts.
    ///
    /// The device reports `Failed to background test runner within 30.0s` with
    /// `com.apple.dt.xctest.ui-testing.error` code 10300. Apple's CoreDevice
    /// stack changed here, not this app: the same runner started by `xcodebuild`
    /// is unaffected, which is why the first-time USB setup path still works.
    /// Appium hit the same wall and stopped using the `devicectl` launch on
    /// these versions (appium/appium#22636).
    ///
    /// Worth separating out because every visible symptom — no `ServerURLHere`,
    /// no listener on 8100 — is identical to a runner that was never installed,
    /// and the old code blamed a locked device even when it was unlocked.
    nonisolated static func outputIndicatesBackgroundingFailure(_ output: String) -> Bool {
        output.contains("ui-testing.error")
            && (output.contains("10300")
                || output.localizedCaseInsensitiveContains("Failed to background test runner"))
    }

    nonisolated static func runnerBundleIdentifier(for bundleID: String) -> String {
        "\(bundleID).xctrunner"
    }

    nonisolated static func processIdentifier(fromDevicectlJSON data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let process = result["process"] as? [String: Any] else { return nil }
        return process["processIdentifier"] as? Int
    }

    nonisolated static func serverURL(fromConsoleOutput output: String) -> URL? {
        guard let marker = output.range(of: "ServerURLHere->") else { return nil }
        let suffix = output[marker.upperBound...]
        guard let end = suffix.range(of: "<-ServerURLHere") else { return nil }
        return URL(string: String(suffix[..<end.lowerBound]))
    }

    private static func wakeDevice(udid: String) throws {
        do {
            _ = try run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "info", "details",
                    "--device", udid, "--quiet", "--timeout", "15"
                ]
            )
        } catch let failure as CommandFailure {
            if outputIndicatesLockedDevice(failure.output) {
                throw WirelessWDAError.deviceLocked
            }
            if outputIndicatesUnavailableDevice(failure.output) {
                throw WirelessWDAError.deviceUnavailable
            }
            throw WirelessWDAError.launchFailed
        }
    }

    private static func prepareCompatibleRunner(
        derivedDataPath: String,
        bundleID: String
    ) throws -> URL {
        let derived = URL(fileURLWithPath: derivedDataPath, isDirectory: true)
        let source = derived
            .appendingPathComponent("Build/Products/Debug-iphoneos", isDirectory: true)
            .appendingPathComponent(runnerName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw WirelessWDAError.firstUSBSetupRequired
        }

        let outputDirectory = derived
            .appendingPathComponent("StupidMirrorWireless", isDirectory: true)
        let destination = outputDirectory.appendingPathComponent(runnerName, isDirectory: true)
        let temporary = outputDirectory.appendingPathComponent(
            ".preparing-\(UUID().uuidString).app",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let frameworks = temporary.appendingPathComponent("Frameworks", isDirectory: true)
            for framework in incompatibleFrameworks {
                let url = frameworks.appendingPathComponent(framework, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try prepareInfoPlist(at: temporary, bundleID: bundleID)
            let identity = try signingIdentitySHA1(for: source)
            _ = try run(
                "/usr/bin/codesign",
                arguments: [
                    "--force", "--sign", identity,
                    "--preserve-metadata=identifier,entitlements,requirements,flags",
                    temporary.path
                ]
            )
            _ = try run(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", temporary.path]
            )

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch let error as WirelessWDAError {
            throw error
        } catch {
            logger.error("Preparing wireless WDA failed: \(error.localizedDescription, privacy: .public)")
            throw WirelessWDAError.buildFailed
        }
    }

    private static func prepareInfoPlist(at runner: URL, bundleID: String) throws {
        let plistURL = runner.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: &format
        ) as? [String: Any] else {
            throw WirelessWDAError.buildFailed
        }
        plist["CFBundleIdentifier"] = runnerBundleIdentifier(for: bundleID)
        plist["NSBonjourServices"] = ["_stupidmirror._tcp"]
        plist["NSLocalNetworkUsageDescription"] =
            "StupidMirror uses the local network to stream this iPhone screen."
        let output = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
        try output.write(to: plistURL, options: .atomic)
    }

    private static func signingIdentitySHA1(for signedRunner: URL) throws -> String {
        let certificateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-WDA-Certificates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: certificateDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: certificateDirectory) }
        let prefix = certificateDirectory.appendingPathComponent("certificate").path
        _ = try run(
            "/usr/bin/codesign",
            arguments: ["-d", "--extract-certificates=\(prefix)", signedRunner.path]
        )
        let leaf = URL(fileURLWithPath: "\(prefix)0")
        let certificate = try Data(contentsOf: leaf)
        return Insecure.SHA1.hash(data: certificate)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private static func installAndLaunch(
        runner: URL,
        udid: String,
        bundleID: String
    ) throws -> RemoteProcess {
        do {
            _ = try run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "install", "app",
                    "--device", udid,
                    "--timeout", "60",
                    runner.path
                ]
            )
            return try launchInstalledRunner(udid: udid, bundleID: bundleID)
        } catch let failure as CommandFailure {
            if outputIndicatesLockedDevice(failure.output) {
                throw WirelessWDAError.deviceLocked
            }
            if outputIndicatesUnavailableDevice(failure.output) {
                throw WirelessWDAError.deviceUnavailable
            }
            logger.error("Installing or launching wireless WDA failed: \(failure.output, privacy: .public)")
            throw WirelessWDAError.launchFailed
        } catch let error as WirelessWDAError {
            throw error
        } catch {
            throw WirelessWDAError.launchFailed
        }
    }

    /// Reuses the registered launch for this device when one is alive, so
    /// concurrent callers never terminate each other's runner.
    private static func launchInstalledRunner(udid: String, bundleID: String) throws -> RemoteProcess {
        if let existing = LaunchRegistry.shared.existing(udid: udid) {
            logger.info("Reusing the running wireless agent launch for \(udid, privacy: .public)")
            return existing
        }
        let launched = try startRunnerProcess(udid: udid, bundleID: bundleID)
        guard let incumbent = LaunchRegistry.shared.register(launched, udid: udid) else {
            return launched
        }
        // Another caller won the race while this launch was starting. Adopt the
        // incumbent and retire this one, rather than leaving two launches that
        // would terminate each other on the next attempt.
        logger.info("Discarding a duplicate wireless agent launch for \(udid, privacy: .public)")
        DispatchQueue.global(qos: .utility).async { launched.stop() }
        return incumbent
    }

    private static func startRunnerProcess(udid: String, bundleID: String) throws -> RemoteProcess {
        let environment = [
            "USE_PORT": "8100",
            "WDA_PRODUCT_BUNDLE_IDENTIFIER": runnerBundleIdentifier(for: bundleID),
            "MJPEG_SERVER_PORT": "9100",
            "STUPIDMIRROR_H264_PORT": "9200",
            "STUPIDMIRROR_H264_FPS": "45",
            "STUPIDMIRROR_H264_SOURCE_QUALITY": "80",
            "STUPIDMIRROR_H264_BITRATE": "8000000"
        ]
        let environmentData = try JSONSerialization.data(withJSONObject: environment)
        guard let environmentJSON = String(data: environmentData, encoding: .utf8) else {
            throw WirelessWDAError.launchFailed
        }
        let process = Process()
        let pipe = Pipe()
        let monitor = ConsoleLaunchMonitor()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "devicectl", "device", "process", "launch",
            "--device", udid,
            "--terminate-existing",
            "--console",
            "--environment-variables", environmentJSON,
            "--timeout", "2147483647",
            runnerBundleIdentifier(for: bundleID)
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            monitor.append(handle.availableData)
        }
        let launchedProcess = RemoteProcessBox()
        process.terminationHandler = { _ in
            monitor.markFinished()
            if let launched = launchedProcess.value {
                LaunchRegistry.shared.remove(udid: udid, if: launched)
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw WirelessWDAError.launchFailed
        }
        // XCTest gives the runner 30.0s to enter the background, so its verdict
        // lands just after that and the process exits a second later. Waiting
        // only 30s raced it and lost, discarding the one line that explains the
        // failure. The monitor also returns as soon as the process exits, so a
        // longer ceiling costs nothing: a healthy runner prints its URL in 2-3s,
        // and a failing one is diagnosed at ~32s instead of being misreported
        // and then reinstalled for another 30s.
        guard let serverURL = monitor.waitForServerURL(timeout: 45) else {
            if process.isRunning {
                process.interrupt()
                process.waitUntilExit()
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            let output = monitor.capturedOutput
            // Check backgrounding first: the device reports it while still
            // unlocked and reachable, so the broader checks below would
            // misattribute it.
            if outputIndicatesBackgroundingFailure(output) {
                logger.error("Wireless WDA could not background on this iOS version: \(output, privacy: .public)")
                throw WirelessWDAError.agentBackgroundingUnsupported
            }
            if outputIndicatesLockedDevice(output) {
                throw WirelessWDAError.deviceLocked
            }
            if outputIndicatesUnavailableDevice(output) {
                throw WirelessWDAError.deviceUnavailable
            }
            logger.error("Launching wireless WDA did not report its LAN URL: \(output, privacy: .public)")
            throw WirelessWDAError.launchFailed
        }
        let remote = RemoteProcess(
            udid: udid,
            consoleProcess: process,
            outputPipe: pipe,
            serverURL: serverURL
        )
        launchedProcess.value = remote
        return remote
    }

    @discardableResult
    private static func webDriverAgentProjectURL() -> URL? {
        let relativePath = "home/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("Appium", isDirectory: true)
                    .appendingPathComponent(relativePath)
            )
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            repositoryRoot.appendingPathComponent(".build/appium-runtime", isDirectory: true)
                .appendingPathComponent(relativePath)
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func srtXcodeConfigURL(for project: URL) -> URL? {
        let config = project.deletingLastPathComponent()
            .appendingPathComponent("../../../../stupidmirror-srt", isDirectory: true)
            .appendingPathComponent("StupidMirrorSRT.xcconfig")
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: config.path) ? config : nil
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CommandFailure(output: output)
        }
        return output
    }

    private static func waitUntilReady(
        _ baseURLs: [URL],
        timeout: Duration
    ) async -> WirelessWDAEndpoint? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return nil }
            if let ready = await firstReadyEndpoint(baseURLs) { return ready }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private static func sendJSON(
        method: String,
        url: URL,
        body: [String: Any]?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WirelessWDAError.launchFailed
        }
        return json
    }

    private static func readyEndpoint(_ baseURL: URL) async -> WirelessWDAEndpoint? {
        var request = URLRequest(url: baseURL.appendingPathComponent("status"))
        request.timeoutInterval = 2
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = endpoint(baseURL: baseURL, statusJSON: json) else { return nil }
        return endpoint
    }

    nonisolated static func endpoint(
        baseURL: URL,
        statusJSON: [String: Any]
    ) -> WirelessWDAEndpoint? {
        guard let value = statusJSON["value"] as? [String: Any],
              value["ready"] as? Bool ?? true else { return nil }
        let reportedIP = (value["ios"] as? [String: Any])?["ip"] as? String
        let trimmedIP = reportedIP?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let videoHost = trimmedIP?.isEmpty == false ? trimmedIP : baseURL.host,
              !videoHost.isEmpty else { return nil }
        return WirelessWDAEndpoint(controlURL: baseURL, videoHost: videoHost)
    }

    private static func firstReadyEndpoint(
        _ baseURLs: [URL]
    ) async -> WirelessWDAEndpoint? {
        await withTaskGroup(of: WirelessWDAEndpoint?.self) { group in
            for url in baseURLs {
                group.addTask {
                    await readyEndpoint(url)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func isLocalNetworkDenied(hostname: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(hostname),
                port: NWEndpoint.Port(rawValue: 8_100)!,
                using: .tcp
            )
            let completion = LocalNetworkProbeCompletion(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting:
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        completion.finish(true)
                    }
                case .ready, .failed, .cancelled:
                    completion.finish(false)
                case .setup, .preparing:
                    break
                @unknown default:
                    completion.finish(false)
                }
            }
            let queue = DispatchQueue(label: "stupidmirror.wireless.local-network-probe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                completion.finish(false)
            }
        }
    }
}

private actor WirelessWDAEnsureGate {
    static let shared = WirelessWDAEnsureGate()

    private var inFlight: [String: Task<WirelessWDAEndpoint, Error>] = [:]

    func run(
        udid: String,
        body: @escaping @Sendable () async throws -> WirelessWDAEndpoint
    ) async throws -> WirelessWDAEndpoint {
        if let existing = inFlight[udid] {
            return try await existing.value
        }
        let task = Task {
            try await body()
        }
        inFlight[udid] = task
        defer { inFlight[udid] = nil }
        return try await task.value
    }
}

private final class ConnectabilityProbeCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Value, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<Value, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: value)
    }
}

private final class LocalNetworkProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ denied: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: denied)
    }
}
