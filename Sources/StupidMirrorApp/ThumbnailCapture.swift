@preconcurrency import AVFoundation
import AppKit
import CoreImage
import Foundation

final class ThumbnailCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "stupidmirror.thumbnail.capture")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let completionLock = NSLock()
    private let completion: @MainActor (Result<NSImage, Error>) -> Void
    private let maximumPixelDimension: CGFloat
    private let firstFrameTimeout: TimeInterval
    private var didComplete = false // Protected by completionLock.
    private var configured = false // Accessed only on queue.

    init(
        maximumPixelDimension: CGFloat = 1_280,
        firstFrameTimeout: TimeInterval = 8,
        completion: @escaping @MainActor (Result<NSImage, Error>) -> Void
    ) {
        self.maximumPixelDimension = max(maximumPixelDimension, 64)
        self.firstFrameTimeout = max(firstFrameTimeout, 0.1)
        self.completion = completion
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            tearDownOnQueue()
        } else {
            queue.sync {
                tearDownOnQueue()
            }
        }
    }

    func start(device: AVCaptureDevice) throws {
        try queue.sync {
            guard !configured else { throw ThumbnailCaptureError.alreadyStarted }
            guard !hasCompleted else { throw ThumbnailCaptureError.cancelled }
            try configureOnQueue(device: device)
        }

        // Use an independent timer queue so a slow startRunning() cannot leave
        // the caller waiting forever for the first-frame result.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + firstFrameTimeout) { [weak self] in
            self?.complete(.failure(ThumbnailCaptureError.timedOut))
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard !self.hasCompleted else {
                self.tearDownOnQueue()
                return
            }
            self.captureSession.startRunning()
            if self.hasCompleted {
                self.tearDownOnQueue()
            }
        }
    }

    func cancel() {
        complete(.failure(ThumbnailCaptureError.cancelled))
    }

    private func configureOnQueue(device: AVCaptureDevice) throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        defer { captureSession.commitConfiguration() }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                throw ThumbnailCaptureError.cannotAddInput
            }
            captureSession.addInput(input)

            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard captureSession.canAddOutput(output) else {
                throw ThumbnailCaptureError.cannotAddOutput
            }
            captureSession.addOutput(output)
            configured = true
        } catch {
            output.setSampleBufferDelegate(nil, queue: nil)
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            throw error
        }
    }

    private var hasCompleted: Bool {
        completionLock.lock()
        let value = didComplete
        completionLock.unlock()
        return value
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !hasCompleted else { return }
        let result: Result<NSImage, Error> = autoreleasepool {
            do {
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw ThumbnailCaptureError.missingImageBuffer
                }
                let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                let sourceExtent = sourceImage.extent
                let longestEdge = max(sourceExtent.width, sourceExtent.height)
                guard longestEdge > 0 else {
                    throw ThumbnailCaptureError.cannotCreateImage
                }
                let scale = min(maximumPixelDimension / longestEdge, 1)
                let thumbnailImage = sourceImage.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
                let outputExtent = thumbnailImage.extent.integral
                guard let cgImage = context.createCGImage(thumbnailImage, from: outputExtent) else {
                    throw ThumbnailCaptureError.cannotCreateImage
                }
                return .success(NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                ))
            } catch {
                return .failure(error)
            }
        }
        complete(result)
    }

    private func complete(_ result: Result<NSImage, Error>) {
        completionLock.lock()
        guard !didComplete else {
            completionLock.unlock()
            return
        }
        didComplete = true
        completionLock.unlock()

        queue.async { [self] in
            tearDownOnQueue()
        }
        let completion = completion
        Task { @MainActor in
            completion(result)
        }
    }

    private func tearDownOnQueue() {
        output.setSampleBufferDelegate(nil, queue: nil)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }

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
        context.clearCaches()
    }
}

enum ThumbnailCaptureError: LocalizedError, Equatable {
    case alreadyStarted
    case cannotAddInput
    case cannotAddOutput
    case missingImageBuffer
    case cannotCreateImage
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "Thumbnail capture has already started."
        case .cannotAddInput:
            "Cannot add device input for thumbnail capture."
        case .cannotAddOutput:
            "Cannot add video output for thumbnail capture."
        case .missingImageBuffer:
            "Thumbnail sample did not contain an image buffer."
        case .cannotCreateImage:
            "Could not create thumbnail image."
        case .cancelled:
            "Thumbnail capture cancelled."
        case .timedOut:
            "Timed out waiting for a thumbnail frame."
        }
    }
}
