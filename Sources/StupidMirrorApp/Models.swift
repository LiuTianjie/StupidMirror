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
    /// An iOS Simulator or Android emulator running on this Mac.
    case simulator
}

/// The media producer is independent of the cable or network carrying it.
enum MirrorVideoSource: Equatable, Sendable {
    case avFoundation
    case iosAgent
    case android
    case simulator
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

    /// The device's physical shape. Simulators report "iPhone Duo" as the
    /// product type; CoreDevice reports the model id (iPhone19,4) there.
    var formFactor: DeviceFormFactor {
        DeviceFormFactor.detect(productType: productType, modelID: nil)
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

/// Where a control connection currently is. `startingService` only applies
/// to Android, whose driver runs inside a local Appium service.
enum ControlConnectionPhase: Equatable, Sendable {
    case startingService
    case startingAgent
    case connectingAgent
    case finishing
}

struct DeviceSession: Identifiable {
    var id: String
    var device: DeviceIdentity
    var transport: DeviceTransport
    var videoSource: MirrorVideoSource
    var captureDevice: AVCaptureDevice?
    var lastUSBCaptureUniqueID: String?
    var wirelessDevice: WirelessDeviceMetadata?
    let androidDevice: AndroidDeviceMetadata?
    let mirrorSession: MirrorCaptureSession
    let controlSession: DeviceControlSession
    /// The screen agent service for an iPhone, whichever cable it is on.
    var iosAgent: IOSAgentService?
    var mirrorState: MirrorState

    var sourceID: String {
        if usesIOSAgentVideo {
            return "ios-agent:\(device.udid ?? id):\(transport.rawValue)"
        }
        if let androidDevice {
            return "android:\(androidDevice.serial)"
        }
        switch transport {
        case .usb:
            return "usb:\(captureDevice?.uniqueID ?? id)"
        case .wireless:
            return "wireless:\(wirelessDevice?.udid ?? id)"
        case .simulator:
            return "simulator:\(id)"
        }
    }

    var platform: DevicePlatform { device.platform }

    var isIOSWireless: Bool {
        platform == .iOS && transport == .wireless
    }

    var needsCameraPermission: Bool {
        videoSource == .avFoundation
    }

    var usesIOSAgentVideo: Bool {
        videoSource == .iosAgent
    }

    var canPlayAudioOnMac: Bool {
        platform == .android || (platform == .iOS && transport == .usb)
    }

    @MainActor
    init(device: DeviceIdentity, captureDevice: AVCaptureDevice?) {
        self.id = device.id
        self.device = device
        self.transport = .usb
        self.videoSource = .iosAgent
        self.captureDevice = captureDevice
        self.lastUSBCaptureUniqueID = captureDevice?.uniqueID
        self.wirelessDevice = nil
        self.androidDevice = nil
        self.mirrorSession = MirrorCaptureSession(
            iosDeviceUDID: device.udid, transport: .usb, usbAudioDevice: captureDevice
        )
        self.controlSession = DeviceControlSession(device: device)
        self.iosAgent = IOSAgentService()
        self.mirrorState = .stopped
    }

    @MainActor
    init(device: DeviceIdentity, wirelessDevice: WirelessDeviceMetadata) {
        self.id = device.id
        self.device = device
        self.transport = .wireless
        self.videoSource = .iosAgent
        self.captureDevice = nil
        self.lastUSBCaptureUniqueID = nil
        self.wirelessDevice = wirelessDevice
        self.androidDevice = nil
        self.mirrorSession = MirrorCaptureSession(wirelessDeviceUDID: wirelessDevice.udid)
        self.controlSession = DeviceControlSession(device: device)
        self.iosAgent = IOSAgentService()
        self.mirrorState = .stopped
    }

    @MainActor
    init(device: DeviceIdentity, androidDevice: AndroidDeviceMetadata) {
        self.id = device.id
        self.device = device
        self.transport = androidDevice.transport
        self.videoSource = .android
        self.captureDevice = nil
        self.lastUSBCaptureUniqueID = nil
        self.wirelessDevice = nil
        self.androidDevice = androidDevice
        self.mirrorSession = MirrorCaptureSession(androidDevice: androidDevice)
        self.controlSession = DeviceControlSession(device: device)
        self.iosAgent = nil
        self.mirrorState = .stopped
    }

    /// An iOS Simulator. Its screen and control both come from the runner
    /// `SimulatorAgentService` starts inside it, not from an `IOSAgentService`.
    @MainActor
    init(device: DeviceIdentity, simulator: SimulatorDevice) {
        self.id = device.id
        self.device = device
        self.transport = .simulator
        self.videoSource = .simulator
        self.captureDevice = nil
        self.lastUSBCaptureUniqueID = nil
        self.wirelessDevice = nil
        self.androidDevice = nil
        self.mirrorSession = MirrorCaptureSession(simulatorUDID: simulator.udid)
        self.controlSession = DeviceControlSession(device: device)
        self.iosAgent = nil
        self.mirrorState = .stopped
        self.mirrorSession.onSimulatorDisplayChange = { [weak controlSession = self.controlSession] in
            controlSession?.refreshScreenSize()
        }
    }

    var isIOSSimulator: Bool {
        platform == .iOS && transport == .simulator
    }

    /// Mirrors whose start can take long enough (a tunnel, a first runner
    /// build) to show its progress, elapsed time and a cancel button.
    var showsMirrorStartupProgress: Bool {
        usesIOSAgentVideo || isIOSSimulator
    }

    @MainActor
    mutating func adoptUSB(identity: DeviceIdentity, captureDevice: AVCaptureDevice?) {
        device = identity
        controlSession.updateDevice(identity)
        transport = .usb
        videoSource = .iosAgent
        self.captureDevice = captureDevice
        if let captureDevice { lastUSBCaptureUniqueID = captureDevice.uniqueID }
        mirrorSession.retargetToIOSStream(
            udid: identity.udid, transport: .usb, usbAudioDevice: captureDevice
        )
    }

    @MainActor
    mutating func adoptWireless(identity: DeviceIdentity, wirelessDevice: WirelessDeviceMetadata) {
        device = identity
        controlSession.updateDevice(identity)
        self.wirelessDevice = wirelessDevice
        if iosAgent == nil {
            iosAgent = IOSAgentService()
        }
        transport = .wireless
        videoSource = .iosAgent
        captureDevice = nil
        mirrorSession.retargetToIOSStream(udid: wirelessDevice.udid, transport: .wireless)
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
        if session.iosAgent != nil { score += 2 }
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
