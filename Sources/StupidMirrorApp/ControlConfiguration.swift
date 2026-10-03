import Foundation

/// Per-device control settings. For iPhones this names the signing identity
/// and the per-device build directory used to prepare the WebDriverAgent
/// runner; for Android it carries the UiAutomator2 session parameters.
struct AppiumControlConfiguration: Hashable, Sendable {
    var platform: DevicePlatform = .iOS
    var xcodeOrgID: String = ""
    var xcodeSigningID: String = "Apple Development"
    var wdaBundleID: String = ""
    var derivedDataPath: String = ""
    var mjpegServerPort: Int = 9100
    var uiautomator2SystemPort: Int = 8200
    var adbExecTimeoutMS: Int = 60_000
    var uiautomator2ServerInstallTimeoutMS: Int = 90_000
    var uiautomator2ServerLaunchTimeoutMS: Int = 60_000
    var sessionStartupTimeoutSeconds: TimeInterval = 125
    var newCommandTimeoutSeconds: Int = 300
    var allowProvisioningDeviceRegistration: Bool = true
    var platformVersion: String = ""

    /// The bundle identifier the runner is built and installed with. Teams get
    /// their own identifier so two Macs with different accounts never fight
    /// over one provisioning profile.
    var installationWDABundleID: String {
        let configured = wdaBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }

        let team = xcodeOrgID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !team.isEmpty else { return "" }
        return "com.stupidmirror.wda.\(team)"
    }

    /// Simultaneous devices need disjoint ports and their own DerivedData
    /// directory; both are derived deterministically from the full UDID.
    func isolated(forDeviceUDID udid: String) -> Self {
        let normalizedUDID = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUDID.isEmpty else { return self }

        let hash = StableDeviceHash.fnv1a64(normalizedUDID)
        let slot = Int(hash % 20_000)
        var result = self
        if platform == .android {
            result.uiautomator2SystemPort = 8_200 + (slot % 1_000)
            result.mjpegServerPort = 12_000 + slot
            return result
        }

        let basePath = derivedDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL
        if basePath.isEmpty {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            baseURL = applicationSupport
                .appendingPathComponent("StupidMirror", isDirectory: true)
                .appendingPathComponent("WebDriverAgentDerivedData", isDirectory: true)
        } else {
            baseURL = URL(fileURLWithPath: basePath, isDirectory: true)
        }
        result.derivedDataPath = baseURL
            .appendingPathComponent(String(format: "device-%016llx", hash), isDirectory: true)
            .path
        return result
    }
}

enum StableDeviceHash {
    static func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
