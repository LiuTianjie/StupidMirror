import AppKit
import ServiceManagement
import XCTest
@testable import StupidMirrorApp

final class AppLifecycleTests: XCTestCase {
    func testUpdaterRunsOnlyWithAnHTTPSFeedAndAPublicKey() {
        XCTAssertTrue(AppUpdater.isConfigured([
            "SUFeedURL": "https://liutianjie.github.io/StupidMirror/updates/appcast.xml",
            "SUPublicEDKey": "Yj8/B8nrGotIJEAEp4TjsvVNNFTRAwzF0CQR4t0qkwk="
        ]))
        // Development and ad hoc builds carry no feed.
        XCTAssertFalse(AppUpdater.isConfigured([:]))
        XCTAssertFalse(AppUpdater.isConfigured(nil))
        XCTAssertFalse(AppUpdater.isConfigured([
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": "key"
        ]))
        XCTAssertFalse(AppUpdater.isConfigured([
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "  "
        ]))
    }

    func testLoginItemStatusMapsToTheSettingsToggle() {
        XCTAssertEqual(LaunchAtLoginController.state(for: .enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginController.state(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginController.state(for: .notRegistered), .disabled)
        XCTAssertEqual(LaunchAtLoginController.state(for: .notFound), .disabled)
    }

    func testDockIconFollowsTheAppsOwnWindows() {
        typealias Snapshot = DockPresence.WindowSnapshot
        let dashboard = DockPresence.dashboardIdentifier
        let mirror = DockPresence.mirrorIdentifier

        XCTAssertEqual(DockPresence.activationPolicy(windows: []), .accessory)
        XCTAssertEqual(DockPresence.activationPolicy(windows: [
            Snapshot(identifier: dashboard, isVisible: true, isMiniaturized: false)
        ]), .regular)
        XCTAssertEqual(DockPresence.activationPolicy(windows: [
            Snapshot(identifier: mirror, isVisible: true, isMiniaturized: false)
        ]), .regular)
        // A minimized window comes back through the Dock, so the icon stays.
        XCTAssertEqual(DockPresence.activationPolicy(windows: [
            Snapshot(identifier: dashboard, isVisible: false, isMiniaturized: true)
        ]), .regular)
        // Closed windows, menus and other system windows do not count.
        XCTAssertEqual(DockPresence.activationPolicy(windows: [
            Snapshot(identifier: dashboard, isVisible: false, isMiniaturized: false),
            Snapshot(identifier: nil, isVisible: true, isMiniaturized: false),
            Snapshot(identifier: NSUserInterfaceItemIdentifier("other"), isVisible: true, isMiniaturized: false)
        ]), .accessory)
    }
}
