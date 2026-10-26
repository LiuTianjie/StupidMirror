@testable import StupidMirrorApp
import XCTest

final class DeviceFormFactorTests: XCTestCase {
    func testPostureControlsApplyOnlyToDuoIdentities() {
        XCTAssertEqual(DeviceFormFactor.detect(productType: "iPhone Duo", modelID: nil).availablePostures, [.closed, .partiallyOpen, .open])
        XCTAssertEqual(DeviceFormFactor.detect(productType: "iOS Device", modelID: "iPhone19,4"), .foldable)
        XCTAssertTrue(DeviceFormFactor.detect(productType: "iPhone 15 Pro", modelID: "iPhone16,1").availablePostures.isEmpty)
    }

    func testLiveDisplayDecodesBooleanAndLegacyNumericFlags() throws {
        for flag in ["true", "1"] {
            let json = """
            {"display_id":3,"native_width":2007,"native_height":2853,"point_scale":3,
             "orientation":"rot90","foldable":\(flag),"hinge_angle":90,"posture":"partially_open"}
            """
            let state = try JSONDecoder().decode(SimulatorDisplayState.self, from: Data(json.utf8))
            XCTAssertEqual(state.posture, .partiallyOpen)
            XCTAssertEqual(state.activeScreen, "inner")
            XCTAssertEqual(state.logicalSize, CGSize(width: 951, height: 669))
        }
    }

    func testActivePanelComesFromDisplayNotAnUnconfirmedPosture() throws {
        let json = """
        {"display_id":1,"native_width":1398,"native_height":2034,"point_scale":3,
         "orientation":"rot0","foldable":true,"hinge_angle":90,"posture":"partially_open"}
        """
        let state = try JSONDecoder().decode(SimulatorDisplayState.self, from: Data(json.utf8))
        XCTAssertEqual(state.activeScreen, "outer")
        XCTAssertEqual(state.logicalSize, CGSize(width: 466, height: 678))
    }
}
