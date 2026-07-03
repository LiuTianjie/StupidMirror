#!/usr/bin/env swift
import AppKit
import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation

struct Options {
    var output: String = "artifacts/avfoundation-frame.png"
    var timeout: TimeInterval = 15
    var deviceID: String?
}

func parseOptions() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--output":
            if let value = iterator.next() {
                options.output = value
            }
        case "--timeout":
            if let value = iterator.next(), let parsed = Double(value) {
                options.timeout = max(1, parsed)
            }
        case "--device-id":
            options.deviceID = iterator.next()
        case "--help", "-h":
            print("Usage: swift tools/probes/avfoundation-frame-capture.swift [--output artifacts/avfoundation-frame.png] [--timeout 15] [--device-id UNIQUE_ID]")
            exit(0)
        default:
            break
        }
    }
    return options
}

func allowScreenCaptureDevices() -> OSStatus {
    let element: CMIOObjectPropertyElement
    if #available(macOS 12.0, *) {
        element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    } else {
        element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
    }

    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: element
    )
    var allow: UInt32 = 1
    return CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &allow
    )
}

func ensureVideoAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { result in
            granted = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 60)
        return granted
    default:
        return false
    }
}

func muxedDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external],
        mediaType: .muxed,
        position: .unspecified
    ).devices
}

func warmUpDiscovery() {
    let mediaTypes: [AVMediaType?] = [nil, .video, .muxed]
    for mediaType in mediaTypes {
        _ = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: mediaType,
            position: .unspecified
        ).devices
    }
}

func waitForMuxedDevice(deviceID: String?, timeout: TimeInterval) -> AVCaptureDevice? {
    let deadline = Date().addingTimeInterval(timeout)
    warmUpDiscovery()

    while Date() < deadline {
        warmUpDiscovery()
        let devices = muxedDevices()
        if let deviceID {
            if let match = devices.first(where: { $0.uniqueID == deviceID }) {
                return match
            }
        } else if let first = devices.first {
            return first
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }
    return nil
}

final class OneFrameCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "stupidmirror.avfoundation.frame")
    private let outputURL: URL
    private let lock = NSLock()
    private var _completed = false
    private var _error: Error?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    var completed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _completed
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _error
    }

    func start(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "StupidMirrorProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add AVCaptureDeviceInput"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "StupidMirrorProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add AVCaptureVideoDataOutput"])
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        if _completed {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw NSError(domain: "StupidMirrorProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Sample buffer has no image buffer"])
            }
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let rep = NSBitmapImageRep(ciImage: ciImage)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "StupidMirrorProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
            }
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL)
        } catch {
            lock.lock()
            _error = error
            lock.unlock()
        }

        lock.lock()
        _completed = true
        lock.unlock()

        DispatchQueue.global().async {
            self.session.stopRunning()
        }
    }
}

let options = parseOptions()
let outputURL = URL(fileURLWithPath: options.output)

print("== AVFoundation frame capture ==")
print("output: \(outputURL.path)")
print("timeout: \(options.timeout)")

let status = allowScreenCaptureDevices()
print("CMIO allowScreenCaptureDevices status: \(status)")

guard ensureVideoAccess() else {
    fputs("Video capture permission is not granted. Grant Camera permission to the launching terminal/app and rerun.\n", stderr)
    exit(2)
}

guard let device = waitForMuxedDevice(deviceID: options.deviceID, timeout: options.timeout) else {
    fputs("No .muxed iPhone screen device appeared before timeout.\n", stderr)
    exit(3)
}

print("device: \(device.localizedName)")
print("uniqueID: \(device.uniqueID)")
print("modelID: \(device.modelID)")

let capture = OneFrameCapture(outputURL: outputURL)
do {
    try capture.start(device: device)
} catch {
    fputs("Failed to start capture: \(error)\n", stderr)
    exit(4)
}

let deadline = Date().addingTimeInterval(options.timeout)
while !capture.completed && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}

if let error = capture.error {
    fputs("Failed to capture frame: \(error)\n", stderr)
    exit(5)
}

guard capture.completed else {
    fputs("Timed out waiting for first frame.\n", stderr)
    exit(6)
}

print("captured: \(outputURL.path)")
