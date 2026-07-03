@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation

enum AVFoundationMirrorBackend {
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

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestVideoAccess() async -> Bool {
        switch authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            false
        }
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
