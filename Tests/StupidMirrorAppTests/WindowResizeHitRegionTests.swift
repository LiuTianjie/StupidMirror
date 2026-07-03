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

    func testWindowEdgesAreResizeTargets() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 640)

        XCTAssertTrue(WindowResizeCorner.top.containsResizePoint(CGPoint(x: 160, y: 635), in: bounds))
        XCTAssertTrue(WindowResizeCorner.bottom.containsResizePoint(CGPoint(x: 160, y: 5), in: bounds))
        XCTAssertTrue(WindowResizeCorner.left.containsResizePoint(CGPoint(x: 5, y: 320), in: bounds))
        XCTAssertTrue(WindowResizeCorner.right.containsResizePoint(CGPoint(x: 315, y: 320), in: bounds))

        XCTAssertFalse(WindowResizeCorner.top.containsResizePoint(CGPoint(x: 160, y: 620), in: bounds))
        XCTAssertFalse(WindowResizeCorner.right.containsResizePoint(CGPoint(x: 300, y: 320), in: bounds))
    }
}
