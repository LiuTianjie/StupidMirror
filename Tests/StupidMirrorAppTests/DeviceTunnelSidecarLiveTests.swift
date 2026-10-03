import Foundation
import XCTest
@testable import StupidMirrorApp

/// Drives the real sidecar against a connected iPhone. Skipped unless
/// `STUPIDMIRROR_TEST_TUNNEL_UDID` names a device usbmuxd can see and
/// `STUPIDMIRROR_TEST_TUNNEL_RUNNER` names its installed runner bundle id
/// (for example `com.stupidmirror.wda.xxxx.xctrunner`).
final class DeviceTunnelSidecarLiveTests: XCTestCase {
    func testSidecarPublishesAReadyRunnerOnLoopback() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["STUPIDMIRROR_TEST_TUNNEL_UDID"], !udid.isEmpty,
              let runner = environment["STUPIDMIRROR_TEST_TUNNEL_RUNNER"], !runner.isEmpty else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_TUNNEL_UDID and STUPIDMIRROR_TEST_TUNNEL_RUNNER to run the live sidecar check.")
        }
        guard DeviceTunnelSidecar.executableURL() != nil else {
            throw XCTSkip("Build the sidecar first: make smtunnel")
        }

        let devices = try await DeviceTunnelSidecar.listDevices()
        XCTAssertTrue(devices.contains { $0.udid == udid }, "usbmuxd does not list \(udid): \(devices)")

        let bundleID = runner.hasSuffix(".xctrunner") ? String(runner.dropLast(".xctrunner".count)) : runner
        let configuration = IOSAgentService.sidecarConfiguration(
            udid: udid,
            transport: .auto,
            bundleID: bundleID
        )
        let started = ContinuousClock.now
        let sidecar = try await DeviceTunnelSidecar.start(configuration)
        defer { sidecar.stop() }
        let elapsed = ContinuousClock.now - started

        let endpoint = try XCTUnwrap(IOSAgentService.endpoint(for: sidecar.endpoints))
        XCTAssertEqual(endpoint.videoHost, "127.0.0.1")
        XCTAssertTrue(sidecar.isRunning)
        let ready = await IOSAgentService.isReady(endpoint.controlURL)
        XCTAssertTrue(ready, "the runner did not answer at \(endpoint.controlURL)")
        print("sidecar ready in \(elapsed) over \(sidecar.endpoints.connectionType): control \(endpoint.controlURL), video udp \(endpoint.videoPort)")

        sidecar.stop()
        XCTAssertFalse(sidecar.isRunning)
    }
}

/// Drives WebDriverAgent directly through the sidecar's loopback forward on a
/// connected iPhone. Same environment variables as the sidecar live test.
final class IOSControlLiveTests: XCTestCase {
    func testWDAControlBackendDrivesTheRunner() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["STUPIDMIRROR_TEST_TUNNEL_UDID"], !udid.isEmpty,
              let runner = environment["STUPIDMIRROR_TEST_TUNNEL_RUNNER"], !runner.isEmpty else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_TUNNEL_UDID and STUPIDMIRROR_TEST_TUNNEL_RUNNER to run the live control check.")
        }
        guard DeviceTunnelSidecar.executableURL() != nil else {
            throw XCTSkip("Build the sidecar first: make smtunnel")
        }
        let bundleID = runner.hasSuffix(".xctrunner") ? String(runner.dropLast(".xctrunner".count)) : runner
        var configuration = AppiumControlConfiguration(platform: .iOS)
        configuration.xcodeOrgID = "LIVE"
        configuration.wdaBundleID = bundleID

        let agent = IOSAgentService()
        let started = ContinuousClock.now
        let endpoint = try await agent.ensureRunning(udid: udid, configuration: configuration)
        let agentReady = ContinuousClock.now - started

        let connectStarted = ContinuousClock.now
        let backend = try await WDAControlBackend.connect(baseURL: endpoint.controlURL)
        let connected = ContinuousClock.now - connectStarted
        defer { Task { await backend.close() } }
        XCTAssertGreaterThan(backend.screenSize.width, 0)

        let tapStarted = ContinuousClock.now
        try await backend.press(.home)
        try await backend.tap(CGPoint(x: backend.screenSize.width / 2, y: backend.screenSize.height / 2))
        let twoActions = ContinuousClock.now - tapStarted
        // The gesture surface: a timed path, a long press, and a pinch.
        let size = backend.screenSize
        try await backend.dragPath([
            DevicePathSample(point: CGPoint(x: size.width / 2, y: size.height * 0.8), offsetMS: 0),
            DevicePathSample(point: CGPoint(x: size.width / 2 + 20, y: size.height * 0.6), offsetMS: 120),
            DevicePathSample(point: CGPoint(x: size.width / 2, y: size.height * 0.3), offsetMS: 260)
        ])
        try await backend.longPress(CGPoint(x: size.width / 2, y: size.height / 2), durationSeconds: 0.6)
        try await backend.press(.home)
        try await backend.pinch(at: CGPoint(x: size.width / 2, y: size.height / 2), scale: 0.6, velocity: -1)
        let png = try await backend.screenshotPNG()
        XCTAssertGreaterThan(png.count, 1_000)
        let tree = try await backend.uiTree()
        XCTAssertTrue(tree.contains("XCUIElementTypeApplication"))
        _ = try await backend.ping()
        print("live control: agent \(agentReady), session \(connected), home+tap \(twoActions), screen \(backend.screenSize)")
        await backend.close()
        await IOSAgentService.terminateSharedAgent(udid: udid)
    }
}
