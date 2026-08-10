@testable import StupidMirrorApp
import XCTest

final class AppLocalizationTests: XCTestCase {
    func testCriticalEnglishKeysArePresent() {
        for key in criticalKeys {
            XCTAssertNotEqual(AppCopy.text(key, language: .en), key, "Missing English copy for \(key)")
        }
    }

    func testCriticalChineseKeysArePresent() {
        for key in criticalKeys {
            XCTAssertNotEqual(AppCopy.text(key, language: .zhHans), key, "Missing Chinese copy for \(key)")
        }
    }

    func testChineseAndEnglishUserVisibleCopyDiffer() {
        XCTAssertEqual(AppCopy.text("menu.devices", language: .en), "Devices")
        XCTAssertEqual(AppCopy.text("menu.devices", language: .zhHans), "设备")
        XCTAssertEqual(AppCopy.text("connection.disconnected", language: .en), "Reconnecting")
        XCTAssertEqual(AppCopy.text("connection.disconnected", language: .zhHans), "重连中")
    }

    private var criticalKeys: [String] {
        [
            "dashboard.subtitle",
            "permission.body.notDetermined",
            "permission.body.denied",
            "permission.requestAccess",
            "permission.openSettings",
            "permission.recheck",
            "permission.requesting",
            "permission.microphone.title",
            "permission.microphone.body.notDetermined",
            "permission.microphone.body.denied",
            "permission.microphone.requestAccess",
            "permission.microphone.openSettings",
            "status.controlPreparingAgent",
            "status.controlSetupRequired",
            "status.controlAppiumUnavailable",
            "status.controlOpenDiagnostics",
            "control.setup.title",
            "control.setup.step1.body",
            "control.setup.step2.body",
            "control.setup.step3.body",
            "control.setup.step4.body",
            "control.setup.retry",
            "menu.showDashboard",
            "menu.devices",
            "menu.reconnecting",
            "license.menu",
            "license.activation.title",
            "license.activation.subtitle",
            "license.code.help",
            "license.badge.unactivated",
            "license.badge.help",
            "license.purchase.placeholder",
            "license.status.trialNotStarted",
            "license.status.expired",
            "license.status.licensed",
            "license.error.notConfigured",
            "license.error.invalid",
            "settings.language",
            "settings.audioPlayback",
            "settings.audioPlaybackHelp",
            "common.close",
            "card.installControlAgent",
            "detail.installControlAgent",
            "detail.controlHelp",
            "mirror.reconnectingBody",
            "mirror.pasteClipboard",
            "connection.disconnected",
            "mirror.state.running",
            "control.state.unavailable",
            "control.loading.title",
            "control.loading.startingService",
            "control.loading.reusingAgent",
            "control.loading.installingAgent",
            "control.loading.expectation.install",
            "control.loading.elapsed",
            "control.loading.keepAwake",
            "control.error.unlockDevice",
            "control.error.signing",
            "status.deviceDisconnectedRefreshing",
            "diagnostic.mirror",
            "diagnostic.microphone"
        ]
    }
}
