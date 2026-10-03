import Foundation
import OSLog

/// Why an iPhone agent could not be prepared or started. Each case maps to
/// one piece of localized copy that tells the user what to do.
enum IOSAgentError: LocalizedError, Equatable {
    case missingSigningTeam
    case missingRuntime
    /// The runner is not installed on this phone: the USB setup has to run.
    case setupRequired
    case buildFailed
    case launchFailed
    case deviceLocked
    case developerModeDisabled
    /// usbmuxd does not list the phone at all (not on USB, not on the network).
    case deviceUnavailable
    /// The phone is only reachable over the network but is not showing up:
    /// Wi-Fi connections are off or the networks differ.
    case wifiConnectionsUnavailable
    case developerImageMissing
    /// iOS did not allow automation in time: after a reboot (or once the last
    /// approval expired) the phone asks for its passcode before the first
    /// automation session.
    case automationNotApproved
    case timedOut

    var copyKey: String {
        switch self {
        case .missingSigningTeam: "agent.error.missingSigningTeam"
        case .missingRuntime: "agent.error.missingRuntime"
        case .setupRequired: "agent.error.setupRequired"
        case .buildFailed: "agent.error.buildFailed"
        case .launchFailed: "agent.error.launchFailed"
        case .deviceLocked: "agent.error.deviceLocked"
        case .developerModeDisabled: "agent.error.developerModeDisabled"
        case .deviceUnavailable: "agent.error.deviceUnavailable"
        case .wifiConnectionsUnavailable: "agent.error.wifiConnectionsUnavailable"
        case .developerImageMissing: "agent.error.developerImageMissing"
        case .automationNotApproved: "agent.error.automationNotApproved"
        case .timedOut: "agent.error.timedOut"
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingSigningTeam:
            "Select an Apple development team before preparing the iPhone agent."
        case .missingRuntime:
            "The bundled device tunnel runtime is unavailable."
        case .setupRequired:
            "The screen agent is not installed on this iPhone. Run the USB setup once."
        case .buildFailed:
            "The screen agent could not be built or installed for this iPhone."
        case .launchFailed:
            "The screen agent could not be started on this iPhone."
        case .deviceLocked:
            "Unlock the iPhone and keep its screen on, then try again."
        case .developerModeDisabled:
            "Enable Developer Mode on the iPhone (Settings > Privacy & Security), then try again."
        case .deviceUnavailable:
            "The iPhone is not connected: plug it in or put it on the same Wi-Fi as this Mac."
        case .wifiConnectionsUnavailable:
            "The iPhone is not reachable on the local network. Keep both devices on the same Wi-Fi."
        case .developerImageMissing:
            "The iPhone's developer disk image is not mounted. Connect it by USB once, then try again."
        case .automationNotApproved:
            "The iPhone did not allow automation. Unlock it, enter its passcode if it asks, then try again."
        case .timedOut:
            "The screen agent did not respond in time. Retry, or reconnect USB if it continues."
        }
    }
}

/// Progress while an agent is being started for mirroring or control.
enum IOSAgentProgress: Equatable, Sendable {
    case checkingExistingAgent
    case checkingDevice
    case launchingAgent
    /// The launch is taking long enough that the phone is probably waiting
    /// for the user: a passcode prompt to allow automation, or a dark screen.
    case waitingForDevice
    case connectingVideo
}

/// Progress while the one-time USB setup runs.
enum IOSAgentSetupStep: Equatable, Sendable {
    case inspecting
    case building
    case installing
    case launching
    /// The test launch is waiting on the phone, usually its passcode prompt
    /// to allow automation.
    case waitingForDevice
    case enablingWiFi
    case verifyingNetwork
}

/// What the sidecar can tell about a phone without touching the agent.
struct IOSDeviceReadiness: Equatable, Sendable {
    let udid: String
    let name: String
    let productType: String
    let productVersion: String
    let connectionTypes: [String]
    let developerMode: Bool?
    let wifiConnections: Bool?
    let runnerInstalled: Bool?
    let developerImageMounted: Bool?
    let passwordProtected: Bool?

    var isOnUSB: Bool { connectionTypes.contains("USB") }
    var isOnNetwork: Bool { connectionTypes.contains("Network") }
}

/// What the USB setup achieved.
struct IOSAgentSetupResult: Equatable, Sendable {
    /// The agent launched and answered over USB.
    let agentReady: Bool
    /// usbmuxd listed the phone over the network before the setup returned.
    let reachableOverWiFi: Bool
}

