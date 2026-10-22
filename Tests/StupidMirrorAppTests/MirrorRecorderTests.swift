@preconcurrency import AVFoundation
@testable import StupidMirrorApp
import CoreMedia
import XCTest

final class MirrorRecorderTests: XCTestCase {
    func testRecordsFramesAndFitsARotatedFrame() async throws {
        let store = MirrorFrameStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = MirrorRecorder(store: store, outputURL: url)
        recorder.start()
        for index in 0..<12 {
            let portrait = index != 6
            store.submit(try Self.sampleBuffer(width: portrait ? 120 : 240, height: portrait ? 240 : 120))
            try await Task.sleep(for: .milliseconds(30))
        }
        let result = try await recorder.stop()

        XCTAssertEqual(result.width, 120)
        XCTAssertEqual(result.height, 240)
        XCTAssertGreaterThanOrEqual(result.frameCount, 6)
        XCTAssertGreaterThan(result.durationSeconds, 0.2)
        XCTAssertNil(result.stoppedReason)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 120, height: 240))
    }

    func testStopWithoutFramesReportsIt() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString).mp4")
        let recorder = MirrorRecorder(store: MirrorFrameStore(), outputURL: url)
        recorder.start()
        do {
            _ = try await recorder.stop()
            XCTFail("Expected noFrames")
        } catch {
            XCTAssertEqual(error as? MirrorRecorderError, .noFrames)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private static func sampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return try XCTUnwrap(sample)
    }
}
