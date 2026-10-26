@testable import StupidMirrorApp
import AppKit
import XCTest

@MainActor
final class ContinuousGestureOverlayTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, _ point: CGPoint, at time: Double, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func view() -> ControlGestureNSView {
        let view = ControlGestureNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        view.isEnabled = true
        view.aspectRatio = 0.5
        return view
    }

    func testLongPressThenDragSendsBeforeMouseUpWithoutReplaying() {
        let view = view()
        var events: [TouchEvent] = []
        var replayed = false
        view.handlers = ControlGestureHandlers(onTap: { _ in replayed = true },
                                               onLongPress: { _, _ in replayed = true },
                                               onDrag: { _ in replayed = true },
                                               onTouch: { events.append($0) })
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 200), at: 1))
        XCTAssertEqual(events.map(\.phase), [.down], "A held contact starts immediately.")
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 120, y: 240), at: 2.5))
        XCTAssertEqual(events.map(\.phase), [.down, .move], "Movement is delivered before release, even after a long hold.")
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 130, y: 250), at: 2.6))
        XCTAssertEqual(events.map(\.phase), [.down, .move, .move, .up])
        XCTAssertEqual(events.last?.point, CGPoint(x: 0.65, y: 0.375))
        XCTAssertFalse(replayed)
    }

    func testBackendChangeCannotReplayAnAlreadyStartedGesture() {
        let view = view()
        var original: [TouchEvent] = []
        var replacement: [TouchEvent] = []
        var replayed = false
        view.handlers.onTouch = { original.append($0) }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 200), at: 1))
        view.handlers = ControlGestureHandlers(onTap: { _ in replayed = true }, onTouch: { replacement.append($0) })
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 100, y: 200), at: 1.1))
        XCTAssertEqual(original.map(\.phase), [.down, .up])
        XCTAssertTrue(replacement.isEmpty)
        XCTAssertFalse(replayed)
    }

    func testResizeCancelsAtLastPositionAndIgnoresLaterMouseUp() {
        let view = view()
        var events: [TouchEvent] = []
        view.handlers.onTouch = { events.append($0) }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 160), at: 1))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 120, y: 200), at: 1.1))
        view.setFrameSize(NSSize(width: 300, height: 600))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 120, y: 200), at: 1.2))
        XCTAssertEqual(events.map(\.phase), [.down, .move, .cancel])
        XCTAssertEqual(events.last?.point, CGPoint(x: 0.6, y: 0.5))
    }

    func testDoubleClickIsTwoContactsWithoutThirdTap() {
        let view = view()
        var events: [TouchEvent] = []
        var replayed = false
        view.handlers.onTouch = { events.append($0) }
        view.handlers.onDoubleTap = { _ in replayed = true }
        for click in 1...2 {
            let time = Double(click) * 0.2
            view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 200), at: time, clicks: click))
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 100, y: 200), at: time + 0.08, clicks: click))
        }
        XCTAssertEqual(events.map(\.phase), [.down, .up, .down, .up])
        XCTAssertFalse(replayed)
    }

    func testOutwardClampedScrollDoesNotTap() {
        let view = view()
        var events: [TouchEvent] = []
        view.handlers.onTouch = { events.append($0) }
        view.coordinateMapper = { _, _, _ in CGPoint(x: 1, y: 0) }
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                             wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: scroll)!)
        view.cancelPendingGestures()
        XCTAssertTrue(events.isEmpty, "A scroll with no possible movement must not create a contact.")
    }

    func testPhasedScrollHoldsContactAcrossPauseUntilEnded() async {
        let view = view()
        var events: [TouchEvent] = []
        view.handlers.onTouch = { events.append($0) }
        defer { view.cancelPendingGestures() }

        func scroll(_ phase: CGScrollPhase, delta: Int32, at time: Double) -> NSEvent {
            let source = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                 wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            source.location = CGPoint(x: 100, y: 160)
            source.timestamp = CGEventTimestamp(time * 1_000_000_000)
            source.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            source.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            return NSEvent(cgEvent: source)!
        }

        let began = scroll(.began, delta: 20, at: 1)
        let changed = scroll(.changed, delta: 10, at: 1.05)
        let origin = view.convert(began.locationInWindow, from: nil)
        // Synthetic CGEvents use screen coordinates; keep this lifecycle
        // check independent of the test machine's display arrangement.
        view.coordinateMapper = { point, _, _ in
            CGPoint(x: 0.5 + (point.x - origin.x) / 200,
                    y: 0.5 + (point.y - origin.y) / 400)
        }
        XCTAssertEqual(began.phase, .began)
        XCTAssertEqual(changed.phase, .changed)
        view.scrollWheel(with: began)
        view.scrollWheel(with: changed)
        XCTAssertEqual(events.map(\.phase), [.down, .move, .move])

        // Let the old 120 ms idle timer run while this same system gesture
        // remains active. A pause must not release or restart its contact.
        let held = expectation(description: "paused past the wheel idle interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { held.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [held], timeout: 1)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events.map(\.phase), [.down, .move, .move])

        view.scrollWheel(with: scroll(.changed, delta: 10, at: 1.4))
        let ended = scroll(.ended, delta: 0, at: 1.5)
        XCTAssertEqual(ended.phase, .ended)
        view.scrollWheel(with: ended)
        XCTAssertEqual(events.map(\.phase), [.down, .move, .move, .move, .up])
    }

    func testCoordinateMapperIsFrozenUntilRelease() {
        let view = view()
        var events: [TouchEvent] = []
        view.handlers.onTouch = { events.append($0) }
        view.coordinateMapper = { point, _, _ in CGPoint(x: point.x / 200, y: point.y / 400) }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 80, y: 160), at: 1))
        view.coordinateMapper = { _, _, _ in CGPoint(x: 0.9, y: 0.9) }
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 120, y: 200), at: 1.1))
        XCTAssertEqual(events.last?.point, CGPoint(x: 0.6, y: 0.5))
    }
}
