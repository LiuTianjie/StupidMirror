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

struct DeviceSession: Identifiable {
    let id: String
    var device: DeviceIdentity
    let captureDevice: AVCaptureDevice
    let mirrorSession: MirrorCaptureSession
    let controlSession: AppiumControlSession
    var mirrorState: MirrorState

    @MainActor
    init(device: DeviceIdentity, captureDevice: AVCaptureDevice) {
        self.id = device.id
        self.device = device
        self.captureDevice = captureDevice
        self.mirrorSession = MirrorCaptureSession(device: captureDevice)
        self.controlSession = AppiumControlSession(device: device)
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
