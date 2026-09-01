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
    case missingInstallation
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
        case .missingInstallation:
            "WebDriverAgent is not installed on this iPhone."
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
/// then reads WDA through the iPhone's verified LAN address. The launch is
/// detached: `devicectl --console` is not used, because that flag waits for
/// the app to exit and forwards a dropped CoreDevice tunnel (or any signal
/// to the Mac command) into a kill of the runner. iOS 17 and newer cannot
/// launch the legacy embedded XCTest framework bundle directly, so a signed
/// compatibility copy is installed before the first wireless launch.
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

    /// A runner started on the iPhone. On iOS 27+ the Mac-side XCTest session
    /// (`xcodebuild test-without-building`) is what keeps it alive; a raw
    /// `devicectl` launch is killed by XCTest before it can serve HTTP.
    final class RemoteProcess: @unchecked Sendable {
        let udid: String
        let pid: Int?
        let serverURL: URL?
        let sessionProcess: Process?

        init(udid: String, pid: Int?, serverURL: URL?, sessionProcess: Process? = nil) {
            self.udid = udid
            self.pid = pid
            self.serverURL = serverURL
            self.sessionProcess = sessionProcess
        }

        func stop() {
            // Shared sessions outlive one mirror. App shutdown uses
            // `terminateSharedRunner`.
        }
    }

    private struct CommandFailure: Error {
        let output: String
    }

    /// Serializes `devicectl process launch --terminate-existing` per device
    /// and remembers the last PID so shutdown can stop the runner without a
    /// console session.
    ///
    /// Launching still passes `--terminate-existing`, so two overlapping
    /// launches for the same bundle ID would kill each other. Mirroring,
    /// control, and retries all reach this code for the same UDID. Holding
    /// one exclusive launch per UDID removes that race. Readiness is the
    /// iPhone's `/status`, not a Mac process still being alive.
    final class LaunchRegistry: @unchecked Sendable {
        static let shared = LaunchRegistry()

        private let lock = NSLock()
        private var exclusiveLocks: [String: NSLock] = [:]
        private var pids: [String: Int] = [:]
        private var sessionProcesses: [String: Process] = [:]

        func withExclusiveLaunch<T>(udid: String, body: () throws -> T) rethrows -> T {
            let udidLock: NSLock = lock.withLock {
                if let existing = exclusiveLocks[udid] { return existing }
                let created = NSLock()
                exclusiveLocks[udid] = created
                return created
            }
            udidLock.lock()
            defer { udidLock.unlock() }
            return try body()
        }

        func remember(pid: Int, udid: String) {
            lock.withLock { pids[udid] = pid }
        }

        func pid(for udid: String) -> Int? {
            lock.withLock { pids[udid] }
        }

        func takePid(_ udid: String) -> Int? {
            lock.withLock {
                let pid = pids[udid]
                pids[udid] = nil
                return pid
            }
        }

        func remember(session process: Process, udid: String) {
            let previous: Process? = lock.withLock {
                let old = sessionProcesses[udid]
                sessionProcesses[udid] = process
                return old === process ? nil : old
            }
            if let previous, previous.isRunning {
                previous.interrupt()
            }
        }

        func runningSession(udid: String) -> Process? {
            lock.withLock {
                guard let process = sessionProcesses[udid], process.isRunning else {
                    sessionProcesses[udid] = nil
                    return nil
                }
                return process
            }
        }

        func takeSession(_ udid: String) -> Process? {
            lock.withLock {
                let process = sessionProcesses[udid]
                sessionProcesses[udid] = nil
                return process
            }
        }
    }

    private final class TextAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ data: Data) {
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            text.append(chunk)
            if text.utf8.count > 65_536 {
                text = String(text.suffix(65_536))
            }
            lock.unlock()
        }

        var value: String {
            lock.withLock { text }
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
    static let xcodebuildReadyTimeout: Duration = .seconds(45)

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
        // Probe CoreDevice's tunnel address first so we can read WDA's reported
        // LAN IP from /status, then require that LAN IP to answer. Passing only
        // through the tunnel would not prove wireless mirroring will work after
        // USB is unplugged.
        let probeURLs = detailsProbeURLs(udid: udid)
        guard let endpoint = await waitUntilReady(probeURLs, timeout: .seconds(15)) else {
            throw await unreachableAgentError(
                host: probeURLs.first?.host ?? launched.serverURL?.host ?? ""
            )
        }
        if let lanURL = controlURL(host: endpoint.videoHost),
           !probeURLs.contains(lanURL) {
            guard await waitUntilReady([lanURL], timeout: .seconds(8)) != nil else {
                throw WirelessWDAError.iphoneLocalNetworkDenied
            }
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

        let isolated = configuration.isolated(forDeviceUDID: device.udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw WirelessWDAError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw WirelessWDAError.missingSigningTeam }

        await progress(.launchingInstalledAgent)
        if Self.needsXCTestSession(osVersion: device.osVersion) {
            let session = try await Task.detached(priority: .userInitiated, operation: {
                try Self.startXcodebuildSession(
                    udid: device.udid,
                    bundleID: bundleID,
                    derivedDataPath: isolated.derivedDataPath
                )
            }).value
            lock.withLock { remoteProcess = session }
            await progress(.waitingForAgent)
            if let endpoint = await Self.waitUntilReady(
                probeURLs(for: device),
                timeout: Self.xcodebuildReadyTimeout
            ) {
                remember(endpoint)
                await progress(.connectingVideo)
                return endpoint
            }
            throw await Self.unreachableAgentError(
                host: device.preferredEndpointHost
            )
        }

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
                host: launched.serverURL?.host ?? device.preferredEndpointHost
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
            host: installed.serverURL?.host ?? device.preferredEndpointHost
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
    /// runner. Only a genuinely missing installation qualifies — a runner that
    /// is installed but not answering must be launched, not replaced.
    nonisolated static func isWorthReinstalling(_ error: WirelessWDAError) -> Bool {
        switch error {
        case .missingInstallation, .firstUSBSetupRequired:
            true
        case .launchFailed, .buildFailed, .timedOut,
             .deviceLocked, .deviceUnavailable, .agentBackgroundingUnsupported,
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
        if let launchedURL = lock.withLock({ remoteProcess?.serverURL }),
           !urls.contains(launchedURL) {
            urls.insert(launchedURL, at: 0)
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
    /// The runner is not owned by this session: stopping one mirror must not
    /// terminate a process another session is still streaming from. App
    /// shutdown uses `terminateSharedRunner`.
    func stop() {
        lock.withLock {
            remoteProcess = nil
            cachedEndpoint = nil
        }
    }

    /// Terminates the shared runner for a device. Only for app shutdown, so
    /// the agent does not keep running after the last mirror closed.
    static func terminateSharedRunner(udid: String) {
        let session = LaunchRegistry.shared.takeSession(udid)
        let pid = LaunchRegistry.shared.takePid(udid)
        guard session != nil || pid != nil else { return }
        DispatchQueue.global(qos: .utility).async {
            if let session, session.isRunning {
                session.interrupt()
                session.waitUntilExit()
            }
            if let pid {
                _ = try? run(
                    "/usr/bin/xcrun",
                    arguments: [
                        "devicectl", "device", "process", "terminate",
                        "--device", udid,
                        "--pid", "\(pid)",
                        "--timeout", "10"
                    ]
                )
            }
        }
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

    /// The installed runner is gone from the iPhone. Reinstalling from this
    /// Mac's cache can fix that; relaunching cannot.
    nonisolated static func outputIndicatesMissingInstallation(_ output: String) -> Bool {
        let haystack = output.lowercased()
        return haystack.contains("is not installed")
            || haystack.contains("not installed on this device")
            || haystack.contains("unable to find application")
            || haystack.contains("could not find application")
            || haystack.contains("failed to find the application")
            || haystack.contains("no app with bundle")
            || (haystack.contains("bundle identifier") && haystack.contains("not found"))
            || haystack.contains("failed to get the identifier for the app to be installed")
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

    /// Serializes `--terminate-existing` launches for this device so concurrent
    /// callers never kill each other's runner.
    private static func launchInstalledRunner(udid: String, bundleID: String) throws -> RemoteProcess {
        try LaunchRegistry.shared.withExclusiveLaunch(udid: udid) {
            try startRunnerProcess(udid: udid, bundleID: bundleID)
        }
    }

    /// Starts the already-installed runner as a normal app and returns once
    /// `devicectl` reports the launch. Readiness is `/status`, not stdout:
    /// attaching `--console` kept the Mac command alive only until the
    /// wireless tunnel blipped, then CoreDevice forwarded that hangup into a
    /// kill of WebDriverAgent.
    private static func startRunnerProcess(udid: String, bundleID: String) throws -> RemoteProcess {
        let environment = launchEnvironment(bundleID: bundleID)
        let environmentData = try JSONSerialization.data(withJSONObject: environment)
        guard let environmentJSON = String(data: environmentData, encoding: .utf8) else {
            throw WirelessWDAError.launchFailed
        }
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-WDA-Launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let arguments = processLaunchArguments(
            udid: udid,
            bundleID: bundleID,
            environmentJSON: environmentJSON,
            jsonOutputPath: jsonURL.path
        )
        do {
            _ = try run("/usr/bin/xcrun", arguments: arguments)
        } catch let failure as CommandFailure {
            if outputIndicatesLockedDevice(failure.output) {
                throw WirelessWDAError.deviceLocked
            }
            if outputIndicatesUnavailableDevice(failure.output) {
                throw WirelessWDAError.deviceUnavailable
            }
            if outputIndicatesBackgroundingFailure(failure.output) {
                logger.error("Wireless WDA could not background on this iOS version: \(failure.output, privacy: .public)")
                throw WirelessWDAError.agentBackgroundingUnsupported
            }
            if outputIndicatesMissingInstallation(failure.output) {
                logger.error("Wireless WDA is not installed on the iPhone: \(failure.output, privacy: .public)")
                throw WirelessWDAError.missingInstallation
            }
            logger.error("Launching wireless WDA failed: \(failure.output, privacy: .public)")
            throw WirelessWDAError.launchFailed
        } catch let error as WirelessWDAError {
            throw error
        } catch {
            throw WirelessWDAError.launchFailed
        }
        let jsonData = (try? Data(contentsOf: jsonURL)) ?? Data()
        let pid = processIdentifier(fromDevicectlJSON: jsonData)
        if let pid {
            LaunchRegistry.shared.remember(pid: pid, udid: udid)
            logger.info("Launched wireless agent pid \(pid, privacy: .public) for \(udid, privacy: .public)")
        } else {
            logger.info("Launched wireless agent for \(udid, privacy: .public) without a reported pid")
        }
        return RemoteProcess(udid: udid, pid: pid, serverURL: nil)
    }

    /// iOS 27+ kills a raw `devicectl` XCTest launch before HTTP starts.
    /// `xcodebuild test-without-building` performs the testmanagerd handshake
    /// that Appium uses on USB, and is the only launch that stays up.
    nonisolated static func needsXCTestSession(osVersion: String) -> Bool {
        let major = osVersion.split(separator: ".").first.flatMap { Int($0) } ?? 0
        return major >= 27
    }

    private static func startXcodebuildSession(
        udid: String,
        bundleID: String,
        derivedDataPath: String
    ) throws -> RemoteProcess {
        try LaunchRegistry.shared.withExclusiveLaunch(udid: udid) {
            if let existing = LaunchRegistry.shared.runningSession(udid: udid) {
                logger.info("Reusing the running XCTest session for \(udid, privacy: .public)")
                return RemoteProcess(
                    udid: udid,
                    pid: LaunchRegistry.shared.pid(for: udid),
                    serverURL: nil,
                    sessionProcess: existing
                )
            }
            guard let xctestrun = xctestrunURL(derivedDataPath: derivedDataPath) else {
                throw WirelessWDAError.firstUSBSetupRequired
            }
            let patched = try patchedXCTestRun(
                from: xctestrun,
                environment: launchEnvironment(bundleID: bundleID)
            )
            let process = Process()
            let pipe = Pipe()
            let output = TextAccumulator()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = xcodebuildTestArguments(
                udid: udid,
                xctestrunPath: patched.path,
                derivedDataPath: derivedDataPath
            )
            process.environment = ProcessInfo.processInfo.environment
                .merging(launchEnvironment(bundleID: bundleID)) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                throw WirelessWDAError.launchFailed
            }
            LaunchRegistry.shared.remember(session: process, udid: udid)
            // xcodebuild either stays up for the test session or dies in a few
            // seconds with a usable error. A healthy run is still starting here.
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, process.isRunning {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if !process.isRunning {
                pipe.fileHandleForReading.readabilityHandler = nil
                let captured = output.value
                if outputIndicatesLockedDevice(captured) {
                    throw WirelessWDAError.deviceLocked
                }
                if outputIndicatesUnavailableDevice(captured) {
                    throw WirelessWDAError.deviceUnavailable
                }
                if outputIndicatesBackgroundingFailure(captured) {
                    throw WirelessWDAError.agentBackgroundingUnsupported
                }
                logger.error("xcodebuild XCTest session exited: \(captured, privacy: .public)")
                throw WirelessWDAError.launchFailed
            }
            return RemoteProcess(
                udid: udid,
                pid: nil,
                serverURL: nil,
                sessionProcess: process
            )
        }
    }

    nonisolated static func xctestrunURL(derivedDataPath: String) -> URL? {
        let products = URL(fileURLWithPath: derivedDataPath, isDirectory: true)
            .appendingPathComponent("Build/Products", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let runs = contents.filter { $0.pathExtension == "xctestrun" }
        return runs.first { $0.lastPathComponent.localizedCaseInsensitiveContains("iphoneos") }
            ?? runs.first
    }

    nonisolated static func xcodebuildTestArguments(
        udid: String,
        xctestrunPath: String,
        derivedDataPath: String
    ) -> [String] {
        [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", "id=\(udid)",
            "-derivedDataPath", derivedDataPath
        ]
    }

    /// Copies an xctestrun so the never-ending WDA test is not killed at the
    /// default 600s allowance, and so H.264/SRT ports are set.
    nonisolated static func patchedXCTestRun(
        from source: URL,
        environment: [String: String]
    ) throws -> URL {
        let data = try Data(contentsOf: source)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [String: Any] else {
            throw WirelessWDAError.firstUSBSetupRequired
        }
        for key in Array(root.keys) {
            guard var test = root[key] as? [String: Any] else { continue }
            var env = (test["EnvironmentVariables"] as? [String: Any]) ?? [:]
            for (name, value) in environment {
                env[name] = value
            }
            test["EnvironmentVariables"] = env
            test["DefaultTestExecutionTimeAllowance"] = 604_800
            test["TestTimeoutsEnabled"] = false
            root[key] = test
        }
        let patched = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-WDA-\(UUID().uuidString).xctestrun")
        let output = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
        try output.write(to: patched, options: .atomic)
        return patched
    }

    nonisolated static func launchEnvironment(bundleID: String) -> [String: String] {
        [
            "USE_PORT": "8100",
            "WDA_PRODUCT_BUNDLE_IDENTIFIER": runnerBundleIdentifier(for: bundleID),
            "MJPEG_SERVER_PORT": "9100",
            "STUPIDMIRROR_H264_PORT": "9200",
            "STUPIDMIRROR_H264_FPS": "45",
            "STUPIDMIRROR_H264_SOURCE_QUALITY": "80",
            "STUPIDMIRROR_H264_BITRATE": "8000000"
        ]
    }

    /// Arguments for a detached `devicectl device process launch`.
    ///
    /// `--console` is intentionally omitted: that flag waits for the app to
    /// exit and forwards catchable signals (including a dropped CoreDevice
    /// tunnel) to the runner. Appium's own `devicectl` launch does the same.
    nonisolated static func processLaunchArguments(
        udid: String,
        bundleID: String,
        environmentJSON: String,
        jsonOutputPath: String
    ) -> [String] {
        [
            "devicectl", "device", "process", "launch",
            "--device", udid,
            "--terminate-existing",
            "--environment-variables", environmentJSON,
            "--timeout", "60",
            "--json-output", jsonOutputPath,
            runnerBundleIdentifier(for: bundleID)
        ]
    }

    nonisolated static func hosts(fromDeviceDetailsJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let connection = (root["result"] as? [String: Any])?["connectionProperties"] as? [String: Any]
        var hosts: [String] = []
        if let ip = (connection?["tunnelIPAddress"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !ip.isEmpty {
            hosts.append(ip)
        }
        for key in ["localHostnames", "potentialHostnames"] {
            if let names = connection?[key] as? [String] {
                hosts.append(contentsOf: names)
            }
        }
        var seen = Set<String>()
        return hosts.compactMap { host in
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    static func detailsProbeURLs(udid: String) -> [URL] {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-WDA-Details-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        do {
            _ = try run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "info", "details",
                    "--device", udid,
                    "--json-output", jsonURL.path,
                    "--timeout", "15"
                ]
            )
        } catch {
            logger.error("Could not read CoreDevice details for \(udid, privacy: .public)")
            return []
        }
        guard let data = try? Data(contentsOf: jsonURL) else { return [] }
        return hosts(fromDeviceDetailsJSON: data).compactMap(controlURL(host:))
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

    nonisolated private static func run(
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

    static func firstReadyEndpoint(
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
