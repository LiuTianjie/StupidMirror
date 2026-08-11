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

final class WirelessH264Decoder: @unchecked Sendable {
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
            fail(WirelessH264DecoderError.decodeFailed)
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
            fail(WirelessH264DecoderError.decodeFailed)
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
            flags: [._1xRealTimePlayback],
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer else {
                    self?.fail(WirelessH264DecoderError.decodeFailed)
                    return
                }
                self?.deliver(imageBuffer)
            }
        )
        if status != noErr {
            fail(WirelessH264DecoderError.decodeFailed)
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

    func resetForDiscontinuity() {
        guard let session else { return }
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
            fail(WirelessH264DecoderError.decodeFailed)
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
            fail(WirelessH264DecoderError.decodeFailed)
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

enum WirelessH264DecoderError: LocalizedError, Equatable {
    case decodeFailed

    var errorDescription: String? {
        "无线 H.264 画面解码失败。"
    }
}
