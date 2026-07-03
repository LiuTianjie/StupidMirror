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
                let name = readInfo(udid: udid, key: "DeviceName") ?? "iPhone"
                let productType = readInfo(udid: udid, key: "ProductType") ?? "iOS Device"
                let osVersion = readInfo(udid: udid, key: "ProductVersion") ?? ""
                return DeviceMetadata(udid: udid, name: name, productType: productType, osVersion: osVersion)
            }
    }

    static func bestMatch(for captureDevice: String, modelID: String, candidates: [DeviceMetadata]) -> DeviceMetadata? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return candidates[0]
        }

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

    private static func readInfo(udid: String, key: String) -> String? {
        guard let ideviceInfo = executablePath(named: "ideviceinfo") else {
            return nil
        }
        return run(ideviceInfo, arguments: ["-u", udid, "-k", key])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
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
