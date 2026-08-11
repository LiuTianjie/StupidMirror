import CoreMedia
import Foundation
import XCTest
@testable import StupidMirrorApp

final class WirelessH264StreamTests: XCTestCase {
    func testLiveDecoderWhenDeviceURLIsProvided() throws {
        guard let rawURL = ProcessInfo.processInfo.environment["STUPIDMIRROR_TEST_H264_URL"],
              let url = URL(string: rawURL) else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_H264_URL to run the real-device decoder check.")
        }
        let receivedFrames = expectation(description: "decoded H.264 frames")
        receivedFrames.expectedFulfillmentCount = 30
        let dimensionsBox = LiveDimensionsBox()
        let stream = WirelessH264Stream(
            url: url,
            onFrame: { sampleBuffer in
                if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    dimensionsBox.set(CMVideoFormatDescriptionGetDimensions(format))
                }
                receivedFrames.fulfill()
            },
            onFailure: { error in
                XCTFail("Live H.264 stream failed: \(error.localizedDescription)")
            }
        )
        stream.start()
        wait(for: [receivedFrames], timeout: 8)
        stream.stop()

        let dimensions = dimensionsBox.get()
        XCTAssertGreaterThan(dimensions.width, 0)
        XCTAssertGreaterThan(dimensions.height, 0)
    }

    func testFramerHandlesFragmentedHeaderAndPayload() throws {
        let packet = makePacket(
            presentationTime: 42_000,
            keyFrame: true,
            payload: Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB])
        )
        let stream = WirelessH264Framer.magic + packet
        var framer = WirelessH264Framer()

        XCTAssertEqual(try framer.append(stream.prefix(3)), [])
        XCTAssertEqual(try framer.append(stream.dropFirst(3).prefix(8)), [])
        let packets = try framer.append(stream.dropFirst(11))

        XCTAssertEqual(
            packets,
            [
                WirelessH264Packet(
                    presentationTimeMicroseconds: 42_000,
                    isKeyFrame: true,
                    annexBPayload: Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB])
                )
            ]
        )
    }

    func testFramerReturnsMultiplePacketsFromOneNetworkChunk() throws {
        let first = makePacket(
            presentationTime: 1,
            keyFrame: true,
            payload: Data([0, 0, 0, 1, 0x67])
        )
        let second = makePacket(
            presentationTime: 2,
            keyFrame: false,
            payload: Data([0, 0, 0, 1, 0x41, 0x01])
        )
        var framer = WirelessH264Framer()

        let packets = try framer.append(WirelessH264Framer.magic + first + second)

        XCTAssertEqual(packets.count, 2)
        XCTAssertTrue(packets[0].isKeyFrame)
        XCTAssertFalse(packets[1].isKeyFrame)
        XCTAssertEqual(packets.map(\.presentationTimeMicroseconds), [1, 2])
    }

    func testFramerRejectsWrongProtocolMagic() {
        var framer = WirelessH264Framer()

        XCTAssertThrowsError(try framer.append(Data("NOPE".utf8))) { error in
            XCTAssertEqual(error as? WirelessH264FramerError, .invalidMagic)
        }
    }

    private func makePacket(
        presentationTime: UInt64,
        keyFrame: Bool,
        payload: Data
    ) -> Data {
        var result = Data()
        var payloadLength = UInt32(payload.count).bigEndian
        var presentationTime = presentationTime.bigEndian
        withUnsafeBytes(of: &payloadLength) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &presentationTime) { result.append(contentsOf: $0) }
        result.append(keyFrame ? 1 : 0)
        result.append(contentsOf: [0, 0, 0])
        result.append(payload)
        return result
    }
}

private final class LiveDimensionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CMVideoDimensions(width: 0, height: 0)

    func set(_ dimensions: CMVideoDimensions) {
        lock.withLock { value = dimensions }
    }

    func get() -> CMVideoDimensions {
        lock.withLock { value }
    }
}
