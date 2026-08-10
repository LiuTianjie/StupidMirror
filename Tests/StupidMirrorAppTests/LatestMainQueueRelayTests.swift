@testable import StupidMirrorApp
import XCTest

final class LatestMainQueueRelayTests: XCTestCase {
    @MainActor
    func testBurstKeepsOnlyLatestPendingValue() async {
        let delivered = expectation(description: "latest value delivered")
        var values: [Int] = []
        let relay = LatestMainQueueRelay<Int> { value in
            values.append(value)
            delivered.fulfill()
        }

        relay.submit(1)
        relay.submit(2)
        relay.submit(3)

        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(values, [3])
    }

    @MainActor
    func testInvalidationDropsPendingValue() async {
        let delivered = expectation(description: "no value delivered after invalidation")
        delivered.isInverted = true
        let relay = LatestMainQueueRelay<Int> { _ in
            delivered.fulfill()
        }

        relay.submit(1)
        relay.invalidate()

        await fulfillment(of: [delivered], timeout: 0.1)
    }
}
