@preconcurrency import AVFoundation
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
        context.coordinator.view = view
        mirrorSession.setVideoSampleBufferConsumer { [weak view] sampleBuffer in
            DispatchQueue.main.async {
                view?.enqueueVideo(sampleBuffer)
            }
        }
        mirrorSession.setAudioSampleBufferConsumer { [weak view] sampleBuffer in
            DispatchQueue.main.async {
                view?.enqueueAudio(sampleBuffer)
            }
        }
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }

    static func dismantleNSView(_ nsView: PreviewContainerView, coordinator: Coordinator) {
        coordinator.mirrorSession.setVideoSampleBufferConsumer(nil)
        coordinator.mirrorSession.setAudioSampleBufferConsumer(nil)
        coordinator.view = nil
        nsView.stop()
    }

    final class Coordinator {
        let mirrorSession: MirrorCaptureSession
        weak var view: PreviewContainerView?

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
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let renderSynchronizer = AVSampleBufferRenderSynchronizer()
    private let maskLayer = CAShapeLayer()

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
        renderSynchronizer.addRenderer(audioRenderer)
        renderSynchronizer.rate = 1.0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueueVideo(_ sampleBuffer: CMSampleBuffer) {
        guard displayLayer.status != .failed else {
            displayLayer.flush()
            return
        }
        markDisplayImmediately(sampleBuffer)
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
        }
    }

    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioRenderer.status != .failed else {
            audioRenderer.flush()
            return
        }
        if audioRenderer.isReadyForMoreMediaData {
            audioRenderer.enqueue(sampleBuffer)
        }
    }

    func stop() {
        renderSynchronizer.rate = 0
        displayLayer.flushAndRemoveImage()
        audioRenderer.flush()
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
