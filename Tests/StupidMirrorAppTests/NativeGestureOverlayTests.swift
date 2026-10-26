@testable import StupidMirrorApp
import AppKit
import XCTest

@MainActor
final class NativeGestureOverlayTests: XCTestCase {
    private func view(onTouch: @escaping (TouchEvent) -> Void) -> ControlGestureNSView {
        let view = ControlGestureNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        view.isEnabled = true
        view.aspectRatio = 0.5
        view.handlers = ControlGestureHandlers(onTouch: onTouch, supportsNativeGestures: true)
        return view
    }

    @discardableResult
    private func send(
        _ kind: NativeHIDGestureTranslator.Kind, to view: ControlGestureNSView,
        phase: NSEvent.Phase, momentumPhase: NSEvent.Phase = [],
        delta: Double = 1, at timestamp: TimeInterval
    ) throws -> HIDInputReport {
        let report: HIDInputReport
        switch kind {
        case .scroll:
            report = try NativeHIDGestureTranslator.scrollReport(
                scrollingDelta: CGPoint(x: 0, y: delta), phase: phase, momentumPhase: momentumPhase,
                timestamp: timestamp, timebase: .init(numerator: 1, denominator: 1)
            )
        case .scale:
            report = try NativeHIDGestureTranslator.scaleReport(
                magnification: delta, phase: phase, timestampTicks: UInt64(timestamp * 1_000_000_000)
            )
        case .rotation:
            report = try NativeHIDGestureTranslator.rotationReport(
                degrees: delta, phase: phase, timestampTicks: UInt64(timestamp * 1_000_000_000)
            )
        }
        view.handleNativeGesture(kind: kind, phase: phase, momentumPhase: momentumPhase,
                                 timestamp: timestamp, location: CGPoint(x: 100, y: 200), report: report)
        return report
    }

    private func mouse(_ type: NSEvent.EventType, at timestamp: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: 100, y: 200), modifierFlags: [],
                          timestamp: timestamp, windowNumber: 0, context: nil,
                          eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func scroll(_ phase: CGScrollPhase, delta: Int32, at timestamp: TimeInterval) -> NSEvent {
        let source = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                             wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        source.location = CGPoint(x: 100, y: 160)
        source.timestamp = CGEventTimestamp(timestamp * 1_000_000_000)
        source.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        source.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return NSEvent(cgEvent: source)!
    }

