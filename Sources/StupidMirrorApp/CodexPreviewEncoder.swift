@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// Hardware H264 for the live view. Still-image observation/annotation keeps
/// using native-resolution PNG; video never goes through MCP JSON responses.
final class CodexPreviewEncoder: @unchecked Sendable {
    typealias Output = @Sendable (Data, Double) -> Void
    private let queue = DispatchQueue(label: "StupidMirror.CodexPreviewEncoder", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: CMSampleBuffer?
    private var scheduled = false
    private var stopped = false
    private var forceKeyFrame = true
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var lastFrameTime: TimeInterval?
    private let output: Output

    init(output: @escaping Output) { self.output = output }

    func submit(_ sample: CMSampleBuffer) {
        let schedule = lock.withLock {
            guard !stopped else { return false }
            pending = sample
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule { queue.async { [weak self] in self?.drain() } }
    }

    func requestKeyFrame() { lock.withLock { forceKeyFrame = true } }

    func stop() {
        lock.withLock { stopped = true; pending = nil }
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
        }
    }

    private func drain() {
        let sample = lock.withLock { () -> CMSampleBuffer? in
            scheduled = false
            let value = pending
            pending = nil
            return stopped ? nil : value
        }
        guard let sample, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastFrameTime, now - lastFrameTime < 0.9 / 30.0 { return }
        let duration = min(0.2, lastFrameTime.map { now - $0 } ?? 1.0 / 30.0)
        lastFrameTime = now
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        if session == nil || w != width || h != height { configure(width: w, height: h) }
        guard let session else { return }
        let keyFrame = lock.withLock { let value = forceKeyFrame; forceKeyFrame = false; return value }
        let properties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let timestamp = CMTime(seconds: now, preferredTimescale: 90_000)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: timestamp,
            duration: CMTime(seconds: duration, preferredTimescale: 90_000),
            frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
    }

    private func configure(width: Int, height: Int) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        self.width = width; self.height = height
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sample in
                guard status == noErr, let sample, let refcon else { return }
                let encoder = Unmanaged<CodexPreviewEncoder>.fromOpaque(refcon).takeUnretainedValue()
                if let data = CodexPreviewEncoder.annexB(sample) {
                    let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
                    encoder.output(data, duration.isFinite && duration > 0 ? duration : 1.0 / 30.0)
                }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created
        )
        guard status == noErr, let created else { return }
        session = created
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 16_000_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
        requestKeyFrame()
    }

    static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        let startCode = Data([0, 0, 0, 1])
        var data = Data()
        if keyFrame {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    data.append(startCode); data.append(pointer, count: size)
                }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 4 else { return nil }
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { return nil }
        var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size > 0, offset + size <= avcc.count else { return nil }
            data.append(startCode); data.append(avcc[offset..<offset + size]); offset += size
        }
        return data.isEmpty ? nil : data
    }
}
