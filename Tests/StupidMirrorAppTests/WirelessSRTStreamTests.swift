import CoreMedia
import Darwin
import Foundation
import libsrt
import XCTest
@testable import StupidMirrorApp

final class WirelessSRTStreamTests: XCTestCase {
    func testPinnedSRTLibraryCompletesLocalLiveModeHandshake() throws {
        XCTAssertEqual(srt_startup(), 0)
        let listener = srt_create_socket()
        XCTAssertNotEqual(listener, SRT_INVALID_SOCK)
        defer { srt_close(listener) }

        var transport = Int32(SRTT_LIVE.rawValue)
        var sender = true
        var tooLateDrop = true
        var peerLatency: Int32 = 80
        var sendTimeout: Int32 = 80
        var receiveTimeout: Int32 = 500
        var payloadSize: Int32 = Int32(WirelessSRTFragment.maximumMessageSize)
        try setOption(listener, SRTO_TRANSTYPE, &transport)
        try setOption(listener, SRTO_SENDER, &sender)
        try setOption(listener, SRTO_TLPKTDROP, &tooLateDrop)
        try setOption(listener, SRTO_PEERLATENCY, &peerLatency)
        try setOption(listener, SRTO_SNDTIMEO, &sendTimeout)
        try setOption(listener, SRTO_RCVTIMEO, &receiveTimeout)
        try setOption(listener, SRTO_PAYLOADSIZE, &payloadSize)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                srt_bind(listener, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertNotEqual(bindResult, SRT_ERROR, String(cString: srt_getlasterror_str()))
        XCTAssertNotEqual(srt_listen(listener, 1), SRT_ERROR, String(cString: srt_getlasterror_str()))

        var boundLength = Int32(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                srt_getsockname(listener, $0, &boundLength)
            }
        }
        XCTAssertNotEqual(nameResult, SRT_ERROR)
        XCTAssertNotEqual(address.sin_port, 0)

        let accepted = expectation(description: "SRT listener accepted caller")
        DispatchQueue.global(qos: .userInitiated).async {
            let client = srt_accept(listener, nil, nil)
            if client != SRT_INVALID_SOCK {
                srt_close(client)
                accepted.fulfill()
            }
        }

        let caller = srt_create_socket()
        XCTAssertNotEqual(caller, SRT_INVALID_SOCK)
        defer { srt_close(caller) }
        var callerTransport = Int32(SRTT_LIVE.rawValue)
        var connectTimeout: Int32 = 2_000
        try setOption(caller, SRTO_TRANSTYPE, &callerTransport)
        try setOption(caller, SRTO_CONNTIMEO, &connectTimeout)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                srt_connect(caller, $0, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertNotEqual(connectResult, SRT_ERROR, String(cString: srt_getlasterror_str()))
        wait(for: [accepted], timeout: 3)
    }

    func testLiveSRTDecoderWhenDeviceHostIsProvided() throws {
        guard let host = ProcessInfo.processInfo.environment["STUPIDMIRROR_TEST_SRT_HOST"],
              !host.isEmpty else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_SRT_HOST to run the real-device SRT decoder check.")
        }
        let receivedFrames = expectation(description: "decoded SRT/H.264 frames")
        receivedFrames.expectedFulfillmentCount = 450
        let dimensionsBox = LiveDimensionsBox()
        let stream = WirelessSRTH264Stream(
            host: host,
            onFrame: { sampleBuffer in
                if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    dimensionsBox.set(CMVideoFormatDescriptionGetDimensions(format))
                }
                receivedFrames.fulfill()
            },
            onFailure: { error in
                XCTFail("Live SRT/H.264 stream failed: \(error.localizedDescription)")
            }
        )
        stream.start()
        wait(for: [receivedFrames], timeout: 20)
        stream.stop()

