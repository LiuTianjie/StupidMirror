@preconcurrency import AVFoundation
import CoreMedia
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

    // Kept as a compatibility alias while callers migrate to the explicit API.
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

/// USB iPhone screens are CoreMediaIO muxed devices (video + audio).
///
/// iOS treats an enabled or auto-connected audio port as a live USB playback
/// destination and mutes the phone speaker. Omitting `AVCaptureAudioDataOutput`
/// is not enough: `addInput` still forms audio connections from the default-
/// enabled ports. Video-only mirroring must disable those ports, connect only
/// video, and stop leftover CoreMediaIO audio streams. Mac playback enables
/// the ports and actually consumes the buffers.
enum IOSUSBAudioRouting {
    static func shouldEnableMuxedAudioPorts(
        playbackEnabled: Bool,
        authorizationStatus: AVAuthorizationStatus
    ) -> Bool {
        playbackEnabled && authorizationStatus == .authorized
    }

    static func setMuxedAudioPortsEnabled(_ enabled: Bool, on input: AVCaptureDeviceInput) {
        setAudioPortsEnabled(enabled, on: input)
    }

    static func setAudioPortsEnabled(_ enabled: Bool, on input: AVCaptureDeviceInput) {
        for port in audioPorts(on: input) {
            port.isEnabled = enabled
        }
    }

    static func muxedAudioPortsAreEnabled(on input: AVCaptureDeviceInput) -> Bool {
        audioPortsAreEnabled(on: input)
    }

    static func audioPortsAreEnabled(on input: AVCaptureDeviceInput) -> Bool {
        audioPorts(on: input).contains { $0.isEnabled }
    }

    static func hasMuxedAudioPorts(on input: AVCaptureDeviceInput) -> Bool {
        hasAudioPorts(on: input)
    }

    static func hasAudioPorts(on input: AVCaptureDeviceInput) -> Bool {
        !audioPorts(on: input).isEmpty
    }

    static func audioPorts(on input: AVCaptureDeviceInput) -> [AVCaptureInput.Port] {
        input.ports.filter { $0.mediaType == .audio }
    }

    static func muxedPorts(on input: AVCaptureDeviceInput) -> [AVCaptureInput.Port] {
        input.ports.filter { $0.mediaType == .muxed }
    }

    static func videoPorts(on input: AVCaptureDeviceInput) -> [AVCaptureInput.Port] {
        let video = input.ports.filter { $0.mediaType == .video }
        if !video.isEmpty { return video }
        return muxedPorts(on: input)
    }

    static func disableAudioConnections(in session: AVCaptureSession) {
        for connection in session.connections where isAudioConnection(connection) {
            connection.isEnabled = false
        }
    }

    static func hasEnabledAudioConnection(in session: AVCaptureSession) -> Bool {
        session.connections.contains { $0.isEnabled && isAudioConnection($0) }
    }

    static func isAudioConnection(_ connection: AVCaptureConnection) -> Bool {
        // A muxed video connection can expose audioChannels without being the
        // USB playback client. Only treat real audio outputs / audio ports.
        if connection.output is AVCaptureVideoDataOutput {
            return false
        }
        return connection.output is AVCaptureAudioDataOutput
            || connection.inputPorts.contains(where: { $0.mediaType == .audio })
    }

    /// Adds the muxed iPhone input without letting AVFoundation auto-wire
    /// audio. Falls back to `addInput` only if a manual video connection
    /// cannot be formed, then immediately disables leftover audio.
    @discardableResult
    static func addVideoOnlyGraph(
        input: AVCaptureDeviceInput,
        videoOutput: AVCaptureVideoDataOutput,
        to session: AVCaptureSession
    ) -> Bool {
        setAudioPortsEnabled(false, on: input)
        guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
            return false
        }

        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(videoOutput)
        let ports = videoPorts(on: input)
        if !ports.isEmpty {
            let connection = AVCaptureConnection(inputPorts: ports, output: videoOutput)
            if session.canAddConnection(connection) {
                session.addConnection(connection)
                pinPhoneSpeaker(input: input, session: session, deviceUniqueID: input.device.uniqueID)
                return true
            }
        }

        session.removeOutput(videoOutput)
        session.removeInput(input)
        session.addInput(input)
        session.addOutput(videoOutput)
        pinPhoneSpeaker(input: input, session: session, deviceUniqueID: input.device.uniqueID)
        return true
    }

    static func pinPhoneSpeaker(
        input: AVCaptureDeviceInput,
        session: AVCaptureSession,
        deviceUniqueID: String
    ) {
        setAudioPortsEnabled(false, on: input)
        disableAudioConnections(in: session)
        suppressCoreMediaIOAudioStreams(forDeviceUniqueID: deviceUniqueID)
    }

    /// CoreMediaIO can keep an audio stream running after AVFoundation has
    /// disabled the port. Stopping those streams is what lets iOS take the
    /// speaker back while video stays up.
    static func suppressCoreMediaIOAudioStreams(forDeviceUniqueID uniqueID: String) {
        guard let deviceID = cmioDeviceID(matching: uniqueID) else { return }
        for streamID in cmioStreams(on: deviceID) where cmioStreamIsAudio(streamID) {
            _ = CMIODeviceStopStream(deviceID, streamID)
        }
    }

    private static func cmioMainElement() -> CMIOObjectPropertyElement {
        if #available(macOS 12.0, *) {
            CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        } else {
            CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
        }
    }

    private static func cmioDeviceID(matching uniqueID: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: cmioMainElement()
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            &devices
        ) == noErr else {
            return nil
        }
        return devices.first { cmioDeviceUID($0) == uniqueID }
    }

    private static func cmioDeviceUID(_ deviceID: CMIOObjectID) -> String? {
        cmioString(deviceID, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
    }

    private static func cmioStreams(on deviceID: CMIOObjectID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: cmioMainElement()
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            &streams
        ) == noErr else {
            return []
        }
        return streams
    }

    private static func cmioStreamIsAudio(_ streamID: CMIOStreamID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: cmioMainElement()
        )
        guard CMIOObjectHasProperty(streamID, &address) else { return false }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<CMFormatDescription>.alignment
        )
        defer { data.deallocate() }
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            streamID,
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            data
        ) == noErr else {
            return false
        }
        let description = data.load(as: CMFormatDescription.self)
        return CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio
    }

    private static func cmioString(
        _ object: CMIOObjectID,
        selector: CMIOObjectPropertySelector
    ) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: cmioMainElement()
        )
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return nil
        }
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<CFString>.alignment
        )
        defer { data.deallocate() }
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            data
        ) == noErr else {
            return nil
        }
        let cfString = data.load(as: CFString.self)
        return cfString as String
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
