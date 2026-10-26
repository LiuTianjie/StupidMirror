@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import libsrt
import OSLog

struct WirelessSRTFragment: Equatable, Sendable {
    static let magic = Data([0x53, 0x4D, 0x53, 0x32]) // SMS2
    static let headerSize = 24
    static let maximumMessageSize = 1_316
    static let maximumPayloadSize = maximumMessageSize - headerSize

    let frameID: UInt32
    let presentationTimeMicroseconds: UInt64
    let fragmentIndex: UInt16
    let fragmentCount: UInt16
    let isKeyFrame: Bool
    let payload: Data

    init?(message: Data) {
        guard message.count >= Self.headerSize,
              message.count <= Self.maximumMessageSize,
              message.prefix(Self.magic.count) == Self.magic else { return nil }
        let bytes = [UInt8](message)
        frameID = Self.readUInt32(bytes, at: 4)
        presentationTimeMicroseconds = Self.readUInt64(bytes, at: 8)
        fragmentIndex = Self.readUInt16(bytes, at: 16)
        fragmentCount = Self.readUInt16(bytes, at: 18)
        isKeyFrame = bytes[20] & 1 != 0
        guard fragmentCount > 0, fragmentIndex < fragmentCount else { return nil }
        payload = Data(bytes[Self.headerSize...])
        guard !payload.isEmpty else { return nil }
    }

    static func makeMessages(for packet: WirelessH264Packet, frameID: UInt32) -> [Data] {
        guard !packet.annexBPayload.isEmpty else { return [] }
        let count = Int(ceil(
            Double(packet.annexBPayload.count) / Double(maximumPayloadSize)
        ))
        guard count > 0, count <= Int(UInt16.max) else { return [] }
        return (0..<count).map { index in
            let start = index * maximumPayloadSize
            let end = min(start + maximumPayloadSize, packet.annexBPayload.count)
            var message = Data(Self.magic)
            appendBigEndian(frameID, to: &message)
            appendBigEndian(packet.presentationTimeMicroseconds, to: &message)
            appendBigEndian(UInt16(index), to: &message)
            appendBigEndian(UInt16(count), to: &message)
            message.append(packet.isKeyFrame ? 1 : 0)
            message.append(contentsOf: [0, 0, 0])
            message.append(packet.annexBPayload[start..<end])
            return message
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64.zero) { value, index in
            value << 8 | UInt64(bytes[offset + index])
        }
    }

