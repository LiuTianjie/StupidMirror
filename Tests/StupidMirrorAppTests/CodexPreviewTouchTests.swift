@testable import StupidMirrorApp
import Foundation
import XCTest

final class CodexPreviewTouchTests: XCTestCase {
    private func decode(_ extra: String = "", phase: String = "down") throws -> CodexPreviewTouchEvent {
        let json = """
        {"phase":"\(phase)","gesture_id":"wheel","seq":0,"x":0.5,"y":0.5,"geometry_id":"3"\(extra)}
        """
        return try JSONDecoder().decode(CodexPreviewTouchEvent.self, from: Data(json.utf8))
    }

    func testOldPointerMessageRemainsAnAbsoluteTouch() throws {
        let event = try decode()
        XCTAssertTrue(event.isValid)
        XCTAssertNil(try event.touchEvent().nativeInput)
    }

    func testWheelOwnsInputWithoutCreatingAPhasedFingerAndReleaseEmitsNoReport() throws {
        let event = try decode(",\"scroll\":{\"delta_x\":2,\"delta_y\":-4}")
        let input = try XCTUnwrap(event.touchEvent().nativeInput)
        XCTAssertEqual(input.reports.count, 1)
        XCTAssertEqual(input.reports.first?.serviceID, 0x501)
        XCTAssertEqual(Array(input.reports[0].data.prefix(5)), [7, 0, 0, 2, 252])
        XCTAssertTrue(input.cancellationReports.isEmpty)
        let released = try decode(",\"scroll\":{\"delta_x\":0,\"delta_y\":0}", phase: "up")
        XCTAssertEqual(try released.touchEvent().nativeInput?.reports, [])
    }

    func testInvalidWheelPayloadCannotSendInput() throws {
        XCTAssertThrowsError(try decode(",\"scroll\":null"))
        XCTAssertThrowsError(try decode(",\"scroll\":{\"delta_x\":1}"))
        XCTAssertThrowsError(try decode(",\"scroll\":{\"delta_x\":null,\"delta_y\":0}"))
        let excessive = try decode(",\"scroll\":{\"delta_x\":1000001,\"delta_y\":0}")
        XCTAssertFalse(excessive.isValid)
        XCTAssertThrowsError(try excessive.touchEvent())
        let lateMovement = try decode(",\"scroll\":{\"delta_x\":1,\"delta_y\":0}", phase: "up")
        XCTAssertFalse(lateMovement.isValid)
    }
}
