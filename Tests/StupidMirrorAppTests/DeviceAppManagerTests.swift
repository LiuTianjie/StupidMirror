@testable import StupidMirrorApp
import XCTest

final class DeviceAppManagerTests: XCTestCase {
    func testDeviceCTLAppListIsParsed() throws {
        let json = """
        {"result":{"apps":[
          {"bundleIdentifier":"com.example.one","name":"One","version":"1.2"},
          {"name":"No identifier"}
        ]}}
        """
        let apps = try DeviceAppManager.parseDeviceCTLApps(Data(json.utf8))
        XCTAssertEqual(apps, [InstalledApp(bundleID: "com.example.one", name: "One", version: "1.2")])
    }

    func testSimctlAppListKeepsUserAppsUnlessSystemIsAsked() throws {
        let plist = """
        {
            "com.apple.Maps" = { ApplicationType = System; CFBundleDisplayName = Maps; };
            "com.example.app" = { ApplicationType = User; CFBundleName = Example; CFBundleShortVersionString = "2.0"; };
        }
        """
        let user = try DeviceAppManager.parseSimctlApps(Data(plist.utf8), includeSystem: false)
        XCTAssertEqual(user, [InstalledApp(bundleID: "com.example.app", name: "Example", version: "2.0")])
        let all = try DeviceAppManager.parseSimctlApps(Data(plist.utf8), includeSystem: true)
        XCTAssertEqual(Set(all.map(\.bundleID)), ["com.apple.Maps", "com.example.app"])
    }

    func testAndroidPackagesAreParsed() {
        let apps = DeviceAppManager.parseAndroidPackages("package:com.a\r\npackage:com.b\n\nnoise\n")
        XCTAssertEqual(apps.map(\.bundleID), ["com.a", "com.b"])
    }

    func testPackagesMustSuitTheTarget() {
        let apk = URL(fileURLWithPath: "/tmp/a.apk")
        let app = URL(fileURLWithPath: "/tmp/A.app")
        let ipa = URL(fileURLWithPath: "/tmp/A.ipa")
        XCTAssertNoThrow(try DeviceAppManager.validatePackage(apk, for: .android(serial: "s")))
        XCTAssertThrowsError(try DeviceAppManager.validatePackage(app, for: .android(serial: "s")))
        XCTAssertNoThrow(try DeviceAppManager.validatePackage(ipa, for: .iPhone(udid: "u")))
        XCTAssertNoThrow(try DeviceAppManager.validatePackage(app, for: .iOSSimulator(udid: "u")))
        XCTAssertThrowsError(try DeviceAppManager.validatePackage(ipa, for: .iOSSimulator(udid: "u")))
    }

    func testURLsAreCheckedAndShellQuoted() throws {
        XCTAssertEqual(try DeviceAppManager.validateURL(" myapp://open?x=1 "), "myapp://open?x=1")
        XCTAssertThrowsError(try DeviceAppManager.validateURL("not a url"))
        XCTAssertThrowsError(try DeviceAppManager.validateURL("-n"))
        XCTAssertThrowsError(try DeviceAppManager.validateURL("https://a\nb"))
        XCTAssertEqual(DeviceAppManager.shellQuoted("https://a/?q=it's"), "'https://a/?q=it'\\''s'")
    }

    func testRecordingFileNameIsSafe() {
        let date = Date(timeIntervalSince1970: 0)
        let url = DeviceAutomationService.recordingURL(deviceName: "A/B:C", date: date)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertTrue(url.path.contains("/Movies/StupidMirror/"))

        let next = DeviceAutomationService.recordingURL(deviceName: "A/B:C", date: date, taken: [url])
        XCTAssertNotEqual(next, url)
        XCTAssertTrue(next.lastPathComponent.hasSuffix(" 2.mp4"))
    }

    func testBundleIDsMustBeExactAndCannotLookLikeOptions() {
        XCTAssertNoThrow(try DeviceAutomationService.validateBundleID("com.example.app"))
        XCTAssertThrowsError(try DeviceAutomationService.validateBundleID(" com.example.app"))
        XCTAssertThrowsError(try DeviceAutomationService.validateBundleID("-com.example"))
        XCTAssertThrowsError(try DeviceAutomationService.validateBundleID("com.example;rm"))
    }
}
