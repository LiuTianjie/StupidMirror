@testable import StupidMirrorApp
import CoreGraphics
import XCTest

final class ControlGestureReducerTests: XCTestCase {
    func testDraggingStreamsSwipeSegmentsWhileMouseMoves() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20))

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 20, y: 25)))
        XCTAssertEqual(
            reducer.updateMouseDrag(to: CGPoint(x: 50, y: 45)),
            ControlGestureCommand.swipe(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 45), durationMS: 16)
        )
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 66, y: 54)))
        XCTAssertEqual(
            reducer.updateMouseDrag(to: CGPoint(x: 90, y: 70)),
            ControlGestureCommand.swipe(from: CGPoint(x: 50, y: 45), to: CGPoint(x: 90, y: 70), durationMS: 16)
        )
        XCTAssertEqual(
            reducer.endMouseDrag(at: CGPoint(x: 112, y: 83)),
            ControlGestureCommand.swipe(from: CGPoint(x: 90, y: 70), to: CGPoint(x: 112, y: 83), durationMS: 16)
        )
    }

    func testMouseUpDoesNotReplayAlreadyStreamedDrag() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20))

        XCTAssertEqual(
            reducer.updateMouseDrag(to: CGPoint(x: 50, y: 45)),
            ControlGestureCommand.swipe(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 45), durationMS: 16)
        )
        XCTAssertNil(reducer.endMouseDrag(at: CGPoint(x: 51, y: 46)))
    }

    func testShortMouseGestureEmitsTap() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 24, y: 40))

        XCTAssertEqual(
            reducer.endMouseDrag(at: CGPoint(x: 28, y: 43)),
            .tap(CGPoint(x: 28, y: 43))
        )
    }

    func testScrollAccumulatesUntilExplicitFlush() {
        var reducer = ControlGestureReducer()

        reducer.beginScroll(at: CGPoint(x: 100, y: 200))
        XCTAssertEqual(
            reducer.appendScroll(delta: CGSize(width: 0, height: 14), precise: true),
            .swipe(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 100, y: 244.8), durationMS: 45)
        )
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 8), precise: true))
        XCTAssertNil(reducer.flushScroll(precise: true))
        XCTAssertNil(reducer.flushScroll(precise: true))
    }

    func testControlSessionKeepsIdleConnectionAliveLongEnoughForRealUse() {
        XCTAssertGreaterThanOrEqual(AppiumControlConfiguration().newCommandTimeoutSeconds, 300)
    }

    func testControlSessionPrefersInstalledWDAByDefault() {
        XCTAssertTrue(AppiumControlConfiguration().preferInstalledWDA)
    }

    func testPreinstalledWDAReuseUsesShortProbeTimeout() {
        let configuration = AppiumControlConfiguration()

        XCTAssertLessThan(configuration.preinstalledWDAStartupTimeoutSeconds, configuration.sessionStartupTimeoutSeconds)
        XCTAssertLessThanOrEqual(configuration.preinstalledWDAStartupTimeoutSeconds, 35)
    }

    func testInstalledWDASessionUsesLaunchOnlyCapability() {
        var configuration = AppiumControlConfiguration()
        configuration.usePreinstalledWDA = true
        configuration.usePrebuiltWDA = true
        configuration.useNewWDA = true
        configuration.wdaBundleID = "com.gaojiua.WebDriverAgentRunner"

        let capabilities = AppiumSessionCapabilities.make(
            udid: "test-udid",
            bundleID: "com.apple.Preferences",
            configuration: configuration
        )

        XCTAssertEqual(capabilities["appium:usePreinstalledWDA"] as? Bool, true)
        XCTAssertNil(capabilities["appium:usePrebuiltWDA"])
        XCTAssertEqual(capabilities["appium:useNewWDA"] as? Bool, true)
        XCTAssertEqual(capabilities["appium:updatedWDABundleId"] as? String, "com.gaojiua.WebDriverAgentRunner")
    }

    func testInstalledWDAFallbackDoesNotHideActionableUserErrors() {
        XCTAssertTrue(AppiumError.shouldFallbackToWDAInstall(afterInstalledWDAError: AppiumError.httpStatus(500, #"{"value":{"message":"WebDriverAgentRunner is not installed"}}"#)))
        XCTAssertTrue(AppiumError.shouldFallbackToWDAInstall(afterInstalledWDAError: AppiumError.httpStatus(500, #"{"value":{"message":"connect ECONNREFUSED 127.0.0.1:8100"}}"#)))
        XCTAssertFalse(AppiumError.shouldFallbackToWDAInstall(afterInstalledWDAError: AppiumError.httpStatus(500, #"{"value":{"message":"Unlock iPhone to Continue"}}"#)))
        XCTAssertFalse(AppiumError.shouldFallbackToWDAInstall(afterInstalledWDAError: AppiumError.httpStatus(500, #"{"value":{"message":"Developer Mode is disabled"}}"#)))
    }

    func testFreshWDARetryOnlyHandlesRecoverableAgentFailures() {
        XCTAssertTrue(AppiumError.shouldRetryWithFreshWDA(afterSessionError: AppiumError.timeout("Timed out while starting WebDriverAgent after 210s.")))
        XCTAssertTrue(AppiumError.shouldRetryWithFreshWDA(afterSessionError: AppiumError.httpStatus(500, #"{"value":{"message":"WebDriverAgent did not become ready and WDA is not listening on 8100"}}"#)))

        XCTAssertFalse(AppiumError.shouldRetryWithFreshWDA(afterSessionError: AppiumError.httpStatus(500, #"{"value":{"message":"Unlock iPhone Air to Continue"}}"#)))
        XCTAssertFalse(AppiumError.shouldRetryWithFreshWDA(afterSessionError: AppiumError.httpStatus(500, #"{"value":{"message":"xcodebuild failed because no provisioning profile was found"}}"#)))
    }

    func testActionFailureInvalidatesDeadSessionsButNotOrdinaryBadInput() {
        XCTAssertTrue(AppiumError.shouldInvalidateActiveSession(afterActionError: AppiumError.httpStatus(404, #"{"value":{"message":"invalid session id"}}"#)))
        XCTAssertTrue(AppiumError.shouldInvalidateActiveSession(afterActionError: AppiumError.httpStatus(500, #"{"value":{"message":"socket hang up while talking to WDA"}}"#)))

        XCTAssertFalse(AppiumError.shouldInvalidateActiveSession(afterActionError: AppiumError.httpStatus(400, #"{"value":{"message":"bad argument: x must be a number"}}"#)))
    }

    func testAppiumDragUsesShortW3CPointerActionInsteadOfHalfSecondHold() throws {
        let payload = AppiumPointerAction.dragPayload(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 80, y: 120),
            durationMS: 16
        )
        let sequences = try XCTUnwrap(payload["actions"] as? [[String: Any]])
        let pointer = try XCTUnwrap(sequences.first)
        let actions = try XCTUnwrap(pointer["actions"] as? [[String: Any]])

        XCTAssertEqual(pointer["type"] as? String, "pointer")
        XCTAssertEqual((pointer["parameters"] as? [String: Any])?["pointerType"] as? String, "touch")
        XCTAssertEqual(actions.compactMap { $0["type"] as? String }, [
            "pointerMove",
            "pointerDown",
            "pointerMove",
            "pointerUp"
        ])
        XCTAssertEqual(actions[0]["x"] as? Int, 10)
        XCTAssertEqual(actions[0]["y"] as? Int, 20)
        XCTAssertEqual(actions[2]["x"] as? Int, 80)
        XCTAssertEqual(actions[2]["y"] as? Int, 120)
        XCTAssertEqual(actions[2]["duration"] as? Int, 16)
        XCTAssertLessThan(actions[2]["duration"] as? Int ?? 500, 500)
    }
}
