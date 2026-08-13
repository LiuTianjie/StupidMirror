import Darwin
import Foundation

private final class AndroidCommandOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) {
        lock.withLock { stdout = data }
    }

    func setStderr(_ data: Data) {
        lock.withLock { stderr = data }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.withLock { (stdout, stderr) }
    }
}

struct AndroidDeviceMetadata: Hashable, Sendable {
    static let minimumSupportedSDK = 30

    let serial: String
    let name: String
    let manufacturer: String
    let model: String
    let product: String
    let osVersion: String?
    let sdkVersion: Int?
    let transport: DeviceTransport
    let connectionState: DeviceConnectionState
    let trustState: DeviceTrustState

    var id: String { "android:\(serial)" }

    var isSupported: Bool {
        guard let sdkVersion else { return connectionState != .connected }
        return sdkVersion >= Self.minimumSupportedSDK
    }

    var identity: DeviceIdentity {
        DeviceIdentity(
            id: id,
            udid: serial,
            platform: .android,
            name: name,
            productType: model.isEmpty ? "Android Device" : model,
            osVersion: osVersion,
            connectionState: isSupported ? connectionState : .unavailable,
            trustState: trustState
        )
    }
}

struct AndroidRuntimeStatus: Equatable, Sendable {
    let adbPath: String?
    let scrcpyServerPath: String?
    let scrcpyServerVersion: String?

    var mirroringAvailable: Bool {
        adbPath != nil && scrcpyServerPath != nil && scrcpyServerVersion != nil
    }
}

enum AndroidRuntime {
    static let pinnedScrcpyServerVersion = "4.1"

    struct ScrcpyServerResource: Equatable, Sendable {
        let path: String
        let version: String
    }

    static var status: AndroidRuntimeStatus {
        let server = scrcpyServerResource()
        return AndroidRuntimeStatus(
            adbPath: adbExecutablePath(),
            scrcpyServerPath: server?.path,
            scrcpyServerVersion: server?.version
        )
    }

