@testable import StupidMirrorApp
import XCTest

final class DeviceDisplayProfileTests: XCTestCase {
    func testIPhoneAirProfileUsesNativeLogicalRatio() {
        let profile = DeviceDisplayProfile.profile(for: "iPhone18,4", name: "iPhone Air")

        XCTAssertEqual(profile?.logicalSize.width, 420)
        XCTAssertEqual(profile?.logicalSize.height, 912)
        XCTAssertEqual(profile?.pixelSize.width, 1260)
        XCTAssertEqual(profile?.pixelSize.height, 2736)
        XCTAssertEqual(profile?.aspectRatio ?? 0, 420.0 / 912.0, accuracy: 0.0001)
    }
}
