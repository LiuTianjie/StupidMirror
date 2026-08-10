@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation

private enum CapturePermissionKind: Hashable, Sendable {
    case video
    case audio

    var mediaType: AVMediaType {
        switch self {
        case .video:
            .video
        case .audio:
            .audio
        }
    }
}

/// Coalesces permission requests so repeated UI actions cannot create multiple
/// simultaneous system prompts for the same media type.
private actor CapturePermissionRequestCoordinator {
    private var waiters: [CapturePermissionKind: [CheckedContinuation<Bool, Never>]] = [:]

    func requestAccess(for kind: CapturePermissionKind) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: kind.mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                let shouldStartRequest = waiters[kind] == nil
                waiters[kind, default: []].append(continuation)
                guard shouldStartRequest else { return }

                AVCaptureDevice.requestAccess(for: kind.mediaType) { granted in
                    Task {
                        await self.completeRequest(for: kind, granted: granted)
                    }
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func completeRequest(for kind: CapturePermissionKind, granted: Bool) {
        let continuations = waiters.removeValue(forKey: kind) ?? []
        for continuation in continuations {
            continuation.resume(returning: granted)
        }
    }
}

enum AVFoundationMirrorBackend {
    private static let permissionRequestCoordinator = CapturePermissionRequestCoordinator()

    static func allowScreenCaptureDevices() -> OSStatus {
        let element: CMIOObjectPropertyElement
        if #available(macOS 12.0, *) {
            element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        } else {
            element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
        }

        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: element
        )
        var allow: UInt32 = 1
        return CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    static func videoAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func audioAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // Kept as a compatibility alias while callers migrate to the explicit
    // video/audio APIs.
    static func authorizationStatus() -> AVAuthorizationStatus {
        videoAuthorizationStatus()
    }

    static func requestVideoAccess() async -> Bool {
        await permissionRequestCoordinator.requestAccess(for: .video)
    }

    static func requestAudioAccess() async -> Bool {
        await permissionRequestCoordinator.requestAccess(for: .audio)
    }

    static func warmUpDiscovery() {
        let mediaTypes: [AVMediaType?] = [nil, .video, .muxed]
        for mediaType in mediaTypes {
            _ = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: mediaType,
                position: .unspecified
            ).devices
        }
    }

    static func discoverMuxedDevices() -> [AVCaptureDevice] {
        warmUpDiscovery()
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
    }

    static func identity(for device: AVCaptureDevice, metadata: DeviceMetadata?) -> DeviceIdentity {
        DeviceIdentity(
            id: metadata?.udid ?? device.uniqueID,
            udid: metadata?.udid,
            name: metadata?.name ?? device.localizedName,
            productType: metadata?.productType ?? (device.modelID.isEmpty ? "iOS Device" : device.modelID),
            osVersion: metadata?.osVersion,
            connectionState: device.isSuspended ? .unavailable : .connected,
            trustState: .trusted
        )
    }
}
