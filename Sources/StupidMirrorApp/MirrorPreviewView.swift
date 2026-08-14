@preconcurrency import AVFoundation
import Foundation
import SwiftUI

struct MirrorPreviewView: NSViewRepresentable {
    let mirrorSession: MirrorCaptureSession
    var cornerRadius: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(mirrorSession: mirrorSession)
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.cornerRadius = cornerRadius
        let videoRelay = view.videoFrameRelay
        let audioRelay = view.audioSampleBufferRelay
        mirrorSession.setVideoSampleBufferConsumer { [weak videoRelay] sampleBuffer in
            videoRelay?.submit(sampleBuffer)
        }
        mirrorSession.setAudioSampleBufferConsumer { [weak audioRelay] sampleBuffer in
            // AVSampleBufferAudioRenderer is fed directly from the serial
            // capture queue. No per-packet main-queue closure can accumulate.
            audioRelay?.enqueue(sampleBuffer)
        }
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }

    static func dismantleNSView(_ nsView: PreviewContainerView, coordinator: Coordinator) {
        // Invalidate the relays first so an in-flight delegate callback cannot
        // retain another full frame after the view starts tearing down.
        nsView.stop()
        coordinator.mirrorSession.setVideoSampleBufferConsumer(nil)
        coordinator.mirrorSession.setAudioSampleBufferConsumer(nil)
    }

    final class Coordinator {
        let mirrorSession: MirrorCaptureSession

        init(mirrorSession: MirrorCaptureSession) {
            self.mirrorSession = mirrorSession
        }
    }
}

// Render captured iPhone frames ourselves instead of using
// AVCaptureVideoPreviewLayer. This avoids that layer's camera-preview color
// pipeline, which made bright iPhone UI look lifted/washed out in this app.
final class PreviewContainerView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let renderSynchronizer = AVSampleBufferRenderSynchronizer()
    private let maskLayer = CAShapeLayer()
    fileprivate lazy var videoFrameRelay = LatestMainQueueRelay<CMSampleBuffer> { [weak self] sampleBuffer in
        self?.enqueueVideo(sampleBuffer)
    }
    fileprivate lazy var audioSampleBufferRelay = AudioSampleBufferRelay(
        synchronizer: renderSynchronizer
    )

    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyMask()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        layer?.mask = maskLayer
        renderSynchronizer.addRenderer(audioSampleBufferRelay.renderer)
        renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        audioSampleBufferRelay.renderer.volume = 1.0
        audioSampleBufferRelay.renderer.isMuted = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueueVideo(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        guard renderer.status != .failed else {
            renderer.flush()
            return
        }
        markDisplayImmediately(sampleBuffer)
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        } else {
            renderer.flush()
        }
    }

    func stop() {
        videoFrameRelay.invalidate()
        audioSampleBufferRelay.stop()
        renderSynchronizer.rate = 0
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        applyMask()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func applyMask() {
        maskLayer.frame = bounds
        maskLayer.path = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        displayLayer.contentsScale = scale
        maskLayer.contentsScale = scale
    }

    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else {
            return
        }

        let count = CFArrayGetCount(attachments)
        for index in 0..<count {
            guard let rawAttachment = CFArrayGetValueAtIndex(attachments, index) else { continue }
            let attachment = unsafeBitCast(rawAttachment, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }
}

/// Coalesces producer updates into one retained pending value and one scheduled
/// main-queue drain. Replacing the pending value releases the older frame
/// immediately, so a busy UI cannot create an unbounded queue of pixel buffers.
final class LatestMainQueueRelay<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @MainActor (Value) -> Void
    private var pendingValue: Value?
    private var drainScheduled = false
    private var invalidated = false

    init(deliver: @escaping @MainActor (Value) -> Void) {
        self.deliver = deliver
    }

    func submit(_ value: Value) {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        pendingValue = value
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if shouldSchedule {
            scheduleDrain()
        }
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        pendingValue = nil
        lock.unlock()
    }

    @MainActor
    private func drainOne() {
        lock.lock()
        guard !invalidated else {
            pendingValue = nil
            drainScheduled = false
            lock.unlock()
            return
        }
        guard let value = pendingValue else {
            drainScheduled = false
            lock.unlock()
            return
        }
        pendingValue = nil
        lock.unlock()

        deliver(value)

        lock.lock()
        guard !invalidated else {
            pendingValue = nil
            drainScheduled = false
            lock.unlock()
            return
        }
        let shouldContinue = pendingValue != nil
        if !shouldContinue {
            drainScheduled = false
        }
        lock.unlock()

        if shouldContinue {
            scheduleDrain()
        }
    }

    private func scheduleDrain() {
        DispatchQueue.main.async { [weak self] in
            self?.drainOne()
        }
    }
}

/// Serial capture callbacks feed the audio renderer synchronously. The lock is
/// only needed to make teardown from the main thread race-free.
final class AudioSampleBufferRelay: @unchecked Sendable {
    let renderer = AVSampleBufferAudioRenderer()

    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let lock = NSLock()
    private var active = true
    private var enqueuedSampleCount = 0

    init(synchronizer: AVSampleBufferRenderSynchronizer) {
        self.synchronizer = synchronizer
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }

        if renderer.status == .failed {
            renderer.flush()
            return
        }
        if renderer.isReadyForMoreMediaData {
            enqueuedSampleCount += 1
            if enqueuedSampleCount == 1 {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                synchronizer.setRate(1.0, time: presentationTime)
            }
            renderer.enqueue(sampleBuffer)
        }
    }

    func stop() {
        lock.lock()
        active = false
        renderer.flush()
        lock.unlock()
    }
}
