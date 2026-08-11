@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct WirelessH264Packet: Equatable, Sendable {
    let presentationTimeMicroseconds: UInt64
    let isKeyFrame: Bool
    let annexBPayload: Data
}

enum WirelessH264FramerError: Error, Equatable {
    case invalidMagic
    case invalidPayloadLength
}

struct WirelessH264Framer: Sendable {
    static let magic = Data([0x53, 0x4D, 0x48, 0x31]) // SMH1
    static let headerLength = 16
    static let maximumPayloadLength = 32 * 1_024 * 1_024

    private var buffer = Data()
    private var consumedMagic = false

    mutating func append(_ data: Data) throws -> [WirelessH264Packet] {
        buffer.append(data)
        if !consumedMagic {
            guard buffer.count >= Self.magic.count else { return [] }
            guard buffer.prefix(Self.magic.count) == Self.magic else {
                throw WirelessH264FramerError.invalidMagic
            }
            buffer.removeFirst(Self.magic.count)
            consumedMagic = true
        }

        var packets: [WirelessH264Packet] = []
        while buffer.count >= Self.headerLength {
            let payloadLength = Int(readBigEndianUInt32(buffer, offset: 0))
            guard payloadLength > 0, payloadLength <= Self.maximumPayloadLength else {
                throw WirelessH264FramerError.invalidPayloadLength
            }
            let packetLength = Self.headerLength + payloadLength
            guard buffer.count >= packetLength else { break }
            let presentationTime = readBigEndianUInt64(buffer, offset: 4)
            let flags = buffer[buffer.index(buffer.startIndex, offsetBy: 12)]
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: Self.headerLength)
            let payloadEnd = buffer.index(payloadStart, offsetBy: payloadLength)
            packets.append(
                WirelessH264Packet(
                    presentationTimeMicroseconds: presentationTime,
                    isKeyFrame: flags & 1 == 1,
                    annexBPayload: Data(buffer[payloadStart..<payloadEnd])
                )
            )
            buffer.removeFirst(packetLength)
        }
        return packets
    }

    private func readBigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[data.index(data.startIndex, offsetBy: offset + index)])
        }
        return value
    }

    private func readBigEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[data.index(data.startIndex, offsetBy: offset + index)])
        }
        return value
    }
}

