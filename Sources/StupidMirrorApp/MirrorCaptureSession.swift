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
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sampleBufferConsumerLock = NSLock()
    private var videoSampleBufferConsumer: (@Sendable (CMSampleBuffer) -> Void)?
    private var audioSampleBufferConsumer: (@Sendable (CMSampleBuffer) -> Void)?
    private var configured = false

    init(device: AVCaptureDevice) {
        self.device = device
        super.init()
    }

    deinit {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    @MainActor
    func start() {
        guard state != .running && state != .starting else { return }
        state = .starting

        let captureSession = captureSession
        let device = device
        sessionQueue.async { [weak self] in
            do {
                guard let self else { return }
                try self.configureIfNeeded(session: captureSession, device: device)
                if !captureSession.isRunning {
                    captureSession.startRunning()
                }
                Task { @MainActor in
                    self.state = .running
                }
            } catch {
                Task { @MainActor in
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    func stop() {
        state = .stopped
        let captureSession = captureSession
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
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

    private func configureIfNeeded(session: AVCaptureSession, device: AVCaptureDevice) throws {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw MirrorError.cannotAddInput
        }
        session.addInput(input)

        // A lightweight data output lets us read each frame's real pixel
        // dimensions and render through our own display layer instead of
        // AVCaptureVideoPreviewLayer's opaque color handling.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        configured = true
    }

    // Reads frame dimensions off the capture stream and reports aspect
    // ratio only when it actually changes (e.g. the device rotates).
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let last = self.frameAspectRatio, abs(last - ratio) < 0.01 { return }
            self.frameAspectRatio = ratio
        }
    }
}

enum MirrorError: LocalizedError {
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "Cannot add this iPhone screen source to the capture session."
        }
    }
}
