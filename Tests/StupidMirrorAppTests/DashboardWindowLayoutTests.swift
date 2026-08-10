@testable import StupidMirrorApp
import AppKit
import XCTest

final class DashboardWindowLayoutTests: XCTestCase {
    func testLargeScreenUsesPreferredContentSize() {
        let sizes = DashboardWindowLayout.sizes(
            for: NSRect(x: 0, y: 0, width: 2_560, height: 1_345)
        )

        XCTAssertEqual(sizes.initial, NSSize(width: 1_100, height: 700))
        XCTAssertEqual(sizes.minimum, NSSize(width: 1_000, height: 640))
    }

    func testSmallScreenClampsInitialAndMinimumSizesInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let sizes = DashboardWindowLayout.sizes(for: visibleFrame)

        XCTAssertEqual(sizes.initial, NSSize(width: 804, height: 524))
        XCTAssertEqual(sizes.minimum, sizes.initial)
    }

    func testExtremelySmallScreenNeverProducesAnOversizedWindow() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let sizes = DashboardWindowLayout.sizes(for: visibleFrame)

        XCTAssertLessThanOrEqual(sizes.initial.width, visibleFrame.width)
        XCTAssertLessThanOrEqual(sizes.initial.height, visibleFrame.height)
        XCTAssertEqual(sizes.minimum, sizes.initial)
    }

    func testMissingScreenFallsBackToPreferredSizes() {
        let sizes = DashboardWindowLayout.sizes(for: nil)

        XCTAssertEqual(sizes.initial, DashboardWindowLayout.preferredContentSize)
        XCTAssertEqual(sizes.minimum, DashboardWindowLayout.minimumContentSize)
    }
}
