import Foundation
import XCTest
@testable import StupidMirrorApp

/// The launch registry exists to stop concurrent callers from terminating each
/// other's WebDriverAgent runner.
///
/// `devicectl device process launch` is invoked with `--terminate-existing`, so
/// a second launch for the same bundle ID kills the first one's runner. The
/// loser's console never prints `ServerURLHere`, its readiness wait times out,
/// and the caller concludes the agent is broken and reinstalls it — a slow
/// no-op, because the agent was never at fault. Mirroring, control, and retries
/// all launch for the same UDID, so this collision is routine.
final class WirelessWDALaunchRegistryTests: XCTestCase {
    private func makeProcess(udid: String, running: Bool) throws -> WirelessWDAService.RemoteProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        if running {
            // Long-lived so `isRunning` stays true for the assertions below.
            process.arguments = ["-c", "sleep 30"]
        } else {
            process.arguments = ["-c", "exit 0"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if !running {
            process.waitUntilExit()
        }
        return WirelessWDAService.RemoteProcess(
            udid: udid,
            consoleProcess: process,
            outputPipe: Pipe(),
            serverURL: URL(string: "http://192.0.2.1:8100")!
        )
    }

    func testRegistersAndReturnsTheLiveLaunchForADevice() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-REGISTER"
        let launch = try makeProcess(udid: udid, running: true)
        defer { launch.consoleProcess.terminate() }

        XCTAssertNil(registry.existing(udid: udid))
        XCTAssertNil(registry.register(launch, udid: udid))
        XCTAssertTrue(registry.existing(udid: udid) === launch)
    }

    func testASecondLaunchReusesTheIncumbentInsteadOfReplacingIt() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-REUSE"
        let first = try makeProcess(udid: udid, running: true)
        let second = try makeProcess(udid: udid, running: true)
        defer {
            first.consoleProcess.terminate()
            second.consoleProcess.terminate()
        }

        XCTAssertNil(registry.register(first, udid: udid))

        // The incumbent is handed back so the caller retires its own launch
        // rather than leaving two that would terminate each other.
        let incumbent = registry.register(second, udid: udid)
        XCTAssertTrue(incumbent === first)
        XCTAssertTrue(registry.existing(udid: udid) === first)
    }

    func testAnExitedLaunchIsNotReused() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-DEAD"
        let dead = try makeProcess(udid: udid, running: false)

        XCTAssertNil(registry.register(dead, udid: udid))
        XCTAssertNil(
            registry.existing(udid: udid),
            "A launch whose console has exited must not be handed to a new caller"
        )
    }

    func testADeadIncumbentIsReplacedByAFreshLaunch() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-REPLACE"
        let dead = try makeProcess(udid: udid, running: false)
        let fresh = try makeProcess(udid: udid, running: true)
        defer { fresh.consoleProcess.terminate() }

        XCTAssertNil(registry.register(dead, udid: udid))
        XCTAssertNil(registry.register(fresh, udid: udid))
        XCTAssertTrue(registry.existing(udid: udid) === fresh)
    }

    func testRemoveOnlyDropsTheMatchingLaunch() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let udid = "00008150-TEST-REMOVE"
        let current = try makeProcess(udid: udid, running: true)
        let stale = try makeProcess(udid: udid, running: true)
        defer {
            current.consoleProcess.terminate()
            stale.consoleProcess.terminate()
        }

        XCTAssertNil(registry.register(current, udid: udid))

        // A superseded launch's termination handler must not evict the launch
        // that replaced it.
        registry.remove(udid: udid, if: stale)
        XCTAssertTrue(registry.existing(udid: udid) === current)

        registry.remove(udid: udid, if: current)
        XCTAssertNil(registry.existing(udid: udid))
    }

    func testLaunchesAreTrackedPerDevice() throws {
        let registry = WirelessWDAService.LaunchRegistry()
        let firstUDID = "00008150-TEST-DEVICE-A"
        let secondUDID = "00008130-TEST-DEVICE-B"
        let first = try makeProcess(udid: firstUDID, running: true)
        let second = try makeProcess(udid: secondUDID, running: true)
        defer {
            first.consoleProcess.terminate()
            second.consoleProcess.terminate()
        }

        XCTAssertNil(registry.register(first, udid: firstUDID))
        XCTAssertNil(
            registry.register(second, udid: secondUDID),
            "A launch for a different device is not an incumbent"
        )
        XCTAssertTrue(registry.existing(udid: firstUDID) === first)
        XCTAssertTrue(registry.existing(udid: secondUDID) === second)
    }
}
