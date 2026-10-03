@testable import StupidMirrorApp
import CoreGraphics
import Foundation
import XCTest

final class ControlGestureReducerTests: XCTestCase {
    func testInteractiveControlBufferStaysBoundedAndCoalescesLaggingGestures() {
        var buffer = ControlActionBuffer()
        for index in 0..<20 {
            buffer.append(.typeText(String(index)))
        }
        XCTAssertEqual(buffer.count, 20, "typed text is never dropped")
        for index in 0..<40 {
            buffer.append(.typeText(String(index)))
        }
        XCTAssertEqual(buffer.count, ControlActionBuffer.hardLimit)

        buffer.removeAll()
        buffer.append(.tap(CGPoint(x: 1, y: 1)))
        buffer.append(.tap(CGPoint(x: 2, y: 2)))
        XCTAssertEqual(buffer.count, 1)

        buffer.append(.typeText("keep"))
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 10, y: 10), durationMS: 120))
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 20, y: 20), durationMS: 120))
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.actions.filter(\.isSwipe).count, 1)
    }

    func testOverflowDropsStaleGesturesButKeepsTextAndKeys() {
        var buffer = ControlActionBuffer(maximumCount: 3)
        buffer.append(.typeText("a"))
        buffer.append(.tap(CGPoint(x: 1, y: 1)))
        buffer.append(.press(.home))
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 5, y: 5), durationMS: 100))
        buffer.append(.longPress(.zero, durationMS: 600))
        XCTAssertEqual(buffer.actions, [
            .typeText("a"),
            .press(.home),
            .longPress(.zero, durationMS: 600)
        ])
    }

    func testSwipesOnlyCollapseWhenAdjacentSoOrderIsKept() {
        var buffer = ControlActionBuffer(maximumCount: 8)
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 1, y: 1), durationMS: 100))
        buffer.append(.tap(CGPoint(x: 2, y: 2)))
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 3, y: 3), durationMS: 100))
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.actions[1], .tap(CGPoint(x: 2, y: 2)))
    }

    func testAQueuedFirstClickMergesWithTheDoubleTap() {
        var buffer = ControlActionBuffer()
        buffer.append(.tap(CGPoint(x: 0.5, y: 0.5)))
        buffer.append(.doubleTap(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(buffer.actions, [.doubleTap(CGPoint(x: 0.5, y: 0.5))])
    }

    func testADoubleClickAfterAnAlreadySentTapAddsOnlyOneTap() {
        let now = Date()
        let point = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(
            DeviceControlSession.resolvingDoubleClick(.doubleTap(point), after: (point, now.addingTimeInterval(-0.3)), now: now),
            .tap(point)
        )
        XCTAssertEqual(
            DeviceControlSession.resolvingDoubleClick(.doubleTap(point), after: (point, now.addingTimeInterval(-5)), now: now),
            .doubleTap(point),
            "an old tap is not part of this double click"
        )
        XCTAssertEqual(
            DeviceControlSession.resolvingDoubleClick(.doubleTap(point), after: (CGPoint(x: 0.1, y: 0.1), now), now: now),
            .doubleTap(point),
            "a tap elsewhere is not part of this double click"
        )
        XCTAssertEqual(DeviceControlSession.resolvingDoubleClick(.doubleTap(point), after: nil, now: now), .doubleTap(point))
    }

    func testDraggingReplaysItsRecordedPathOnMouseUp() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 20, y: 25), timestamp: 0.05))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 50, y: 45), timestamp: 0.30))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 66, y: 54), timestamp: 0.45))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 90, y: 70), timestamp: 0.60))
        guard case let .drag(path)? = reducer.endMouseDrag(at: CGPoint(x: 112, y: 83), timestamp: 0.75) else {
            return XCTFail("a slow drag should replay its whole path")
        }
        XCTAssertEqual(path.first?.point, CGPoint(x: 10, y: 20))
        XCTAssertEqual(path.last?.point, CGPoint(x: 112, y: 83))
        XCTAssertEqual(path.count, 6)
    }

    func testShortCompletedDragUsesItsFullDistance() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 18, y: 24), timestamp: 0.05))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 50, y: 45), timestamp: 0.40))
        guard case let .drag(path)? = reducer.endMouseDrag(at: CGPoint(x: 51, y: 46), timestamp: 0.45) else {
            return XCTFail("a short completed drag should still replay its path")
        }
        XCTAssertEqual(path.first?.point, CGPoint(x: 10, y: 20))
        XCTAssertEqual(path.last?.point, CGPoint(x: 51, y: 46))
    }

    func testFastSwipeIsEmittedBeforeMouseUpAndNotDuplicated() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)

        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 20, y: 24), timestamp: 0.02))
        XCTAssertEqual(
            reducer.updateMouseDrag(to: CGPoint(x: 80, y: 30), timestamp: 0.08),
            .flick(from: CGPoint(x: 10, y: 20), toward: CGPoint(x: 80, y: 30), durationMS: 160)
        )
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 110, y: 35), timestamp: 0.10))
        XCTAssertNil(reducer.endMouseDrag(at: CGPoint(x: 120, y: 40)))
    }

    func testFastHorizontalFlickUsesNativeFullScreenDirection() {
        let direction = ControlGestureNSView.flickDirection(
            from: CGPoint(x: 0.85, y: 0.5),
            toward: CGPoint(x: 0.72, y: 0.49)
        )

        XCTAssertEqual(direction, .left)
    }

    func testFastVerticalFlickUsesNativeFullScreenDirection() {
        let direction = ControlGestureNSView.flickDirection(
            from: CGPoint(x: 0.5, y: 0.80),
            toward: CGPoint(x: 0.51, y: 0.68)
        )

        XCTAssertEqual(direction, .up)
    }

    func testShortMouseGestureEmitsTap() {
        var reducer = ControlGestureReducer()

        reducer.beginMouseDrag(at: CGPoint(x: 24, y: 40))

        XCTAssertEqual(
            reducer.endMouseDrag(at: CGPoint(x: 28, y: 43)),
            .tap(CGPoint(x: 28, y: 43))
        )
    }

    func testScrollAccumulatesUntilExplicitFlush() {
        var reducer = ControlGestureReducer()

        reducer.beginScroll(at: CGPoint(x: 100, y: 200))
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 14), precise: true))
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 8), precise: true))
        XCTAssertEqual(
            reducer.flushScroll(precise: true),
            .swipe(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 100, y: 270.4), durationMS: 180)
        )
        XCTAssertNil(reducer.flushScroll(precise: true))
    }
}
