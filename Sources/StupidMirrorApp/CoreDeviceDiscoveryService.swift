import Foundation
import OSLog

/// An iPhone usbmuxd lists on the local network. That is exactly the entry
/// `smtunnel` opens its tunnel over, so a listed phone can be connected to.
struct WirelessDeviceMetadata: Hashable, Sendable {
    let udid: String
    let name: String
    let productType: String
    let osVersion: String
    /// False while the phone's lockdown identity could not be read yet; the
    /// name is then a placeholder that should not replace a known one.
    let hasIdentity: Bool
    /// usbmuxd also lists the phone on USB.
    let isAlsoOnUSB: Bool

    init(
        udid: String,
        name: String,
        productType: String,
        osVersion: String,
        hasIdentity: Bool = true,
        isAlsoOnUSB: Bool = false
    ) {
        self.udid = udid
        self.name = name
        self.productType = productType
        self.osVersion = osVersion
        self.hasIdentity = hasIdentity
        self.isAlsoOnUSB = isAlsoOnUSB
    }
}

enum WirelessDiscoveryOutcome: Equatable, Sendable {
    case available([WirelessDeviceMetadata])
    case unavailable
}

/// Finds iPhones that are reachable over Wi-Fi through usbmuxd, the same path
/// the `smtunnel` sidecar uses to reach them. CoreDevice (`devicectl`) is not
/// consulted: its tunnel state describes Xcode's system tunnel, which the app
/// does not use, and it often disagrees with usbmuxd about the transport.
enum WirelessDiscoveryService {
    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "WirelessDiscovery")

    /// Names and models by UDID. Learned from USB discovery and from
    /// `smtunnel list --details`, so identity is read over Wi-Fi at most once
    /// per phone instead of on every poll.
    final class IdentityCache: @unchecked Sendable {
        static let shared = IdentityCache()

        private let lock = NSLock()
        private var identities: [String: DeviceMetadata] = [:]

        func identity(for udid: String) -> DeviceMetadata? {
            lock.withLock { identities[udid] }
        }

        func remember(_ metadata: DeviceMetadata) {
            guard !metadata.udid.isEmpty, !metadata.name.isEmpty else { return }
            lock.withLock { identities[metadata.udid] = metadata }
        }
    }

    static func discover(cache: IdentityCache = .shared) async -> WirelessDiscoveryOutcome {
        let entries: [DeviceTunnelDeviceEntry]
        do {
            entries = try await DeviceTunnelSidecar.listDevices(timeout: 5)
        } catch {
            logger.error("usbmuxd discovery failed: \((error as? DeviceTunnelSidecarError)?.message ?? error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        let networkUDIDs = entries.filter(\.isNetwork).map(\.udid)
        if networkUDIDs.contains(where: { cache.identity(for: $0) == nil }),
           let detailed = try? await DeviceTunnelSidecar.listDevices(details: true, timeout: 15) {
            for entry in detailed {
                if let metadata = identityMetadata(from: entry) {
                    cache.remember(metadata)
                }
            }
        }
        let devices = wirelessDevices(from: entries, cache: cache)
        logger.info("Discovered \(devices.count) wireless iPhone(s)")
        return .available(devices)
    }

    nonisolated static func identityMetadata(from entry: DeviceTunnelDeviceEntry) -> DeviceMetadata? {
        guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return DeviceMetadata(
            udid: entry.udid,
            name: name,
            productType: entry.productType?.nonEmpty ?? "iOS Device",
            osVersion: entry.productVersion?.nonEmpty ?? ""
        )
    }

    /// One device per phone usbmuxd lists over the network, whether or not it
    /// is also plugged in; USB discovery claims a plugged-in phone first.
    nonisolated static func wirelessDevices(
        from entries: [DeviceTunnelDeviceEntry],
        cache: IdentityCache
    ) -> [WirelessDeviceMetadata] {
        let usbUDIDs = Set(entries.filter(\.isUSB).map(\.udid))
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.isNetwork, seen.insert(entry.udid).inserted else { return nil }
            let onUSB = usbUDIDs.contains(entry.udid)
            if let identity = cache.identity(for: entry.udid) {
                return WirelessDeviceMetadata(
                    udid: entry.udid,
                    name: identity.name,
                    productType: identity.productType,
                    osVersion: identity.osVersion,
                    isAlsoOnUSB: onUSB
                )
            }
            return WirelessDeviceMetadata(
                udid: entry.udid,
                name: "iPhone",
                productType: "iOS Device",
                osVersion: "",
                hasIdentity: false,
                isAlsoOnUSB: onUSB
            )
        }
    }
}

/// Reads wired iPhone metadata through Apple's supported `devicectl` CLI when
/// libimobiledevice is not installed.
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
    let pairingState: String?
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
