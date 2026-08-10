import CoreGraphics
import Foundation

enum ControlFlickDirection: String, Equatable, Sendable {
    case up, down, left, right
}

enum ControlGestureCommand: Equatable {
    case tap(CGPoint)
    case swipe(from: CGPoint, to: CGPoint, durationMS: Int)
    case flick(from: CGPoint, toward: CGPoint, durationMS: Int)
}

struct ControlGestureReducer {
    var tapDistance: CGFloat = 8
    var dragDurationMS = 220
    var earlySwipeDurationMS = 160
    var earlySwipeDistance: CGFloat = 28
    var earlySwipeSamplingWindow: TimeInterval = 0.14
    var scrollDurationMS = 180
    var scrollMinimumDistance: CGFloat = 14
    var preciseScrollScale: CGFloat = 3.2
    var discreteScrollScale: CGFloat = 1.8
    var maxScrollDeltaX: CGFloat = 220
    var maxScrollDeltaY: CGFloat = 260

    private var mouseStartLocation: CGPoint?
    private var lastMouseDragLocation: CGPoint?
    private var firstMouseMotionTimestamp: TimeInterval?
    private var didCommitMouseSwipe = false
    private var scrollLocation: CGPoint?
    private var accumulatedScroll = CGSize.zero

    var hasActiveScroll: Bool {
        scrollLocation != nil
    }

    mutating func beginMouseDrag(
        at location: CGPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        mouseStartLocation = location
        lastMouseDragLocation = location
        firstMouseMotionTimestamp = nil
        didCommitMouseSwipe = false
    }

    mutating func updateMouseDrag(
        to location: CGPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ControlGestureCommand? {
        guard let start = mouseStartLocation, !didCommitMouseSwipe else { return nil }
        lastMouseDragLocation = location
        let totalDistance = distance(from: start, to: location)
        if firstMouseMotionTimestamp == nil, totalDistance >= tapDistance {
            firstMouseMotionTimestamp = timestamp
        }
        guard totalDistance >= earlySwipeDistance,
              let firstMouseMotionTimestamp,
              timestamp - firstMouseMotionTimestamp <= earlySwipeSamplingWindow else {
            return nil
        }

        // A fast gesture is a flick/page swipe. Send it while the mouse is
        // still down. Slow, precise drags retain their exact mouse-up endpoint.
        didCommitMouseSwipe = true
        return .flick(from: start, toward: location, durationMS: earlySwipeDurationMS)
    }

    mutating func endMouseDrag(at location: CGPoint) -> ControlGestureCommand? {
        guard let start = mouseStartLocation else { return nil }
        let wasCommitted = didCommitMouseSwipe
        resetMouseDrag()

        if wasCommitted {
            // The fast swipe was already sent before mouse-up.
            return nil
        }

        let totalDistance = distance(from: start, to: location)
        if totalDistance < tapDistance {
            return .tap(location)
        }
        return .swipe(from: start, to: location, durationMS: dragDurationMS)
    }

    private mutating func resetMouseDrag() {
        mouseStartLocation = nil
        lastMouseDragLocation = nil
        firstMouseMotionTimestamp = nil
        didCommitMouseSwipe = false
    }

    mutating func beginScroll(at location: CGPoint) {
        scrollLocation = location
        accumulatedScroll = .zero
    }

    mutating func appendScroll(delta: CGSize, precise: Bool) -> ControlGestureCommand? {
        accumulatedScroll.width += delta.width
        accumulatedScroll.height += delta.height
        // Trackpads also emit many samples. Coalesce the entire burst and send
        // one WDA gesture after the 35 ms idle flush.
        return nil
    }

    mutating func flushScroll(precise: Bool) -> ControlGestureCommand? {
        makeScrollCommand(precise: precise, clearsScroll: true)
    }

    private mutating func makeScrollCommand(precise: Bool, clearsScroll: Bool) -> ControlGestureCommand? {
        guard let center = scrollLocation else { return nil }
        let distance = hypot(accumulatedScroll.width, accumulatedScroll.height)
        guard distance >= scrollMinimumDistance else {
            if clearsScroll {
                scrollLocation = nil
                accumulatedScroll = .zero
            }
            return nil
        }

        let scale = precise ? preciseScrollScale : discreteScrollScale
        let cappedDX = min(max(accumulatedScroll.width * scale, -maxScrollDeltaX), maxScrollDeltaX)
        let cappedDY = min(max(accumulatedScroll.height * scale, -maxScrollDeltaY), maxScrollDeltaY)

        accumulatedScroll = .zero
        if clearsScroll {
            scrollLocation = nil
        }

        return .swipe(
            from: center,
            to: CGPoint(x: center.x - cappedDX, y: center.y + cappedDY),
            durationMS: scrollDurationMS
        )
    }

    mutating func cancel() {
        resetMouseDrag()
        scrollLocation = nil
        accumulatedScroll = .zero
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}
