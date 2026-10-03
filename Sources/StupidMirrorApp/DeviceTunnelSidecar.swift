import Foundation
import OSLog

/// Which usbmuxd entry the sidecar should use to reach the phone.
enum DeviceTunnelTransport: String, Sendable {
    /// Prefer the local-network entry, fall back to USB when the phone is plugged in.
    case auto
    case network
    case usb
}

/// One JSON line printed by the `smtunnel` sidecar.
///
/// The fields are plain JSON values (strings, numbers, arrays, dictionaries)
/// straight from `JSONSerialization`, which is why the struct can promise
/// Sendable without the compiler being able to check it.
struct DeviceTunnelEvent: @unchecked Sendable {
    let name: String
    private let fields: [String: Any]

    init(name: String, fields: [String: Any]) {
        self.name = name
        self.fields = fields
    }

    func string(_ key: String) -> String? {
        fields[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let number = fields[key] as? NSNumber { return number.intValue }
        if let text = fields[key] as? String { return Int(text) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        (fields[key] as? NSNumber)?.boolValue
    }

    func array(_ key: String) -> [[String: Any]] {
        (fields[key] as? [[String: Any]]) ?? []
    }

    func stringArray(_ key: String) -> [String] {
        (fields[key] as? [String]) ?? []
    }

    /// Parses one stdout line. Lines that are not JSON objects with an
    /// `event` key (go-ios logging, partial output) yield `nil`.
    static func parse(_ line: String) -> DeviceTunnelEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["event"] as? String else { return nil }
        var fields = object
        fields["event"] = nil
        return DeviceTunnelEvent(name: name, fields: fields)
    }
}

/// Where the sidecar published the runner's ports on the Mac.
struct DeviceTunnelEndpoints: Equatable, Sendable {
    let udid: String
    let connectionType: String
    let tunnelAddress: String
    /// Device TCP port → 127.0.0.1 port.
    let tcpPorts: [Int: Int]
    /// Device UDP port → 127.0.0.1 port.
    let udpPorts: [Int: Int]

    func localURL(forDeviceTCPPort port: Int) -> URL? {
        guard let local = tcpPorts[port] else { return nil }
        return URL(string: "http://127.0.0.1:\(local)")
    }
}

enum DeviceTunnelSidecarError: Error, Equatable {
    /// The bundled `smtunnel` executable is missing.
    case missingSidecar
    /// usbmuxd does not list the device over the requested transport.
    case deviceNotFound(String)
    /// CoreDeviceProxy or the in-process tunnel could not be established.
    case tunnelFailed(String)
    /// The device offers no testmanagerd: the developer disk image is not mounted.
    case developerImageMissing(String)
    /// The runner launched but never answered on its status port.
    case runnerNotReady(String)
    /// XCTest gave up waiting for iOS to allow automation. The phone asks for
    /// its passcode before the first automation session after a reboot.
    case automationNotApproved(String)
    /// The runner's test session ended.
    case runnerExited(String)
    /// The tunnel's connection to the device broke.
    case tunnelClosed(String)
    /// The sidecar ended without reporting why.
    case terminated(status: Int32, output: String)
    case timedOut

    static func from(code: String, message: String) -> DeviceTunnelSidecarError {
        switch code {
        case "device_not_found", "usbmuxd_unavailable", "lockdown_failed":
            .deviceNotFound(message)
        case "developer_image_missing":
            .developerImageMissing(message)
        case "runner_not_ready":
            .runnerNotReady(message)
        case "automation_not_approved":
            .automationNotApproved(message)
        case "tunnel_closed":
            .tunnelClosed(message)
        default:
            .tunnelFailed(message)
        }
    }

