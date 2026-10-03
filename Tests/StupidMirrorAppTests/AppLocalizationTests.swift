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
            "status.controlAppiumUnavailable",
            "status.controlOpenDiagnostics",
            "control.setup.accountMissing",
            "control.setup.manualEntry",
            "menu.showDashboard",
            "menu.devices",
            "menu.reconnecting",
            "toolbar.discoverWireless",
            "toolbar.discoverWirelessHelp",
            "status.discoveringWireless",
            "agent.error.setupRequired",
            "agent.error.launchFailed",
            "agent.error.wifiConnectionsUnavailable",
            "agent.error.developerImageMissing",
            "agent.error.developerModeDisabled",
            "agent.error.timedOut",
            "agent.start.checkingAgent",
            "agent.start.waitingForDevice",
            "agent.error.automationNotApproved",
            "iphone.setup.step.waitingForDevice",
            "iphone.setup.cancelled",
            "iphone.setup.stop",
            "iphone.setup.preparingOther",
            "iphone.setup.developerMode.howTo",
            "iphone.setup.developerImage.missing",
            "iphone.setup.passcode.on",
            "agent.start.connectingVideo",
            "agent.start.retryingAgent",
            "agent.start.elapsed",
            "iphone.setup.title",
            "iphone.setup.step.usb.body",
            "iphone.setup.step.agent.body",
            "iphone.setup.developerMode.off",
            "iphone.setup.ready.usbOnly",
            "iphone.setup.note",
            "iphone.setup.prepare",
            "iphone.setup.finish",
            "control.loading.startingAgent",
            "control.loading.connectingAgent",
            "license.menu",
            "license.activation.title",
            "license.activation.subtitle",
            "license.code.help",
            "license.badge.unactivated",
            "license.badge.help",
            "license.purchase.help",
            "license.purchase.online",
            "license.signIn.google",
            "license.signIn.github",
            "license.signIn.email",
            "license.signIn.password",
            "license.signIn.emailSubmit",
            "license.redeem",
            "license.claim",
            "license.error.loginRequired",
            "license.error.itool",
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
            "control.loading.expectation.agent",
            "control.loading.elapsed",
            "control.loading.keepAwake",
            "control.error.unlockDevice",
            "control.error.signing",
            "status.deviceDisconnectedRefreshing",
            "diagnostic.mirror"
        ]
    }
}
