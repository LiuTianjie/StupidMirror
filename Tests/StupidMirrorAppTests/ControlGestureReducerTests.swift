@testable import StupidMirrorApp
import CoreGraphics
import XCTest

final class ControlGestureReducerTests: XCTestCase {
    func testDraggingEmitsOneCoherentSwipeOnMouseUp() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 20, y: 25), timestamp: 0.05))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 50, y: 45), timestamp: 0.30))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 66, y: 54), timestamp: 0.45))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 90, y: 70), timestamp: 0.60))
        XCTAssertEqual(
            reducer.endMouseDrag(at: CGPoint(x: 112, y: 83)),
            ControlGestureCommand.swipe(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 112, y: 83), durationMS: 220)
        )
    }

    func testShortCompletedDragUsesItsFullDistance() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 18, y: 24), timestamp: 0.05))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 50, y: 45), timestamp: 0.40))
        XCTAssertEqual(
            reducer.endMouseDrag(at: CGPoint(x: 51, y: 46)),
            .swipe(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 51, y: 46), durationMS: 220)
        )
    }

    func testFastSwipeIsEmittedBeforeMouseUpAndNotDuplicated() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 20, y: 24), timestamp: 0.02))
        XCTAssertEqual(
            reducer.updateMouseDrag(to: CGPoint(x: 80, y: 30), timestamp: 0.08),
            .flick(from: CGPoint(x: 10, y: 20), toward: CGPoint(x: 80, y: 30), durationMS: 160)
        )
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 110, y: 35), timestamp: 0.10))
        XCTAssertNil(reducer.endMouseDrag(at: CGPoint(x: 120, y: 40)))
    }

    func testFastHorizontalFlickUsesNativeFullScreenDirection() {
        let direction = ControlGestureNSView.flickDirection(
            from: CGPoint(x: 0.85, y: 0.5),
            toward: CGPoint(x: 0.72, y: 0.49)
        )

        XCTAssertEqual(direction, .left)
    }

    func testFastVerticalFlickUsesNativeFullScreenDirection() {
        let direction = ControlGestureNSView.flickDirection(
            from: CGPoint(x: 0.5, y: 0.80),
            toward: CGPoint(x: 0.51, y: 0.68)
        )

        XCTAssertEqual(direction, .up)
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
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 14), precise: true))
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 8), precise: true))
        XCTAssertEqual(
            reducer.flushScroll(precise: true),
            .swipe(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 100, y: 270.4), durationMS: 180)
        )
        XCTAssertNil(reducer.flushScroll(precise: true))
    }

    func testControlSessionKeepsIdleConnectionAliveLongEnoughForRealUse() {
        XCTAssertGreaterThanOrEqual(AppiumControlConfiguration().newCommandTimeoutSeconds, 300)
    }

    func testControlSessionPrefersInstalledWDAByDefault() {
        XCTAssertTrue(AppiumControlConfiguration().preferInstalledWDA)
    }

    @MainActor
    func testControlSessionExposesImmediateCancelablePreparationProgress() {
        let session = AppiumControlSession(device: DeviceIdentity(
            id: "test-device",
            udid: "00008110-001234567890001E",
            name: "Test iPhone",
            productType: "iPhone",
            osVersion: "18.0",
            connectionState: .connected,
            trustState: .trusted
        ))

        session.beginPreparingService()

        XCTAssertTrue(session.isConnecting)
        XCTAssertEqual(session.connectionPhase, .startingService)
        XCTAssertNotNil(session.connectionStartedAt)

        session.stop(serverURL: "http://127.0.0.1:4723")

        XCTAssertFalse(session.isConnecting)
        XCTAssertNil(session.connectionPhase)
        XCTAssertNil(session.connectionStartedAt)
    }

    @MainActor
    func testDisconnectKeepsMatchingSessionWarmForImmediateResume() {
        let device = DeviceIdentity(
            id: "test-device",
            udid: "00008110-001234567890001E",
            name: "Test iPhone",
            productType: "iPhone",
            osVersion: "18.0",
            connectionState: .connected,
            trustState: .trusted
        )
        let session = AppiumControlSession(device: device)
        let configuration = AppiumControlConfiguration(derivedDataPath: "/tmp/StupidMirror-WDA-tests")
        session.installWarmSessionForTesting(
            serverURL: "http://127.0.0.1:4723",
            bundleID: "com.apple.Preferences",
            configuration: configuration,
            screenSize: DeviceScreenSize(width: 390, height: 844)
        )

        session.disconnectKeepingAgentWarm()
        XCTAssertFalse(session.isReady)

        XCTAssertTrue(session.resumeWarmSession(
            serverURL: "http://127.0.0.1:4723",
            bundleID: "com.apple.Preferences",
            configuration: configuration
        ))
        XCTAssertTrue(session.isReady)
    }

    func testFirstInstallUsesAutomaticProvisioningAndTeamScopedBundleID() {
        var configuration = AppiumControlConfiguration()
        configuration.xcodeOrgID = "6XRHTPFUB6"

        XCTAssertTrue(configuration.allowProvisioningDeviceRegistration)
        XCTAssertEqual(configuration.installationWDABundleID, "com.stupidmirror.wda.6xrhtpfub6")

        configuration.wdaBundleID = "com.example.CustomWDA"
        XCTAssertEqual(configuration.installationWDABundleID, "com.example.CustomWDA")
    }

    func testControlConfigurationIsolatesParallelDevicesDeterministically() {
        var base = AppiumControlConfiguration()
        base.derivedDataPath = "/tmp/StupidMirror-WDA-tests"

        let first = base.isolated(forDeviceUDID: "00008110-001234567890001E")
        let firstAgain = base.isolated(forDeviceUDID: "00008110-001234567890001E")
        let second = base.isolated(forDeviceUDID: "00008120-009876543210001E")

        XCTAssertEqual(first.wdaLocalPort, firstAgain.wdaLocalPort)
        XCTAssertEqual(first.mjpegServerPort, firstAgain.mjpegServerPort)
        XCTAssertEqual(first.derivedDataPath, firstAgain.derivedDataPath)
        XCTAssertNotEqual(first.wdaLocalPort, second.wdaLocalPort)
        XCTAssertNotEqual(first.mjpegServerPort, second.mjpegServerPort)
        XCTAssertNotEqual(first.derivedDataPath, second.derivedDataPath)
        XCTAssertTrue((10_000..<30_000).contains(first.wdaLocalPort))
        XCTAssertTrue((30_000..<50_000).contains(first.mjpegServerPort))
    }

    func testSessionCapabilitiesIncludePerDeviceWDAForwardingPort() {
        var configuration = AppiumControlConfiguration()
        configuration.wdaLocalPort = 18_123

        let capabilities = AppiumSessionCapabilities.make(
            udid: "test-udid",
            bundleID: "com.apple.Preferences",
            configuration: configuration
        )

        XCTAssertEqual(capabilities["appium:wdaLocalPort"] as? Int, 18_123)
        XCTAssertEqual(capabilities["appium:allowProvisioningDeviceRegistration"] as? Bool, true)
    }

    func testWirelessSessionUsesDirectWDAHostWithoutMacPortForwarding() {
        var configuration = AppiumControlConfiguration()
        configuration.directDeviceHost = "test-iphone.local"
        configuration.platformVersion = "26.5"
        configuration.webDriverAgentURL = "http://test-iphone.local:8100"
        let isolated = configuration.isolated(forDeviceUDID: "wireless-device")
        let capabilities = AppiumSessionCapabilities.make(
            udid: "wireless-device",
            bundleID: "",
            configuration: isolated
        )

        XCTAssertEqual(isolated.wdaLocalPort, 8_100)
        XCTAssertEqual(isolated.mjpegServerPort, 9_100)
        XCTAssertEqual(
            capabilities["appium:wdaBaseUrl"] as? String,
            "http://test-iphone.local"
        )
        XCTAssertEqual(capabilities["appium:platformVersion"] as? String, "26.5")
        XCTAssertEqual(
            capabilities["appium:webDriverAgentUrl"] as? String,
            "http://test-iphone.local:8100"
        )
        XCTAssertEqual(capabilities["appium:wdaRemotePort"] as? Int, 8_100)
        XCTAssertNil(capabilities["appium:mjpegServerPort"])
    }

    func testPreinstalledWDAReuseUsesShortProbeTimeout() {
        let configuration = AppiumControlConfiguration()
        let probe = configuration.preinstalledProbeConfiguration

        XCTAssertLessThan(configuration.preinstalledWDAStartupTimeoutSeconds, configuration.sessionStartupTimeoutSeconds)
        XCTAssertEqual(probe.wdaStartupRetries, 1)
        XCTAssertEqual(probe.wdaStartupRetryIntervalMS, 0)
        XCTAssertTrue(probe.usePreinstalledWDA)
        XCTAssertFalse(probe.usePrebuiltWDA)
        XCTAssertFalse(probe.useNewWDA)
        XCTAssertLessThan(
            TimeInterval(probe.wdaLaunchTimeoutMS) / 1_000,
            probe.sessionStartupTimeoutSeconds
        )
        XCTAssertLessThanOrEqual(probe.sessionStartupTimeoutSeconds, 15)
    }

    func testCachedWDABuildRequiresRunnerAndXctestrunForSameDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let udid = "cached-device"
        let isolated = AppiumControlConfiguration(derivedDataPath: root.path)
            .isolated(forDeviceUDID: udid)
        let products = URL(fileURLWithPath: isolated.derivedDataPath, isDirectory: true)
            .appendingPathComponent("Build/Products", isDirectory: true)
        let runner = products
            .appendingPathComponent("Debug-iphoneos", isDirectory: true)
            .appendingPathComponent("WebDriverAgentRunner-Runner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)

        XCTAssertFalse(DeviceGalleryStore.hasCachedWDABuild(
            udid: udid,
            derivedDataPath: root.path
        ))

        try Data().write(to: products.appendingPathComponent("WebDriverAgentRunner.xctestrun"))
        XCTAssertFalse(DeviceGalleryStore.hasCachedWDABuild(
            udid: udid,
            derivedDataPath: root.path
        ))

        let framework = runner
            .appendingPathComponent("PlugIns/WebDriverAgentRunner.xctest/Frameworks/WebDriverAgentLib.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("binary application/x-stupidmirror-h264 marker".utf8)
            .write(to: framework.appendingPathComponent("WebDriverAgentLib"))
        XCTAssertTrue(DeviceGalleryStore.hasCachedWDABuild(
            udid: udid,
            derivedDataPath: root.path
        ))
        XCTAssertFalse(DeviceGalleryStore.hasCachedWDABuild(
            udid: "different-device",
            derivedDataPath: root.path
        ))
    }

    func testWDAStartupUsesOneAppiumOwnedAttemptWithRequestHeadroom() {
        let configuration = AppiumControlConfiguration()

        XCTAssertEqual(configuration.wdaStartupRetries, 1)
        XCTAssertEqual(configuration.wdaStartupRetryIntervalMS, 0)
        XCTAssertFalse(configuration.useNewWDA)
        XCTAssertLessThan(
            TimeInterval(configuration.wdaLaunchTimeoutMS) / 1_000,
            configuration.sessionStartupTimeoutSeconds
        )
        XCTAssertLessThanOrEqual(configuration.sessionStartupTimeoutSeconds, 125)
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

    func testActionFailureInvalidatesDeadSessionsButNotOrdinaryBadInput() {
        XCTAssertTrue(AppiumError.shouldInvalidateActiveSession(afterActionError: AppiumError.httpStatus(404, #"{"value":{"message":"invalid session id"}}"#)))
        XCTAssertTrue(AppiumError.shouldInvalidateActiveSession(afterActionError: AppiumError.httpStatus(500, #"{"value":{"message":"socket hang up while talking to WDA"}}"#)))

        XCTAssertFalse(AppiumError.shouldInvalidateActiveSession(afterActionError: AppiumError.httpStatus(400, #"{"value":{"message":"bad argument: x must be a number"}}"#)))
    }

    func testAppiumDragUsesOneShortW3CGestureWithoutHalfSecondHold() throws {
        let payload = AppiumPointerAction.dragPayload(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 80, y: 120),
            durationMS: 200
        )
        let sequences = try XCTUnwrap(payload["actions"] as? [[String: Any]])
        let actions = try XCTUnwrap(sequences.first?["actions"] as? [[String: Any]])

        XCTAssertEqual(actions.map { $0["type"] as? String }, [
            "pointerMove", "pointerDown", "pointerMove", "pointerUp"
        ])
        XCTAssertEqual(actions[2]["duration"] as? Int, 200)
        XCTAssertLessThan(actions[2]["duration"] as? Int ?? 500, 500)
    }

    func testLowLatencyControlSettingsDisableTwoSecondAnimationWait() throws {
        let settings = try XCTUnwrap(
            AppiumControlSettings.lowLatencyPayload()["settings"] as? [String: Any]
        )

        XCTAssertEqual(settings["animationCoolOffTimeout"] as? Double, 0)
        XCTAssertEqual(settings["waitForIdleTimeout"] as? Double, 0)
    }

    func testNativeFlickUsesAFullScreenW3CTrajectory() {
        let points = AppiumControlSession.flickPoints(
            direction: .left,
            size: DeviceScreenSize(width: 420, height: 912)
        )

        XCTAssertEqual(points.start.x, 357, accuracy: 0.01)
        XCTAssertEqual(points.end.x, 63, accuracy: 0.01)
        XCTAssertEqual(points.start.y, 456, accuracy: 0.01)
        XCTAssertEqual(points.end.y, 456, accuracy: 0.01)
    }

    func testSessionWithoutLaunchBundleStartsFromCurrentForegroundApp() {
        let capabilities = AppiumSessionCapabilities.make(udid: "test-udid", bundleID: "  ")

        XCTAssertNil(capabilities["appium:bundleId"])
    }

    func testSessionIncludesExplicitLaunchBundleWhenConfigured() {
        let capabilities = AppiumSessionCapabilities.make(
            udid: "test-udid",
            bundleID: " com.example.App "
        )

        XCTAssertEqual(capabilities["appium:bundleId"] as? String, "com.example.App")
    }
}
