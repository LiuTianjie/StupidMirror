@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// What `stop_recording` reports.
struct MirrorRecordingResult: Codable, Equatable, Sendable {
    let path: String
    let durationSeconds: Double
    let frameCount: Int
    let width: Int
    let height: Int
    /// Set when the recording ended on its own before `stop_recording`.
    let stoppedReason: String?

    enum CodingKeys: String, CodingKey {
        case path
        case durationSeconds = "duration_seconds"
        case frameCount = "frame_count"
        case width, height
        case stoppedReason = "stopped_reason"
    }
}

enum MirrorRecorderError: LocalizedError, Equatable {
    case noFrames
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames:
            "No mirror frames arrived while recording. Start the mirror and keep the device screen on."
        case let .writerFailed(message):
            "The recording could not be written: \(message)"
        }
    }
}

/// Writes the live mirror frames of one device to an H.264 `.mp4`.
///
/// Frames come from `MirrorFrameStore`, which every capture path feeds with
/// decoded pixel buffers, so USB, Wi-Fi, Android and simulator recordings
/// share this writer. Frames are timed by arrival: a still screen sends few
/// frames and the movie simply holds the last one. The size is fixed by the
/// first frame; a rotated frame is fitted inside it.
final class MirrorRecorder: @unchecked Sendable {
    static let maximumDuration: TimeInterval = 600

    let outputURL: URL
    private let store: MirrorFrameStore
    private let queue = DispatchQueue(label: "com.stupidmirror.recorder")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var observerID: UUID?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var lastTime: CMTime = .invalid
    private var size: (width: Int, height: Int) = (0, 0)
    private var frameCount = 0
    private var failure: String?
    private var finished = false
    private var autoStopReason: String?
    private let pendingLock = NSLock()
    private var pending = 0

    init(store: MirrorFrameStore, outputURL: URL) {
        self.store = store
        self.outputURL = outputURL
    }

    func start() {
        let id = store.addObserver { [weak self] sampleBuffer in
            guard let self, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            // Capture buffers come from the capture source's own pool. Holding
            // more than a couple while the writer catches up would starve the
            // mirror, so a frame that arrives behind a backlog is skipped.
            guard pendingLock.withLock({
                guard pending < 2 else { return false }
                pending += 1
                return true
            }) else { return }
            queue.async {
                self.append(pixelBuffer, at: time)
                self.pendingLock.withLock { self.pending -= 1 }
            }
        }
        queue.sync { observerID = id }
    }

    /// Ends the recording and finishes the file. The last frame is held up to
    /// the moment of the call, so the movie runs for the whole recording.
    func stop() async throws -> MirrorRecordingResult {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        struct Ending {
            var writer: AVAssetWriter?
            var failure: String?
            var reason: String?
            var duration: Double = 0
        }
        let ending: Ending = queue.sync {
            stopObserving()
            guard !finished else { return Ending(failure: failure, reason: autoStopReason) }
            finished = true
            guard let writer, let startTime else { return Ending(failure: failure, reason: autoStopReason) }
            input?.markAsFinished()
            // An automatic stop already ended at the last frame it kept.
            let end = autoStopReason == nil ? stopTime : lastTime
            let length = CMTimeMaximum(CMTimeSubtract(end, startTime), .zero)
            writer.endSession(atSourceTime: length)
            return Ending(writer: writer, failure: failure, reason: autoStopReason, duration: CMTimeGetSeconds(length))
        }
        if let failure = ending.failure {
            ending.writer?.cancelWriting()
            throw MirrorRecorderError.writerFailed(failure)
        }
        guard let writer = ending.writer else {
            throw MirrorRecorderError.noFrames
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MirrorRecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        let (frames, width, height) = queue.sync { (frameCount, size.width, size.height) }
        return MirrorRecordingResult(
            path: outputURL.path,
            durationSeconds: (ending.duration * 10).rounded() / 10,
            frameCount: frames,
            width: width,
            height: height,
            stoppedReason: ending.reason
        )
    }

    // MARK: Writing (on `queue`)

    private func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !finished, failure == nil else { return }
        if writer == nil {
            do {
                try configure(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            } catch {
                failure = error.localizedDescription
                return
            }
            startTime = time
        }
        guard let writer, let input, let adaptor, let startTime else { return }
        guard writer.status == .writing else {
            failure = writer.error?.localizedDescription ?? "writer stopped"
            return
        }
        if CMTimeGetSeconds(CMTimeSubtract(time, startTime)) > Self.maximumDuration {
            autoStopReason = "Reached the \(Int(Self.maximumDuration / 60))-minute recording limit."
            stopObserving()
            return
        }
        // Timestamps must rise; a frame that arrives in the same tick is dropped.
        guard lastTime == .invalid || CMTimeCompare(time, lastTime) > 0 else { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let frame = fitted(pixelBuffer, pool: adaptor.pixelBufferPool) else { return }
        if adaptor.append(frame, withPresentationTime: CMTimeSubtract(time, startTime)) {
            lastTime = time
            frameCount += 1
        } else {
            failure = writer.error?.localizedDescription ?? "a frame could not be appended"
        }
    }

    private func configure(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw MirrorRecorderError.noFrames }
        // H.264 wants even dimensions.
        let evenWidth = width & ~1
        let evenHeight = height & ~1
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The owner picks a name nothing uses; never overwrite a file.
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw MirrorRecorderError.writerFailed("\(outputURL.lastPathComponent) already exists")
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(12_000_000, evenWidth * evenHeight * 4),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: evenWidth,
            kCVPixelBufferHeightKey as String: evenHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw MirrorRecorderError.writerFailed("the video track was refused") }
        writer.add(input)
        guard writer.startWriting() else {
            throw MirrorRecorderError.writerFailed(writer.error?.localizedDescription ?? "the file could not be opened")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        size = (evenWidth, evenHeight)
    }

    /// Draws the frame into a buffer of the recording's size: unchanged when
    /// it already fits, else scaled to fit and centred on black.
    private func fitted(_ pixelBuffer: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let target = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let extent = source.extent
        let image: CIImage
        if Int(extent.width) == size.width, Int(extent.height) == size.height {
            image = source
        } else {
            let scale = min(target.width / extent.width, target.height / extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let offset = CGAffineTransform(
                translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY
            )
            image = scaled.transformed(by: offset)
                .composited(over: CIImage(color: .black).cropped(to: target))
        }
        context.render(image, to: output, bounds: target, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    private func stopObserving() {
        let id = observerID
        observerID = nil
        if let id { store.removeObserver(id) }
    }
}