    func testScaleEndingKeepsSimultaneousRotationAndOwnerActive() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }

        let scaleBegin = try send(.scale, to: view, phase: .began, delta: 0.1, at: 1)
        let rotationBegin = try send(.rotation, to: view, phase: .began, delta: 3, at: 1.01)
        XCTAssertEqual(events.map(\.phase), [.down, .move])
        XCTAssertEqual(events.last?.nativeInput?.cancellationReports.count, 2)

        let scaleEnd = try send(.scale, to: view, phase: .ended, delta: 0, at: 1.02)
        XCTAssertEqual(events.last?.phase, .move, "Ending one component must not release the shared owner.")
        XCTAssertEqual(events.last?.nativeInput?.cancellationReports.count, 1)

        let rotationMove = try send(.rotation, to: view, phase: .changed, delta: 2, at: 1.03)
        let rotationEnd = try send(.rotation, to: view, phase: .ended, delta: 0, at: 1.04)
        XCTAssertEqual(events.map(\.phase), [.down, .move, .move, .move, .up])
        XCTAssertEqual(events.flatMap { $0.nativeInput?.reports ?? [] },
                       [scaleBegin, rotationBegin, scaleEnd, rotationMove, rotationEnd])
        XCTAssertEqual(events.last?.nativeInput?.cancellationReports.count, 0)
    }

    func testZeroDeltaScrollEndIsForwardedBeforeReleasingOwner() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }

        let begin = try send(.scroll, to: view, phase: .began, delta: 12, at: 1)
        let end = try send(.scroll, to: view, phase: .ended, delta: 0, at: 1.1)

        XCTAssertEqual(events.map(\.phase), [.down, .up])
        XCTAssertEqual(events.flatMap { $0.nativeInput?.reports ?? [] }, [begin, end])
        XCTAssertEqual(events.last?.nativeInput?.reports, [end])
        XCTAssertEqual(events.last?.nativeInput?.cancellationReports.count, 0)
    }

    func testMomentumReportsSurviveFingerEndThroughMomentumEnd() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }
        var reports: [HIDInputReport] = []

        reports.append(try send(.scroll, to: view, phase: .began, delta: 12, at: 1))
        reports.append(try send(.scroll, to: view, phase: .changed, delta: 8, at: 1.01))
        reports.append(try send(.scroll, to: view, phase: .ended, delta: 0, at: 1.02))
        reports.append(try send(.scroll, to: view, phase: [], momentumPhase: .began, delta: 6, at: 1.03))
        reports.append(try send(.scroll, to: view, phase: [], momentumPhase: .changed, delta: 3, at: 1.04))
        reports.append(try send(.scroll, to: view, phase: [], momentumPhase: .ended, delta: 0, at: 1.05))

        XCTAssertEqual(events.flatMap { $0.nativeInput?.reports ?? [] }, reports)
        XCTAssertEqual(events.last?.phase, .up)
        XCTAssertFalse(events.contains { $0.phase == .cancel })
    }

    func testCancellationBetweenFingerEndAndMomentumBlocksOldMomentum() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }

        try send(.scroll, to: view, phase: .began, delta: 12, at: 1)
        try send(.scroll, to: view, phase: .ended, delta: 0, at: 1.01)
        view.cancelPendingGestures()
        let beforeMomentum = events

        try send(.scroll, to: view, phase: [], momentumPhase: .began, delta: 6, at: 1.02)
        try send(.scroll, to: view, phase: [], momentumPhase: .changed, delta: 3, at: 1.03)
        try send(.scroll, to: view, phase: [], momentumPhase: .ended, delta: 0, at: 1.04)

        XCTAssertEqual(events, beforeMomentum, "An ended owner must still remember that its momentum was cancelled.")
    }

    func testNewFingerBeginImmediatelyRestartsAfterCancellation() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }

        try send(.scroll, to: view, phase: .began, delta: 12, at: 1)
        view.cancelPendingGestures()
        XCTAssertEqual(events.map(\.phase), [.down, .cancel])
        try send(.scroll, to: view, phase: .changed, delta: 6, at: 1.01)
        XCTAssertEqual(events.map(\.phase), [.down, .cancel])

        let nextBegin = try send(.scroll, to: view, phase: .began, delta: 4, at: 1.02)
        XCTAssertEqual(events.map(\.phase), [.down, .cancel, .down])
        XCTAssertEqual(events.last?.nativeInput?.reports, [nextBegin])
        try send(.scroll, to: view, phase: .ended, delta: 0, at: 1.03)
        XCTAssertEqual(events.last?.phase, .up)
    }

    func testMouseDownCancelsNativeInputBeforeStartingDirectContact() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }

        try send(.scale, to: view, phase: .began, delta: 0.1, at: 1)
        try send(.rotation, to: view, phase: .began, delta: 3, at: 1.01)
        let nativeEventCount = events.count
        view.mouseDown(with: mouse(.leftMouseDown, at: 1.02))

        let handoff = Array(events.dropFirst(nativeEventCount))
        XCTAssertEqual(handoff.map(\.phase), [.cancel, .down])
        XCTAssertTrue(handoff.allSatisfy { $0.nativeInput == nil })

        view.mouseUp(with: mouse(.leftMouseUp, at: 1.03))
        XCTAssertEqual(events.dropFirst(nativeEventCount).map(\.phase), [.cancel, .down, .up])
    }

    func testNativeToFallbackSwitchDoesNotReplayCancelledScrollTail() throws {
        var events: [TouchEvent] = []
        let view = view { events.append($0) }

        try send(.scroll, to: view, phase: .began, delta: 12, at: 1)
        view.cancelPendingGestures()
        view.handlers.supportsNativeGestures = false
        let afterCancellation = events

        let oldChange = scroll(.changed, delta: 20, at: 1.01)
        let origin = view.convert(oldChange.locationInWindow, from: nil)
        // Keep the in-memory CGEvent independent of the test machine's screen layout.
        view.coordinateMapper = { point, _, _ in
            CGPoint(x: 0.5 + (point.x - origin.x) / 200,
                    y: 0.5 + (point.y - origin.y) / 400)
        }
        XCTAssertEqual(oldChange.phase, .changed)
        view.scrollWheel(with: oldChange)
        XCTAssertEqual(events, afterCancellation, "A route change must not turn the old tail into a direct DOWN.")

        view.scrollWheel(with: scroll(.began, delta: 20, at: 1.02))
        let freshEvents = Array(events.dropFirst(afterCancellation.count))
        XCTAssertEqual(freshEvents.first?.phase, .down)
        XCTAssertTrue(freshEvents.allSatisfy { $0.nativeInput == nil })
        view.scrollWheel(with: scroll(.ended, delta: 0, at: 1.03))
        XCTAssertEqual(events.last?.phase, .up)
    }
}
