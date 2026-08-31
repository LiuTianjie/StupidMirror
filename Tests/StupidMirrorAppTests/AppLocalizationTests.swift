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
            "permission.usbBanner.title",
            "permission.usbBanner.body",
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
            "toolbar.discoverWireless",
            "toolbar.discoverWirelessHelp",
            "status.discoveringWireless",
            "status.wirelessLocalNetworkDenied",
            "wireless.error.firstUSBSetupRequired",
            "wireless.error.launchFailed",
            "wireless.error.iphoneLocalNetworkDenied",
            "wireless.error.timedOut",
            "wireless.start.checkingAgent",
            "wireless.start.waitingForAgent",
            "wireless.start.connectingVideo",
            "wireless.start.retryingAgent",
            "wireless.start.elapsed",
            "wireless.setup.title",
            "wireless.setup.step1.body",
            "wireless.setup.step3.body",
            "wireless.setup.noControl",
            "wireless.setup.prepare",
            "wireless.setup.finish",
            "wireless.access.title",
            "wireless.access.openSettings",
            "license.menu",
            "license.activation.title",
            "license.activation.subtitle",
            "license.code.help",
            "license.badge.unactivated",
            "license.badge.help",
            "license.purchase.help",
            "license.purchase.online",
            "license.status.unlicensed",
            "license.status.licensed",
            "license.error.storage",
            "license.capabilities.unactivated",
            "license.capabilities.activated",
            "control.state.activationRequired",
            "status.activationDeviceLimit",
            "status.activationControlRequired",
            "license.error.notConfigured",
            "license.error.invalid",
            "settings.language",
            "settings.audioPlayback",
            "settings.audioPlaybackHelp",
            "toolbar.audioPlayback",
            "common.close",
            "card.installControlAgent",
            "detail.installControlAgent",
            "detail.controlHelp",
            "device.remove",
            "device.remove.message",
            "mirror.reconnectingBody",
            "mirror.copyScreenshot",
            "mirror.screenshotCopied",
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
            "diagnostic.mirror"
        ]
    }
}
