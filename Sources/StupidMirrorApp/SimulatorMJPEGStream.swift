import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network

enum SimulatorMJPEGError: LocalizedError {
    case ended
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .ended:
            "The simulator screen stream ended."
        case let .connection(message):
            "The simulator screen stream failed: \(message)"
        }
    }
}

/// Splits WebDriverAgent's MJPEG stream into JPEG frames. Each part is
/// `--boundary`, headers with a `Content-Length`, a blank line, then the
/// image.
struct MJPEGPartParser {
    private var buffer = Data()
    /// A part larger than this is not a screen frame; the stream is resynced.
    static let maximumFrameSize = 32 * 1_024 * 1_024

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        var frames: [Data] = []
        while let headerEnd = buffer.range(of: separator) {
            let headers = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            // The blank line after an image, or headers without a usable
            // length: skip past them to the next part.
            guard let length = Self.contentLength(headers), length > 0, length <= Self.maximumFrameSize else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            frames.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        // Headers are short; a long run without them is noise.
        if buffer.range(of: separator) == nil, buffer.count > 64 * 1_024 {
            buffer.removeAll(keepingCapacity: true)
        }
        return frames
    }

    static func contentLength(_ headers: String) -> Int? {
        for line in headers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// Reads a simulator's screen from WebDriverAgent's MJPEG server and hands
/// out decoded frames as sample buffers, like the other capture paths.
/// Decoding keeps only the newest frame: when the Mac falls behind, older
/// frames are skipped rather than queued.
///
/// The stream is read over a plain TCP connection. URLSession understands
/// `multipart/x-mixed-replace` itself and strips each part's boundary and
/// headers, which leaves nothing to tell where one JPEG ends.
final class SimulatorMJPEGStream: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let networkQueue = DispatchQueue(label: "com.stupidmirror.simulator.mjpeg.network", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "com.stupidmirror.simulator.mjpeg", qos: .userInteractive)
    private let lock = NSLock()
    private var connection: NWConnection?
    /// Only touched on `networkQueue`.
    private var parser = MJPEGPartParser()
    private var pendingFrame: Data?
    private var decoding = false
    private var stopped = false
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    init(
        url: URL,
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        host = NWEndpoint.Host(url.host ?? "127.0.0.1")
        port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 80)) ?? .http
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        lock.withLock { self.connection = connection }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let request = "GET / HTTP/1.0\r\nHost: \(self.host)\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                    if let error { self?.fail(SimulatorMJPEGError.connection(error.localizedDescription)) }
                })
                self.receive(on: connection)
            case let .failed(error), let .waiting(error):
                self.fail(SimulatorMJPEGError.connection(error.localizedDescription))
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    func stop() {
        let connection = lock.withLock { () -> NWConnection? in
            stopped = true
            pendingFrame = nil
            defer { self.connection = nil }
            return self.connection
        }
        connection?.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // The HTTP response header has no Content-Length, so the
                // parser passes over it like any other non-frame block.
                if let frame = self.parser.append(data).last {
                    self.submit(frame)
                }
            }
            if let error {
                self.fail(SimulatorMJPEGError.connection(error.localizedDescription))
            } else if isComplete {
                self.fail(SimulatorMJPEGError.ended)
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func submit(_ frame: Data) {
        let startDecode = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            pendingFrame = frame
            guard !decoding else { return false }
            decoding = true
            return true
        }
        if startDecode {
            decodeQueue.async { [weak self] in self?.decodePending() }
        }
    }

    /// Reports the first failure once; the owner decides whether to retry.
    private func fail(_ error: Error) {
        let connection = lock.withLock { () -> NWConnection? in
            guard !stopped else { return nil }
            stopped = true
            defer { self.connection = nil }
            return self.connection
        }
        guard let connection else { return }
        connection.cancel()
        onFailure(error)
    }

    // MARK: Decoding

    private func decodePending() {
        while true {
            let frame = lock.withLock { () -> Data? in
                let frame = stopped ? nil : pendingFrame
                pendingFrame = nil
                if frame == nil { decoding = false }
                return frame
            }
            guard let frame else { return }
            if let sampleBuffer = decode(frame) {
                onFrame(sampleBuffer)
            }
        }
    }

    private func decode(_ jpeg: Data) -> CMSampleBuffer? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let pixelBuffer = makePixelBuffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize.width != width || poolSize.height != height {
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
