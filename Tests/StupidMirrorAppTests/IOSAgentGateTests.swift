import Foundation
import XCTest
@testable import StupidMirrorApp

@MainActor
final class IOSAgentGateTests: XCTestCase {
    func testUSBRequestDoesNotBorrowAnInFlightNetworkEndpoint() async throws {
        let gate = IOSAgentGate()
        let networkEntered = expectation(description: "network launch is in flight")
        let usbRequested = expectation(description: "USB caller arrived before network finished")
        let networkMayFinish = IOSAgentGateTestLatch()
        let networkEndpoint = endpoint(port: 18_100, transport: .network)
        let usbEndpoint = endpoint(port: 28_100, transport: .usb)

        let network = Task {
            try await gate.run(udid: "same-phone", transport: .network) {
                networkEntered.fulfill()
                await networkMayFinish.wait()
                return networkEndpoint
            }
        }
        let networkStarted = await XCTWaiter.fulfillment(of: [networkEntered], timeout: 1)
        XCTAssertEqual(networkStarted, .completed)
        let usb = Task {
            usbRequested.fulfill()
            return try await gate.run(udid: "same-phone", transport: .usb) {
                return usbEndpoint
            }
        }
        let secondStarted = await XCTWaiter.fulfillment(of: [usbRequested], timeout: 1)
        XCTAssertEqual(secondStarted, .completed)
        // The first operation remains suspended while the second request
        // reaches the actor. It must queue instead of returning that result.
        await Task.yield()
        await networkMayFinish.release()

        let first = try await network.value
        let second = try await usb.value
        XCTAssertEqual(first, networkEndpoint)
        XCTAssertEqual(second, usbEndpoint)
    }

    private func endpoint(port: Int, transport: DeviceTunnelTransport) -> IOSAgentEndpoint {
        IOSAgentEndpoint(
            controlURL: URL(string: "http://127.0.0.1:\(port)")!,
            videoHost: "127.0.0.1", videoPort: port + 100, transport: transport
        )
    }
}

private actor IOSAgentGateTestLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