/// Where the Mac reaches a running agent: loopback ports the sidecar forwards
/// into the device tunnel.
struct IOSAgentEndpoint: Equatable, Sendable {
    let controlURL: URL
    let videoHost: String
    let videoPort: Int

    init(controlURL: URL, videoHost: String, videoPort: Int) {
        self.controlURL = controlURL
        self.videoHost = videoHost
        self.videoPort = videoPort
    }
}

/// Prepares and runs the WebDriverAgent-based screen agent on an iPhone.
///
/// One path for USB and Wi-Fi: the `smtunnel` sidecar reaches the phone
/// through usbmuxd, opens Apple's CoreDeviceProxy tunnel in an in-process
/// network stack, and launches the runner through testmanagerd like an IDE.
/// The one-time USB setup builds and installs the runner and switches on the
/// phone's Wi-Fi connections (Xcode's "Connect via network"), after which
/// nothing on the phone needs touching again.
final class IOSAgentService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "IOSAgent")
    private static let runnerName = "WebDriverAgentRunner-Runner.app"
    static let controlPort = 8_100
    static let mjpegPort = 9_100
    static let videoPort = 9_200

    private struct CommandFailure: Error {
        let output: String
    }

    /// One sidecar per phone, shared by mirroring and control. Closing one
    /// mirror must not end a tunnel another session is still streaming from;
    /// app shutdown uses `terminateSharedAgent`.
    final class AgentRegistry: @unchecked Sendable {
        static let shared = AgentRegistry()

        private let lock = NSLock()
        private var sidecars: [String: DeviceTunnelSidecar] = [:]

        func running(udid: String) -> DeviceTunnelSidecar? {
            lock.withLock {
                guard let sidecar = sidecars[udid] else { return nil }
                guard sidecar.isRunning else {
                    sidecars[udid] = nil
                    return nil
                }
                return sidecar
            }
        }

        /// Records the sidecar for a phone. Any previous one must already be
        /// stopped (`take` it first): two tunnels to one phone fight over the
        /// runner.
        func register(_ sidecar: DeviceTunnelSidecar, udid: String) {
            let previous: DeviceTunnelSidecar? = lock.withLock {
                let old = sidecars[udid]
                sidecars[udid] = sidecar
                return old === sidecar ? nil : old
            }
            previous?.stop()
            sidecar.onExit { [weak self, weak sidecar] error in
                self?.forget(sidecar, udid: udid)
                IOSAgentService.logger.error("Agent tunnel for \(udid, privacy: .public) ended: \(error.message, privacy: .public)")
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: IOSAgentService.agentDidExitNotification,
                        object: nil,
                        userInfo: [IOSAgentService.udidUserInfoKey: udid]
                    )
                }
            }
        }

        func forget(_ sidecar: DeviceTunnelSidecar?, udid: String) {
            lock.withLock {
                if sidecars[udid] === sidecar {
                    sidecars[udid] = nil
                }
            }
        }

        func take(udid: String) -> DeviceTunnelSidecar? {
            lock.withLock {
                let sidecar = sidecars[udid]
                sidecars[udid] = nil
                return sidecar
            }
        }
    }

    /// Posted on the main actor when a phone's tunnel ends on its own (Wi-Fi
    /// lost, cable pulled, runner gone). `userInfo[udidUserInfoKey]` names it.
    static let agentDidExitNotification = Notification.Name("StupidMirrorIOSAgentDidExit")
    static let udidUserInfoKey = "udid"

    private let lock = NSLock()
    private var cachedEndpoint: IOSAgentEndpoint?

    var activeEndpoint: IOSAgentEndpoint? {
        lock.withLock { cachedEndpoint }
    }

    deinit { stop() }

    // MARK: - Inspection

    /// Reads the phone's state over usbmuxd: identity, Developer Mode, the
    /// Wi-Fi connections switch, whether the runner is installed, and whether a
    /// developer image is mounted.
    static func inspect(udid: String, configuration: AppiumControlConfiguration?) async throws -> IOSDeviceReadiness {
        let runner = configuration.map { runnerBundleIdentifier(for: $0.isolated(forDeviceUDID: udid).installationWDABundleID) }
        do {
            return try await DeviceTunnelSidecar.inspect(udid: udid, runnerBundleID: runner)
        } catch let error as DeviceTunnelSidecarError {
            throw agentError(from: error)
        }
    }

    // MARK: - One-time USB setup

    /// Builds and installs the runner over USB, proves that it launches, and
    /// switches on the phone's Wi-Fi connections. `force` rebuilds and
    /// reinstalls even when a runner is already present.
    static func prepare(
        udid: String,
        configuration: AppiumControlConfiguration,
        force: Bool = false,
        progress: @escaping @Sendable (IOSAgentSetupStep) async -> Void = { _ in }
    ) async throws -> IOSAgentSetupResult {
        let isolated = configuration.isolated(forDeviceUDID: udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw IOSAgentError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw IOSAgentError.missingSigningTeam }
        guard DeviceTunnelSidecar.executableURL() != nil else { throw IOSAgentError.missingRuntime }

        await progress(.inspecting)
        let readiness = try await inspect(udid: udid, configuration: configuration)
        guard readiness.isOnUSB else { throw IOSAgentError.deviceUnavailable }
        if readiness.developerMode == false { throw IOSAgentError.developerModeDisabled }

        if force || readiness.runnerInstalled != true {
            guard let project = webDriverAgentProjectURL(),
                  let srtXcodeConfig = srtXcodeConfigURL(for: project) else {
                throw IOSAgentError.missingRuntime
            }
            try Task.checkCancellation()
            await progress(.building)
            try await Task.detached(priority: .userInitiated) {
                try buildRunner(
                    project: project,
                    srtXcodeConfig: srtXcodeConfig,
                    udid: udid,
                    team: team,
                    bundleID: bundleID,
                    isolated: isolated
                )
            }.value
            try Task.checkCancellation()
            await progress(.installing)
            try await Task.detached(priority: .userInitiated) {
                try installRunner(derivedDataPath: isolated.derivedDataPath, udid: udid)
            }.value
        }

        // A launch over USB proves the installed runner, the mounted developer
        // image, and the testmanagerd handshake before the cable comes out.
        try Task.checkCancellation()
        await progress(.launching)
        // A running mirror or control session holds its own tunnel and runner;
        // the probe would kill that runner, so the session is ended first.
        await AgentRegistry.shared.take(udid: udid)?.stopAndWait()
        let probe = try await startSidecar(
            udid: udid,
            transport: .usb,
            bundleID: bundleID,
            allowDeveloperImageRecovery: true,
            onWaiting: { Task { await progress(.waitingForDevice) } }
        )
        await probe.stopAndWait()

        try Task.checkCancellation()
        await progress(.enablingWiFi)
        do {
            let enabled = try await DeviceTunnelSidecar.setWiFiConnections(udid: udid, enabled: true)
            guard enabled else { throw IOSAgentError.wifiConnectionsUnavailable }
        } catch let error as IOSAgentError {
            throw error
        } catch {
            logger.error("Enabling Wi-Fi connections failed: \((error as? DeviceTunnelSidecarError)?.message ?? error.localizedDescription, privacy: .public)")
            throw IOSAgentError.wifiConnectionsUnavailable
        }

        await progress(.verifyingNetwork)
        let reachable = await waitForNetworkEntry(udid: udid, timeout: .seconds(20))
        return IOSAgentSetupResult(agentReady: true, reachableOverWiFi: reachable)
    }

    private static func buildRunner(
        project: URL,
        srtXcodeConfig: URL,
        udid: String,
        team: String,
        bundleID: String,
        isolated: AppiumControlConfiguration
    ) throws {
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
                throw IOSAgentError.deviceLocked
            }
            logger.error("Runner build failed: \(failure.output, privacy: .public)")
            throw IOSAgentError.buildFailed
        }
    }

    /// Installs the freshly built runner over the current USB connection.
    private static func installRunner(derivedDataPath: String, udid: String) throws {
        let runner = URL(fileURLWithPath: derivedDataPath, isDirectory: true)
            .appendingPathComponent("Build/Products/Debug-iphoneos", isDirectory: true)
            .appendingPathComponent(runnerName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: runner.path) else {
            throw IOSAgentError.buildFailed
        }
        do {
            _ = try run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "install", "app",
                    "--device", udid,
                    "--timeout", "120",
                    runner.path
                ]
            )
        } catch let failure as CommandFailure {
            if outputIndicatesLockedDevice(failure.output) {
                throw IOSAgentError.deviceLocked
            }
            logger.error("Runner install failed: \(failure.output, privacy: .public)")
            throw IOSAgentError.buildFailed
        }
    }

    /// Waits for usbmuxd to list the phone over the local network.
    static func waitForNetworkEntry(udid: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let devices = try? await DeviceTunnelSidecar.listDevices(),
               devices.contains(where: { $0.udid == udid && $0.isNetwork }) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: - Running the agent

    /// Starts (or reuses) the agent for a phone and returns where to reach it.
    /// The transport is whatever usbmuxd offers, preferring the network entry
    /// so a session survives the cable coming out.
    func ensureRunning(
        udid: String,
        transport: DeviceTunnelTransport = .auto,
        configuration: AppiumControlConfiguration,
        progress: @escaping @Sendable (IOSAgentProgress) async -> Void = { _ in }
    ) async throws -> IOSAgentEndpoint {
        try await IOSAgentGate.shared.run(udid: udid) {
            try await self.ensureRunningUniquely(
                udid: udid,
                transport: transport,
                configuration: configuration,
                progress: progress
            )
        }
    }

    private func ensureRunningUniquely(
        udid: String,
        transport: DeviceTunnelTransport,
        configuration: AppiumControlConfiguration,
        progress: @escaping @Sendable (IOSAgentProgress) async -> Void
    ) async throws -> IOSAgentEndpoint {
        await progress(.checkingExistingAgent)
        if let running = AgentRegistry.shared.running(udid: udid),
           let endpoint = Self.endpoint(for: running.endpoints),
           await Self.isReady(endpoint.controlURL) {
            remember(endpoint)
            await progress(.connectingVideo)
            return endpoint
        }

        let isolated = configuration.isolated(forDeviceUDID: udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw IOSAgentError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw IOSAgentError.missingSigningTeam }

        await progress(.checkingDevice)
        let readiness = try await Self.inspect(udid: udid, configuration: configuration)
        if readiness.runnerInstalled == false { throw IOSAgentError.setupRequired }
        if readiness.developerMode == false { throw IOSAgentError.developerModeDisabled }

        // A tunnel that is up but whose runner stopped answering is replaced.
        // It is stopped before the new one starts so the phone never carries
        // two tunnels, and the new runner launch does not race the old one.
        await AgentRegistry.shared.take(udid: udid)?.stopAndWait()

        await progress(.launchingAgent)
        let sidecar = try await Self.startSidecar(
            udid: udid,
            transport: transport,
            bundleID: bundleID,
            allowDeveloperImageRecovery: true,
            onWaiting: { Task { await progress(.waitingForDevice) } }
        )
        guard let endpoint = Self.endpoint(for: sidecar.endpoints) else {
            await sidecar.stopAndWait()
            throw IOSAgentError.launchFailed
        }
        AgentRegistry.shared.register(sidecar, udid: udid)
        remember(endpoint)
        await progress(.connectingVideo)
        return endpoint
    }

    private static func startSidecar(
        udid: String,
        transport: DeviceTunnelTransport,
        bundleID: String,
        allowDeveloperImageRecovery: Bool,
        onWaiting: @escaping @Sendable () -> Void
    ) async throws -> DeviceTunnelSidecar {
        let configuration = sidecarConfiguration(udid: udid, transport: transport, bundleID: bundleID)
        do {
            return try await DeviceTunnelSidecar.start(configuration, onWaiting: onWaiting)
        } catch let error as DeviceTunnelSidecarError {
            if case .developerImageMissing = error, allowDeveloperImageRecovery {
                // Any CoreDevice command mounts the personalized developer image
                // on a paired phone; it stays mounted until the next reboot.
                logger.info("Developer image missing on \(udid, privacy: .public); asking CoreDevice to mount it")
                try? await Task.detached(priority: .userInitiated) {
                    try mountDeveloperImage(udid: udid)
                }.value
                return try await startSidecar(
                    udid: udid,
                    transport: transport,
                    bundleID: bundleID,
                    allowDeveloperImageRecovery: false,
                    onWaiting: onWaiting
                )
            }
            throw agentError(from: error)
        }
    }

    nonisolated static func sidecarConfiguration(
        udid: String,
        transport: DeviceTunnelTransport,
        bundleID: String
    ) -> DeviceTunnelSidecar.Configuration {
        DeviceTunnelSidecar.Configuration(
            udid: udid,
            transport: transport,
            runnerBundleID: runnerBundleIdentifier(for: bundleID),
            environment: launchEnvironment(bundleID: bundleID),
            tcpPorts: [controlPort, mjpegPort],
            udpPorts: [videoPort],
            statusPort: controlPort
        )
    }

    nonisolated static func endpoint(for endpoints: DeviceTunnelEndpoints) -> IOSAgentEndpoint? {
        guard let controlURL = endpoints.localURL(forDeviceTCPPort: controlPort),
              let videoPort = endpoints.udpPorts[videoPort] else { return nil }
        return IOSAgentEndpoint(controlURL: controlURL, videoHost: "127.0.0.1", videoPort: videoPort)
    }

    /// Names the user-facing failure behind a sidecar error.
    nonisolated static func agentError(from error: DeviceTunnelSidecarError) -> IOSAgentError {
        switch error {
        case .missingSidecar:
            return .missingRuntime
        case let .deviceNotFound(message):
            // "only reachable over USB, not Network": the phone is plugged in
            // but not visible on Wi-Fi. The reverse means the cable is out.
            return message.contains("only reachable over USB") ? .wifiConnectionsUnavailable : .deviceUnavailable
        case .developerImageMissing:
            return .developerImageMissing
        case .automationNotApproved:
            return .automationNotApproved
        case .timedOut:
            return .timedOut
        case let .runnerNotReady(message), let .runnerExited(message),
             let .tunnelFailed(message), let .tunnelClosed(message):
            if outputIndicatesMissingInstallation(message) {
                return .setupRequired
            }
            if outputIndicatesLockedDevice(message) {
                return .deviceLocked
            }
            if case .runnerNotReady = error {
                return .timedOut
            }
            return .launchFailed
        case let .terminated(_, output):
            if outputIndicatesMissingInstallation(output) {
                return .setupRequired
            }
            return .launchFailed
        }
    }

    private static func mountDeveloperImage(udid: String) throws {
        do {
            _ = try run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "info", "details",
                    "--device", udid, "--quiet", "--timeout", "30"
                ]
            )
        } catch let failure as CommandFailure {
            if outputIndicatesLockedDevice(failure.output) {
                throw IOSAgentError.deviceLocked
            }
            throw IOSAgentError.developerImageMissing
        }
    }

    /// Releases this session's reference to the shared agent.
    func stop() {
        lock.withLock { cachedEndpoint = nil }
    }

    /// Ends the shared tunnel for a device, which also stops the runner. Only
    /// for app shutdown, so the agent does not keep running after the last
    /// mirror closed.
    static func terminateSharedAgent(udid: String) async {
        await AgentRegistry.shared.take(udid: udid)?.stopAndWait()
    }

    private func remember(_ endpoint: IOSAgentEndpoint) {
        lock.withLock { cachedEndpoint = endpoint }
    }

    // MARK: - Helpers

    nonisolated static func outputIndicatesLockedDevice(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("Unlock ")
            || output.localizedCaseInsensitiveContains("device is locked")
    }

    /// The runner is gone from the iPhone. Only the USB setup can fix that.
    nonisolated static func outputIndicatesMissingInstallation(_ output: String) -> Bool {
        let haystack = output.lowercased()
        return haystack.contains("is not installed")
            || haystack.contains("not installed on this device")
            || haystack.contains("unable to find application")
            || haystack.contains("could not find application")
            || haystack.contains("failed to find the application")
            || haystack.contains("no app with bundle")
            || haystack.contains("could not find app")
            || (haystack.contains("bundle identifier") && haystack.contains("not found"))
            || haystack.contains("failed to get the identifier for the app to be installed")
    }

    nonisolated static func runnerBundleIdentifier(for bundleID: String) -> String {
        "\(bundleID).xctrunner"
    }

    nonisolated static func launchEnvironment(bundleID: String) -> [String: String] {
        [
            "USE_PORT": "\(controlPort)",
            "WDA_PRODUCT_BUNDLE_IDENTIFIER": runnerBundleIdentifier(for: bundleID),
            "MJPEG_SERVER_PORT": "\(mjpegPort)",
            "STUPIDMIRROR_H264_PORT": "\(videoPort)",
            "STUPIDMIRROR_H264_FPS": "45",
            "STUPIDMIRROR_H264_SOURCE_QUALITY": "80",
            "STUPIDMIRROR_H264_BITRATE": "8000000"
        ]
    }

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

    /// Whether WebDriverAgent answers `/status` at a base URL.
    static func isReady(_ baseURL: URL, timeout: TimeInterval = 3) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("status"))
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

private actor IOSAgentGate {
    static let shared = IOSAgentGate()

    private var inFlight: [String: Task<IOSAgentEndpoint, Error>] = [:]

    func run(
        udid: String,
        operation: @escaping @Sendable () async throws -> IOSAgentEndpoint
    ) async throws -> IOSAgentEndpoint {
        if let existing = inFlight[udid] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[udid] = task
        defer { inFlight[udid] = nil }
        return try await task.value
    }
}
