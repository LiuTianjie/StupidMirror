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
            "status.controlPreparingAgent",
            "menu.showDashboard",
            "menu.devices",
            "menu.reconnecting",
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
            "diagnostic.mirror"
        ]
    }
}
