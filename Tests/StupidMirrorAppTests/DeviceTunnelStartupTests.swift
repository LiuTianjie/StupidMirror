import XCTest
@testable import StupidMirrorApp

@MainActor
final class DeviceTunnelStartupTests: XCTestCase {
    func testTimeoutReturnsWithoutSidecarOutputAndIgnoresLateReady() async {
        let collector = StartupCollector(udid: "test")
        let completed = expectation(description: "startup timed out without process output")
        let waiter = Task {
            do {
                _ = try await collector.waitUntilReady(timeout: .milliseconds(20))
                XCTFail("Startup must not succeed without a ready event")
            } catch {
                XCTAssertEqual(error as? DeviceTunnelSidecarError, .timedOut)
            }
            completed.fulfill()
        }

        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(result, .completed)
        // Also unblocks a broken implementation after the expectation fails,
        // keeping this regression from leaving a suspended task in the suite.
        collector.handle(DeviceTunnelEvent(name: "ready", fields: [:]))
        await waiter.value

        do {
            _ = try await collector.waitUntilReady(timeout: .seconds(1))
            XCTFail("Late output must not replace the settled timeout")
        } catch {
            XCTAssertEqual(error as? DeviceTunnelSidecarError, .timedOut)
        }
    }

    func testCancellationReturnsWithoutWaitingForProcessExit() async {
        let collector = StartupCollector(udid: "test")
        let entered = expectation(description: "startup wait entered")
        let completed = expectation(description: "startup cancellation completed")
        let waiter = Task {
            entered.fulfill()
            do {
                _ = try await collector.waitUntilReady(timeout: .seconds(30))
                XCTFail("A cancelled startup must not return an endpoint")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            completed.fulfill()
        }

        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        waiter.cancel()
        let completedResult = await XCTWaiter.fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completedResult, .completed)
        collector.terminated(status: 0, output: "")
        collector.handle(DeviceTunnelEvent(name: "ready", fields: [:]))
        await waiter.value
    }
}
