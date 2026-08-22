import AudioToolbox
import CoreMedia
import Darwin
import Foundation

/// Owns one scrcpy server process and its ADB-forwarded media sockets. The
/// Android server only captures media; semantic control remains owned by the
/// Appium/UiAutomator2 session so every automated action has one coordinator.
final class AndroidScrcpyStream: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        let serial: String
        let adbPath: String
        let serverPath: String
        let serverVersion: String
        let audioEnabled: Bool
        var duplicateDeviceAudio = false
        var maxSize = 2_160
        var maxFPS = 60
        var videoBitRate = 12_000_000
    }

    private let configuration: Configuration
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onAudio: @Sendable (CMSampleBuffer) -> Void
    private let onSessionSize: @Sendable (Int, Int) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let stateLock = NSLock()
    private let workQueue = DispatchQueue(label: "stupidmirror.android.scrcpy", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "stupidmirror.android.scrcpy.audio", qos: .userInitiated)
    private var process: Process?
    private var localPort: Int?
    private var sockets = Set<Int32>()
    private var generation: UInt64 = 0
    private var stopping = false
    private var failureDelivered = false
    private var serverLog = Data()

    init(
        configuration: Configuration,
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void,
        onAudio: @escaping @Sendable (CMSampleBuffer) -> Void,
        onSessionSize: @escaping @Sendable (Int, Int) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.configuration = configuration
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.onSessionSize = onSessionSize
        self.onFailure = onFailure
    }

    deinit {
        stop()
    }

    func start() {
        let taskGeneration = stateLock.withLock { () -> UInt64 in
            generation &+= 1
            stopping = false
            failureDelivered = false
            serverLog.removeAll(keepingCapacity: true)
            return generation
        }
        workQueue.async { [weak self] in
            self?.run(generation: taskGeneration)
        }
    }

    func stop() {
        let resources = stateLock.withLock { () -> (Process?, Int?, [Int32]) in
            generation &+= 1
            stopping = true
            let current = (process, localPort, Array(sockets))
            process = nil
            localPort = nil
            sockets.removeAll()
            return current
        }
        for socket in resources.2 {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
        if let process = resources.0, process.isRunning {
            process.terminate()
        }
        if let port = resources.1 {
            removeForward(port: port)
        }
    }

    private func run(generation taskGeneration: UInt64) {
        var videoSocket: Int32 = -1
        var audioSocket: Int32 = -1
        var decoder: WirelessH264Decoder?
        defer {
            decoder?.stop()
            closeSocket(videoSocket)
            closeSocket(audioSocket)
            let resources = stateLock.withLock { () -> (Process?, Int?) in
                guard generation == taskGeneration else { return (nil, nil) }
                let current = (process, localPort)
                process = nil
                localPort = nil
                return current
            }
            if let process = resources.0, process.isRunning {
                process.terminate()
            }
            if let port = resources.1 {
                removeForward(port: port)
            }
        }

        do {
            try checkActive(generation: taskGeneration)
            try pushServer()
            let scid = Self.scid(for: configuration.serial, generation: taskGeneration)
            let socketName = String(format: "scrcpy_%08x", scid)
            let port = try createForward(socketName: socketName)
            stateLock.withLock {
                guard generation == taskGeneration else { return }
                localPort = port
            }
            try checkActive(generation: taskGeneration)
            let serverProcess = try launchServer(scid: scid)
            stateLock.withLock {
                guard generation == taskGeneration else {
                    if serverProcess.isRunning { serverProcess.terminate() }
                    return
                }
                process = serverProcess
            }

            // The dummy byte is emitted on the first accepted socket. It lets
            // us distinguish the ADB forward listener from a ready device-side
            // server without guessing a startup delay.
            videoSocket = try Self.connectFirstSocket(port: port) {
                self.isActive(generation: taskGeneration)
            }
            register(socket: videoSocket, generation: taskGeneration)
            if configuration.audioEnabled {
                audioSocket = try Self.connectSocket(port: port)
                register(socket: audioSocket, generation: taskGeneration)
            }

            try checkActive(generation: taskGeneration)
            decoder = WirelessH264Decoder(
                onFrame: onFrame,
                onFailure: { [weak self] error in
                    self?.deliverFailure(error, generation: taskGeneration)
                }
            )

            let audioGroup = DispatchGroup()
            if audioSocket >= 0 {
                let capturedAudioSocket = audioSocket
                audioGroup.enter()
                audioQueue.async { [weak self] in
                    defer { audioGroup.leave() }
                    self?.readAudio(socket: capturedAudioSocket, generation: taskGeneration)
                }
            }
            try readVideo(
                socket: videoSocket,
                decoder: decoder!,
                generation: taskGeneration
            )
            if audioSocket >= 0 {
                Darwin.shutdown(audioSocket, SHUT_RDWR)
            }
            _ = audioGroup.wait(timeout: .now() + 2)
            if isActive(generation: taskGeneration) {
                throw AndroidScrcpyError.streamEnded(lastServerLog())
            }
        } catch is CancellationError {
            return
        } catch {
            deliverFailure(error, generation: taskGeneration)
        }
    }

    private func pushServer() throws {
        let result = try AndroidADBService.run(
            adb: configuration.adbPath,
            arguments: [
                "-s", configuration.serial,
                "push", configuration.serverPath,
                Self.deviceServerPath
            ],
            timeout: 15
        )
        guard result.status == 0 else {
            throw AndroidScrcpyError.adb(Self.commandError(result))
        }
    }

    private func createForward(socketName: String) throws -> Int {
        let result = try AndroidADBService.run(
            adb: configuration.adbPath,
            arguments: [
                "-s", configuration.serial,
                "forward", "tcp:0", "localabstract:\(socketName)"
            ],
            timeout: 5
        )
        let output = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, let port = Int(output), (1...65_535).contains(port) else {
            throw AndroidScrcpyError.adb(Self.commandError(result))
        }
        return port
    }

    private func launchServer(scid: UInt32) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.adbPath)
        var arguments = [
            "-s", configuration.serial,
            "shell",
            "CLASSPATH=\(Self.deviceServerPath)",
            "app_process", "/",
            "com.genymobile.scrcpy.Server",
            configuration.serverVersion,
            String(format: "scid=%08x", scid),
            "log_level=warn",
            "tunnel_forward=true",
            "control=false",
            "send_device_meta=false",
            "power_on=false",
            "video_codec=h264",
            "video_bit_rate=\(configuration.videoBitRate)",
            "max_size=\(configuration.maxSize)",
            "max_fps=\(configuration.maxFPS)"
        ]
        arguments.append(contentsOf: Self.serverAudioArguments(
            audioEnabled: configuration.audioEnabled,
            duplicateDeviceAudio: configuration.duplicateDeviceAudio
        ))
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendServerLog(data)
        }
        process.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try process.run()
            return process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw AndroidScrcpyError.adb(error.localizedDescription)
        }
    }

    private func readVideo(
        socket: Int32,
        decoder: WirelessH264Decoder,
        generation taskGeneration: UInt64
    ) throws {
        let codecID = try Self.readUInt32(socket: socket)
        guard codecID == Self.h264CodecID else {
            if codecID == 0 { throw AndroidScrcpyError.videoUnavailable }
            throw AndroidScrcpyError.unsupportedVideoCodec(codecID)
        }
        var pendingConfiguration = Data()
        while isActive(generation: taskGeneration) {
            let header = try Self.readExact(socket: socket, count: Self.packetHeaderSize)
            let flags = Self.uint64BE(header, offset: 0)
            if flags & Self.sessionPacketFlag != 0 {
                let width = Int(Self.uint32BE(header, offset: 4))
                let height = Int(Self.uint32BE(header, offset: 8))
                guard width > 0, height > 0 else {
                    throw AndroidScrcpyError.invalidPacket
                }
                onSessionSize(width, height)
                continue
            }

            let length = Int(Self.uint32BE(header, offset: 8))
            guard (1...Self.maximumPacketSize).contains(length) else {
                throw AndroidScrcpyError.invalidPacket
            }
            let payload = try Self.readExact(socket: socket, count: length)
            if flags & Self.configPacketFlag != 0 {
                pendingConfiguration.append(payload)
                continue
            }
            var accessUnit = Data()
            if !pendingConfiguration.isEmpty {
                accessUnit.append(pendingConfiguration)
                pendingConfiguration.removeAll(keepingCapacity: true)
            }
            accessUnit.append(payload)
            decoder.decode(WirelessH264Packet(
                presentationTimeMicroseconds: flags & Self.presentationTimeMask,
                isKeyFrame: flags & Self.keyFramePacketFlag != 0,
                annexBPayload: accessUnit
            ))
        }
        throw CancellationError()
    }

    private func readAudio(socket: Int32, generation taskGeneration: UInt64) {
        do {
            let codecID = try Self.readUInt32(socket: socket)
            guard codecID == Self.rawAudioCodecID else {
                if codecID == 0 { return }
                throw AndroidScrcpyError.unsupportedAudioCodec(codecID)
            }
            while isActive(generation: taskGeneration) {
                let header = try Self.readExact(socket: socket, count: Self.packetHeaderSize)
                let flags = Self.uint64BE(header, offset: 0)
                guard flags & Self.sessionPacketFlag == 0 else { continue }
                let length = Int(Self.uint32BE(header, offset: 8))
                guard length > 0,
                      length <= Self.maximumPacketSize,
                      length.isMultiple(of: Self.rawAudioBytesPerFrame) else {
                    throw AndroidScrcpyError.invalidPacket
                }
                let payload = try Self.readExact(socket: socket, count: length)
                guard flags & Self.configPacketFlag == 0 else { continue }
                if let sampleBuffer = ScrcpyPCMSampleBufferFactory.make(
                    data: payload,
                    presentationTimeMicroseconds: flags & Self.presentationTimeMask
                ) {
                    onAudio(sampleBuffer)
                }
            }
        } catch {
            if isActive(generation: taskGeneration) {
                deliverFailure(error, generation: taskGeneration)
            }
        }
    }

    private func register(socket: Int32, generation taskGeneration: UInt64) {
        stateLock.withLock {
            guard generation == taskGeneration else {
                Darwin.close(socket)
                return
            }
            sockets.insert(socket)
        }
    }

    private func closeSocket(_ socket: Int32) {
        guard socket >= 0 else { return }
        let shouldClose = stateLock.withLock { sockets.remove(socket) != nil }
        if shouldClose {
            Darwin.shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
    }

    private func removeForward(port: Int) {
        let adb = configuration.adbPath
        let serial = configuration.serial
        DispatchQueue.global(qos: .utility).async {
            _ = try? AndroidADBService.run(
                adb: adb,
                arguments: ["-s", serial, "forward", "--remove", "tcp:\(port)"],
                timeout: 3
            )
        }
    }

    private func checkActive(generation taskGeneration: UInt64) throws {
        guard isActive(generation: taskGeneration) else { throw CancellationError() }
    }

    private func isActive(generation taskGeneration: UInt64) -> Bool {
        stateLock.withLock { generation == taskGeneration && !stopping }
    }

    private func deliverFailure(_ error: Error, generation taskGeneration: UInt64) {
        let shouldDeliver = stateLock.withLock { () -> Bool in
            guard generation == taskGeneration, !stopping, !failureDelivered else { return false }
            failureDelivered = true
            return true
        }
        if shouldDeliver { onFailure(error) }
    }

    private func appendServerLog(_ data: Data) {
        stateLock.withLock {
            serverLog.append(data)
            if serverLog.count > 8_192 {
                serverLog = Data(serverLog.suffix(8_192))
            }
        }
    }

    private func lastServerLog() -> String {
        stateLock.withLock {
            String(decoding: serverLog, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func scid(for serial: String, generation: UInt64) -> UInt32 {
        let hash = serial.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return UInt32(truncatingIfNeeded: (hash ^ generation) & 0x7FFF_FFFF)
    }

    private static func connectFirstSocket(
        port: Int,
        isActive: () -> Bool
    ) throws -> Int32 {
        var lastError = AndroidScrcpyError.cannotConnect
        for _ in 0..<100 where isActive() {
            do {
                let socket = try connectSocket(port: port, receiveTimeoutMilliseconds: 250)
                do {
                    _ = try readExact(socket: socket, count: 1)
                    try setReceiveTimeout(socket: socket, milliseconds: 0)
                    return socket
                } catch {
                    Darwin.close(socket)
                    lastError = .cannotConnect
                }
            } catch let error as AndroidScrcpyError {
                lastError = error
            } catch {
                lastError = .cannotConnect
            }
            usleep(100_000)
        }
        throw lastError
    }

    private static func connectSocket(
        port: Int,
        receiveTimeoutMilliseconds: Int = 0
    ) throws -> Int32 {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { throw AndroidScrcpyError.cannotConnect }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        do {
            try setReceiveTimeout(
                socket: socketFD,
                milliseconds: receiveTimeoutMilliseconds
            )
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw AndroidScrcpyError.cannotConnect }
            return socketFD
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    private static func setReceiveTimeout(socket: Int32, milliseconds: Int) throws {
        var timeout = timeval(
            tv_sec: milliseconds / 1_000,
            tv_usec: Int32(milliseconds % 1_000) * 1_000
        )
        guard setsockopt(
            socket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        ) == 0 else {
            throw AndroidScrcpyError.cannotConnect
        }
    }

    private static func readUInt32(socket: Int32) throws -> UInt32 {
        uint32BE(try readExact(socket: socket, count: 4), offset: 0)
    }

    private static func readExact(socket: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let received = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < count {
                let result = Darwin.recv(socket, base.advanced(by: offset), count - offset, 0)
                if result == 0 { return offset }
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += result
            }
            return offset
        }
        guard received == count else { throw AndroidScrcpyError.streamClosed }
        return data
    }

    private static func uint32BE(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }

    private static func uint64BE(_ data: Data, offset: Int) -> UInt64 {
        let upper = UInt64(uint32BE(data, offset: offset))
        let lower = UInt64(uint32BE(data, offset: offset + 4))
        return upper << 32 | lower
    }

    /// Android 13+ can capture playback and keep the speaker. Older versions
    /// mute the phone when output audio is captured.
    nonisolated static func shouldDuplicateDeviceAudio(sdkVersion: Int?) -> Bool {
        (sdkVersion ?? 0) >= 33
    }

    nonisolated static func serverAudioArguments(
        audioEnabled: Bool,
        duplicateDeviceAudio: Bool
    ) -> [String] {
        guard audioEnabled else { return ["audio=false"] }
        var arguments = ["audio=true", "audio_codec=raw"]
        if duplicateDeviceAudio {
            arguments.append(contentsOf: ["audio_source=playback", "audio_dup=true"])
        }
        return arguments
    }

    private static func commandError(_ result: AndroidADBService.CommandResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return "ADB exited with status \(result.status)."
    }

    private static let deviceServerPath = "/data/local/tmp/stupidmirror-scrcpy-server.jar"
    private static let packetHeaderSize = 12
    private static let maximumPacketSize = 32 * 1_024 * 1_024
    private static let rawAudioBytesPerFrame = 4
    private static let sessionPacketFlag = UInt64(1) << 63
    private static let configPacketFlag = UInt64(1) << 62
    private static let keyFramePacketFlag = UInt64(1) << 61
    private static let presentationTimeMask = keyFramePacketFlag - 1
    private static let h264CodecID: UInt32 = 0x6832_3634
    private static let rawAudioCodecID: UInt32 = 0x0072_6177
}

private enum ScrcpyPCMSampleBufferFactory {
    static func make(data: Data, presentationTimeMicroseconds: UInt64) -> CMSampleBuffer? {
        guard !data.isEmpty, data.count.isMultiple(of: 4) else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
        let blockBuffer,
        data.withUnsafeBytes({ bytes in
            guard let base = bytes.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            ) == kCMBlockBufferNoErr
        }) else { return nil }

        let frameCount = data.count / 4
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(
                value: Int64(clamping: presentationTimeMicroseconds),
                timescale: 1_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

enum AndroidScrcpyError: LocalizedError, Equatable {
    case adb(String)
    case cannotConnect
    case streamClosed
    case streamEnded(String)
    case videoUnavailable
    case unsupportedVideoCodec(UInt32)
    case unsupportedAudioCodec(UInt32)
    case invalidPacket

    var errorDescription: String? {
        switch self {
        case let .adb(message):
            "ADB error: \(message)"
        case .cannotConnect:
            "Could not connect to the Android screen service."
        case .streamClosed:
            "The Android screen stream closed."
        case let .streamEnded(log):
            log.isEmpty ? "The Android screen service exited." : "The Android screen service exited: \(log)"
        case .videoUnavailable:
            "This Android device could not start screen capture."
        case let .unsupportedVideoCodec(codec):
            String(format: "Unsupported Android video codec 0x%08x.", codec)
        case let .unsupportedAudioCodec(codec):
            String(format: "Unsupported Android audio codec 0x%08x.", codec)
        case .invalidPacket:
            "The Android screen service returned an invalid media packet."
        }
    }
}