        let dimensions = dimensionsBox.get()
        XCTAssertGreaterThan(dimensions.width, 0)
        XCTAssertGreaterThan(dimensions.height, 0)
    }

    func testFragmentRoundTripPreservesCompleteFrame() {
        let payload = Data((0..<(WirelessSRTFragment.maximumPayloadSize * 2 + 9)).map {
            UInt8(truncatingIfNeeded: $0)
        })
        let source = WirelessH264Packet(
            presentationTimeMicroseconds: 123_456,
            isKeyFrame: true,
            annexBPayload: payload
        )
        let messages = WirelessSRTFragment.makeMessages(for: source, frameID: 42)

        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { $0.count <= WirelessSRTFragment.maximumMessageSize })
        var reassembler = WirelessSRTFrameReassembler()
        var completed: WirelessSRTReassemblyResult?
        for message in messages {
            completed = reassembler.append(message: message)
        }
        XCTAssertEqual(completed?.frame, source)
        XCTAssertFalse(completed?.shouldRequestKeyFrame ?? true)
        XCTAssertFalse(completed?.shouldResetDecoder ?? true)
    }

    func testReassemblerNeverEmitsFrameWithMissingFragment() {
        let source = WirelessH264Packet(
            presentationTimeMicroseconds: 1,
            isKeyFrame: true,
            annexBPayload: Data(repeating: 0x65, count: WirelessSRTFragment.maximumPayloadSize * 3)
        )
        let messages = WirelessSRTFragment.makeMessages(for: source, frameID: 10)
        var reassembler = WirelessSRTFrameReassembler()

        XCTAssertNil(reassembler.append(message: messages[0]).frame)
        let loss = reassembler.append(message: messages[2])

        XCTAssertNil(loss.frame)
        XCTAssertTrue(loss.shouldRequestKeyFrame)
        XCTAssertTrue(loss.shouldResetDecoder)
    }

    func testReassemblerDropsDependentFramesUntilCompleteIDR() {
        let initial = packet(time: 1, keyFrame: true)
        let incomplete = WirelessH264Packet(
            presentationTimeMicroseconds: 2,
            isKeyFrame: false,
            annexBPayload: Data(repeating: 0x41, count: WirelessSRTFragment.maximumPayloadSize * 2)
        )
        let dependent = packet(time: 3)
        let recovery = packet(time: 4, keyFrame: true)
        var reassembler = WirelessSRTFrameReassembler()

        let initialResult = WirelessSRTFragment.makeMessages(for: initial, frameID: 100)
            .map { reassembler.append(message: $0) }.last
        let incompleteMessages = WirelessSRTFragment.makeMessages(for: incomplete, frameID: 101)
        _ = reassembler.append(message: incompleteMessages[0])
        let dependentResult = WirelessSRTFragment.makeMessages(for: dependent, frameID: 102)
            .map { reassembler.append(message: $0) }.last
        let recoveryResult = WirelessSRTFragment.makeMessages(for: recovery, frameID: 103)
            .map { reassembler.append(message: $0) }.last

        XCTAssertEqual(initialResult?.frame, initial)
        XCTAssertNil(dependentResult?.frame)
        XCTAssertTrue(dependentResult?.shouldRequestKeyFrame ?? false)
        XCTAssertTrue(dependentResult?.shouldResetDecoder ?? false)
        XCTAssertEqual(recoveryResult?.frame, recovery)
        XCTAssertFalse(recoveryResult?.shouldResetDecoder ?? true)
    }

    func testReassemblerDetectsWholeFrameJump() {
        let key = packet(time: 1, keyFrame: true)
        let nextKey = packet(time: 3, keyFrame: true)
        var reassembler = WirelessSRTFrameReassembler()

        _ = WirelessSRTFragment.makeMessages(for: key, frameID: 7)
            .map { reassembler.append(message: $0) }
        let jumped = WirelessSRTFragment.makeMessages(for: nextKey, frameID: 9)
            .map { reassembler.append(message: $0) }.last

        XCTAssertEqual(jumped?.frame, nextKey)
        XCTAssertTrue(jumped?.shouldResetDecoder ?? false)
        XCTAssertFalse(jumped?.shouldRequestKeyFrame ?? true)
    }

    func testFragmentRejectsTruncatedAndInvalidMetadata() {
        XCTAssertNil(WirelessSRTFragment(message: Data(WirelessSRTFragment.magic)))
        var invalid = Data(WirelessSRTFragment.magic)
        invalid.append(contentsOf: Array(repeating: 0, count: WirelessSRTFragment.headerSize - 4))
        invalid.append(0x41)
        XCTAssertNil(WirelessSRTFragment(message: invalid))
    }

    func testDecoderSplitsAnnexBNALUnits() {
        let payload = Data([
            0, 0, 0, 1, 0x67, 0x01,
            0, 0, 1, 0x68, 0x02,
            0, 0, 0, 1, 0x65, 0x03
        ])

        XCTAssertEqual(
            WirelessH264Decoder.annexBNALUnits(payload),
            [Data([0x67, 0x01]), Data([0x68, 0x02]), Data([0x65, 0x03])]
        )
    }

    private func packet(time: UInt64, keyFrame: Bool = false) -> WirelessH264Packet {
        WirelessH264Packet(
            presentationTimeMicroseconds: time,
            isKeyFrame: keyFrame,
            annexBPayload: Data([0, 0, 0, 1, keyFrame ? 0x65 : 0x41])
        )
    }

    private func setOption<T>(
        _ socket: SRTSOCKET,
        _ option: SRT_SOCKOPT,
        _ value: inout T
    ) throws {
        let result = withUnsafePointer(to: &value) {
            srt_setsockflag(socket, option, $0, Int32(MemoryLayout<T>.size))
        }
        if result == SRT_ERROR {
            throw NSError(
                domain: "WirelessSRTStreamTests",
                code: Int(srt_getlasterror(nil)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: srt_getlasterror_str())]
            )
        }
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