    private static func appendBigEndian(_ value: UInt16, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendBigEndian(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

struct WirelessSRTReassemblyResult: Equatable, Sendable {
    let frame: WirelessH264Packet?
    let shouldRequestKeyFrame: Bool
    let shouldResetDecoder: Bool
}

struct WirelessSRTFrameReassembler: Sendable {
    static let maximumFrameBytes = 16 * 1_024 * 1_024
    private let maximumPayloadBytes: Int
    private var frameID: UInt32?
    private var presentationTimeMicroseconds: UInt64 = 0
    private var fragmentCount: UInt16 = 0
    private var nextFragmentIndex: UInt16 = 0
    private var keyFrame = false
    private var payload = Data()
    private var lastCompletedFrameID: UInt32?
    private var waitingForKeyFrame = true

    init(maximumPayloadBytes: Int = Self.maximumFrameBytes) {
        precondition(maximumPayloadBytes > 0)
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    mutating func append(message: Data) -> WirelessSRTReassemblyResult {
        guard let fragment = WirelessSRTFragment(message: message) else {
            discardCurrentFrame()
            waitingForKeyFrame = true
            return WirelessSRTReassemblyResult(
                frame: nil,
                shouldRequestKeyFrame: true,
                shouldResetDecoder: true
            )
        }

        var discontinuity = false
        if fragment.fragmentIndex == 0 {
            if frameID != nil {
                discontinuity = true
            }
            if let lastCompletedFrameID,
               fragment.frameID != lastCompletedFrameID &+ 1 {
                discontinuity = true
            }
            if discontinuity {
                waitingForKeyFrame = true
            }
            beginFrame(fragment)
        } else if frameID != fragment.frameID
                    || fragment.fragmentCount != fragmentCount
                    || fragment.fragmentIndex != nextFragmentIndex
                    || fragment.presentationTimeMicroseconds != presentationTimeMicroseconds
                    || fragment.isKeyFrame != keyFrame {
            discardCurrentFrame()
            waitingForKeyFrame = true
            return WirelessSRTReassemblyResult(
                frame: nil,
                shouldRequestKeyFrame: true,
                shouldResetDecoder: true
            )
        }

        guard frameID == fragment.frameID else {
            return WirelessSRTReassemblyResult(
                frame: nil,
                shouldRequestKeyFrame: true,
                shouldResetDecoder: true
            )
        }
        guard fragment.payload.count <= maximumPayloadBytes - payload.count else {
            discardCurrentFrame()
            waitingForKeyFrame = true
            return WirelessSRTReassemblyResult(
                frame: nil,
                shouldRequestKeyFrame: true,
                shouldResetDecoder: true
            )
        }
        payload.append(fragment.payload)
        nextFragmentIndex = fragment.fragmentIndex &+ 1
        guard nextFragmentIndex == fragmentCount else {
            if discontinuity {
                waitingForKeyFrame = true
            }
            return WirelessSRTReassemblyResult(
                frame: nil,
                shouldRequestKeyFrame: discontinuity,
                shouldResetDecoder: discontinuity
            )
        }

        let completedFrameID = fragment.frameID
        let completedIsKeyFrame = keyFrame
        let completed = WirelessH264Packet(
            presentationTimeMicroseconds: presentationTimeMicroseconds,
            isKeyFrame: completedIsKeyFrame,
            annexBPayload: payload
        )
        lastCompletedFrameID = completedFrameID
        discardCurrentFrame()

        if waitingForKeyFrame, !completedIsKeyFrame {
            return WirelessSRTReassemblyResult(
                frame: nil,
                shouldRequestKeyFrame: true,
                shouldResetDecoder: discontinuity
            )
        }
        if completedIsKeyFrame {
            waitingForKeyFrame = false
        }
        return WirelessSRTReassemblyResult(
            frame: completed,
            shouldRequestKeyFrame: false,
            shouldResetDecoder: discontinuity
        )
    }

    mutating func reset() {
        discardCurrentFrame()
        lastCompletedFrameID = nil
        waitingForKeyFrame = true
    }

    private mutating func beginFrame(_ fragment: WirelessSRTFragment) {
        frameID = fragment.frameID
        presentationTimeMicroseconds = fragment.presentationTimeMicroseconds
        fragmentCount = fragment.fragmentCount
        nextFragmentIndex = 0
        keyFrame = fragment.isKeyFrame
        payload = Data()
    }

    private mutating func discardCurrentFrame() {
        frameID = nil
        presentationTimeMicroseconds = 0
        fragmentCount = 0
        nextFragmentIndex = 0
        keyFrame = false
        payload = Data()
    }
}

/// Protected by the stream's state lock. Admission happens on the receiver,
/// before submitting any decode work, so queued Dispatch blocks cannot retain
/// an unbounded second backlog of compressed frames.
struct WirelessH264DecodeBuffer: Sendable {
    struct Work: Equatable, Sendable {
        let resetDecoder: Bool
        let frame: WirelessH264Packet?
    }

    private let maximumFrames: Int
    private let maximumBytes: Int
    private var frames: [WirelessH264Packet] = []
    private var byteCount = 0
    private var resetPending = false
    private(set) var waitingForKeyFrame = true
    private(set) var overloadResets = 0
    private(set) var droppedFrames = 0
    private(set) var peakFrames = 0
    private(set) var peakBytes = 0

    init(maximumFrames: Int = 2, maximumBytes: Int = WirelessSRTFrameReassembler.maximumFrameBytes) {
        precondition(maximumFrames > 0 && maximumBytes > 0)
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
    }

    var hasWork: Bool { resetPending || !frames.isEmpty }
    var pendingFrameCount: Int { frames.count }
    var pendingByteCount: Int { byteCount }

    /// Returns true when recovery needs a new IDR. P frames can never replace
    /// other P frames: a dropped reference invalidates the entire queued chain.
    mutating func append(_ frame: WirelessH264Packet) -> Bool {
        guard frame.annexBPayload.count <= maximumBytes else {
            overloadResets += 1
            droppedFrames += 1
            resetForDiscontinuity()
            return true
        }
        if waitingForKeyFrame && !frame.isKeyFrame {
            droppedFrames += 1
            return true
        }
        if frames.count >= maximumFrames || frame.annexBPayload.count > maximumBytes - byteCount {
            overloadResets += 1
            resetForDiscontinuity()
            if !frame.isKeyFrame {
                droppedFrames += 1
                return true
            }
        }
        if frame.isKeyFrame { waitingForKeyFrame = false }
        frames.append(frame)
        byteCount += frame.annexBPayload.count
        peakFrames = max(peakFrames, frames.count)
        peakBytes = max(peakBytes, byteCount)
        return false
    }

    mutating func resetForDiscontinuity() {
        droppedFrames += frames.count
        frames.removeAll(keepingCapacity: true)
        byteCount = 0
        waitingForKeyFrame = true
        resetPending = true
    }

    mutating func take() -> Work? {
        guard hasWork else { return nil }
        let reset = resetPending
        resetPending = false
        let frame = frames.isEmpty ? nil : frames.removeFirst()
        byteCount -= frame?.annexBPayload.count ?? 0
        return Work(resetDecoder: reset, frame: frame)
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: false)
        byteCount = 0
        resetPending = false
        waitingForKeyFrame = true
    }
}

final class WirelessSRTH264Stream: @unchecked Sendable {
    private static let keyFrameRequest = Data([0x53, 0x4D, 0x4B, 0x46]) // SMKF
    private static let startupResult: Int32 = srt_startup()
    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "WirelessSRT")

    private let host: String
    private let port: Int
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let receiveQueue = DispatchQueue(
        label: "stupidmirror.wireless-srt.receive",
        qos: .userInitiated
    )
    private let decodeQueue = DispatchQueue(
        label: "stupidmirror.wireless-srt.decode",
        qos: .userInteractive
    )
    private let controlQueue = DispatchQueue(
        label: "stupidmirror.wireless-srt.control",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var decoder: WirelessH264Decoder?
    private var reassembler = WirelessSRTFrameReassembler()
    private var decodeBuffer = WirelessH264DecodeBuffer()
    private var decodeScheduled = false
    private var started = false
    private var deliveredFrame = false
    private var stopped = false
    private var failureDelivered = false
    private var lastDecodedFrameUptime: TimeInterval?
    private var lastKeyFrameRequestUptime = TimeInterval.zero
    private var keyFrameRequestScheduled = false
    private var forceKeyFrameRequest = false
    private var receivedFrames = 0
    private var decodedFrames = 0
    private var lastStatisticsUptime = ProcessInfo.processInfo.systemUptime
    private var firstFrameTimeout: DispatchWorkItem?
    private var stallWatchdog: DispatchSourceTimer?

    init(
        host: String,
        port: Int = 9_200,
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.host = host
        self.port = port
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() {
        guard stateLock.withLock({
            guard !started, !stopped else { return false }
            started = true
            return true
        }) else { return }
        guard Self.startupResult == 0 else {
            failOnce(WirelessSRTStreamError.libraryStartupFailed)
            return
        }
        decodeQueue.async { [weak self] in
            guard let self, stateLock.withLock({ !stopped }) else { return }
            decoder = WirelessH264Decoder(
                onFrame: { [weak self] frame in self?.receiveDecodedFrame(frame) },
                onFailure: { [weak self] error in self?.failOnce(error) }
            )
        }
        scheduleFirstFrameTimeout()
        startStallWatchdog()
        receiveQueue.async { [weak self] in self?.connectAndReceive() }
    }

    func stop() {
        let activeSocket: SRTSOCKET? = stateLock.withLock {
            guard !stopped else { return nil }
            stopped = true
            decodeBuffer.removeAll()
            keyFrameRequestScheduled = false
            forceKeyFrameRequest = false
            firstFrameTimeout?.cancel()
            firstFrameTimeout = nil
            stallWatchdog?.cancel()
            stallWatchdog = nil
            let activeSocket = socket
            socket = SRT_INVALID_SOCK
            return activeSocket
        }
        guard let activeSocket else { return }
        if activeSocket != SRT_INVALID_SOCK {
            // Sends and closes share this queue. Never close/reuse a socket
            // between a control request's state check and srt_sendmsg.
            controlQueue.async { srt_close(activeSocket) }
        }
        // VT output callbacks finish synchronously with decode(). Waiting here
        // could deadlock if a callback's consumer is the caller of stop().
        decodeQueue.async { [self] in
            decoder?.stop()
            decoder = nil
        }
    }

    private func connectAndReceive() {
        let candidate = srt_create_socket()
        guard candidate != SRT_INVALID_SOCK else {
            failOnce(makeSRTError(.connectionFailed))
            return
        }
        var registered = false
        do {
            try configure(candidate)
            let shouldContinue = stateLock.withLock { () -> Bool in
                guard !stopped else { return false }
                socket = candidate
                return true
            }
            guard shouldContinue else {
                srt_close(candidate)
                return
            }
            registered = true
            try connect(candidate)
            requestRecoveryKeyFrame(force: true)
            receiveMessages(from: candidate)
        } catch {
            if registered { closeIfCurrent(candidate) }
            else { srt_close(candidate) }
            failOnce(error)
        }
    }

    private func configure(_ socket: SRTSOCKET) throws {
        var transport = Int32(SRTT_LIVE.rawValue)
        try setOption(socket, SRTO_TRANSTYPE, &transport)
        var receiveLatency: Int32 = 80
        try setOption(socket, SRTO_RCVLATENCY, &receiveLatency)
        var tooLateDrop = true
        try setOption(socket, SRTO_TLPKTDROP, &tooLateDrop)
        var nakReport = true
        try setOption(socket, SRTO_NAKREPORT, &nakReport)
        var reorderTolerance: Int32 = 32
        try setOption(socket, SRTO_LOSSMAXTTL, &reorderTolerance)
        var receiveTimeout: Int32 = 1_000
        try setOption(socket, SRTO_RCVTIMEO, &receiveTimeout)
        // A keyframe request must never block the control queue/watchdog.
        // The TTL in srt_sendmsg is not a send timeout.
        var synchronousSend = false
        try setOption(socket, SRTO_SNDSYN, &synchronousSend)
        var connectTimeout: Int32 = 4_000
        try setOption(socket, SRTO_CONNTIMEO, &connectTimeout)
        var peerIdleTimeout: Int32 = 4_000
        try setOption(socket, SRTO_PEERIDLETIMEO, &peerIdleTimeout)
    }

    private func setOption<T>(
        _ socket: SRTSOCKET,
        _ option: SRT_SOCKOPT,
        _ value: inout T
    ) throws {
        let status = withUnsafePointer(to: &value) {
            srt_setsockflag(socket, option, $0, Int32(MemoryLayout<T>.size))
        }
        guard status != SRT_ERROR else { throw makeSRTError(.configurationFailed) }
    }

    private func connect(_ socket: SRTSOCKET) throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0 else {
            throw WirelessSRTStreamError.addressResolutionFailed
        }
        defer { freeaddrinfo(addresses) }
        var address = addresses
        while let current = address {
            if srt_connect(socket, current.pointee.ai_addr, Int32(current.pointee.ai_addrlen)) != SRT_ERROR {
                return
            }
            address = current.pointee.ai_next
        }
        throw makeSRTError(.connectionFailed)
    }

    private func receiveMessages(from socket: SRTSOCKET) {
        var buffer = Data(count: WirelessSRTFragment.maximumMessageSize)
        while stateLock.withLock({ !stopped && self.socket == socket }) {
            let received: Int32 = buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return SRT_ERROR }
                return srt_recvmsg(
                    socket,
                    baseAddress.assumingMemoryBound(to: CChar.self),
                    Int32(rawBuffer.count)
                )
            }
            if received > 0 {
                autoreleasepool { processMessage(buffer.prefix(Int(received))) }
                continue
            }
            if srt_getsockstate(socket) == SRTS_CONNECTED {
                continue
            }
            break
        }
        closeIfCurrent(socket)
        let shouldFail = stateLock.withLock { !stopped && !failureDelivered }
        if shouldFail {
            failOnce(WirelessSRTStreamError.connectionEnded)
        }
    }

    private func processMessage(_ message: Data) {
        let result = reassembler.append(message: message)
        var requestKeyFrame = result.shouldRequestKeyFrame
        let scheduleDecode = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            if result.shouldResetDecoder { decodeBuffer.resetForDiscontinuity() }
            if let frame = result.frame {
                receivedFrames += 1
                requestKeyFrame = decodeBuffer.append(frame) || requestKeyFrame
            }
            guard decodeBuffer.hasWork, !decodeScheduled else { return false }
            decodeScheduled = true
            return true
        }
        if requestKeyFrame { requestRecoveryKeyFrame() }
        if scheduleDecode {
            decodeQueue.async { [weak self] in self?.drainFrames() }
        }
    }

