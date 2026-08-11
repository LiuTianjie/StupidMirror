import Foundation
import OSLog

struct WirelessDeviceMetadata: Hashable, Sendable {
    let udid: String
    let name: String
    let productType: String
    let osVersion: String
    let hostname: String
}

/// Discovers Xcode-paired iPhones through Apple's supported `devicectl` CLI.
/// The app never opens or implements the underlying device transport protocol.
enum CoreDeviceDiscoveryService {
    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "CoreDeviceDiscovery")

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
    }

    static func wirelessDevices() -> [WirelessDeviceMetadata] {
        guard isAvailable else { return [] }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-CoreDevice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "devicectl", "list", "devices",
            "--json-output", outputURL.path,
            "--quiet",
            "--timeout", "5"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to launch devicectl: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: outputURL) else {
            logger.error("devicectl discovery failed with status \(process.terminationStatus)")
            return []
        }
        let devices = parseWirelessDevices(data)
        logger.info("Discovered \(devices.count) wireless iPhone(s)")
        return devices
    }

    nonisolated static func parseWirelessDevices(_ data: Data) -> [WirelessDeviceMetadata] {
        guard let payload = try? JSONDecoder().decode(CoreDevicePayload.self, from: data) else {
            return []
        }
        return payload.result.devices.compactMap { device in
            guard device.hardwareProperties.platform == "iOS",
                  device.hardwareProperties.deviceType == "iPhone",
                  device.hardwareProperties.reality == "physical",
                  device.connectionProperties.pairingState == "paired",
                  device.connectionProperties.transportType == "localNetwork",
                  let udid = device.hardwareProperties.udid?.nonEmpty,
                  let name = device.deviceProperties.name?.nonEmpty,
                  let hostname = preferredHostname(for: device)?.nonEmpty else {
                return nil
            }
            return WirelessDeviceMetadata(
                udid: udid,
                name: name,
                productType: device.hardwareProperties.productType?.nonEmpty ?? "iOS Device",
                osVersion: device.deviceProperties.osVersionNumber?.nonEmpty ?? "",
                hostname: hostname
            )
        }
    }

    private static func preferredHostname(for device: CoreDeviceRecord) -> String? {
        let candidates = (device.connectionProperties.localHostnames ?? [])
            + (device.connectionProperties.potentialHostnames ?? [])
        let valid = candidates.filter { hostname in
            let normalized = hostname.lowercased()
            return normalized.hasSuffix(".coredevice.local")
                && !normalized.contains("/")
                && !normalized.contains(":")
        }
        guard !valid.isEmpty else { return nil }

        let normalizedName = device.deviceProperties.name?
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return valid.first { hostname in
            guard let normalizedName else { return false }
            return hostname.lowercased().hasPrefix(normalizedName)
        } ?? valid[0]
    }
}

private struct CoreDevicePayload: Decodable {
    let result: CoreDeviceResult
}

private struct CoreDeviceResult: Decodable {
    let devices: [CoreDeviceRecord]
}

private struct CoreDeviceRecord: Decodable {
    let connectionProperties: CoreDeviceConnectionProperties
    let deviceProperties: CoreDeviceProperties
    let hardwareProperties: CoreDeviceHardwareProperties
}

private struct CoreDeviceConnectionProperties: Decodable {
    let localHostnames: [String]?
    let pairingState: String?
    let potentialHostnames: [String]?
    let transportType: String?
}

private struct CoreDeviceProperties: Decodable {
    let bootState: String?
    let name: String?
    let osVersionNumber: String?
}

private struct CoreDeviceHardwareProperties: Decodable {
    let deviceType: String?
    let platform: String?
    let productType: String?
    let reality: String?
    let udid: String?
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