    var message: String {
        switch self {
        case .missingSidecar: "the smtunnel sidecar is not bundled"
        case let .deviceNotFound(text), let .tunnelFailed(text), let .developerImageMissing(text),
             let .runnerNotReady(text), let .automationNotApproved(text), let .runnerExited(text),
             let .tunnelClosed(text):
            text
        case let .terminated(status, output):
            "smtunnel exited with status \(status): \(output.suffix(400))"
        case .timedOut: "smtunnel did not become ready in time"
        }
    }
}

struct DeviceTunnelDeviceEntry: Equatable, Sendable {
    let udid: String
    /// Every transport usbmuxd currently offers for the phone ("USB", "Network").
    let connectionTypes: [String]
    let name: String?
    let productType: String?
    let productVersion: String?

    init(udid: String, connectionTypes: [String], name: String? = nil, productType: String? = nil, productVersion: String? = nil) {
        self.udid = udid
        self.connectionTypes = connectionTypes
        self.name = name
        self.productType = productType
        self.productVersion = productVersion
    }

    var isNetwork: Bool { connectionTypes.contains("Network") }
    var isUSB: Bool { connectionTypes.contains("USB") }
}

/// A running `smtunnel serve` process: one CoreDevice tunnel to one phone,
/// optionally holding the WebDriverAgent runner's XCTest session open.
///
/// The sidecar reaches the phone through usbmuxd (USB, or the local network
/// once Wi-Fi connections are enabled on the phone), so no Xcode launcher,
/// no kernel interface, and no Local Network permission is involved.
final class DeviceTunnelSidecar: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var udid: String
        var transport: DeviceTunnelTransport = .auto
        var runnerBundleID: String?
        var xctestConfig: String = "WebDriverAgentRunner.xctest"
        var environment: [String: String] = [:]
        var tcpPorts: [Int] = []
        var udpPorts: [Int] = []
        var statusPort: Int?
    }

    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "DeviceTunnelSidecar")
    private static let readyTimeout: Duration = .seconds(120)

    let configuration: Configuration
    let endpoints: DeviceTunnelEndpoints

    private let process: Process
    private let stdin: Pipe
    private let lock = NSLock()
    private var exitHandler: (@Sendable (DeviceTunnelSidecarError) -> Void)?
    private var exitError: DeviceTunnelSidecarError?
    private var stopping = false
    private var finished = false

    private init(
        configuration: Configuration,
        endpoints: DeviceTunnelEndpoints,
        process: Process,
        stdin: Pipe
    ) {
        self.configuration = configuration
        self.endpoints = endpoints
        self.process = process
        self.stdin = stdin
    }

    var isRunning: Bool {
        lock.withLock { !finished } && process.isRunning
    }

    /// Called once if the sidecar ends on its own (device gone, runner exited).
    /// Not called after `stop()`.
    func onExit(_ handler: @escaping @Sendable (DeviceTunnelSidecarError) -> Void) {
        let pending: DeviceTunnelSidecarError? = lock.withLock {
            exitHandler = handler
            return finished && !stopping ? (exitError ?? .terminated(status: process.terminationStatus, output: "")) : nil
        }
        if let pending { handler(pending) }
    }

    /// Ends the session: the runner is killed by the sidecar on the way out.
    /// Blocks for up to `stopGrace`; async callers use `stopAndWait()`.
    func stop() {
        lock.withLock { stopping = true }
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(Self.stopGrace)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// `stop()` off the cooperative thread pool.
    func stopAndWait() async {
        await Task.detached(priority: .userInitiated) { self.stop() }.value
    }

    /// The sidecar itself waits up to five seconds for the runner kill to land
    /// after SIGTERM; this leaves it room to finish before SIGKILL.
    private static let stopGrace: TimeInterval = 7

    // MARK: - Locating the executable

    static func executableURL() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("smtunnel", isDirectory: true)
                    .appendingPathComponent("smtunnel")
            )
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repositoryRoot.appendingPathComponent(".build/smtunnel/smtunnel"))
        candidates.append(repositoryRoot.appendingPathComponent("tools/smtunnel/smtunnel"))
        if let override = ProcessInfo.processInfo.environment["STUPIDMIRROR_SMTUNNEL"], !override.isEmpty {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func arguments(for configuration: Configuration) -> [String] {
        var arguments = ["serve", "--udid", configuration.udid, "--transport", configuration.transport.rawValue, "--watch-stdin"]
        if let runner = configuration.runnerBundleID, !runner.isEmpty {
            arguments += ["--runner", runner, "--xctest-config", configuration.xctestConfig]
            for key in configuration.environment.keys.sorted() {
                arguments += ["--env", "\(key)=\(configuration.environment[key] ?? "")"]
            }
        }
        for port in configuration.tcpPorts {
            arguments += ["--tcp", "\(port)"]
        }
        for port in configuration.udpPorts {
            arguments += ["--udp", "\(port)"]
        }
        if let statusPort = configuration.statusPort {
            arguments += ["--status-port", "\(statusPort)"]
        }
        return arguments
    }

    // MARK: - Starting

    /// Launches the sidecar and waits until it reports `ready`. `onWaiting`
    /// fires once if the runner is slow enough that the phone is probably
    /// waiting for the user (a passcode prompt for automation, a dark screen).
    static func start(
        _ configuration: Configuration,
        onWaiting: @escaping @Sendable () -> Void = {}
    ) async throws -> DeviceTunnelSidecar {
        guard let executable = executableURL() else {
            throw DeviceTunnelSidecarError.missingSidecar
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: configuration)
        process.environment = ProcessInfo.processInfo.environment.merging(["GO_IOS_LOG_LEVEL": "warn"]) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let startup = StartupCollector(udid: configuration.udid, onWaiting: onWaiting)
        let stderrTail = TextTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrTail.append(handle.availableData)
        }
        let lineReader = LineReader { line in
            guard let event = DeviceTunnelEvent.parse(line) else { return }
            startup.handle(event)
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lineReader.append(data)
        }

        let sidecarBox = SidecarBox()
        process.terminationHandler = { process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            lineReader.flush()
            let output = stderrTail.value
            startup.terminated(status: process.terminationStatus, output: output)
            sidecarBox.sidecar?.processEnded(status: process.terminationStatus, output: output, lastError: startup.lastError)
        }

        do {
            try process.run()
        } catch {
            throw DeviceTunnelSidecarError.tunnelFailed("could not start smtunnel: \(error.localizedDescription)")
        }

        do {
            let endpoints = try await startup.waitUntilReady(timeout: readyTimeout)
            let sidecar = DeviceTunnelSidecar(
                configuration: configuration,
                endpoints: endpoints,
                process: process,
                stdin: stdin
            )
            sidecarBox.sidecar = sidecar
            // A sidecar that already ended before we attached must still report it.
            if !process.isRunning {
                sidecar.processEnded(status: process.terminationStatus, output: stderrTail.value, lastError: startup.lastError)
            }
            logger.info("smtunnel ready for \(configuration.udid, privacy: .public) over \(endpoints.connectionType, privacy: .public)")
            return sidecar
        } catch {
            if process.isRunning {
                try? stdin.fileHandleForWriting.close()
                process.terminate()
            }
            logger.error("smtunnel failed for \(configuration.udid, privacy: .public): \((error as? DeviceTunnelSidecarError)?.message ?? error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func processEnded(status: Int32, output: String, lastError: DeviceTunnelSidecarError?) {
        let (handler, error, wasStopping): (
            (@Sendable (DeviceTunnelSidecarError) -> Void)?, DeviceTunnelSidecarError, Bool
        ) = lock.withLock {
            guard !finished else { return (nil, .timedOut, true) }
            finished = true
            let error = lastError ?? .terminated(status: status, output: output)
            exitError = error
            return (exitHandler, error, stopping)
        }
        guard !wasStopping else { return }
        Self.logger.error("smtunnel for \(self.configuration.udid, privacy: .public) ended: \(error.message, privacy: .public)")
        handler?(error)
    }

    // MARK: - One-shot commands

    /// Devices usbmuxd currently lists, one entry per phone with every transport
    /// it is reachable over. With `details` the lockdown identity is read too.
    static func listDevices(details: Bool = false) async throws -> [DeviceTunnelDeviceEntry] {
        let events = try await runOnce(arguments: details ? ["list", "--details"] : ["list"], timeout: 20)
        guard let event = events.last(where: { $0.name == "devices" }) else {
            throw lastError(in: events) ?? .tunnelFailed("smtunnel list printed no device list")
        }
        return parseDeviceList(event.array("devices"))
    }

    nonisolated static func parseDeviceList(_ rows: [[String: Any]]) -> [DeviceTunnelDeviceEntry] {
        var order: [String] = []
        var types: [String: [String]] = [:]
        var identity: [String: (String?, String?, String?)] = [:]
        for row in rows {
            guard let udid = row["udid"] as? String else { continue }
            if types[udid] == nil {
                order.append(udid)
                types[udid] = []
            }
            if let list = row["connectionTypes"] as? [String] {
                types[udid, default: []].append(contentsOf: list)
            } else if let single = row["connectionType"] as? String {
                types[udid, default: []].append(single)
            }
            if let name = row["name"] as? String {
                identity[udid] = (name, row["productType"] as? String, row["productVersion"] as? String)
            }
        }
        return order.map { udid in
            let id = identity[udid]
            var seen = Set<String>()
            let unique = (types[udid] ?? []).filter { seen.insert($0).inserted }
            return DeviceTunnelDeviceEntry(
                udid: udid,
                connectionTypes: unique,
                name: id?.0,
                productType: id?.1,
                productVersion: id?.2
            )
        }
    }

    /// Reads a phone's setup state: identity, Developer Mode, the Wi-Fi
    /// connections switch, whether `runnerBundleID` is installed, and whether a
    /// developer image is mounted.
    static func inspect(udid: String, runnerBundleID: String?) async throws -> IOSDeviceReadiness {
        var arguments = ["info", "--udid", udid]
        if let runnerBundleID, !runnerBundleID.isEmpty {
            arguments += ["--runner", runnerBundleID]
        }
        let events = try await runOnce(arguments: arguments, timeout: 30)
        guard let event = events.last(where: { $0.name == "info" }) else {
            throw lastError(in: events) ?? .tunnelFailed("smtunnel info printed no report")
        }
        return IOSDeviceReadiness(
            udid: udid,
            name: event.string("name") ?? "",
            productType: event.string("productType") ?? "",
            productVersion: event.string("productVersion") ?? "",
            connectionTypes: event.stringArray("connectionTypes"),
            developerMode: event.bool("developerMode"),
            wifiConnections: event.bool("enableWifiConnections"),
            runnerInstalled: event.bool("runnerInstalled"),
            developerImageMounted: event.bool("developerImageMounted"),
            passwordProtected: event.bool("passwordProtected")
        )
    }

    /// Turns the phone's "Wi-Fi connections" lockdown flag on or off. This is
    /// what Xcode's "Connect via network" toggles; it needs no tap on the phone.
    @discardableResult
    static func setWiFiConnections(udid: String, enabled: Bool) async throws -> Bool {
        let events = try await runOnce(arguments: ["wifi", "--udid", udid, enabled ? "on" : "off"], timeout: 30)
        guard let event = events.last(where: { $0.name == "wifi" }) else {
            throw lastError(in: events) ?? .tunnelFailed("smtunnel wifi printed no result")
        }
        return event.bool("enableWifiConnections") ?? false
    }

    private static func lastError(in events: [DeviceTunnelEvent]) -> DeviceTunnelSidecarError? {
        guard let event = events.last(where: { $0.name == "error" }) else { return nil }
        return .from(code: event.string("code") ?? "", message: event.string("message") ?? "")
    }

    private static func runOnce(arguments: [String], timeout: TimeInterval) async throws -> [DeviceTunnelEvent] {
        guard let executable = executableURL() else {
            throw DeviceTunnelSidecarError.missingSidecar
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try process.run()
                let reader = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    process.terminate()
                }
                let data = await reader.value
                try Task.checkCancellation()
                let text = String(data: data, encoding: .utf8) ?? ""
                return text.split(separator: "\n").compactMap { DeviceTunnelEvent.parse(String($0)) }
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

// MARK: - Startup bookkeeping

/// Collects the events a starting sidecar prints until it is ready or dead.
private final class StartupCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let udid: String
    private var connectionType = ""
    private var tunnelAddress = ""
    private var tcpPorts: [Int: Int] = [:]
    private var udpPorts: [Int: Int] = [:]
    private var recordedError: DeviceTunnelSidecarError?
    private var outcome: Result<DeviceTunnelEndpoints, DeviceTunnelSidecarError>?
    private var continuation: CheckedContinuation<DeviceTunnelEndpoints, Error>?
    private let onWaiting: @Sendable () -> Void

    init(udid: String, onWaiting: @escaping @Sendable () -> Void = {}) {
        self.udid = udid
        self.onWaiting = onWaiting
    }

    var lastError: DeviceTunnelSidecarError? {
        lock.withLock { recordedError }
    }

    func handle(_ event: DeviceTunnelEvent) {
        if event.name == "runner", event.string("state") == "waiting_for_device" {
            let settled = lock.withLock { outcome != nil }
            if !settled { onWaiting() }
            return
        }
        lock.lock()
        switch event.name {
        case "device":
            connectionType = event.string("connectionType") ?? ""
        case "tunnel":
            tunnelAddress = event.string("address") ?? ""
        case "forward":
            if let devicePort = event.int("devicePort"), let localPort = event.int("localPort") {
                if event.string("proto") == "udp" {
                    udpPorts[devicePort] = localPort
                } else {
                    tcpPorts[devicePort] = localPort
                }
            }
        case "ready":
            let endpoints = DeviceTunnelEndpoints(
                udid: udid,
                connectionType: connectionType,
                tunnelAddress: tunnelAddress,
                tcpPorts: tcpPorts,
                udpPorts: udpPorts
            )
            settle(.success(endpoints))
            return
        case "error":
            let error = DeviceTunnelSidecarError.from(
                code: event.string("code") ?? "",
                message: event.string("message") ?? ""
            )
            recordedError = error
            settle(.failure(error))
            return
        case "runner":
            if event.string("state") == "exited" {
                let error = DeviceTunnelSidecarError.runnerExited(event.string("message") ?? "the runner exited")
                recordedError = error
                settle(.failure(error))
                return
            }
        default:
            break
        }
        lock.unlock()
    }

    func terminated(status: Int32, output: String) {
        lock.lock()
        settle(.failure(recordedError ?? .terminated(status: status, output: output)))
    }

    /// Must be called with the lock held; releases it.
    private func settle(_ result: Result<DeviceTunnelEndpoints, DeviceTunnelSidecarError>) {
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let waiting {
            waiting.resume(with: result.mapError { $0 as Error })
        }
    }

    func waitUntilReady(timeout: Duration) async throws -> DeviceTunnelEndpoints {
        try await withThrowingTaskGroup(of: DeviceTunnelEndpoints.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DeviceTunnelEndpoints, Error>) in
                    self.lock.lock()
                    if let outcome = self.outcome {
                        self.lock.unlock()
                        continuation.resume(with: outcome.mapError { $0 as Error })
                        return
                    }
                    self.continuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DeviceTunnelSidecarError.timedOut
            }
            guard let first = try await group.next() else {
                throw DeviceTunnelSidecarError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}

private final class SidecarBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeviceTunnelSidecar?

    var sidecar: DeviceTunnelSidecar? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Splits a byte stream into lines, tolerating chunks that end mid-line.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        var lines: [String] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }
        lines.forEach(onLine)
    }

    func flush() {
        let rest: String? = lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
        }
        if let rest, !rest.isEmpty { onLine(rest) }
    }
}

private final class TextTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.withLock {
            text.append(chunk)
            if text.utf8.count > 16_384 {
                text = String(text.suffix(16_384))
            }
        }
    }

    var value: String {
        lock.withLock { text }
    }
}
