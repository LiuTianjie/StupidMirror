@testable import StupidMirrorApp
import XCTest

final class AppiumErrorTests: XCTestCase {
    func testLockedDeviceMessageIsMappedToActionableCopyKey() {
        let body = """
        {"value":{"message":"Error Domain=com.apple.dt.deviceprep Code=-3 \\"Unlock iPhone Air to Continue\\" Xcode cannot launch WebDriverAgentRunner because the device is locked."}}
        """

        let message = AppiumError.controlFailureMessage(for: AppiumError.httpStatus(500, body))

        XCTAssertEqual(message, "control.error.unlockDevice")
    }

    func testSigningFailureMessageIsMappedToActionableCopyKey() {
        let error = AppiumError.httpStatus(500, #"{"value":{"message":"xcodebuild failed because no provisioning profile was found"}}"#)

        XCTAssertEqual(AppiumError.controlFailureMessage(for: error), "control.error.signing")
    }
}
