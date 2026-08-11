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
            "Allow local network access for WebDriverAgentRunner on iPhone, then try again."
        }
    }
}

enum WirelessWDAProgress: Equatable, Sendable {
    case launching
    case waitingForUnlock
    case waitingForLocalNetwork
}

/// Launches a USB-prepared WebDriverAgent with Apple's public CoreDevice CLI,
/// then reads WDA's ordinary LAN HTTP/MJPEG ports. iOS 17 and newer cannot
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
    private var streamConfigured = false

    deinit { stop() }

    func ensureRunning(
        device: WirelessDeviceMetadata,
        configuration: AppiumControlConfiguration,
        progress: @escaping @Sendable (WirelessWDAProgress) async -> Void = { _ in }
    ) async throws -> URL {
        let lanHostname = Self.lanHostname(from: device.hostname)
        let baseURL = URL(string: "http://\(lanHostname):8100")!
        if await Self.isReady(baseURL) {
            await configureStreamIfNeeded(baseURL)
            return baseURL
        }
        if await Self.isLocalNetworkDenied(hostname: lanHostname) {
            throw WirelessWDAError.localNetworkDenied
        }

        try await Task.detached(priority: .userInitiated) {
            try Self.wakeDevice(udid: device.udid)
        }.value
        if await Self.isReady(baseURL) {
            await configureStreamIfNeeded(baseURL)
            return baseURL
        }

        lock.withLock { streamConfigured = false }

        let isolated = configuration.isolated(forDeviceUDID: device.udid)
        let team = isolated.xcodeOrgID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw WirelessWDAError.missingSigningTeam }
        let bundleID = isolated.installationWDABundleID
        guard !bundleID.isEmpty else { throw WirelessWDAError.missingSigningTeam }

        await progress(.launching)
        if let installedProcess = try? await Task.detached(priority: .userInitiated, operation: {
            try Self.launchInstalledRunner(udid: device.udid, bundleID: bundleID)
        }).value {
            lock.withLock { remoteProcess = installedProcess }
            if await Self.waitUntilReady(baseURL, timeout: .seconds(8)) {
                await configureStreamIfNeeded(baseURL)
                return baseURL
            }
        }

        let preparedRunner = try await Task.detached(priority: .userInitiated) {
            try Self.prepareCompatibleRunner(
                derivedDataPath: isolated.derivedDataPath,
                bundleID: bundleID
            )
        }.value
        let launched = try await Task.detached(priority: .userInitiated) {
            try Self.installAndLaunch(
                runner: preparedRunner,
                udid: device.udid,
                bundleID: bundleID
            )
        }.value
        lock.withLock { remoteProcess = launched }
        await progress(.waitingForLocalNetwork)

        if await Self.waitUntilReady(baseURL, timeout: .seconds(75)) {
            await configureStreamIfNeeded(baseURL)
            return baseURL
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
            _ = try? Self.run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "process", "terminate",
                    "--device", running.udid,
                    "--pid", String(running.pid),
                    "--timeout", "10",
                    "--quiet"
                ]
            )
        }
    }

    private func configureStreamIfNeeded(_ baseURL: URL) async {
        let shouldConfigure = lock.withLock { () -> Bool in
            guard !streamConfigured else { return false }
            streamConfigured = true
            return true
        }
        guard shouldConfigure else { return }
        do {
            try await Self.configureMJPEGStream(baseURL)
        } catch {
            lock.withLock { streamConfigured = false }
            Self.logger.warning(
                "Configuring wireless MJPEG stream failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func lanHostname(from coreDeviceHostname: String) -> String {
        let suffix = ".coredevice.local"
        guard coreDeviceHostname.lowercased().hasSuffix(suffix) else {
            return coreDeviceHostname
        }
        return String(coreDeviceHostname.dropLast(suffix.count)) + ".local"
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

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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

    private static func waitUntilReady(_ baseURL: URL, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if await isReady(baseURL) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// WDA defaults to 10 FPS. Its settings API is session-scoped even though
    /// these MJPEG values are process-global, so use a short no-app session to
    /// set the stream and immediately delete it. This does not enable control
    /// or launch an application on the iPhone.
    private static func configureMJPEGStream(_ baseURL: URL) async throws {
        let createBody: [String: Any] = [
            "capabilities": [
                "alwaysMatch": ["platformName": "iOS"],
                "firstMatch": [[:]]
            ]
        ]
        let created = try await sendJSON(
            method: "POST",
            url: baseURL.appendingPathComponent("session"),
            body: createBody
        )
        let sessionID = created["sessionId"] as? String
            ?? ((created["value"] as? [String: Any])?["sessionId"] as? String)
        guard let sessionID, !sessionID.isEmpty else { return }
        let sessionURL = baseURL
            .appendingPathComponent("session")
            .appendingPathComponent(sessionID)
        do {
            _ = try await sendJSON(
                method: "POST",
                url: sessionURL.appendingPathComponent("appium/settings"),
                body: [
                    "settings": [
                        "mjpegServerFramerate": 30,
                        "mjpegServerScreenshotQuality": 25,
                        "mjpegScalingFactor": 100
                    ]
                ]
            )
        } catch {
            _ = try? await sendJSON(method: "DELETE", url: sessionURL, body: nil)
            throw error
        }
        _ = try? await sendJSON(method: "DELETE", url: sessionURL, body: nil)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WirelessWDAError.launchFailed
        }
        return json
    }

    private static func isReady(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("status"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? [String: Any] else { return false }
        return value["ready"] as? Bool ?? true
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
