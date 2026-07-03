@preconcurrency import AVFoundation
import AppKit
import CoreImage
import Foundation

final class ThumbnailCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "stupidmirror.thumbnail.capture")
    private let context = CIContext()
    private let completion: @MainActor (Result<NSImage, Error>) -> Void
    private var didComplete = false

    init(completion: @escaping @MainActor (Result<NSImage, Error>) -> Void) {
        self.completion = completion
    }

    func start(device: AVCaptureDevice) throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw ThumbnailCaptureError.cannotAddInput
        }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard captureSession.canAddOutput(output) else {
            throw ThumbnailCaptureError.cannotAddOutput
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        queue.async { [captureSession] in
            captureSession.startRunning()
        }
    }

    func cancel() {
        complete(.failure(ThumbnailCaptureError.cancelled))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !didComplete else { return }
        do {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw ThumbnailCaptureError.missingImageBuffer
            }
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                throw ThumbnailCaptureError.cannotCreateImage
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            complete(.success(image))
        } catch {
            complete(.failure(error))
        }
    }

    private func complete(_ result: Result<NSImage, Error>) {
        guard !didComplete else { return }
        didComplete = true
        queue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        let completion = completion
        Task { @MainActor in
            completion(result)
        }
    }
}

enum ThumbnailCaptureError: LocalizedError, Equatable {
    case cannotAddInput
    case cannotAddOutput
    case missingImageBuffer
    case cannotCreateImage
    case cancelled

    var errorDescription: String? {
        switch self {
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
        }
    }
}
