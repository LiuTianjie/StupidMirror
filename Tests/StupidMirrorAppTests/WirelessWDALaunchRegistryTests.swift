import Foundation
import XCTest
@testable import StupidMirrorApp

/// The launch registry serializes `--terminate-existing` launches per device
/// and remembers the last PID so shutdown can stop a detached runner.
final class WirelessWDALaunchRegistryTests: XCTestCase {
    func testExclusiveLaunchRunsTheBody() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-EXCLUSIVE"
        let result = registry.withExclusiveLaunch(udid: udid) { 7 }
        XCTAssertEqual(result, 7)
    }

    func testPidsAreTrackedPerDeviceAndTakenOnShutdown() {
        let registry = WirelessWDAService.LaunchRegistry()
        let firstUDID = "00008150-TEST-DEVICE-A"
        let secondUDID = "00008130-TEST-DEVICE-B"

        registry.remember(pid: 11, udid: firstUDID)
        registry.remember(pid: 22, udid: secondUDID)
        XCTAssertEqual(registry.pid(for: firstUDID), 11)
        XCTAssertEqual(registry.pid(for: secondUDID), 22)

        XCTAssertEqual(registry.takePid(firstUDID), 11)
        XCTAssertNil(registry.pid(for: firstUDID))
        XCTAssertEqual(registry.pid(for: secondUDID), 22)
    }

    func testALaterPidReplacesThePreviousOne() {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-REPLACE"
        registry.remember(pid: 1, udid: udid)
        registry.remember(pid: 2, udid: udid)
        XCTAssertEqual(registry.pid(for: udid), 2)
        XCTAssertEqual(registry.takePid(udid), 2)
        XCTAssertNil(registry.takePid(udid))
    }
}

final class WirelessWDADetachedLaunchTests: XCTestCase {
    func testIOS27UsesAnXCTestSessionInsteadOfARawLaunch() {
        XCTAssertTrue(WirelessWDAService.needsXCTestSession(osVersion: "27.0"))
        XCTAssertTrue(WirelessWDAService.needsXCTestSession(osVersion: "27.1"))
        XCTAssertFalse(WirelessWDAService.needsXCTestSession(osVersion: "26.2"))
        XCTAssertFalse(WirelessWDAService.needsXCTestSession(osVersion: "18.5"))
    }

    func testXcodebuildTestArgumentsUseTheCachedRunWithoutRebuilding() {
        let arguments = WirelessWDAService.xcodebuildTestArguments(
            udid: "00008150-TEST",
            xctestrunPath: "/tmp/WDA.xctestrun",
            derivedDataPath: "/tmp/WDA-Derived"
        )
        XCTAssertTrue(arguments.contains("test-without-building"))
        XCTAssertFalse(arguments.contains("--console"))
        XCTAssertFalse(arguments.contains("build-for-testing"))
        XCTAssertEqual(arguments.last, "/tmp/WDA-Derived")
    }

    func testPatchedXCTestRunRaisesTheExecutionTimeAllowance() throws {
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-WDA-original.xctestrun")
        let plist: [String: Any] = [
            "WebDriverAgentRunner": [
                "EnvironmentVariables": ["USE_PORT": ""],
                "DefaultTestExecutionTimeAllowance": 600
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }

        let patched = try WirelessWDAService.patchedXCTestRun(
            from: original,
            environment: ["USE_PORT": "8100", "STUPIDMIRROR_H264_PORT": "9200"]
        )
        defer { try? FileManager.default.removeItem(at: patched) }
        let parsed = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: patched),
                format: nil
            ) as? [String: Any]
        )
        let test = try XCTUnwrap(parsed["WebDriverAgentRunner"] as? [String: Any])
        let env = try XCTUnwrap(test["EnvironmentVariables"] as? [String: Any])
        XCTAssertEqual(env["USE_PORT"] as? String, "8100")
        XCTAssertEqual(env["STUPIDMIRROR_H264_PORT"] as? String, "9200")
        XCTAssertEqual((test["DefaultTestExecutionTimeAllowance"] as? NSNumber)?.intValue, 604_800)
        XCTAssertEqual(test["TestTimeoutsEnabled"] as? Bool, false)
    }

    func testProcessLaunchArgumentsDoNotAttachAConsoleSession() {
        let arguments = WirelessWDAService.processLaunchArguments(
            udid: "00008150-TEST-LAUNCH",
            bundleID: "com.stupidmirror.wda.team",
            environmentJSON: #"{"USE_PORT":"8100"}"#,
            jsonOutputPath: "/tmp/wda-launch.json"
        )
        XCTAssertFalse(arguments.contains("--console"))
        XCTAssertTrue(arguments.contains("--terminate-existing"))
        XCTAssertTrue(arguments.contains("--json-output"))
        XCTAssertEqual(
            arguments.last,
            "com.stupidmirror.wda.team.xctrunner"
        )
        XCTAssertFalse(arguments.contains("2147483647"))
    }

    func testDeviceDetailsHostsPreferTheTunnelAddress() throws {
        let data = try XCTUnwrap(
            """
            {"result":{"connectionProperties":{
              "tunnelIPAddress":"fd81:2749:b042::1",
              "localHostnames":["iPhone-Air.coredevice.local","iPhone-Air.coredevice.local"],
              "potentialHostnames":["00008150-001C2C1E26D8401C.coredevice.local"]
            }}}
            """.data(using: .utf8)
        )
        XCTAssertEqual(
            WirelessWDAService.hosts(fromDeviceDetailsJSON: data),
            [
                "fd81:2749:b042::1",
                "iPhone-Air.coredevice.local",
                "00008150-001C2C1E26D8401C.coredevice.local"
            ]
        )
    }
}

