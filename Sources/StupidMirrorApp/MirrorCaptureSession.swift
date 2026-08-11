@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation
import ImageIO

final class MirrorCaptureSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let captureSession = AVCaptureSession()
    let device: AVCaptureDevice?
    let mjpegURL: URL?

    @Published private(set) var state: MirrorState = .stopped
    // Live aspect ratio read from actual frames, so the window can follow
    // device rotation instead of being locked to a static portrait profile.
    @Published private(set) var frameAspectRatio: Double?
    @Published private(set) var latestWirelessFrame: NSImage?

    private let sessionQueue = DispatchQueue(label: "stupidmirror.capture.session")
    private let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleBufferConsumerLock = NSLock()
    private var videoSampleBufferConsumer: (@Sendable (CMSampleBuffer) -> Void)?
    private var audioSampleBufferConsumer: (@Sendable (CMSampleBuffer) -> Void)?
    private var configured = false
    private var audioEnabled = false
    private var disposed = false
    private var lastObservedAspectRatio: Double?
    private var wirelessStream: WirelessMJPEGStream?
    private var wirelessH264Stream: WirelessH264Stream?
    private var wirelessH264Unavailable = false
    private var wirelessRetryTask: Task<Void, Never>?
    private var wirelessGeneration: UInt64 = 0
    private var wirelessStartedAt: Date?
    private var wirelessOnRunning: (@MainActor @Sendable () -> Void)?
    private var lastWirelessPreviewUpdate = Date.distantPast

    init(device: AVCaptureDevice) {
        self.device = device
        self.mjpegURL = nil
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    init(mjpegURL: URL) {
        self.device = nil
        self.mjpegURL = mjpegURL
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    deinit {
        clearSampleBufferConsumers()
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            tearDownOnSessionQueue()
        } else {
            sessionQueue.sync {
                tearDownOnSessionQueue()
            }
        }
    }

    @MainActor
    func start(onRunning: @escaping @MainActor @Sendable () -> Void = {}) {
        if state == .running {
            onRunning()
            return
        }
        guard state != .starting else { return }
        state = .starting

        if mjpegURL != nil {
            wirelessStartedAt = Date()
            wirelessOnRunning = onRunning
            wirelessH264Unavailable = false
            wirelessGeneration &+= 1
            startWirelessAttempt(generation: wirelessGeneration)
            return
        }

        sessionQueue.async { [self] in
            do {
                guard !disposed else { throw MirrorError.disposed }
                try configureIfNeeded()
                applyAudioEnabledOnSessionQueue()
                if !captureSession.isRunning {
                    captureSession.startRunning()
                }
                guard captureSession.isRunning else {
                    throw MirrorError.cannotStartSession
                }
                Task { @MainActor in
                    // stop() may have raced in while the queue was starting the
                    // session; don't resurrect the running state in that case.
                    guard self.state == .starting else { return }
                    self.state = .running
                    onRunning()
                }
            } catch {
                Task { @MainActor in
                    guard self.state == .starting else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    func stop() {
        state = .stopped
        wirelessGeneration &+= 1
        wirelessRetryTask?.cancel()
        wirelessRetryTask = nil
        wirelessH264Stream?.stop()
        wirelessH264Stream = nil
        wirelessStream?.stop()
        wirelessStream = nil
        wirelessH264Unavailable = false
        wirelessOnRunning = nil
        wirelessStartedAt = nil
        sessionQueue.async { [self] in
            stopRunningOnSessionQueue()
        }
    }

    @MainActor
    func failWirelessStart(_ message: String) {
        guard mjpegURL != nil, state == .starting else { return }
        wirelessGeneration &+= 1
        wirelessRetryTask?.cancel()
        wirelessRetryTask = nil
        wirelessH264Stream?.stop()
        wirelessH264Stream = nil
        wirelessStream?.stop()
        wirelessStream = nil
        wirelessOnRunning = nil
        wirelessStartedAt = nil
        state = .failed(message)
    }

    /// Permanently releases capture inputs, outputs, delegates, and consumers.
    /// A disposed mirror session cannot be restarted.
    @MainActor
    func dispose() {
        stop()
        clearSampleBufferConsumers()
        sessionQueue.async { [self] in
            disposed = true
            tearDownOnSessionQueue()
        }
    }

    /// Audio capture is opt-in so merely opening a mirror cannot implicitly
    /// trigger microphone access. Callers should only enable it after the
    /// system reports audio capture as authorized.
    nonisolated func setAudioEnabled(_ enabled: Bool) {
        sessionQueue.async { [self] in
            guard !disposed else { return }
            audioEnabled = enabled
            if configured {
                applyAudioEnabledOnSessionQueue()
            }
        }
    }

    nonisolated func setVideoSampleBufferConsumer(_ consumer: (@Sendable (CMSampleBuffer) -> Void)?) {
        sampleBufferConsumerLock.lock()
        videoSampleBufferConsumer = consumer
        sampleBufferConsumerLock.unlock()
    }

    nonisolated func setAudioSampleBufferConsumer(_ consumer: (@Sendable (CMSampleBuffer) -> Void)?) {
        sampleBufferConsumerLock.lock()
        audioSampleBufferConsumer = consumer
        sampleBufferConsumerLock.unlock()
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device else { throw MirrorError.missingCaptureSource }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        defer { captureSession.commitConfiguration() }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                throw MirrorError.cannotAddInput
            }
            captureSession.addInput(input)

            // A lightweight data output lets us read each frame's real pixel
            // dimensions and render through our own display layer instead of
            // AVCaptureVideoPreviewLayer's opaque color handling.
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            guard captureSession.canAddOutput(videoOutput) else {
                throw MirrorError.cannotAddVideoOutput
            }
            captureSession.addOutput(videoOutput)
            configured = true
        } catch {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            throw error
        }
    }

    private func applyAudioEnabledOnSessionQueue() {
        let hasAudioOutput = captureSession.outputs.contains { $0 === audioOutput }

        if audioEnabled {
            guard !hasAudioOutput, captureSession.canAddOutput(audioOutput) else { return }
            captureSession.beginConfiguration()
            audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            captureSession.addOutput(audioOutput)
            captureSession.commitConfiguration()
        } else {
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            guard hasAudioOutput else { return }
            captureSession.beginConfiguration()
            captureSession.removeOutput(audioOutput)
            captureSession.commitConfiguration()
        }
    }

    private func stopRunningOnSessionQueue() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func tearDownOnSessionQueue() {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        stopRunningOnSessionQueue()

        guard configured || !captureSession.inputs.isEmpty || !captureSession.outputs.isEmpty else { return }
        captureSession.beginConfiguration()
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        captureSession.commitConfiguration()
        configured = false
        lastObservedAspectRatio = nil
    }

    private func clearSampleBufferConsumers() {
        sampleBufferConsumerLock.lock()
        videoSampleBufferConsumer = nil
        audioSampleBufferConsumer = nil
        sampleBufferConsumerLock.unlock()
    }

    @MainActor
    private func startWirelessAttempt(generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting,
              let mjpegURL,
              !disposed else { return }

        if !wirelessH264Unavailable,
           var h264Components = URLComponents(url: mjpegURL, resolvingAgainstBaseURL: false) {
            h264Components.port = 9_200
            if let h264URL = h264Components.url {
                let stream = WirelessH264Stream(
                    url: h264URL,
                    onFrame: { [weak self] sampleBuffer in
                        self?.receiveWirelessSampleBuffer(
                            sampleBuffer,
                            jpegData: nil,
                            generation: generation
                        )
                    },
                    onFailure: { [weak self] error in
                        Task { @MainActor in
                            self?.handleWirelessH264Failure(error, generation: generation)
                        }
                    }
                )
                wirelessH264Stream?.stop()
                wirelessH264Stream = stream
                wirelessStream?.stop()
                wirelessStream = nil
                stream.start()
                return
            }
        }

        startWirelessMJPEGAttempt(mjpegURL: mjpegURL, generation: generation)
    }

    @MainActor
    private func startWirelessMJPEGAttempt(mjpegURL: URL, generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting || state == .running,
              !disposed else { return }

        let stream = WirelessMJPEGStream(
            url: mjpegURL,
            onFrame: { [weak self] jpegData in
                self?.receiveWirelessFrame(jpegData, generation: generation)
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.handleWirelessFailure(error, generation: generation)
                }
            }
        )
        wirelessStream?.stop()
        wirelessStream = stream
        stream.start()
    }

    private func receiveWirelessFrame(_ jpegData: Data, generation: UInt64) {
        guard let sampleBuffer = WirelessJPEGDecoder.sampleBuffer(from: jpegData) else { return }

        receiveWirelessSampleBuffer(
            sampleBuffer,
            jpegData: jpegData,
            generation: generation
        )
    }

    private func receiveWirelessSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        jpegData: Data?,
        generation: UInt64
    ) {

        sampleBufferConsumerLock.lock()
        let consumer = videoSampleBufferConsumer
        sampleBufferConsumerLock.unlock()
        consumer?(sampleBuffer)

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.height > 0 else { return }
        let ratio = Double(dimensions.width) / Double(dimensions.height)

        let previewSource = WirelessPreviewSource(
            sampleBuffer: sampleBuffer,
            jpegData: jpegData
        )
        Task { @MainActor [weak self, previewSource] in
            guard let self,
                  generation == self.wirelessGeneration,
                  self.state == .starting || self.state == .running else { return }
            if self.state == .starting {
                self.state = .running
                let onRunning = self.wirelessOnRunning
                self.wirelessOnRunning = nil
                onRunning?()
            }
            if self.frameAspectRatio == nil || abs((self.frameAspectRatio ?? ratio) - ratio) >= 0.01 {
                self.frameAspectRatio = ratio
            }
            let now = Date()
            if now.timeIntervalSince(self.lastWirelessPreviewUpdate) >= 0.5,
               let image = Self.previewImage(previewSource) {
                self.lastWirelessPreviewUpdate = now
                self.latestWirelessFrame = image
            }
        }
    }

    @MainActor
    private static func previewImage(_ source: WirelessPreviewSource) -> NSImage? {
        if let jpegData = source.jpegData, let image = NSImage(data: jpegData) {
            return image
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(source.sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let representation = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    @MainActor
    private func handleWirelessH264Failure(_ error: Error, generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting || state == .running,
              !disposed,
              let mjpegURL else { return }
        wirelessH264Unavailable = true
        wirelessH264Stream?.stop()
        wirelessH264Stream = nil
        startWirelessMJPEGAttempt(mjpegURL: mjpegURL, generation: generation)
    }

    @MainActor
    private func handleWirelessFailure(_ error: Error, generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting || state == .running,
              !disposed else { return }
        wirelessStream?.stop()
        wirelessStream = nil
        wirelessH264Stream?.stop()
        wirelessH264Stream = nil

        let elapsed = Date().timeIntervalSince(wirelessStartedAt ?? Date())
        guard elapsed < 120 else {
            state = .failed(error.localizedDescription)
            wirelessOnRunning = nil
            return
        }

        state = .starting
        wirelessRetryTask?.cancel()
        wirelessRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.startWirelessAttempt(generation: generation)
        }
    }

    // Reads frame dimensions off the capture stream and reports aspect
    // ratio only when it actually changes (e.g. the device rotates).
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            guard audioEnabled else { return }
            sampleBufferConsumerLock.lock()
            let consumer = audioSampleBufferConsumer
            sampleBufferConsumerLock.unlock()
            consumer?(sampleBuffer)
            return
        }

        sampleBufferConsumerLock.lock()
        let consumer = videoSampleBufferConsumer
        sampleBufferConsumerLock.unlock()
        consumer?(sampleBuffer)

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.height > 0 else { return }
        let ratio = Double(dimensions.width) / Double(dimensions.height)
        guard ratio > 0 else { return }
        if let lastObservedAspectRatio, abs(lastObservedAspectRatio - ratio) < 0.01 {
            return
        }
        lastObservedAspectRatio = ratio
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let last = self.frameAspectRatio, abs(last - ratio) < 0.01 { return }
            self.frameAspectRatio = ratio
        }
    }
}

