@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation

final class MirrorCaptureSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let captureSession = AVCaptureSession()
    private(set) var device: AVCaptureDevice?
    private(set) var wirelessEndpointURL: URL?
    private(set) var androidDevice: AndroidDeviceMetadata?

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
    private let audioCallbackQueue = DispatchQueue(label: "stupidmirror.capture.audio", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let deviceAudioPlayer = LiveCaptureAudioPlayer()
    private var primaryDeviceInput: AVCaptureDeviceInput?
    private var dedicatedIOSAudioInput: AVCaptureDeviceInput?
    private let sampleBufferConsumerLock = NSLock()
    private var videoSampleBufferConsumer: (@Sendable (CMSampleBuffer) -> Void)?
    private var audioSampleBufferConsumer: (@Sendable (CMSampleBuffer) -> Void)?
    private var liveUSBAudioArmed = false
    private var configured = false
    private var audioEnabled = false
    private var iosMacPlaybackUnavailable = false
    private var disposed = false
    private var lastObservedAspectRatio: Double?
    private var wirelessSRTStream: WirelessSRTH264Stream?
    private var androidStream: AndroidScrcpyStream?
    private var androidAudioEnabled = false
    private var wirelessStreamURL: URL?
    private var wirelessRetryTask: Task<Void, Never>?
    private var wirelessGeneration: UInt64 = 0
    private var wirelessStartedAt: Date?
    private var lastStreamFailureAt: Date?
    private var wirelessOnRunning: (@MainActor @Sendable () -> Void)?
    var onWirelessEndpointNeedsRefresh: (@MainActor @Sendable () -> Void)?
    private var lastWirelessPreviewUpdate = Date.distantPast
    private var automationActionClearTask: Task<Void, Never>?

    init(device: AVCaptureDevice) {
        self.device = device
        self.wirelessEndpointURL = nil
        self.androidDevice = nil
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    init(wirelessEndpointURL: URL) {
        self.device = nil
        self.wirelessEndpointURL = wirelessEndpointURL
        self.androidDevice = nil
        self.wirelessStreamURL = wirelessEndpointURL
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    init(androidDevice: AndroidDeviceMetadata) {
        self.device = nil
        self.wirelessEndpointURL = nil
        self.androidDevice = androidDevice
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: 1)
    }

    deinit {
        automationActionClearTask?.cancel()
        wirelessSRTStream?.stop()
        androidStream?.stop()
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
    func retargetToUSB(_ captureDevice: AVCaptureDevice) {
        guard device?.uniqueID != captureDevice.uniqueID
                || wirelessEndpointURL != nil
                || androidDevice != nil else {
            return
        }
        resetForRetarget()
        device = captureDevice
        wirelessEndpointURL = nil
        androidDevice = nil
        wirelessStreamURL = nil
    }

    @MainActor
    func retargetToWireless(endpointURL: URL) {
        guard wirelessEndpointURL != endpointURL || device != nil || androidDevice != nil else {
            return
        }
        resetForRetarget()
        device = nil
        wirelessEndpointURL = endpointURL
        androidDevice = nil
        wirelessStreamURL = endpointURL
    }

    @MainActor
    private func resetForRetarget() {
        stop()
        sessionQueue.sync {
            tearDownOnSessionQueue()
            disposed = false
            configured = false
        }
        latestFrameStore.clear()
        frameAspectRatio = nil
        latestWirelessFrame = nil
        lastStreamFailureAt = nil
    }

    nonisolated static func shouldRetryWirelessFailure(
        lastFailureAt: Date?,
        now: Date = Date(),
        window: TimeInterval = 120
    ) -> Bool {
        let started = lastFailureAt ?? now
        return now.timeIntervalSince(started) < window
    }

    @MainActor
    func start(onRunning: @escaping @MainActor @Sendable () -> Void = {}) {
        if state == .running {
            onRunning()
            return
        }
        guard state != .starting else { return }
        lastStreamFailureAt = nil
        state = .starting

        if androidDevice != nil {
            wirelessStartedAt = Date()
            wirelessStartupBeganAt = wirelessStartedAt
            wirelessStartupDetail = "Starting Android screen service…"
            wirelessOnRunning = onRunning
            wirelessGeneration &+= 1
            startAndroidAttempt(generation: wirelessGeneration)
            return
        }

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
                // startRunning can resurrect muxed audio ports; pin the
                // speaker-vs-Mac choice after the session is live.
                applyAudioEnabledOnSessionQueue()
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
        androidStream?.stop()
        androidStream = nil
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
        wirelessGeneration &+= 1
        lastStreamFailureAt = nil
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

    /// Device audio is opt-in. USB iPhone screens are muxed: an enabled audio
    /// port makes iOS hand playback to the Mac and mute the phone speaker.
    /// Off disables that port so sound stays on the iPhone; on consumes the
    /// same port and plays it through this Mac.
    nonisolated func setAudioEnabled(_ enabled: Bool) {
        sampleBufferConsumerLock.lock()
        let androidAudioChanged = androidAudioEnabled != enabled
        androidAudioEnabled = enabled
        let usesAndroid = androidDevice != nil
        sampleBufferConsumerLock.unlock()

        if usesAndroid {
            guard androidAudioChanged else { return }
            if !enabled {
                deviceAudioPlayer.stop()
            }
            Task { @MainActor [weak self] in
                self?.restartAndroidForAudioPreferenceChange()
            }
            return
        }
        sessionQueue.async { [self] in
            guard !disposed else { return }
            audioEnabled = enabled
            if enabled {
                iosMacPlaybackUnavailable = false
            }
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
            primaryDeviceInput = input
            // Disable before startRunning. An enabled muxed audio port is
            // enough for iOS to steal the speaker, even without an audio output.
            IOSUSBAudioRouting.setMuxedAudioPortsEnabled(false, on: input)

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
            primaryDeviceInput = nil
            dedicatedIOSAudioInput = nil
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
        guard let primaryDeviceInput else { return }

        let wantsMacPlayback = audioEnabled && !iosMacPlaybackUnavailable
        let hasSampleOutput = captureSession.outputs.contains { $0 === audioOutput }
        let muxedAudioEnabled = IOSUSBAudioRouting.muxedAudioPortsAreEnabled(on: primaryDeviceInput)
        let hasDedicatedInput = dedicatedIOSAudioInput != nil
        let graphMatches = wantsMacPlayback
            ? hasSampleOutput && (muxedAudioEnabled || hasDedicatedInput)
            : !hasSampleOutput && !hasDedicatedInput && !muxedAudioEnabled
        if graphMatches {
            if !wantsMacPlayback {
                IOSUSBAudioRouting.setMuxedAudioPortsEnabled(false, on: primaryDeviceInput)
                setLiveUSBAudioArmed(false)
                deviceAudioPlayer.stop()
            }
            return
        }

        let shouldRestart = captureSession.isRunning
        if shouldRestart {
            captureSession.stopRunning()
        }

        captureSession.beginConfiguration()
        if wantsMacPlayback {
            if !attachIOSMacPlaybackIfPossible(primaryDeviceInput: primaryDeviceInput) {
                detachIOSMacPlayback(primaryDeviceInput: primaryDeviceInput)
                iosMacPlaybackUnavailable = true
            }
        } else {
            detachIOSMacPlayback(primaryDeviceInput: primaryDeviceInput)
        }
        captureSession.commitConfiguration()

        if shouldRestart {
            captureSession.startRunning()
        }

        if audioEnabled && !iosMacPlaybackUnavailable {
            setLiveUSBAudioArmed(true)
        } else {
            IOSUSBAudioRouting.setMuxedAudioPortsEnabled(false, on: primaryDeviceInput)
            setLiveUSBAudioArmed(false)
            deviceAudioPlayer.stop()
        }
    }

    private func setLiveUSBAudioArmed(_ armed: Bool) {
        sampleBufferConsumerLock.lock()
        liveUSBAudioArmed = armed
        sampleBufferConsumerLock.unlock()
    }

    @discardableResult
    private func attachIOSMacPlaybackIfPossible(primaryDeviceInput: AVCaptureDeviceInput) -> Bool {
        if IOSUSBAudioRouting.hasMuxedAudioPorts(on: primaryDeviceInput) {
            // The muxed screen track is the phone's routed playback. The
            // separate "iPhone Mic" device is the microphone and stays silent
            // while a video or game is playing.
            IOSUSBAudioRouting.setMuxedAudioPortsEnabled(true, on: primaryDeviceInput)
        } else if dedicatedIOSAudioInput == nil {
            guard let screenDevice = device,
                  let audioDevice = matchingIOSAudioDevice(for: screenDevice),
                  let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                  captureSession.canAddInput(audioInput) else {
                return false
            }
            captureSession.addInput(audioInput)
            dedicatedIOSAudioInput = audioInput
        }

        return attachIOSMacPlaybackViaSampleBuffers()
    }

    private func attachIOSMacPlaybackViaSampleBuffers() -> Bool {
        if !captureSession.outputs.contains(where: { $0 === audioOutput }) {
            guard captureSession.canAddOutput(audioOutput) else { return false }
            audioOutput.setSampleBufferDelegate(self, queue: audioCallbackQueue)
            captureSession.addOutput(audioOutput)
        }
        for connection in audioOutput.connections {
            connection.isEnabled = true
            for channel in connection.audioChannels {
                channel.isEnabled = true
                channel.volume = 1.0
            }
        }
        return captureSession.outputs.contains { $0 === audioOutput }
    }

    private func detachIOSMacPlayback(primaryDeviceInput: AVCaptureDeviceInput) {
        setLiveUSBAudioArmed(false)
        deviceAudioPlayer.stop()
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        if captureSession.outputs.contains(where: { $0 === audioOutput }) {
            captureSession.removeOutput(audioOutput)
        }
        if let dedicatedIOSAudioInput {
            captureSession.removeInput(dedicatedIOSAudioInput)
            self.dedicatedIOSAudioInput = nil
        }
        IOSUSBAudioRouting.setMuxedAudioPortsEnabled(false, on: primaryDeviceInput)
    }

    private func matchingIOSAudioDevice(for screenDevice: AVCaptureDevice) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.first { candidate in
            let nameMatch = candidate.localizedName
                .localizedCaseInsensitiveContains(screenDevice.localizedName)
            let modelMatch = candidate.modelID.localizedCaseInsensitiveContains("iPhone")
            return nameMatch && modelMatch
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
        setLiveUSBAudioArmed(false)
        deviceAudioPlayer.stop()
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
        primaryDeviceInput = nil
        dedicatedIOSAudioInput = nil
        iosMacPlaybackUnavailable = false
        lastObservedAspectRatio = nil
    }

    @MainActor
    private func restartAndroidForAudioPreferenceChange() {
        guard androidDevice != nil,
              state == .starting || state == .running,
              !disposed else { return }
        wirelessGeneration &+= 1
        wirelessRetryTask?.cancel()
        wirelessRetryTask = nil
        androidStream?.stop()
        androidStream = nil
        state = .starting
        wirelessStartedAt = Date()
        wirelessStartupBeganAt = wirelessStartedAt
        wirelessStartupDetail = "Restarting Android audio stream…"
        startAndroidAttempt(generation: wirelessGeneration)
    }

    @MainActor
    private func startAndroidAttempt(generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting,
              let androidDevice,
              !disposed else { return }
        guard let adbPath = AndroidRuntime.adbExecutablePath() else {
            failAndroidStart(AndroidADBError.adbUnavailable.localizedDescription)
            return
        }
        guard let server = AndroidRuntime.scrcpyServerResource() else {
            failAndroidStart("The bundled Android screen service is unavailable.")
            return
        }
        sampleBufferConsumerLock.lock()
        let audioEnabled = androidAudioEnabled
        sampleBufferConsumerLock.unlock()
        let stream = AndroidScrcpyStream(
            configuration: AndroidScrcpyStream.Configuration(
                serial: androidDevice.serial,
                adbPath: adbPath,
                serverPath: server.path,
                serverVersion: server.version,
                audioEnabled: audioEnabled
            ),
            onFrame: { [weak self] sampleBuffer in
                self?.receiveWirelessSampleBuffer(sampleBuffer, generation: generation)
            },
            onAudio: { [weak self] sampleBuffer in
                self?.receiveAndroidAudioSampleBuffer(sampleBuffer, generation: generation)
            },
            onSessionSize: { [weak self] width, height in
                Task { @MainActor in
                    self?.receiveAndroidSessionSize(width: width, height: height, generation: generation)
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.handleAndroidFailure(error, generation: generation)
                }
            }
        )
        androidStream?.stop()
        androidStream = stream
        wirelessStartupDetail = "Connecting the Android video stream…"
        stream.start()
    }

    private func receiveAndroidAudioSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        generation: UInt64
    ) {
        sampleBufferConsumerLock.lock()
        let enabled = androidAudioEnabled
        sampleBufferConsumerLock.unlock()
        guard enabled, generation == wirelessGeneration else { return }
        deviceAudioPlayer.enqueue(sampleBuffer)
    }

    @MainActor
    private func receiveAndroidSessionSize(width: Int, height: Int, generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting || state == .running,
              width > 0, height > 0 else { return }
        let ratio = Double(width) / Double(height)
        if frameAspectRatio == nil || abs((frameAspectRatio ?? ratio) - ratio) >= 0.01 {
            frameAspectRatio = ratio
        }
    }

    @MainActor
    private func failAndroidStart(_ message: String) {
        guard androidDevice != nil, state == .starting else { return }
        wirelessGeneration &+= 1
        wirelessRetryTask?.cancel()
        wirelessRetryTask = nil
        androidStream?.stop()
        androidStream = nil
        wirelessOnRunning = nil
        wirelessStartupDetail = nil
        wirelessStartupBeganAt = nil
        state = .failed(message)
    }

    @MainActor
    private func handleAndroidFailure(_ error: Error, generation: UInt64) {
        guard generation == wirelessGeneration,
              state == .starting || state == .running,
              !disposed else { return }
        androidStream?.stop()
        androidStream = nil

        let elapsed = Date().timeIntervalSince(wirelessStartedAt ?? Date())
        guard elapsed < 30 else {
            state = .failed(error.localizedDescription)
            wirelessOnRunning = nil
            wirelessStartupDetail = nil
            wirelessStartupBeganAt = nil
            return
        }
        state = .starting
        wirelessStartupDetail = "Reconnecting the Android screen service…"
        wirelessRetryTask?.cancel()
        wirelessRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.startAndroidAttempt(generation: generation)
        }
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
                self.lastStreamFailureAt = nil
                let onRunning = self.wirelessOnRunning
                self.wirelessOnRunning = nil
                onRunning?()
            }
            self.lastStreamFailureAt = nil
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

        lastStreamFailureAt = lastStreamFailureAt ?? Date()
        guard Self.shouldRetryWirelessFailure(lastFailureAt: lastStreamFailureAt) else {
            state = .failed(error.localizedDescription)
            wirelessOnRunning = nil
            return
        }

        state = .starting
        wirelessRetryTask?.cancel()
        wirelessRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Re-resolve WDA's LAN IP instead of hammering a stale SRT host
            // after DHCP or tunnel rotation.
            if let refresh = self?.onWirelessEndpointNeedsRefresh {
                refresh()
            } else {
                self?.startWirelessAttempt(generation: generation)
            }
        }
    }

    // Reads frame dimensions off the capture stream and reports aspect
    // ratio only when it actually changes (e.g. the device rotates).
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            sampleBufferConsumerLock.lock()
            let armed = liveUSBAudioArmed
            sampleBufferConsumerLock.unlock()
            guard armed else { return }
            deviceAudioPlayer.enqueue(sampleBuffer)
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

/// Session-owned live player. PCM is copied on the capture callback, then
/// scheduled on a serial queue with a short backlog cap so latency cannot grow.
final class LiveCaptureAudioPlayer: @unchecked Sendable {
    private static let maxPendingBuffers = 6

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let lock = NSLock()
    private let playbackQueue = DispatchQueue(label: "stupidmirror.live-audio.player", qos: .userInitiated)
    private var engineAttached = false
    private var engineFormat: AVAudioFormat?
    private var rendererStarted = false
    private var pendingBuffers = 0
    private var active = true

    init() {
        synchronizer.addRenderer(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        renderer.volume = 1.0
        renderer.isMuted = false
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if let pcm = Self.makePCMBuffer(from: sampleBuffer) {
            lock.lock()
            active = true
            if pendingBuffers >= Self.maxPendingBuffers {
                lock.unlock()
                return
            }
            pendingBuffers += 1
            lock.unlock()
            playbackQueue.async { [self] in
                self.schedulePCM(pcm)
            }
            return
        }

        lock.lock()
        active = true
        enqueueWithRendererLocked(sampleBuffer)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        active = false
        pendingBuffers = 0
        lock.unlock()
        playbackQueue.async { [self] in
            self.stopEngineOnPlaybackQueue()
            self.renderer.flush()
            self.synchronizer.rate = 0
            self.rendererStarted = false
        }
    }

    private func schedulePCM(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        let shouldPlay = active
        lock.unlock()
        guard shouldPlay else {
            finishPending()
            return
        }

        do {
            try startEngineOnPlaybackQueue(format: pcm.format)
        } catch {
            stopEngineOnPlaybackQueue()
            finishPending()
            return
        }

        playerNode.scheduleBuffer(pcm) { [weak self] in
            self?.finishPending()
        }
    }

    private func finishPending() {
        lock.lock()
        pendingBuffers = max(0, pendingBuffers - 1)
        lock.unlock()
    }

    private func startEngineOnPlaybackQueue(format: AVAudioFormat) throws {
        if engineAttached, let engineFormat, !Self.formatsMatch(engineFormat, format) {
            stopEngineOnPlaybackQueue()
        }
        if !engineAttached {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1.0
            engineAttached = true
            engineFormat = format
        }
        if !engine.isRunning {
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func stopEngineOnPlaybackQueue() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        if engineAttached {
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
            engineAttached = false
        }
        engineFormat = nil
    }

    private func enqueueWithRendererLocked(_ sampleBuffer: CMSampleBuffer) {
        guard active else { return }
        if renderer.status == .failed || !renderer.isReadyForMoreMediaData {
            renderer.flush()
            rendererStarted = false
        }
        if !rendererStarted {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let startTime = presentationTime.isValid && presentationTime.isNumeric
                ? presentationTime
                : .zero
            synchronizer.setRate(1.0, time: startTime)
            rendererStarted = true
        }
        renderer.enqueue(sampleBuffer)
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        let left = lhs.streamDescription.pointee
        let right = rhs.streamDescription.pointee
        return left.mSampleRate == right.mSampleRate
            && left.mFormatID == right.mFormatID
            && left.mFormatFlags == right.mFormatFlags
            && left.mBytesPerPacket == right.mBytesPerPacket
            && left.mFramesPerPacket == right.mFramesPerPacket
            && left.mBytesPerFrame == right.mBytesPerFrame
            && left.mChannelsPerFrame == right.mChannelsPerFrame
            && left.mBitsPerChannel == right.mBitsPerChannel
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
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
