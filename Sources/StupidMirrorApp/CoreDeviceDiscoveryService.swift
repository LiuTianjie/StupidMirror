import Foundation
import OSLog

struct WirelessDeviceMetadata: Hashable, Sendable {
    let udid: String
    let name: String
    let productType: String
    let osVersion: String
    let hostname: String
    let hostnames: [String]
    let tunnelIPAddress: String?
    let tunnelState: String?

    init(
        udid: String,
        name: String,
        productType: String,
        osVersion: String,
        hostname: String,
        hostnames: [String] = [],
        tunnelIPAddress: String? = nil,
        tunnelState: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.productType = productType
        self.osVersion = osVersion
        self.hostname = hostname
        self.hostnames = Self.uniqueHosts([hostname] + hostnames)
        self.tunnelIPAddress = tunnelIPAddress?.nonEmpty
        self.tunnelState = tunnelState?.nonEmpty
    }

    var isTunnelConnected: Bool {
        tunnelState == "connected" && !endpointHosts.isEmpty
    }

    var endpointHosts: [String] {
        Self.uniqueHosts([tunnelIPAddress].compactMap { $0?.nonEmpty } + hostnames)
    }

    var preferredEndpointHost: String {
        endpointHosts.first ?? hostname
    }

    var formattedPreferredEndpointHost: String {
        Self.formattedURLHost(preferredEndpointHost)
    }

    func endpointURLs(port: Int, path: String = "") -> [URL] {
        endpointHosts.compactMap { host in
            var components = URLComponents()
            components.scheme = "http"
            components.host = Self.formattedURLHost(host)
            components.port = port
            components.path = path
            return components.url
        }
    }

    private static func formattedURLHost(_ host: String) -> String {
        host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]"))
            ? "[\(host)]"
            : host
    }

    private static func uniqueHosts(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let host = value.nonEmpty else { return nil }
            let key = host.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return host
        }
    }
}

enum WirelessDiscoveryOutcome: Equatable, Sendable {
    case available([WirelessDeviceMetadata])
    case unavailable
}

/// Discovers Xcode-paired iPhones through Apple's supported `devicectl` CLI.
/// The app never opens or implements the underlying device transport protocol.
enum CoreDeviceDiscoveryService {
    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "CoreDeviceDiscovery")

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
    }

    static func discoverUSBDeviceMetadata() -> [DeviceMetadata] {
        guard let data = deviceListData() else { return [] }
        let devices = parseUSBDevices(data)
        logger.info("Discovered \(devices.count) wired iPhone(s) through CoreDevice")
        return devices
    }

    static func discoverWirelessDevices() -> WirelessDiscoveryOutcome {
        guard let data = deviceListData() else { return .unavailable }
        let devices = parseWirelessDevices(data)
        logger.info("Discovered \(devices.count) wireless iPhone(s)")
        return .available(devices)
    }

    private static func deviceListData() -> Data? {
        guard isAvailable else { return nil }

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
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: outputURL) else {
            logger.error("devicectl discovery failed with status \(process.terminationStatus)")
            return nil
        }
        return data
    }

    nonisolated static func parseUSBDevices(_ data: Data) -> [DeviceMetadata] {
        guard let payload = try? JSONDecoder().decode(CoreDevicePayload.self, from: data) else {
            return []
        }
        return payload.result.devices.compactMap { device in
            guard device.hardwareProperties.platform == "iOS",
                  device.hardwareProperties.deviceType == "iPhone",
                  device.hardwareProperties.reality == "physical",
                  device.connectionProperties.pairingState == "paired",
                  device.connectionProperties.transportType == "wired",
                  let udid = device.hardwareProperties.udid?.nonEmpty,
                  let name = device.deviceProperties.name?.nonEmpty else {
                return nil
            }
            return DeviceMetadata(
                udid: udid,
                name: name,
                productType: device.hardwareProperties.productType?.nonEmpty ?? "iOS Device",
                osVersion: device.deviceProperties.osVersionNumber?.nonEmpty ?? ""
            )
        }
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
                  let name = device.deviceProperties.name?.nonEmpty else {
                return nil
            }
            let hostnames = preferredHostnames(for: device)
            let tunnelIPAddress = device.connectionProperties.tunnelIPAddress?.nonEmpty
            guard let hostname = hostnames.first ?? tunnelIPAddress else { return nil }
            return WirelessDeviceMetadata(
                udid: udid,
                name: name,
                productType: device.hardwareProperties.productType?.nonEmpty ?? "iOS Device",
                osVersion: device.deviceProperties.osVersionNumber?.nonEmpty ?? "",
                hostname: hostname,
                hostnames: hostnames,
                tunnelIPAddress: tunnelIPAddress,
                tunnelState: device.connectionProperties.tunnelState
            )
        }
    }

    private static func preferredHostnames(for device: CoreDeviceRecord) -> [String] {
        let candidates = (device.connectionProperties.localHostnames ?? [])
            + (device.connectionProperties.potentialHostnames ?? [])
        let valid = candidates.filter { hostname in
            let normalized = hostname.lowercased()
            return normalized.hasSuffix(".coredevice.local")
                && !normalized.contains("/")
                && !normalized.contains(":")
        }
        guard !valid.isEmpty else { return [] }

        let normalizedName = device.deviceProperties.name?
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let preferred = valid.first { hostname in
            guard let normalizedName else { return false }
            return hostname.lowercased().hasPrefix(normalizedName)
        }
        var ordered = valid
        if let preferred, let index = ordered.firstIndex(of: preferred) {
            ordered.remove(at: index)
            ordered.insert(preferred, at: 0)
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.lowercased()).inserted }
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
    let tunnelIPAddress: String?
    let tunnelState: String?
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
