@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Optional USB playback alongside an independent video stream. This object
/// never creates a video output, and the phone route creates no capture graph.
final class IOSUSBAudioSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private enum Failure: LocalizedError {
        case microphonePermission
        case cameraPermission
        case disconnected
        case audioUnavailable
        case cannotStart

        var errorDescription: String? {
            switch self {
            case .microphonePermission:
                "Allow Microphone access to play USB iPhone audio on this Mac."
            case .cameraPermission:
                "Allow Camera access to use this iPhone's USB audio device. Video continues through the separate screen stream."
            case .disconnected:
                "The USB iPhone audio device is no longer connected."
            case .audioUnavailable:
                "This USB iPhone does not expose an audio playback stream. Sound remains on the phone."
            case .cannotStart:
                "The USB iPhone audio stream could not start."
            }
        }
    }

    /// Capture resources are owned by the audio queue. Keeping them together
    /// also permits asynchronous cleanup if an owner forgets to await close().
    private final class Graph: @unchecked Sendable {
        let session: AVCaptureSession
        let input: AVCaptureDeviceInput
        let output: AVCaptureAudioDataOutput
        var generation: UInt64
        var observers: [NSObjectProtocol] = []

        init(session: AVCaptureSession, input: AVCaptureDeviceInput, output: AVCaptureAudioDataOutput, generation: UInt64) {
            self.session = session
            self.input = input
            self.output = output
            self.generation = generation
        }
    }

    private let queue = DispatchQueue(label: "stupidmirror.usb-audio.session", qos: .userInitiated)
    private let requestLock = NSLock()
    private var requestGeneration: UInt64 = 0
    private var closed = false
    // Accessed only on queue, apart from deinit after queued owners are gone.
    private var graph: Graph?
    private let onSampleBuffer: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onStopped: @Sendable () -> Void

    /// All callbacks run on the audio queue. onStopped should stop the caller's
    /// player there, after the last accepted sample, so old samples cannot
    /// reactivate playback after switching the route back to the phone.
    init(
        onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onStopped: @escaping @Sendable () -> Void = {}
    ) {
        self.onSampleBuffer = onSampleBuffer
        self.onFailure = onFailure
        self.onStopped = onStopped
        super.init()
    }

    /// The caller supplies only a USB screen device, never a microphone chosen
    /// by name. false or nil releases our graph without discovering or opening
    /// any AVFoundation device. Permission prompts belong to the app's UI.
    func setEnabled(_ enabled: Bool, device: AVCaptureDevice?) {
        requestLock.lock()
        guard !closed else {
            requestLock.unlock()
            return
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        requestLock.unlock()

        queue.async { [self] in
            guard isCurrent(generation) else { return }
            guard enabled, let device else {
                stopGraph()
                return
            }
            do {
                if let graph, graph.input.device.uniqueID == device.uniqueID,
                   graph.input.device.isConnected, graph.session.isRunning {
                    graph.generation = generation
                    return
                }
                stopGraph()
                try startGraph(device: device, generation: generation)
                // A route change made while startRunning was blocked must not
                // leave an obsolete Mac-audio claim or deliver any samples.
                if !isCurrent(generation) { stopGraph() }
            } catch {
                stopGraph()
                if isCurrent(generation) { onFailure(error.localizedDescription) }
            }
        }
    }

    func stop() {
        setEnabled(false, device: nil)
    }

    /// Seals this owner and waits for its capture resources to be released.
    func close() async {
        requestLock.withLock {
            closed = true
            requestGeneration &+= 1
        }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopGraph()
                continuation.resume()
            }
        }
    }

    deinit {
        guard let graph else { return }
        let onStopped = onStopped
        queue.async {
            Self.release(graph)
            onStopped()
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return !closed && generation == requestGeneration
    }

    private func startGraph(device: AVCaptureDevice, generation: UInt64) throws {
        guard AVFoundationMirrorBackend.audioAuthorizationStatus() == .authorized else {
            throw Failure.microphonePermission
        }
        // The USB screen source is muxed. Creating its input may otherwise
        // implicitly request Camera access even for an audio-only connection.
        if device.hasMediaType(.video) || device.hasMediaType(.muxed) {
            guard AVFoundationMirrorBackend.videoAuthorizationStatus() == .authorized else {
                throw Failure.cameraPermission
            }
        }
        let device = AVFoundationMirrorBackend.liveMuxedDevice(for: device)
        guard device.isConnected, !device.isSuspended else { throw Failure.disconnected }
        guard isCurrent(generation) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        let audioPorts = IOSUSBAudioRouting.audioPorts(on: input)
        let ports = audioPorts.isEmpty ? IOSUSBAudioRouting.muxedPorts(on: input) : audioPorts
        guard !ports.isEmpty else { throw Failure.audioUnavailable }
        for port in input.ports {
            port.isEnabled = ports.contains { $0 === port }
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let graph = Graph(session: session, input: input, output: output, generation: generation)
        self.graph = graph
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.audioUnavailable
        }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard session.canAddConnection(connection) else {
            session.commitConfiguration()
            throw Failure.audioUnavailable
        }
        session.addConnection(connection)
        connection.isEnabled = true
        for channel in connection.audioChannels {
            channel.isEnabled = true
            channel.volume = 1
        }
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        installObservers(for: graph)
        guard isCurrent(generation) else { return }
        session.startRunning()
        guard session.isRunning else { throw Failure.cannotStart }
    }

    private func installObservers(for graph: Graph) {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: graph.session, queue: nil) { [weak self, weak graph] notification in
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                    ?? "USB iPhone audio was interrupted. Select Mac audio again after reconnecting the phone."
                self?.queue.async { [weak self, weak graph] in
                    guard let self, let graph, self.graph === graph,
                          self.isCurrent(graph.generation) else { return }
                    self.stopGraph()
                    self.onFailure(message)
                }
            }
            graph.observers.append(observer)
        }
    }

    private func stopGraph() {
        guard let graph else { return }
        self.graph = nil
        Self.release(graph)
        onStopped()
    }

    private static func release(_ graph: Graph) {
        for observer in graph.observers { NotificationCenter.default.removeObserver(observer) }
        graph.observers.removeAll()
        graph.output.setSampleBufferDelegate(nil, queue: nil)
        for connection in graph.output.connections { connection.isEnabled = false }
        for port in graph.input.ports { port.isEnabled = false }
        if graph.session.isRunning { graph.session.stopRunning() }
        graph.session.beginConfiguration()
        for output in graph.session.outputs { graph.session.removeOutput(output) }
        for input in graph.session.inputs { graph.session.removeInput(input) }
        graph.session.commitConfiguration()
        // Do not call the device-wide CMIO stop helper: this graph must release
        // only its own claim, leaving audio clients in other apps untouched.
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let graph, output === graph.output, graph.session.isRunning,
              isCurrent(graph.generation) else { return }
        onSampleBuffer(sampleBuffer)
    }
}
