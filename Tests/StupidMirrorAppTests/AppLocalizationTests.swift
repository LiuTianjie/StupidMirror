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
            "menu.showDashboard",
            "menu.devices",
            "menu.reconnecting",
            "license.menu",
            "license.activation.title",
            "license.activation.subtitle",
            "license.code.help",
            "license.purchase.placeholder",
            "license.status.trialNotStarted",
            "license.status.expired",
            "license.status.licensed",
            "license.error.notConfigured",
            "license.error.invalid",
            "settings.language",
            "common.close",
            "card.installControlAgent",
            "detail.installControlAgent",
            "mirror.reconnectingBody",
            "mirror.pasteClipboard",
            "connection.disconnected",
            "mirror.state.running",
            "control.state.unavailable",
            "control.error.unlockDevice",
            "control.error.signing",
            "status.deviceDisconnectedRefreshing",
            "diagnostic.mirror",
            "diagnostic.microphone"
        ]
    }
}
