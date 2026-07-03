@testable import StupidMirrorApp
import CoreGraphics
import XCTest

final class WindowResizeHitRegionTests: XCTestCase {
    func testTopLeftResizeHandleDoesNotCoverTrafficLightButtons() {
        let bounds = CGRect(x: 0, y: 0, width: 56, height: 56)

        XCTAssertFalse(
            WindowResizeCorner.topLeft.containsResizePoint(CGPoint(x: 25, y: 34), in: bounds)
        )
        XCTAssertTrue(
            WindowResizeCorner.topLeft.containsResizePoint(CGPoint(x: 6, y: 34), in: bounds)
        )
        XCTAssertTrue(
            WindowResizeCorner.topLeft.containsResizePoint(CGPoint(x: 25, y: 51), in: bounds)
        )
    }

    func testTopRightResizeHandleLeavesChromeButtonsClickable() {
        let bounds = CGRect(x: 0, y: 0, width: 56, height: 56)

        XCTAssertFalse(
            WindowResizeCorner.topRight.containsResizePoint(CGPoint(x: 31, y: 34), in: bounds)
        )
        XCTAssertTrue(
            WindowResizeCorner.topRight.containsResizePoint(CGPoint(x: 50, y: 34), in: bounds)
        )
        XCTAssertTrue(
            WindowResizeCorner.topRight.containsResizePoint(CGPoint(x: 31, y: 51), in: bounds)
        )
    }
}
