@testable import StupidMirrorApp
import CoreMedia
import XCTest

final class AndroidSupportTests: XCTestCase {
    func testADBDeviceListAndPropertiesAreParsed() {
        let listed = AndroidADBService.parseDeviceList(
            """
            List of devices attached
            RFCY10DHQ3P device usb:0-1 product:pa1qzcx model:SM_S9310 device:pa1q transport_id:7
            192.168.1.22:5555 unauthorized product:test model:Pixel_9
            """
        )
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed[0].serial, "RFCY10DHQ3P")
        XCTAssertEqual(listed[0].state, "device")
        XCTAssertEqual(listed[0].details["model"], "SM_S9310")
        XCTAssertEqual(listed[1].serial, "192.168.1.22:5555")
        XCTAssertEqual(listed[1].state, "unauthorized")

        let properties = AndroidADBService.parseGetProp(
            """
            [ro.build.version.release]: [16]
            [ro.build.version.sdk]: [36]
            [ro.product.model]: [SM-S9310]
            """
        )
        XCTAssertEqual(properties["ro.build.version.release"], "16")
        XCTAssertEqual(properties["ro.build.version.sdk"], "36")
        XCTAssertEqual(properties["ro.product.model"], "SM-S9310")
    }

    func testAndroidCapabilitiesUseUiAutomator2AndUniquePorts() {
        let base = AppiumControlConfiguration(platform: .android, platformVersion: "16")
        let first = base.isolated(forDeviceUDID: "android-one")
        let second = base.isolated(forDeviceUDID: "android-two")
        XCTAssertEqual(first.platform, .android)
        XCTAssertNotEqual(first.uiautomator2SystemPort, second.uiautomator2SystemPort)
        XCTAssertNotEqual(first.mjpegServerPort, second.mjpegServerPort)
        XCTAssertTrue(first.derivedDataPath.isEmpty)

        let capabilities = AppiumSessionCapabilities.make(
            udid: "android-one",
            bundleID: "",
            configuration: first
        )
        XCTAssertEqual(capabilities["platformName"] as? String, "Android")
        XCTAssertEqual(capabilities["appium:automationName"] as? String, "UiAutomator2")
        XCTAssertEqual(capabilities["appium:udid"] as? String, "android-one")
        XCTAssertEqual(capabilities["appium:systemPort"] as? Int, first.uiautomator2SystemPort)
        XCTAssertEqual(capabilities["appium:platformVersion"] as? String, "16")
        XCTAssertNil(capabilities["appium:xcodeOrgId"])
        XCTAssertNil(capabilities["appium:bundleId"])
    }

    func testAndroidSemanticLocatorsUseNativeStrategies() {
        let element = ScreenElement(
            id: "login",
            type: "android.widget.Button",
            name: "com.example:id/login",
            label: "登录",
            value: "立即登录",
            enabled: true,
            visible: true,
            frame: ScreenElementFrame(x: 10, y: 20, width: 100, height: 60)
        )
        let locators = AppiumSemanticElementResolver.locators(for: element, platform: .android)
        XCTAssertEqual(locators.first, AppiumSemanticLocator(
            using: "id",
            value: "com.example:id/login"
        ))
        XCTAssertTrue(locators.contains(AppiumSemanticLocator(
            using: "accessibility id",
            value: "登录"
        )))
        let contains = AppiumSemanticElementResolver.textContainsLocator(
            query: "登录",
            platform: .android
        )
        XCTAssertEqual(contains.using, "xpath")
        XCTAssertTrue(contains.value.contains("@text"))
        XCTAssertTrue(contains.value.contains("@content-desc"))
    }

    func testAndroidHierarchyBoundsAndAttributesAreParsed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <hierarchy rotation="0">
          <android.widget.FrameLayout index="0" class="android.widget.FrameLayout" package="com.example" enabled="true" bounds="[0,0][1080,2340]">
            <android.widget.Button index="1" text="继续" resource-id="com.example:id/continue" class="android.widget.Button" content-desc="下一步" clickable="true" enabled="true" focused="false" selected="false" bounds="[120,1600][960,1760]" displayed="true" />
          </android.widget.FrameLayout>
        </hierarchy>
        """
        let elements = ScreenElementParser.parse(
            xml,
            screenSize: DeviceScreenSize(width: 1080, height: 2340)
        )
        let button = try XCTUnwrap(elements.first { $0.value == "继续" })
        XCTAssertEqual(button.type, "android.widget.Button")
        XCTAssertEqual(button.name, "com.example:id/continue")
        XCTAssertEqual(button.label, "下一步")
        XCTAssertEqual(button.hittable, true)
        XCTAssertEqual(button.frame, ScreenElementFrame(x: 120, y: 1600, width: 840, height: 160))
        let normalized = try XCTUnwrap(button.normalizedFrame)
        XCTAssertEqual(normalized.x, 120.0 / 1080.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.height, 160.0 / 2340.0, accuracy: 0.0001)
    }

    @MainActor
    func testLiveAndroidControlKeepAliveSurvivesSessionTimeout() async throws {
        guard let serial = ProcessInfo.processInfo.environment["STUPIDMIRROR_TEST_ANDROID_SERIAL"],
              !serial.isEmpty else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_ANDROID_SERIAL to run the real-device control keep-alive check.")
        }
        let session = AppiumControlSession(device: DeviceIdentity(
            id: serial,
            udid: serial,
            platform: .android,
            name: "Live Android",
            productType: "Android",
            osVersion: nil,
            connectionState: .connected,
            trustState: .trusted
        ))
        var configuration = AppiumControlConfiguration(platform: .android)
        configuration.newCommandTimeoutSeconds = 3
        configuration.keepAliveIntervalSeconds = 1
        session.prepare(
            serverURL: "http://127.0.0.1:4723",
            bundleID: "",
            configuration: configuration
        )

        let deadline = Date().addingTimeInterval(45)
        while !session.isReady, session.isConnecting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard session.isReady else {
            let message = session.statusMessage
            await session.shutdown(serverURL: "http://127.0.0.1:4723")
            XCTFail("Android control did not become ready: \(message)")
            return
        }

        try await Task.sleep(for: .seconds(6))
        let stayedAlive = await session.verifyReadySession(serverURL: "http://127.0.0.1:4723")
        await session.shutdown(serverURL: "http://127.0.0.1:4723")

        XCTAssertTrue(stayedAlive, "The Android session expired despite control keep-alive.")
    }

    func testLiveAndroidScrcpyWhenDeviceSerialIsProvided() async throws {
        guard let serial = ProcessInfo.processInfo.environment["STUPIDMIRROR_TEST_ANDROID_SERIAL"],
              !serial.isEmpty else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_ANDROID_SERIAL to run the real-device scrcpy decoder check.")
        }
        guard let adb = AndroidRuntime.adbExecutablePath(),
              let server = AndroidRuntime.scrcpyServerResource() else {
            XCTFail("Android runtime is unavailable.")
            return
        }

        let frame = expectation(description: "decoded Android video frame")
        let size = expectation(description: "received Android session size")
        let stream = AndroidScrcpyStream(
            configuration: .init(
                serial: serial,
                adbPath: adb,
                serverPath: server.path,
                serverVersion: server.version,
                audioEnabled: false
            ),
            onFrame: { _ in frame.fulfill() },
            onAudio: { _ in },
            onSessionSize: { width, height in
                if width > 0, height > 0 { size.fulfill() }
            },
            onFailure: { error in
                XCTFail("Android scrcpy stream failed: \(error.localizedDescription)")
            }
        )
        stream.start()
        await fulfillment(of: [size, frame], timeout: 20)
        stream.stop()
    }

    func testLiveAndroidScrcpyAudioWhenDeviceSerialIsProvided() async throws {
        guard let serial = ProcessInfo.processInfo.environment["STUPIDMIRROR_TEST_ANDROID_SERIAL"],
              !serial.isEmpty else {
            throw XCTSkip("Set STUPIDMIRROR_TEST_ANDROID_SERIAL to run the real-device scrcpy audio check.")
        }
        guard let adb = AndroidRuntime.adbExecutablePath(),
              let server = AndroidRuntime.scrcpyServerResource() else {
            XCTFail("Android runtime is unavailable.")
            return
        }

        let frame = expectation(description: "decoded Android video frame")
        let audio = expectation(description: "decoded Android PCM audio")
        frame.assertForOverFulfill = false
        audio.assertForOverFulfill = false
        let stream = AndroidScrcpyStream(
            configuration: .init(
                serial: serial,
                adbPath: adb,
                serverPath: server.path,
                serverVersion: server.version,
                audioEnabled: true
            ),
            onFrame: { _ in frame.fulfill() },
            onAudio: { sampleBuffer in
                if CMSampleBufferGetNumSamples(sampleBuffer) > 0 { audio.fulfill() }
            },
            onSessionSize: { _, _ in },
            onFailure: { error in
                XCTFail("Android scrcpy audio stream failed: \(error.localizedDescription)")
            }
        )
        stream.start()
        await fulfillment(of: [frame, audio], timeout: 20)
        stream.stop()
    }
}