    private func sendPendingKeyFrameRequest() {
        let now = ProcessInfo.processInfo.systemUptime
        let request = stateLock.withLock { () -> (socket: SRTSOCKET, delay: TimeInterval)? in
            guard !stopped, socket != SRT_INVALID_SOCK else {
                keyFrameRequestScheduled = false
                forceKeyFrameRequest = false
                return nil
            }
            let delay = forceKeyFrameRequest ? 0 : max(0, 0.2 - (now - lastKeyFrameRequestUptime))
            if delay == 0 {
                keyFrameRequestScheduled = false
                forceKeyFrameRequest = false
                lastKeyFrameRequestUptime = now
            }
            return (socket, delay)
        }
        guard let request else { return }
        if request.delay > 0 {
            // Keep the scheduled flag set: all intervening recovery requests
            // coalesce into this one delayed send, without retaining frames.
            controlQueue.asyncAfter(deadline: .now() + request.delay) { [weak self] in
                self?.sendPendingKeyFrameRequest()
            }
            return
        }
        _ = Self.keyFrameRequest.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return SRT_ERROR }
            return srt_sendmsg(
                request.socket,
                baseAddress.assumingMemoryBound(to: CChar.self),
                Int32(rawBuffer.count),
                200,
                0
            )
        }
    }

    private func drainFrames() {
        while true {
            let work = stateLock.withLock { () -> WirelessH264DecodeBuffer.Work? in
                guard !stopped, let work = decodeBuffer.take() else {
                    decodeScheduled = false
                    return nil
                }
                return work
            }
            guard let work else { return }
            // Keep VT synchronous: at most one frame is in flight in addition
            // to the bounded pending buffer. No state lock spans callbacks.
            autoreleasepool {
                if work.resetDecoder { decoder?.resetForDiscontinuity() }
                if let frame = work.frame { decoder?.decode(frame) }
            }
        }
    }

    private func requestRecoveryKeyFrame(force: Bool = false) {
        let schedule = stateLock.withLock { () -> Bool in
            guard !stopped, socket != SRT_INVALID_SOCK else { return false }
            forceKeyFrameRequest = forceKeyFrameRequest || force
            guard !keyFrameRequestScheduled else { return false }
            keyFrameRequestScheduled = true
            return true
        }
        if schedule {
            controlQueue.async { [weak self] in self?.sendPendingKeyFrameRequest() }
        }
    }

    private func closeIfCurrent(_ candidate: SRTSOCKET) {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard socket == candidate else { return false }
            socket = SRT_INVALID_SOCK
            return true
        }
        if shouldClose { controlQueue.async { srt_close(candidate) } }
    }

    private func scheduleFirstFrameTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldFail = stateLock.withLock { !stopped && !deliveredFrame }
            if shouldFail { failOnce(WirelessSRTStreamError.firstFrameTimedOut) }
        }
        let schedule = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            firstFrameTimeout = timeout
            return true
        }
        if schedule { controlQueue.asyncAfter(deadline: .now() + 8, execute: timeout) }
    }

    private func startStallWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let shouldFail = stateLock.withLock {
                !stopped && !failureDelivered && deliveredFrame
                    && lastDecodedFrameUptime.map {
                        ProcessInfo.processInfo.systemUptime - $0 >= 3
                    } == true
            }
            reportStatisticsIfNeeded()
            if shouldFail { failOnce(WirelessSRTStreamError.streamStalled) }
            else if stateLock.withLock({ !stopped && decodeBuffer.waitingForKeyFrame }) {
                requestRecoveryKeyFrame()
            }
        }
        timer.resume()
        stateLock.withLock {
            if stopped { timer.cancel() }
            else { stallWatchdog = timer }
        }
    }

    private func receiveDecodedFrame(_ sampleBuffer: CMSampleBuffer) {
        let shouldDeliver = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            deliveredFrame = true
            decodedFrames += 1
            lastDecodedFrameUptime = ProcessInfo.processInfo.systemUptime
            firstFrameTimeout?.cancel()
            firstFrameTimeout = nil
            return true
        }
        if shouldDeliver { onFrame(sampleBuffer) }
    }

    private func reportStatisticsIfNeeded() {
        let statistics = stateLock.withLock { () -> String? in
            let now = ProcessInfo.processInfo.systemUptime
            guard !stopped, now - lastStatisticsUptime >= 5 else { return nil }
            lastStatisticsUptime = now
            return "received=\(receivedFrames) decoded=\(decodedFrames) overload_resets=\(decodeBuffer.overloadResets) dropped=\(decodeBuffer.droppedFrames) pending=\(decodeBuffer.pendingFrameCount) peak_pending=\(decodeBuffer.peakFrames) pending_bytes=\(decodeBuffer.pendingByteCount) peak_bytes=\(decodeBuffer.peakBytes) waiting_idr=\(decodeBuffer.waitingForKeyFrame)"
        }
        if let statistics {
            Self.logger.info("SRT \(self.host, privacy: .public):\(self.port) video \(statistics, privacy: .public)")
        }
    }

    private func makeSRTError(_ fallback: WirelessSRTStreamError) -> Error {
        let message = String(cString: srt_getlasterror_str())
        return message.isEmpty ? fallback : WirelessSRTStreamError.libraryError(message)
    }

    private func failOnce(_ error: Error) {
        let shouldDeliver = stateLock.withLock { () -> Bool in
            guard !stopped, !failureDelivered else { return false }
            failureDelivered = true
            firstFrameTimeout?.cancel()
            firstFrameTimeout = nil
            return true
        }
        if shouldDeliver {
            stop()
            onFailure(error)
        }
    }
}

enum WirelessSRTStreamError: LocalizedError, Equatable {
    case libraryStartupFailed
    case addressResolutionFailed
    case configurationFailed
    case connectionFailed
    case connectionEnded
    case firstFrameTimedOut
    case streamStalled
    case libraryError(String)

    var errorDescription: String? {
        switch self {
        case .libraryStartupFailed:
            "SRT 视频传输组件启动失败。"
        case .addressResolutionFailed:
            "无法解析 iPhone 的无线地址。"
        case .configurationFailed:
            "无法配置 SRT 视频传输。"
        case .connectionFailed:
            "无法连接 iPhone 的 SRT 视频流。"
        case .connectionEnded:
            "iPhone 的 SRT 视频连接已断开。"
        case .firstFrameTimedOut:
            "无线视频流未收到首帧，请确认 iPhone 与 Mac 位于同一局域网。"
        case .streamStalled:
            "无线视频流已中断，请重试。"
        case let .libraryError(message):
            "SRT 视频传输失败：\(message)"
        }
    }
}
