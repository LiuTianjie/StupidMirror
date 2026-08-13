@preconcurrency import AVFoundation
import Foundation

enum DeviceConnectionState: String, Codable, Sendable {
    case connected
    case disconnected
    case unavailable

    var label: String {
        switch self {
        case .connected:
            "Connected"
        case .disconnected:
            "Reconnecting"
        case .unavailable:
            "Unavailable"
        }
    }
}

enum DeviceTrustState: String, Codable, Sendable {
    case trusted
    case unknown
    case unauthorized
}

enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case iOS = "ios"
    case android

    var displayName: String {
        switch self {
        case .iOS: "iOS"
        case .android: "Android"
        }
    }

    var systemImage: String {
        switch self {
        case .iOS: "iphone.gen3"
        case .android: "apps.iphone"
        }
    }
}

enum DeviceTransport: String, Codable, Sendable {
    case usb
    case wireless
}

struct DeviceIdentity: Identifiable, Hashable, Sendable {
    let id: String
    let udid: String?
    let platform: DevicePlatform
    let name: String
    let productType: String
    let osVersion: String?
    var connectionState: DeviceConnectionState
    var trustState: DeviceTrustState

    init(
        id: String,
        udid: String?,
        platform: DevicePlatform = .iOS,
        name: String,
        productType: String,
        osVersion: String?,
        connectionState: DeviceConnectionState,
        trustState: DeviceTrustState
    ) {
        self.id = id
        self.udid = udid
        self.platform = platform
        self.name = name
        self.productType = productType
        self.osVersion = osVersion
        self.connectionState = connectionState
        self.trustState = trustState
    }

    var subtitle: String {
        [productType, osVersion].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " / ")
    }
}

struct DeviceMetadata: Hashable, Sendable {
    let udid: String
    let name: String
    let productType: String
    let osVersion: String
}

enum MirrorState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Live"
        case .failed:
            "Failed"
        }
    }
}

enum ControlState: Equatable {
    case unavailable
    case connecting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .unavailable:
            "Control not connected"
        case .connecting:
            "Connecting"
        case .ready:
            "Control ready"
        case .failed:
            "Control failed"
        }
    }
}

enum ControlConnectionPhase: Equatable, Sendable {
    case startingService
    case reusingAgent
    case installingAgent
    case finishing
}

struct DeviceSession: Identifiable {
    var id: String
    var device: DeviceIdentity
    var transport: DeviceTransport
    var captureDevice: AVCaptureDevice?
    var lastUSBCaptureUniqueID: String?
    var wirelessDevice: WirelessDeviceMetadata?
    let androidDevice: AndroidDeviceMetadata?
    let mirrorSession: MirrorCaptureSession
    let controlSession: AppiumControlSession
    var wirelessWDA: WirelessWDAService?
    var mirrorState: MirrorState

    var sourceID: String {
        if let androidDevice {
            return "android:\(androidDevice.serial)"
        }
        switch transport {
        case .usb:
            return "usb:\(captureDevice?.uniqueID ?? id)"
        case .wireless:
            return "wireless:\(wirelessDevice?.preferredEndpointHost ?? id)"
        }
    }

    var platform: DevicePlatform { device.platform }

    var isIOSWireless: Bool {
        platform == .iOS && transport == .wireless
    }

    @MainActor
    init(device: DeviceIdentity, captureDevice: AVCaptureDevice) {
        self.id = device.id
        self.device = device
        self.transport = .usb
        self.captureDevice = captureDevice
        self.lastUSBCaptureUniqueID = captureDevice.uniqueID
        self.wirelessDevice = nil
        self.androidDevice = nil
        self.mirrorSession = MirrorCaptureSession(device: captureDevice)
        self.controlSession = AppiumControlSession(device: device)
        self.wirelessWDA = nil
        self.mirrorState = .stopped
    }

    @MainActor
    init(device: DeviceIdentity, wirelessDevice: WirelessDeviceMetadata) {
        self.id = device.id
        self.device = device
        self.transport = .wireless
        self.captureDevice = nil
        self.lastUSBCaptureUniqueID = nil
        self.wirelessDevice = wirelessDevice
        self.androidDevice = nil
        self.mirrorSession = MirrorCaptureSession(
            wirelessEndpointURL: wirelessDevice.endpointURLs(port: 8_100).first!
        )
        self.controlSession = AppiumControlSession(device: device)
        self.wirelessWDA = WirelessWDAService()
        self.mirrorState = .stopped
    }

    @MainActor
    init(device: DeviceIdentity, androidDevice: AndroidDeviceMetadata) {
        self.id = device.id
        self.device = device
        self.transport = androidDevice.transport
        self.captureDevice = nil
        self.lastUSBCaptureUniqueID = nil
        self.wirelessDevice = nil
        self.androidDevice = androidDevice
        self.mirrorSession = MirrorCaptureSession(androidDevice: androidDevice)
        self.controlSession = AppiumControlSession(device: device)
        self.wirelessWDA = nil
        self.mirrorState = .stopped
    }

    @MainActor
    mutating func adoptUSB(identity: DeviceIdentity, captureDevice: AVCaptureDevice) {
        device = identity
        controlSession.updateDevice(identity)
        let needsRetarget = transport != .usb || self.captureDevice?.uniqueID != captureDevice.uniqueID
        self.captureDevice = captureDevice
        lastUSBCaptureUniqueID = captureDevice.uniqueID
        if needsRetarget {
            transport = .usb
            mirrorSession.retargetToUSB(captureDevice)
        }
    }

    @MainActor
    mutating func adoptWireless(identity: DeviceIdentity, wirelessDevice: WirelessDeviceMetadata) {
        device = identity
        controlSession.updateDevice(identity)
        self.wirelessDevice = wirelessDevice
        if wirelessWDA == nil {
            wirelessWDA = WirelessWDAService()
        }
        guard transport != .wireless else { return }
        transport = .wireless
        captureDevice = nil
        if let url = wirelessDevice.endpointURLs(port: 8_100).first {
            mirrorSession.retargetToWireless(endpointURL: url)
        }
    }

    func matchesDiscovery(id: String, udid: String?, captureUniqueID: String?) -> Bool {
        if self.id == id { return true }
        if let udid, !udid.isEmpty, self.id == udid || device.udid == udid {
            return true
        }
        if let captureUniqueID, !captureUniqueID.isEmpty {
            return self.captureDevice?.uniqueID == captureUniqueID
                || lastUSBCaptureUniqueID == captureUniqueID
        }
        return false
    }

    @MainActor
    static func reusePreferenceScore(_ session: DeviceSession) -> Int {
        var score = 0
        if session.device.udid?.isEmpty == false { score += 8 }
        if session.controlSession.isReady { score += 4 }
        if session.controlSession.isConnecting { score += 2 }
        if session.wirelessWDA != nil { score += 2 }
        switch session.mirrorSession.state {
        case .running: score += 2
        case .starting: score += 1
        case .stopped, .failed: break
        }
        if session.id == session.device.udid { score += 1 }
        return score
    }
}

struct DeviceScreenSize: Equatable, Sendable {
    var width: Double
    var height: Double

    var aspectRatio: Double {
        guard height > 0 else { return 9.0 / 19.5 }
        return width / height
    }
}
