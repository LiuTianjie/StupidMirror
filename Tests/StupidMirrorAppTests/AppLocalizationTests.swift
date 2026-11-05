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
        XCTAssertEqual(AppCopy.plain(AppCopy.text("menu.devices", language: .zhHans)), "设备")
        XCTAssertEqual(AppCopy.text("connection.disconnected", language: .en), "Reconnecting")
        XCTAssertEqual(AppCopy.plain(AppCopy.text("connection.disconnected", language: .zhHans)), "重连中")
    }

    func testMembershipCopyNamesTheYearlyOfferAndNoActivationCodes() {
        XCTAssertEqual(
            AppCopy.plain(AppCopy.text("license.purchase.join", language: .zhHans)),
            "开通 iTool 年度会员（¥99/年，含全部 iTool 产品）"
        )
        XCTAssertEqual(AppCopy.plain(AppCopy.text("license.purchase.upgrade", language: .zhHans)), "升级年度会员")
        for language in [AppLanguage.en, .zhHans] {
            for key in criticalKeys where key.hasPrefix("license.") || key.contains("membership") || key.contains("Membership") {
                let text = AppCopy.plain(AppCopy.text(key, language: language))
                XCTAssertFalse(text.contains("SM-"), "\(key) mentions SM- codes")
                XCTAssertFalse(text.lowercased().contains("activation code"), "\(key) mentions activation codes")
                XCTAssertFalse(text.contains("激活码"), "\(key) mentions activation codes")
            }
        }
    }

    func testMonthlyAndMemberDetailsFormatADate() {
        for language in [AppLanguage.en, .zhHans] {
            for key in ["license.page.monthly.detail", "license.page.member.detail"] {
                let text = String(format: AppCopy.text(key, language: language), "2027-11-05")
                XCTAssertTrue(text.contains("2027-11-05"), "\(key) does not show the date")
            }
        }
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
            "license.account",
            "license.page.free.title",
            "license.page.free.detail",
            "license.page.notMember.detail",
            "license.page.monthly.title",
            "license.page.monthly.detail",
            "license.page.member.title",
            "license.page.member.detail",
            "license.page.member.detailNoEnd",
            "license.page.unverified.detail",
            "license.purchase.join",
            "license.purchase.upgrade",
            "license.page.purchase.help",
            "license.page.upgrade.help",
            "license.purchase.online",
            "license.purchase.upgradeButton",
            "license.refresh",
            "license.badge.free",
            "license.badge.notMember",
            "license.badge.help",
            "license.signIn.email",
            "license.signIn.password",
            "license.tier.yearly",
            "license.tier.monthly",
            "license.status.free",
            "license.status.member",
            "license.status.unverified",
            "license.error.storage",
            "license.error.offline",
            "license.error.notConfigured",
            "control.state.membershipRequired",
            "detail.controlMembershipHelp",
            "status.membershipDeviceLimit",
            "status.membershipControlRequired",
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
