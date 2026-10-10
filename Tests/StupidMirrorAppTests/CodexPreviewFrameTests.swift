@testable import StupidMirrorApp
import CoreMedia
import CoreVideo
import ImageIO
import XCTest

final class CodexPreviewFrameTests: XCTestCase {
    func testPreviewPreservesNativeResolutionWithoutLossyEncoding() throws {
        let width = 1260, height = 2736
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<height {
            let bytes = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                // Single-pixel vertical lines expose resizing or JPEG smoothing.
                let value: UInt8 = col.isMultiple(of: 2) ? 0 : 255
                bytes[col * 4] = value; bytes[col * 4 + 1] = value
                bytes[col * 4 + 2] = value; bytes[col * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let store = MirrorFrameStore()
        store.submit(try XCTUnwrap(sample))
        let frame = try XCTUnwrap(store.previewPNG(afterSequence: 0))
        XCTAssertEqual(frame.width, width); XCTAssertEqual(frame.height, height)
        XCTAssertEqual(frame.mimeType, "image/png")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frame.data)))
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
        let decoded = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(decoded))
        XCTAssertEqual(bytes[0], 0); XCTAssertEqual(bytes[4], 255)
        XCTAssertNil(store.previewPNG(afterSequence: frame.seq)?.data)
        store.clear()
        XCTAssertNil(store.previewPNG(afterSequence: 0))
    }
}