final class WirelessH264Stream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let stateLock = NSLock()
    private let decodeQueue = DispatchQueue(
        label: "stupidmirror.wireless-h264.decode",
        qos: .userInitiated
    )
    private var framer = WirelessH264Framer()
    private var decoder: WirelessH264Decoder?
    private var stopped = false
    private var deliveredFrame = false
    private var failureDelivered = false
    private var firstFrameTimeout: DispatchWorkItem?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        url: URL,
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.url = url
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.connectionProxyDictionary = [:]
        let delegateQueue = OperationQueue()
        delegateQueue.name = "stupidmirror.wireless-h264.network"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        self.session = session
        decoder = WirelessH264Decoder(
            onFrame: { [weak self] sampleBuffer in
                self?.receiveDecodedFrame(sampleBuffer)
            },
            onFailure: { [weak self] error in
                self?.failOnce(error)
            }
        )
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            stateLock.lock()
            let shouldFail = !stopped && !deliveredFrame
            stateLock.unlock()
            if shouldFail {
                failOnce(WirelessH264StreamError.firstFrameTimedOut)
            }
        }
        firstFrameTimeout = timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: timeout)
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        stateLock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        decodeQueue.sync {
            decoder?.stop()
            decoder = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.value(forHTTPHeaderField: "Content-Type") == "application/x-stupidmirror-h264" else {
            completionHandler(.cancel)
            failOnce(WirelessH264StreamError.unsupportedServer)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        do {
            let packets = try framer.append(data)
            stateLock.unlock()
            guard !packets.isEmpty else { return }
            decodeQueue.async { [weak self] in
                guard let self else { return }
                for packet in packets {
                    stateLock.lock()
                    let active = !stopped
                    stateLock.unlock()
                    guard active else { return }
                    decoder?.decode(packet)
                }
            }
        } catch {
            stateLock.unlock()
            failOnce(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let shouldReport = !stopped && !failureDelivered
        stateLock.unlock()
        guard shouldReport else { return }
        failOnce(error ?? WirelessH264StreamError.streamEnded)
    }

    private func receiveDecodedFrame(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        deliveredFrame = true
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        stateLock.unlock()
        onFrame(sampleBuffer)
    }

    private func failOnce(_ error: Error) {
        stateLock.lock()
        guard !stopped, !failureDelivered else {
            stateLock.unlock()
            return
        }
        failureDelivered = true
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        stateLock.unlock()
        onFailure(error)
    }
}

private final class WirelessH264Decoder: @unchecked Sendable {
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var configuredSequenceParameterSet: Data?
    private var configuredPictureParameterSet: Data?
    private var failed = false

    init(
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func decode(_ packet: WirelessH264Packet) {
        guard !failed else { return }
        let units = Self.annexBNALUnits(packet.annexBPayload)
        guard !units.isEmpty else { return }
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1F {
            case 7:
                sequenceParameterSet = unit
            case 8:
                pictureParameterSet = unit
            default:
                break
            }
        }
        if session == nil || packet.isKeyFrame {
            guard prepareSessionIfPossible() else { return }
        }
        guard let session, let formatDescription else { return }

        let frameUnits = units.filter { unit in
            guard let first = unit.first else { return false }
            let type = first & 0x1F
            return type != 7 && type != 8 && type != 9
        }
        guard !frameUnits.isEmpty else { return }
        var avcc = Data()
        for unit in frameUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
        let blockBuffer,
        avcc.withUnsafeBytes({ bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            ) == kCMBlockBufferNoErr
        }) else {
            fail(WirelessH264StreamError.decodeFailed)
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: Int64(clamping: packet.presentationTimeMicroseconds),
                timescale: 1_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer else {
            fail(WirelessH264StreamError.decodeFailed)
            return
        }
        if !packet.isKeyFrame,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
               sampleBuffer,
               createIfNecessary: true
           ),
           CFArrayGetCount(attachments) > 0,
           let raw = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer else {
                    self?.fail(WirelessH264StreamError.decodeFailed)
                    return
                }
                self?.deliver(imageBuffer)
            }
        )
        if status != noErr {
            fail(WirelessH264StreamError.decodeFailed)
        }
    }

    func stop() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        formatDescription = nil
        configuredSequenceParameterSet = nil
        configuredPictureParameterSet = nil
    }

    private func prepareSessionIfPossible() -> Bool {
        guard let sequenceParameterSet, let pictureParameterSet else { return false }
        if session != nil,
           configuredSequenceParameterSet == sequenceParameterSet,
           configuredPictureParameterSet == pictureParameterSet {
            return true
        }
        stop()

        var createdFormat: CMFormatDescription?
        let formatStatus = sequenceParameterSet.withUnsafeBytes { spsBytes in
            pictureParameterSet.withUnsafeBytes { ppsBytes in
                guard let sps = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_InvalidParameter)
                }
                let pointers = [sps, pps]
                let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &createdFormat
                        )
                    }
                }
            }
        }
        guard formatStatus == noErr,
              let createdFormat else {
            fail(WirelessH264StreamError.decodeFailed)
            return false
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var createdSession: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: nil,
            decompressionOutputRefCon: nil
        )
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: createdFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            fail(WirelessH264StreamError.decodeFailed)
            return false
        }
        formatDescription = createdFormat
        session = createdSession
        configuredSequenceParameterSet = sequenceParameterSet
        configuredPictureParameterSet = pictureParameterSet
        return true
    }

    private func deliver(_ imageBuffer: CVImageBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &format
        ) == noErr,
        let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer else { return }
        onFrame(sampleBuffer)
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        onFailure(error)
    }

    static func annexBNALUnits(_ data: Data) -> [Data] {
        guard data.count >= 5 else { return [] }
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return [] }
        return starts.enumerated().compactMap { item -> Data? in
            let payloadStart = item.element.offset + item.element.length
            let payloadEnd = item.offset + 1 < starts.count
                ? starts[item.offset + 1].offset
                : bytes.count
            guard payloadEnd > payloadStart else { return nil }
            return Data(bytes[payloadStart..<payloadEnd])
        }
    }
}

enum WirelessH264StreamError: LocalizedError {
    case unsupportedServer
    case firstFrameTimedOut
    case streamEnded
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            "The wireless H.264 stream is unavailable."
        case .firstFrameTimedOut:
            "The wireless H.264 stream did not produce a frame."
        case .streamEnded:
            "The wireless H.264 stream ended."
        case .decodeFailed:
            "The wireless H.264 frame could not be decoded."
        }
    }
}
