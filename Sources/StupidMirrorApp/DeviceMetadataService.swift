import Darwin
import Foundation

enum DeviceMetadataService {
    static var isAvailable: Bool {
        executablePath(named: "idevice_id") != nil && executablePath(named: "ideviceinfo") != nil
    }

    static func connectedDevices() -> [DeviceMetadata] {
        guard let ideviceID = executablePath(named: "idevice_id"),
              let udids = run(ideviceID, arguments: ["-l"]) else {
            return []
        }

        return udids
            .split(whereSeparator: \.isNewline)
            .compactMap { rawUDID in
                let udid = String(rawUDID)
                guard !udid.isEmpty else { return nil }
                let info = readInfo(udid: udid)
                let name = info["DeviceName"] ?? "iPhone"
                let productType = info["ProductType"] ?? "iOS Device"
                let osVersion = info["ProductVersion"] ?? ""
                return DeviceMetadata(udid: udid, name: name, productType: productType, osVersion: osVersion)
            }
    }

    static func bestMatch(for captureDevice: String, modelID: String, candidates: [DeviceMetadata]) -> DeviceMetadata? {
        guard !candidates.isEmpty else { return nil }
        let normalizedCaptureName = normalize(captureDevice)
        let exactNameMatches = candidates.filter { normalize($0.name) == normalizedCaptureName || normalizedCaptureName.contains(normalize($0.name)) }
        if exactNameMatches.count == 1 {
            return exactNameMatches[0]
        }

        let modelMatches = candidates.filter { $0.productType == modelID }
        if modelMatches.count == 1 {
            return modelMatches[0]
        }

        return nil
    }

    private static func readInfo(udid: String) -> [String: String] {
        guard let ideviceInfo = executablePath(named: "ideviceinfo") else {
            return [:]
        }
        guard let output = run(ideviceInfo, arguments: ["-u", udid]) else {
            return [:]
        }

        return parseInfo(output)
    }

    nonisolated static func parseInfo(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }

    private static func executablePath(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ launchPath: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                guard finished.wait(timeout: .now() + 1) == .success else {
                    return nil
                }
            }
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        try? output.fileHandleForReading.close()
        return String(data: data, encoding: .utf8)
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "的相机", with: "")
            .replacingOccurrences(of: "的麦克风", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
