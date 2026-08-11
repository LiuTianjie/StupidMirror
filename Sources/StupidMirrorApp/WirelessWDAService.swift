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
    case deviceLocked
    case deviceUnavailable
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
        case .deviceLocked:
            "Unlock the iPhone and keep its screen on, then try again."
        case .deviceUnavailable:
            "The iPhone is not available over Wi-Fi. Unlock it and check that both devices are on the same network."
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
/// then reads WDA through the public CoreDevice tunnel. iOS 17 and newer cannot
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

    private struct RemoteProcess: Sendable {
        let udid: String
        let pid: Int
    }

    private struct CommandFailure: Error {
        let output: String
    }

    private let lock = NSLock()
    private var remoteProcess: RemoteProcess?

    deinit { stop() }

    /// Builds the patched WDA runner while the iPhone is connected by USB.
    /// This prepares wireless mirroring only; it does not create an Appium
    /// session or enable Mac-side iPhone control.
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
    }

    func ensureRunning(
        device: WirelessDeviceMetadata,
        configuration: AppiumControlConfiguration,
        progress: @escaping @Sendable (WirelessWDAProgress) async -> Void = { _ in }
    ) async throws -> WirelessWDAEndpoint {
        // CoreDevice endpoints are dynamic. Prefer the current tunnel address,
        // but retain every devicectl-provided hostname as a generic fallback.
        // Never cache one candidate across a discovery generation.
        guard device.isTunnelConnected else { throw WirelessWDAError.deviceUnavailable }
        let baseURLs = Self.candidateBaseURLs(for: device)
        guard !baseURLs.isEmpty else { throw WirelessWDAError.deviceUnavailable }
        if await Self.isLocalNetworkDenied(hostname: device.preferredEndpointHost) {
            throw WirelessWDAError.localNetworkDenied
        }
        await progress(.checkingExistingAgent)
        if let endpoint = await Self.firstReadyEndpoint(baseURLs) {
            await progress(.connectingVideo)
            return endpoint
        }

        await progress(.connectingDevice)
        try await Task.detached(priority: .userInitiated) {
            try Self.wakeDevice(udid: device.udid)
        }.value
        if let endpoint = await Self.firstReadyEndpoint(baseURLs) {
            await progress(.connectingVideo)
            return endpoint
        }

        let isolated = configuration.isolated(forDeviceUDID: device.udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw WirelessWDAError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw WirelessWDAError.missingSigningTeam }

        await progress(.launchingInstalledAgent)
        if let installedProcess = try? await Task.detached(priority: .userInitiated, operation: {
            try Self.launchInstalledRunner(udid: device.udid, bundleID: bundleID)
        }).value {
            lock.withLock { remoteProcess = installedProcess }
            await progress(.waitingForAgent)
            if let endpoint = await Self.waitUntilReady(baseURLs, timeout: .seconds(15)) {
                await progress(.connectingVideo)
                return endpoint
            }
            await Task.detached(priority: .utility) {
                try? Self.terminate(installedProcess)
            }.value
            lock.withLock {
                if remoteProcess?.pid == installedProcess.pid {
                    remoteProcess = nil
                }
            }
        }

        await progress(.preparingAgent)
        let preparedRunner = try await Task.detached(priority: .userInitiated) {
            try Self.prepareCompatibleRunner(
                derivedDataPath: isolated.derivedDataPath,
                bundleID: bundleID
            )
        }.value
        await progress(.installingAgent)
        let launched = try await Task.detached(priority: .userInitiated) {
            try Self.installAndLaunch(
                runner: preparedRunner,
                udid: device.udid,
                bundleID: bundleID
            )
        }.value
        lock.withLock { remoteProcess = launched }
        await progress(.waitingForAgent)

        if let endpoint = await Self.waitUntilReady(baseURLs, timeout: .seconds(20)) {
            await progress(.connectingVideo)
            return endpoint
        }
        throw WirelessWDAError.timedOut
    }

    func stop() {
        let running = lock.withLock { () -> RemoteProcess? in
            defer { remoteProcess = nil }
            return remoteProcess
        }
        guard let running else { return }
        DispatchQueue.global(qos: .utility).async {
            try? Self.terminate(running)
        }
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

    nonisolated static func runnerBundleIdentifier(for bundleID: String) -> String {
        "\(bundleID).xctrunner"
    }

    nonisolated static func processIdentifier(fromDevicectlJSON data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let process = result["process"] as? [String: Any] else { return nil }
        return process["processIdentifier"] as? Int
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
        } catch {
            throw WirelessWDAError.launchFailed
        }
    }

    private static func launchInstalledRunner(udid: String, bundleID: String) throws -> RemoteProcess {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-WDA-Launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let environment = [
            "USE_PORT": "8100",
            "WDA_PRODUCT_BUNDLE_IDENTIFIER": runnerBundleIdentifier(for: bundleID),
            "MJPEG_SERVER_PORT": "9100",
            "STUPIDMIRROR_H264_PORT": "9200",
            "STUPIDMIRROR_H264_FPS": "45",
            "STUPIDMIRROR_H264_SOURCE_QUALITY": "90",
            "STUPIDMIRROR_H264_BITRATE": "16000000"
        ]
        let environmentData = try JSONSerialization.data(withJSONObject: environment)
        guard let environmentJSON = String(data: environmentData, encoding: .utf8) else {
            throw WirelessWDAError.launchFailed
        }
        _ = try run(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "process", "launch",
                "--device", udid,
                "--terminate-existing",
                "--environment-variables", environmentJSON,
                "--json-output", outputURL.path,
                "--timeout", "30",
                runnerBundleIdentifier(for: bundleID)
            ]
        )
        let output = try Data(contentsOf: outputURL)
        guard let pid = processIdentifier(fromDevicectlJSON: output) else {
            throw WirelessWDAError.launchFailed
        }
        return RemoteProcess(udid: udid, pid: pid)
    }

    private static func terminate(_ process: RemoteProcess) throws {
        _ = try run(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "process", "terminate",
                "--device", process.udid,
                "--pid", String(process.pid),
                "--timeout", "10",
                "--quiet"
            ]
        )
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
