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

    // Kept as a compatibility alias while callers migrate to the explicit API.
    static func authorizationStatus() -> AVAuthorizationStatus {
        videoAuthorizationStatus()
    }

    static func requestVideoAccess() async -> Bool {
        await permissionRequestCoordinator.requestAccess(for: .video)
    }

    static func warmUpDiscovery() {
        MuxedDeviceCatalog.shared.warmUp()
    }

    static func discoverMuxedDevices() -> [AVCaptureDevice] {
        MuxedDeviceCatalog.shared.devices()
    }

    static func identity(
        for device: AVCaptureDevice,
        metadata: DeviceMetadata?,
        cachedUDID: String? = nil,
        existingUDID: String? = nil
    ) -> DeviceIdentity {
        let udid = resolvedUDID(
            captureUniqueID: device.uniqueID,
            metadataMatch: metadata,
            cachedUDID: cachedUDID,
            existingUDID: existingUDID
        )
        return DeviceIdentity(
            id: udid ?? device.uniqueID,
            udid: udid,
            name: metadata?.name ?? device.localizedName,
            productType: metadata?.productType ?? (device.modelID.isEmpty ? "iOS Device" : device.modelID),
            osVersion: metadata?.osVersion,
            connectionState: device.isSuspended ? .unavailable : .connected,
            trustState: .trusted
        )
    }

    nonisolated static func resolvedUDID(
        captureUniqueID: String,
        metadataMatch: DeviceMetadata?,
        cachedUDID: String?,
        existingUDID: String?
    ) -> String? {
        if let udid = metadataMatch?.udid, !udid.isEmpty, udid != captureUniqueID {
            return udid
        }
        if let udid = cachedUDID, !udid.isEmpty, udid != captureUniqueID {
            return udid
        }
        if let udid = existingUDID, !udid.isEmpty, udid != captureUniqueID {
            return udid
        }
        return nil
    }

    nonisolated static func preferSoleMetadataMatch(
        captureCount: Int,
        metadata: [DeviceMetadata]
    ) -> DeviceMetadata? {
        guard captureCount == 1, metadata.count == 1 else { return nil }
        return metadata[0]
    }
}

/// Keeps CoreMediaIO discovery sessions alive. Throwaway sessions often miss
/// a just-attached iPhone muxed source until a later poll.
private final class MuxedDeviceCatalog: @unchecked Sendable {
    static let shared = MuxedDeviceCatalog()

    private let lock = NSLock()
    private var warmupSessions: [AVCaptureDevice.DiscoverySession] = []
    private var muxedSession: AVCaptureDevice.DiscoverySession?

    private init() {}

    func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        guard warmupSessions.isEmpty || muxedSession == nil else { return }
        let mediaTypes: [AVMediaType?] = [nil, .video, .muxed]
        warmupSessions = mediaTypes.map { mediaType in
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: mediaType,
                position: .unspecified
            )
        }
        muxedSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )
    }

    func devices() -> [AVCaptureDevice] {
        warmUp()
        lock.lock()
        let session = muxedSession
        lock.unlock()
        return session?.devices ?? []
    }
}