    static func adbExecutablePath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let configured = environment["STUPIDMIRROR_ADB_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Android/sdk/platform-tools/adb")
            .path {
            candidates.append(bundled)
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent("platform-tools/adb").path)
            }
        }
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        )
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb"
        ])
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func scrcpyServerResource() -> ScrcpyServerResource? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        if let configured = environment["STUPIDMIRROR_SCRCPY_SERVER_PATH"],
           fileManager.fileExists(atPath: configured) {
            let version = environment["STUPIDMIRROR_SCRCPY_SERVER_VERSION"]
                .flatMap(Self.nonempty) ?? pinnedScrcpyServerVersion
            return ScrcpyServerResource(path: configured, version: version)
        }

        if let root = Bundle.main.resourceURL?.appendingPathComponent("Android", isDirectory: true),
           let resource = resource(in: root) {
            return resource
        }

        let workingRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/android-runtime", isDirectory: true)
        if let resource = resource(in: workingRoot) {
            return resource
        }
        return nil
    }

    private static func resource(in root: URL) -> ScrcpyServerResource? {
        let fileManager = FileManager.default
        let versionURL = root.appendingPathComponent("scrcpy-server.version")
        let version = (try? String(contentsOf: versionURL, encoding: .utf8))
            .flatMap(nonempty) ?? pinnedScrcpyServerVersion
        let candidates = [
            root.appendingPathComponent("scrcpy-server"),
            root.appendingPathComponent("scrcpy-server-v\(version)")
        ]
        guard let server = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return ScrcpyServerResource(path: server.path, version: version)
    }

    private static func nonempty(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

enum AndroidADBService {
    struct CommandResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum DiscoveryOutcome: Equatable, Sendable {
        case available([AndroidDeviceMetadata])
        case unavailable
    }

    static func discoverDevices() -> DiscoveryOutcome {
        guard let adb = AndroidRuntime.adbExecutablePath() else {
            return .unavailable
        }
        guard let result = try? run(adb: adb, arguments: ["devices", "-l"], timeout: 5) else {
            return .unavailable
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        return .available(parseDeviceList(output).map { listed in
            metadata(for: listed, adb: adb)
        })
    }

    static func captureScreenshot(serial: String) throws -> Data {
        guard let adb = AndroidRuntime.adbExecutablePath() else {
            throw AndroidADBError.adbUnavailable
        }
        let result = try run(
            adb: adb,
            arguments: ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: 12
        )
        guard result.status == 0,
              result.stdout.count > 8,
              result.stdout.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw AndroidADBError.commandFailed(Self.errorMessage(result))
        }
        return result.stdout
    }

    static func parseDeviceList(_ output: String) -> [ListedAndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("List of devices attached"),
                  !line.hasPrefix("* daemon") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            var details: [String: String] = [:]
            for value in parts.dropFirst(2) {
                guard let separator = value.firstIndex(of: ":") else { continue }
                details[String(value[..<separator])] = String(value[value.index(after: separator)...])
            }
            return ListedAndroidDevice(
                serial: parts[0],
                state: parts[1],
                details: details
            )
        }
    }

    static func parseGetProp(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("["),
                  let keyEnd = line.firstIndex(of: "]"),
                  let valueStart = line.range(of: ": [", range: keyEnd..<line.endIndex)?.upperBound,
                  line.hasSuffix("]") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<keyEnd])
            let value = String(line[valueStart..<line.index(before: line.endIndex)])
            values[key] = value
        }
        return values
    }

    static func run(
        adb: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            throw AndroidADBError.adbUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitSemaphore = DispatchSemaphore(value: 0)
        let readGroup = DispatchGroup()
        let output = AndroidCommandOutputBox()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            output.setStdout(data)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            output.setStderr(data)
            readGroup.leave()
        }
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw AndroidADBError.commandFailed(error.localizedDescription)
        }

        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exitSemaphore.wait(timeout: .now() + 0.75) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 1)
            }
            _ = readGroup.wait(timeout: .now() + 1)
            throw AndroidADBError.timedOut
        }
        _ = readGroup.wait(timeout: .now() + 2)
        let captured = output.snapshot()
        return CommandResult(
            status: process.terminationStatus,
            stdout: captured.stdout,
            stderr: captured.stderr
        )
    }

    private static func metadata(for listed: ListedAndroidDevice, adb: String) -> AndroidDeviceMetadata {
        let state: DeviceConnectionState
        let trust: DeviceTrustState
        switch listed.state {
        case "device":
            state = .connected
            trust = .trusted
        case "unauthorized":
            state = .unavailable
            trust = .unauthorized
        default:
            state = .unavailable
            trust = .unknown
        }

        var properties: [String: String] = [:]
        if state == .connected,
           let result = try? run(
               adb: adb,
               arguments: ["-s", listed.serial, "shell", "getprop"],
               timeout: 4
           ), result.status == 0 {
            properties = parseGetProp(String(decoding: result.stdout, as: UTF8.self))
        }

        let manufacturer = properties["ro.product.manufacturer"]
            ?? listed.details["product"] ?? "Android"
        let model = properties["ro.product.model"]
            ?? listed.details["model"]?.replacingOccurrences(of: "_", with: " ")
            ?? "Android Device"
        let product = properties["ro.product.name"] ?? listed.details["product"] ?? ""
        let osVersion = properties["ro.build.version.release"]
        let sdkVersion = properties["ro.build.version.sdk"].flatMap(Int.init)
        let normalizedManufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = model.localizedCaseInsensitiveContains(normalizedManufacturer)
            ? model
            : "\(normalizedManufacturer) \(model)"
        let transport: DeviceTransport = listed.details["usb"] == nil
            && (listed.serial.contains(":") || listed.serial.hasPrefix("adb-"))
            ? .wireless
            : .usb
        return AndroidDeviceMetadata(
            serial: listed.serial,
            name: name,
            manufacturer: manufacturer,
            model: model,
            product: product,
            osVersion: osVersion,
            sdkVersion: sdkVersion,
            transport: transport,
            connectionState: state,
            trustState: trust
        )
    }

    private static func errorMessage(_ result: CommandResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "ADB exited with status \(result.status).")
    }
}

struct ListedAndroidDevice: Equatable, Sendable {
    let serial: String
    let state: String
    let details: [String: String]
}

enum AndroidADBError: LocalizedError, Equatable {
    case adbUnavailable
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .adbUnavailable:
            "Android platform-tools (adb) are unavailable."
        case let .commandFailed(message):
            message
        case .timedOut:
            "The Android device did not respond before the ADB timeout."
        }
    }
}
