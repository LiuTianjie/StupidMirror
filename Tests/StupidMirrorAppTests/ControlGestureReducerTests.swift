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
        XCTAssertEqual(buffer.count, 2, "rapid taps are all delivered, in order")

        buffer.append(.typeText("keep"))
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 10, y: 10), durationMS: 120))
        buffer.append(.swipe(from: .zero, to: CGPoint(x: 20, y: 20), durationMS: 120))
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.actions.filter(\.isSwipe).count, 1)
    }

    func testOnlyAContinuingScrollIsCombined() {
        var buffer = ControlActionBuffer()
        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.5), durationMS: 180))
        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.7), durationMS: 180))
        XCTAssertEqual(
            buffer.actions,
            [.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.7), durationMS: 180)],
            "a reversed scroll replaces the first; adding them would cancel to a motionless touch, a tap"
        )

        buffer.removeAll()
        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.3), to: CGPoint(x: 0.2, y: 0.3), durationMS: 60))
        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.2, y: 0.6), durationMS: 60))
        XCTAssertEqual(
            buffer.actions,
            [.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.2, y: 0.6), durationMS: 60)],
            "a flick on another row is its own gesture"
        )
    }

    func testQueuedScrollSwipesAddUpInsteadOfDroppingDistance() {
        var buffer = ControlActionBuffer()
        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.5), durationMS: 180))
        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.45), durationMS: 180))
        XCTAssertEqual(buffer.actions.count, 1)
        guard case let .swipe(from, to, durationMS) = buffer.actions[0] else {
            return XCTFail("expected one combined swipe")
        }
        XCTAssertEqual(from, CGPoint(x: 0.5, y: 0.6))
        XCTAssertEqual(to.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(to.y, 0.35, accuracy: 0.0001, "both scrolls' distance is kept")
        XCTAssertEqual(durationMS, 360, "at the same average speed")

        buffer.append(.swipe(from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 0.0), durationMS: 180))
        guard case let .swipe(_, clampedEnd, _) = buffer.actions[0] else {
            return XCTFail("expected one combined swipe")
        }
        XCTAssertEqual(clampedEnd.y, 0, "a combined scroll never leaves the screen")
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
            .flick(from: CGPoint(x: 10, y: 20), toward: CGPoint(x: 80, y: 30), durationMS: 80),
            "a flick carries the stroke's real duration so its speed survives"
        )
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 110, y: 35), timestamp: 0.10))
        XCTAssertNil(reducer.endMouseDrag(at: CGPoint(x: 120, y: 40)))
    }

    func testARestBeforeAFlickDoesNotSlowIt() {
        var reducer = ControlGestureReducer()
        reducer.beginMouseDrag(at: CGPoint(x: 10, y: 20), timestamp: 0)
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 11, y: 20), timestamp: 0.30))
        XCTAssertNil(reducer.updateMouseDrag(to: CGPoint(x: 25, y: 20), timestamp: 0.32))
        XCTAssertEqual(
            reducer.updateMouseDrag(to: CGPoint(x: 45, y: 20), timestamp: 0.34),
            .flick(from: CGPoint(x: 10, y: 20), toward: CGPoint(x: 45, y: 20), durationMS: 40),
            "the stroke is timed from when the pointer started moving, not from mouse-down"
        )
    }

    func testAQuickTrackpadFlickKeepsItsSpeed() {
        var reducer = ControlGestureReducer()
        reducer.beginScroll(at: CGPoint(x: 100, y: 200))
        _ = reducer.appendScroll(delta: CGSize(width: 0, height: 12), precise: true, timestamp: 1.00)
        _ = reducer.appendScroll(delta: CGSize(width: 0, height: 13), precise: true, timestamp: 1.06)
        guard case let .swipe(_, _, durationMS)? = reducer.flushScroll(precise: true) else {
            return XCTFail("expected a swipe")
        }
        XCTAssertEqual(durationMS, 60, "a 60 ms stroke lifts at its own speed so the phone coasts")
    }

    func testFlingKeepsStartDirectionAndSpeed() {
        let fling = ControlGestureNSView.fling(
            from: CGPoint(x: 0.5, y: 0.7),
            toward: CGPoint(x: 0.5, y: 0.62),
            durationMS: 60
        )
        XCTAssertEqual(fling.start, CGPoint(x: 0.5, y: 0.7), "a flick starts where the finger went down")
        XCTAssertEqual(fling.end.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(fling.end.y, 0.5, accuracy: 0.0001, "0.08 moved, extended 2.5x")
        XCTAssertEqual(fling.durationMS, 150, "same speed: 2.5x the distance in 2.5x the time")
    }

    func testFlingStopsAtTheScreenEdgeAtTheSameSpeed() {
        let fling = ControlGestureNSView.fling(
            from: CGPoint(x: 0.5, y: 0.2),
            toward: CGPoint(x: 0.5, y: 0.1),
            durationMS: 40
        )
        XCTAssertEqual(fling.end.y, 0, accuracy: 0.0001)
        // 0.25 would leave the screen; 0.2 of it fits, at 0.1 per 40 ms.
        XCTAssertEqual(fling.durationMS, 80)
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
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 14), precise: true, timestamp: 0))
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 8), precise: true, timestamp: 0.25))
        XCTAssertEqual(
            reducer.flushScroll(precise: true),
            .swipe(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 100, y: 270.4), durationMS: 180)
        )
        XCTAssertNil(reducer.flushScroll(precise: true))
    }

    func testOneMouseWheelNotchScrolls() {
        var reducer = ControlGestureReducer()

        reducer.beginScroll(at: CGPoint(x: 100, y: 200))
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 1), precise: false))
        XCTAssertEqual(
            reducer.flushScroll(precise: false),
            .swipe(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 100, y: 218), durationMS: 180),
            "a single wheel notch reports one line and must still move the phone"
        )
    }

    func testATinyTrackpadNudgeIsIgnored() {
        var reducer = ControlGestureReducer()

        reducer.beginScroll(at: CGPoint(x: 100, y: 200))
        XCTAssertNil(reducer.appendScroll(delta: CGSize(width: 0, height: 2), precise: true))
        XCTAssertNil(reducer.flushScroll(precise: true))
    }
}
