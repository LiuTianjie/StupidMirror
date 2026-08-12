@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation

final class MirrorCaptureSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let captureSession = AVCaptureSession()
    let device: AVCaptureDevice?
    let wirelessEndpointURL: URL?

    @Published private(set) var state: MirrorState = .stopped
    // Live aspect ratio read from actual frames, so the window can follow
    // device rotation instead of being locked to a static portrait profile.
    @Published private(set) var frameAspectRatio: Double?
    @Published private(set) var latestWirelessFrame: NSImage?
    @Published private(set) var wirelessStartupDetail: String?
    @Published private(set) var wirelessStartupBeganAt: Date?
    @Published private(set) var automationActions: [AutomationActionVisualization] = []
    let latestFrameStore = MirrorFrameStore()

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
    private var wirelessSRTStream: WirelessSRTH264Stream?
    private var wirelessStreamURL: URL?
    private var wirelessRetryTask: Task<Void, Never>?
    private var wirelessGeneration: UInt64 = 0
    private var wirelessStartedAt: Date?
    private var wirelessOnRunning: (@MainActor @Sendable () -> Void)?
    private var lastWirelessPreviewUpdate = Date.distantPast
    private var automationActionClearTask: Task<Void, Never>?

    init(device: AVCaptureDevice) {
        self.device = device
        self.wirelessEndpointURL = nil
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    init(wirelessEndpointURL: URL) {
        self.device = nil
        self.wirelessEndpointURL = wirelessEndpointURL
        self.wirelessStreamURL = wirelessEndpointURL
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    deinit {
        automationActionClearTask?.cancel()
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

        if wirelessEndpointURL != nil {
            wirelessStartedAt = Date()
            wirelessStartupBeganAt = wirelessStartedAt
            wirelessOnRunning = onRunning
            wirelessGeneration &+= 1
            // The WDA owner will call connectWirelessVideo only after /status
            // is ready. Starting the socket here races the agent launch and
            // produces false transport failures before SRT can listen.
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
        latestFrameStore.clear()
        clearAutomationAction()
        wirelessGeneration &+= 1
        wirelessRetryTask?.cancel()
        wirelessRetryTask = nil
        wirelessSRTStream?.stop()
        wirelessSRTStream = nil
        wirelessOnRunning = nil
        wirelessStartedAt = nil
        wirelessStartupDetail = nil
        wirelessStartupBeganAt = nil
        sessionQueue.async { [self] in
            stopRunningOnSessionQueue()
        }
    }

    @MainActor
    func failWirelessStart(_ message: String) {
        guard wirelessEndpointURL != nil, state == .starting else { return }
        wirelessGeneration &+= 1
        wirelessRetryTask?.cancel()
        wirelessRetryTask = nil
        wirelessSRTStream?.stop()
        wirelessSRTStream = nil
        wirelessOnRunning = nil
        wirelessStartedAt = nil
        wirelessStartupDetail = nil
        wirelessStartupBeganAt = nil
        state = .failed(message)
    }

    @MainActor
    func updateWirelessStartupDetail(_ detail: String) {
        guard wirelessEndpointURL != nil, state == .starting else { return }
        wirelessStartupBeganAt = wirelessStartupBeganAt ?? Date()
        wirelessStartupDetail = detail
    }

    @MainActor
    func connectWirelessVideo(host: String) {
        guard wirelessEndpointURL != nil,
              state == .starting || state == .running,
              !disposed else { return }
        var components = URLComponents()
        components.scheme = "srt"
        components.host = host
        components.port = 9_200
        guard let streamURL = components.url else {
            failWirelessStart(WirelessMirrorError.invalidEndpoint.localizedDescription)
            return
        }
        wirelessStreamURL = streamURL
        startWirelessAttempt(generation: wirelessGeneration)
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

    @MainActor
    func showAutomationTarget(normalizedFrame: ScreenElementFrame?, label: String) {
        showAutomationAction(AutomationActionVisualization(
            kind: .target,
            label: label,
            normalizedTargetFrame: normalizedFrame
        ))
    }

    @MainActor
    func showAutomationHighlights(
        _ targets: [(frame: ScreenElementFrame, label: String)],
        durationMilliseconds: Int
    ) {
        automationActionClearTask?.cancel()
        automationActions = targets.map {
            AutomationActionVisualization(
                kind: .highlight,
                label: $0.label,
                normalizedTargetFrame: $0.frame
            )
        }
        guard !automationActions.isEmpty else {
            automationActionClearTask = nil
            return
        }
        automationActionClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMilliseconds))
            guard !Task.isCancelled else { return }
            self?.automationActions.removeAll(keepingCapacity: true)
            self?.automationActionClearTask = nil
        }
    }

    @MainActor
    func clearAutomationHighlights() {
        clearAutomationAction()
    }

    @MainActor
    func showAutomationPoint(
        _ point: CGPoint,
        kind: AutomationActionVisualKind = .tap,
        label: String
    ) {
        showAutomationAction(AutomationActionVisualization(
            kind: kind,
            label: label,
            normalizedPoint: point
        ))
    }

    @MainActor
    func showAutomationSwipe(from start: CGPoint, to end: CGPoint, label: String) {
        showAutomationAction(AutomationActionVisualization(
            kind: .swipe,
            label: label,
            normalizedStart: start,
            normalizedEnd: end
        ))
    }

    @MainActor
    func showAutomationNotice(_ label: String) {
        showAutomationAction(AutomationActionVisualization(kind: .notice, label: label))
    }

    @MainActor
    private func showAutomationAction(_ action: AutomationActionVisualization) {
        automationActionClearTask?.cancel()
        automationActions.append(action)
        if automationActions.count > 4 {
            automationActions.removeFirst(automationActions.count - 4)
        }
        automationActionClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_650))
            guard !Task.isCancelled, self?.automationActions.last?.id == action.id else { return }
            self?.automationActions.removeAll(keepingCapacity: true)
            self?.automationActionClearTask = nil
        }
    }

    @MainActor
    private func clearAutomationAction() {
        automationActionClearTask?.cancel()
        automationActionClearTask = nil
        automationActions.removeAll(keepingCapacity: true)
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
              let srtURL = wirelessStreamURL,
              !disposed else { return }
        guard let host = srtURL.host, !host.isEmpty else {
            failWirelessStart(WirelessMirrorError.invalidEndpoint.localizedDescription)
            return
        }
        let stream = WirelessSRTH264Stream(
            host: host,
            port: srtURL.port ?? 9_200,
            onFrame: { [weak self] sampleBuffer in
                self?.receiveWirelessSampleBuffer(
                    sampleBuffer,
                    generation: generation
                )
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.handleWirelessFailure(error, generation: generation)
                }
            }
        )
        wirelessSRTStream?.stop()
        wirelessSRTStream = stream
        stream.start()
    }

    private func receiveWirelessSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        generation: UInt64
    ) {
        latestFrameStore.submit(sampleBuffer)
        sampleBufferConsumerLock.lock()
        let consumer = videoSampleBufferConsumer
        sampleBufferConsumerLock.unlock()
        consumer?(sampleBuffer)

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.height > 0 else { return }
        let ratio = Double(dimensions.width) / Double(dimensions.height)

        let previewSource = WirelessPreviewSource(
            sampleBuffer: sampleBuffer
        )
        Task { @MainActor [weak self, previewSource] in
            guard let self,
                  generation == self.wirelessGeneration,
                  self.state == .starting || self.state == .running else { return }
            if self.state == .starting {
                self.state = .running
                self.wirelessStartupDetail = nil
                self.wirelessStartupBeganAt = nil
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(source.sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let representation = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    @MainActor
    private func handleWirelessFailure(_ error: Error, generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting || state == .running,
              !disposed else { return }
        wirelessSRTStream?.stop()
        wirelessSRTStream = nil

        let elapsed = Date().timeIntervalSince(wirelessStartedAt ?? Date())
        guard elapsed < 120 else {
            state = .failed(error.localizedDescription)
            wirelessOnRunning = nil
            return
        }

        state = .starting
        wirelessRetryTask?.cancel()
        wirelessRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
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

        latestFrameStore.submit(sampleBuffer)

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

private enum WirelessMirrorError: LocalizedError {
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The wireless iPhone endpoint is invalid."
        }
    }
}
