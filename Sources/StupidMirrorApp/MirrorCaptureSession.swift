@preconcurrency import AVFoundation
import Combine
import Foundation

final class MirrorCaptureSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let captureSession = AVCaptureSession()
    let device: AVCaptureDevice

    @Published private(set) var state: MirrorState = .stopped
    // Live aspect ratio read from actual frames, so the window can follow
    // device rotation instead of being locked to a static portrait profile.
    @Published private(set) var frameAspectRatio: Double?

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

    init(device: AVCaptureDevice) {
        self.device = device
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
        sessionQueue.async { [self] in
            stopRunningOnSessionQueue()
        }
    }

    /// Permanently releases capture inputs, outputs, delegates, and consumers.
    /// A disposed mirror session cannot be restarted.
    @MainActor
    func dispose() {
        state = .stopped
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

enum MirrorError: LocalizedError {
    case cannotAddInput
    case cannotAddVideoOutput
    case cannotStartSession
    case disposed

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
        }
    }
}
