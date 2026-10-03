import CoreGraphics
import Foundation
import XCTest
@testable import StupidMirrorApp

/// The reducer must reproduce what the user did, not just where they let go.
final class ControlGestureFidelityTests: XCTestCase {
    func testHoldingStillBecomesALongPressWithItsRealDuration() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: CGPoint(x: 50, y: 50), timestamp: 10)
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 52, y: 51), timestamp: 10.3))
        let command = reducer.endMouseDrag(at: CGPoint(x: 52, y: 51), timestamp: 10.8)
        XCTAssertEqual(command, .longPress(CGPoint(x: 52, y: 51), durationMS: 800))
    }

    func testAVeryLongHoldIsCapped() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: .zero, timestamp: 0)
        XCTAssertEqual(reducer.endMouseDrag(at: .zero, timestamp: 9), .longPress(.zero, durationMS: 1_500))
    }

    func testAQuickReleaseIsStillATapAndADoubleClickADoubleTap() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: CGPoint(x: 5, y: 5), timestamp: 0)
        XCTAssertEqual(reducer.endMouseDrag(at: CGPoint(x: 5, y: 5), timestamp: 0.12), .tap(CGPoint(x: 5, y: 5)))

        reducer.beginMouseDrag(at: CGPoint(x: 5, y: 5), timestamp: 1)
        XCTAssertEqual(
            reducer.endMouseDrag(at: CGPoint(x: 5, y: 5), timestamp: 1.1, clickCount: 2),
            .doubleTap(CGPoint(x: 5, y: 5))
        )
    }

    func testASlowCurvedDragKeepsItsPathAndTiming() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: CGPoint(x: 0, y: 0), timestamp: 0)
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 10, y: 20), timestamp: 0.3))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 40, y: 25), timestamp: 0.6))
        let command = reducer.endMouseDrag(at: CGPoint(x: 60, y: 10), timestamp: 0.9)
        guard case let .drag(path)? = command else {
            return XCTFail("expected a path drag, got \(String(describing: command))")
        }
        XCTAssertEqual(path.map(\.point), [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 25), CGPoint(x: 60, y: 10)
        ])
        XCTAssertEqual(path.map(\.timestamp), [0, 0.3, 0.6, 0.9])
    }

    func testLongPathsAreDownsampledButKeepBothEnds() {
        let samples = (0..<200).map { index in
            ControlPathSample(point: CGPoint(x: Double(index), y: 0), timestamp: Double(index) / 100)
        }
        let reduced = ControlGestureReducer.downsample(samples, to: 24)
        XCTAssertEqual(reduced.count, 24)
        XCTAssertEqual(reduced.first, samples.first)
        XCTAssertEqual(reduced.last, samples.last)
    }

    func testPathReplayIsCompressedIntoABoundedWindow() {
        let size = DeviceScreenSize(width: 400, height: 800)
        let slow = [
            ControlPathSample(point: CGPoint(x: 0.5, y: 0.9), timestamp: 0),
            ControlPathSample(point: CGPoint(x: 0.5, y: 0.5), timestamp: 1.0),
            ControlPathSample(point: CGPoint(x: 0.5, y: 0.1), timestamp: 2.0)
        ]
        let replay = DeviceControlSession.devicePath(slow, size)
        XCTAssertEqual(replay.map(\.offsetMS), [0, 350, 700])
        XCTAssertEqual(replay.last?.point, CGPoint(x: 200, y: 80))

        let fast = [
            ControlPathSample(point: .zero, timestamp: 0),
            ControlPathSample(point: CGPoint(x: 1, y: 1), timestamp: 0.05)
        ]
        XCTAssertEqual(DeviceControlSession.devicePath(fast, size).last?.offsetMS, 120)
    }

    func testW3CPathPayloadHasOneTimedMovePerSample() throws {
        let payload = W3CPointerAction.path([
            DevicePathSample(point: CGPoint(x: 10, y: 10), offsetMS: 0),
            DevicePathSample(point: CGPoint(x: 20, y: 30), offsetMS: 100),
            DevicePathSample(point: CGPoint(x: 40, y: 50), offsetMS: 250)
        ])
        let actions = try XCTUnwrap((payload["actions"] as? [[String: Any]])?.first?["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["type"] as? String }, ["pointerMove", "pointerDown", "pointerMove", "pointerMove", "pointerUp"])
        XCTAssertEqual(actions[2]["duration"] as? Int, 100)
        XCTAssertEqual(actions[3]["duration"] as? Int, 150)
        XCTAssertEqual(actions[3]["x"] as? Int, 40)
    }
}
