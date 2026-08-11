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

enum DeviceTransport: String, Codable, Sendable {
    case usb
    case wireless
}

struct DeviceIdentity: Identifiable, Hashable, Sendable {
    let id: String
    let udid: String?
    let name: String
    let productType: String
    let osVersion: String?
    var connectionState: DeviceConnectionState
    var trustState: DeviceTrustState

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
    let id: String
    var device: DeviceIdentity
    let transport: DeviceTransport
    let captureDevice: AVCaptureDevice?
    let wirelessDevice: WirelessDeviceMetadata?
    let mirrorSession: MirrorCaptureSession
    let controlSession: AppiumControlSession
    let wirelessWDA: WirelessWDAService?
    var mirrorState: MirrorState

    var sourceID: String {
        switch transport {
        case .usb:
            "usb:\(captureDevice?.uniqueID ?? id)"
        case .wireless:
            "wireless:\(wirelessDevice?.hostname ?? id)"
        }
    }

    @MainActor
    init(device: DeviceIdentity, captureDevice: AVCaptureDevice) {
        self.id = device.id
        self.device = device
        self.transport = .usb
        self.captureDevice = captureDevice
        self.wirelessDevice = nil
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
        self.wirelessDevice = wirelessDevice
        self.mirrorSession = MirrorCaptureSession(
            mjpegURL: URL(
                string: "http://\(WirelessWDAService.lanHostname(from: wirelessDevice.hostname)):9100"
            )!
        )
        self.controlSession = AppiumControlSession(device: device)
        self.wirelessWDA = WirelessWDAService()
        self.mirrorState = .stopped
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