/// The iOS 27 `devicectl` launch regression looks exactly like a missing agent
/// from the Mac's side, so it has to be recognised from the device's own output.
final class WirelessWDABackgroundingFailureTests: XCTestCase {
    /// Verbatim from `devicectl device process launch` against an unlocked
    /// iPhone on iOS 27.0.
    private let realFailureOutput = """
    Failed to initialize for UI testing: Error Domain=com.apple.dt.xctest.ui-testing.error \
    Code=10300 "Failed to background test runner within 30.0s." UserInfo={screenshot-data=\
    {length = 34801}, NSLocalizedDescription=Failed to background test runner within 30.0s.}
    20:22:16  Acquired tunnel connection to device.
    Launched application with com.stupidmirror.wda.l95pylft86.xctrunner bundle identifier.
    The app terminated with the exit code 1.
    """

    func testRecognisesTheBackgroundingFailure() {
        XCTAssertTrue(
            WirelessWDAService.outputIndicatesBackgroundingFailure(realFailureOutput)
        )
    }

    func testDoesNotBlameALockedOrUnavailableDevice() {
        // The device was unlocked and reachable, so these must not claim it.
        XCTAssertFalse(WirelessWDAService.outputIndicatesLockedDevice(realFailureOutput))
        XCTAssertFalse(WirelessWDAService.outputIndicatesUnavailableDevice(realFailureOutput))
    }

    func testASuccessfulLaunchIsNotMistakenForTheFailure() {
        let success = """
        2026-09-01 19:04:10.522 WebDriverAgentRunner-Runner[22497:16810761] \
        ServerURLHere->http://192.168.1.8:8100<-ServerURLHere
        StupidMirror SRT/H.264 stream listening on UDP port 9200
        """
        XCTAssertFalse(WirelessWDAService.outputIndicatesBackgroundingFailure(success))
    }

    func testAnUnrelatedUITestingErrorIsNotTreatedAsBackgrounding() {
        let other = """
        Failed to initialize for UI testing: Error Domain=com.apple.dt.xctest.ui-testing.error \
        Code=9 "Some other UI testing failure."
        """
        XCTAssertFalse(WirelessWDAService.outputIndicatesBackgroundingFailure(other))
    }
}

/// Reinstalling the runner costs a slow install plus a repeat of the launch
/// wait, so it must only be attempted for failures it could actually fix.
final class WirelessWDAReinstallPolicyTests: XCTestCase {
    func testOnlyABrokenInstallationJustifiesReinstalling() {
        for error in [
            WirelessWDAError.missingInstallation,
            .firstUSBSetupRequired
        ] {
            XCTAssertTrue(
                WirelessWDAService.isWorthReinstalling(error),
                "\(error) should allow a reinstall attempt"
            )
        }
    }

    func testFailuresAReinstallCannotFixSkipIt() {
        for error in [
            // The OS refuses this launch path; a fresh copy behaves identically.
            WirelessWDAError.agentBackgroundingUnsupported,
            .launchFailed,
            .timedOut,
            .buildFailed,
            .deviceLocked,
            .deviceUnavailable,
            .localNetworkDenied,
            .iphoneLocalNetworkDenied,
            .missingSigningTeam,
            .missingRuntime
        ] {
            XCTAssertFalse(
                WirelessWDAService.isWorthReinstalling(error),
                "\(error) must not trigger a pointless reinstall"
            )
        }
    }

    func testMissingInstallationIsDetectedFromDevicectlOutput() {
        XCTAssertTrue(
            WirelessWDAService.outputIndicatesMissingInstallation(
                "The application with bundle identifier com.stupidmirror.wda.team.xctrunner is not installed on this device."
            )
        )
        XCTAssertFalse(
            WirelessWDAService.outputIndicatesMissingInstallation(
                "Failed to background test runner within 30.0s."
            )
        )
        XCTAssertFalse(
            WirelessWDAService.outputIndicatesMissingInstallation(
                "connect ECONNREFUSED 192.168.1.8:8100"
            )
        )
    }
}