private struct WirelessPreviewSource: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let jpegData: Data?
}

enum MirrorError: LocalizedError {
    case cannotAddInput
    case cannotAddVideoOutput
    case cannotStartSession
    case disposed
    case missingCaptureSource

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "Cannot add this iPhone screen source to the capture session."
        case .cannotAddVideoOutput:
            "Cannot add a video output for this iPhone screen source."
        case .cannotStartSession:
            "The iPhone screen capture session could not start."
        case .disposed:
            "This mirror capture session has already been disposed."
        case .missingCaptureSource:
            "The mirror capture source is unavailable."
        }
    }
}

private final class WirelessMJPEGStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let jpegStart = Data([0xFF, 0xD8])
    private static let jpegEnd = Data([0xFF, 0xD9])
    private static let maximumBufferSize = 32 * 1_024 * 1_024

    private let url: URL
    private let onFrame: @Sendable (Data) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let stateLock = NSLock()
    private let frameDecodeQueue = DispatchQueue(
        label: "stupidmirror.wireless-mjpeg.decode",
        qos: .userInitiated
    )
    private var buffer = Data()
    private var stopped = false
    private var pendingFrame: Data?
    private var frameDrainScheduled = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        url: URL,
        onFrame: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.url = url
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.connectionProxyDictionary = [:]
        let delegateQueue = OperationQueue()
        delegateQueue.name = "stupidmirror.wireless-mjpeg"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        self.session = session
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func stop() {
        stateLock.lock()
        stopped = true
        buffer.removeAll(keepingCapacity: false)
        pendingFrame = nil
        stateLock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
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
        buffer.append(data)
        let newestFrame = extractFramesLocked().last
        if buffer.count > Self.maximumBufferSize {
            if let start = buffer.range(of: Self.jpegStart)?.lowerBound {
                buffer.removeSubrange(buffer.startIndex..<start)
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
        }
        stateLock.unlock()
        if let newestFrame {
            submitNewestFrame(newestFrame)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let wasStopped = stopped
        stateLock.unlock()
        guard !wasStopped else { return }
        onFailure(error ?? WirelessMirrorError.streamEnded)
    }

    /// Must be called with `stateLock` held. Returning complete frames keeps
    /// ImageIO decoding outside the lock while buffer mutation remains atomic.
    private func extractFramesLocked() -> [Data] {
        var frames: [Data] = []
        while let startRange = buffer.range(of: Self.jpegStart),
              let endRange = buffer.range(
                of: Self.jpegEnd,
                in: startRange.lowerBound..<buffer.endIndex
              ) {
            let frameEnd = endRange.upperBound
            let frame = Data(buffer[startRange.lowerBound..<frameEnd])
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
            frames.append(frame)
        }
        return frames
    }

    private func submitNewestFrame(_ frame: Data) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        pendingFrame = frame
        let shouldSchedule = !frameDrainScheduled
        frameDrainScheduled = true
        stateLock.unlock()
        guard shouldSchedule else { return }
        frameDecodeQueue.async { [weak self] in
            self?.drainLatestFrames()
        }
    }

    private func drainLatestFrames() {
        while true {
            stateLock.lock()
            guard !stopped, let frame = pendingFrame else {
                pendingFrame = nil
                frameDrainScheduled = false
                stateLock.unlock()
                return
            }
            pendingFrame = nil
            stateLock.unlock()
            onFrame(frame)
        }
    }
}

private enum WirelessJPEGDecoder {
    static func sampleBuffer(from data: Data) -> CMSampleBuffer? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 0,
                  image.height > 0 else { return nil }

            var pixelBuffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                image.width,
                image.height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            ) == kCVReturnSuccess,
            let pixelBuffer else { return nil }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else { return nil }

            // The JPEG bytes are already in display orientation. Applying the
            // usual Core Graphics Y-axis flip here mirrors the wireless frame
            // vertically, while NSImage-based dashboard previews stay correct.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

            var formatDescription: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr,
            let formatDescription else { return nil }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr else { return nil }
            return sampleBuffer
        }
    }
}

private enum WirelessMirrorError: LocalizedError {
    case streamEnded

    var errorDescription: String? {
        "The wireless iPhone video stream ended."
    }
}
