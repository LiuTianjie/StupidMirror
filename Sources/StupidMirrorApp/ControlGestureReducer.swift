import CoreGraphics
import Foundation

enum ControlFlickDirection: String, Equatable, Sendable {
    case up, down, left, right
}

/// One recorded point of a finger (mouse) path, in the overlay's coordinates.
struct ControlPathSample: Equatable, Sendable {
    var point: CGPoint
    var timestamp: TimeInterval
}

/// What the mouse did on the mirror, reduced to one device gesture.
enum ControlGestureCommand: Equatable {
    case tap(CGPoint)
    case doubleTap(CGPoint)
    /// The mouse stayed down without moving for at least `longPressThreshold`.
    case longPress(CGPoint, durationMS: Int)
    /// A straight two-point movement (scroll wheel, very short drags).
    case swipe(from: CGPoint, to: CGPoint, durationMS: Int)
    /// A recorded path with real timing, replayed on the device so curves,
    /// pauses, and release velocity survive.
    case drag(path: [ControlPathSample])
    case flick(from: CGPoint, toward: CGPoint, durationMS: Int)
}

/// Turns raw mouse and scroll events into device gestures.
///
/// XCTest replays a complete gesture; it cannot follow a finger that is still
/// down. The reducer therefore decides, at mouse-up, which single gesture best
/// reproduces what the user did: a tap, a long press, a flick that was already
/// sent while the mouse moved fast, or a path drag that keeps the recorded
/// shape and timing.
struct ControlGestureReducer {
    var tapDistance: CGFloat = 8
    var longPressThreshold: TimeInterval = 0.45
    var maximumLongPressMS = 1_500
    var dragDurationMS = 220
    var earlySwipeDurationMS = 160
    var earlySwipeDistance: CGFloat = 28
    var earlySwipeSamplingWindow: TimeInterval = 0.14
    var maximumPathSamples = 24
    var scrollDurationMS = 180
    var scrollMinimumDistance: CGFloat = 14
    var preciseScrollScale: CGFloat = 3.2
    var discreteScrollScale: CGFloat = 1.8
    var maxScrollDeltaX: CGFloat = 220
    var maxScrollDeltaY: CGFloat = 260

    private var mouseStartLocation: CGPoint?
    private var mouseDownTimestamp: TimeInterval?
    private var firstMouseMotionTimestamp: TimeInterval?
    private var didCommitMouseSwipe = false
    private var pathSamples: [ControlPathSample] = []
    private var scrollLocation: CGPoint?
    private var accumulatedScroll = CGSize.zero

    var hasActiveScroll: Bool {
        scrollLocation != nil
    }

    /// The path recorded so far, for drawing while the mouse is down.
    var currentPath: [CGPoint] {
        pathSamples.map(\.point)
    }

    mutating func beginMouseDrag(
        at location: CGPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        mouseStartLocation = location
        mouseDownTimestamp = timestamp
        firstMouseMotionTimestamp = nil
        didCommitMouseSwipe = false
        pathSamples = [ControlPathSample(point: location, timestamp: timestamp)]
    }

    mutating func updateMouseDrag(
        to location: CGPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ControlGestureCommand? {
        guard let start = mouseStartLocation, !didCommitMouseSwipe else { return nil }
        pathSamples.append(ControlPathSample(point: location, timestamp: timestamp))
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
        // still down. Slow, precise drags keep their full path for mouse-up.
        didCommitMouseSwipe = true
        return .flick(from: start, toward: location, durationMS: earlySwipeDurationMS)
    }

    mutating func endMouseDrag(
        at location: CGPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        clickCount: Int = 1
    ) -> ControlGestureCommand? {
        guard let start = mouseStartLocation else { return nil }
        let wasCommitted = didCommitMouseSwipe
        let downTimestamp = mouseDownTimestamp ?? timestamp
        var samples = pathSamples
        resetMouseDrag()

        if wasCommitted {
            // The fast swipe was already sent before mouse-up.
            return nil
        }

        let totalDistance = distance(from: start, to: location)
        let moved = samples.contains { distance(from: start, to: $0.point) >= tapDistance }
        if totalDistance < tapDistance, !moved {
            if clickCount >= 2 {
                return .doubleTap(location)
            }
            let held = timestamp - downTimestamp
            if held >= longPressThreshold {
                return .longPress(location, durationMS: min(Int((held * 1_000).rounded()), maximumLongPressMS))
            }
            return .tap(location)
        }
        if samples.last?.point != location {
            samples.append(ControlPathSample(point: location, timestamp: timestamp))
        }
        let path = Self.downsample(samples, to: maximumPathSamples)
        guard path.count >= 3 else {
            return .swipe(from: start, to: location, durationMS: dragDurationMS)
        }
        return .drag(path: path)
    }

    /// Keeps the first and last samples and spreads the rest evenly, so a
    /// long drag does not turn into hundreds of pointer moves.
    static func downsample(_ samples: [ControlPathSample], to limit: Int) -> [ControlPathSample] {
        guard samples.count > limit, limit >= 2 else { return samples }
        var result: [ControlPathSample] = []
        result.reserveCapacity(limit)
        let step = Double(samples.count - 1) / Double(limit - 1)
        for index in 0..<limit {
            result.append(samples[Int((Double(index) * step).rounded())])
        }
        return result
    }

    private mutating func resetMouseDrag() {
        mouseStartLocation = nil
        mouseDownTimestamp = nil
        firstMouseMotionTimestamp = nil
        didCommitMouseSwipe = false
        pathSamples = []
    }

    mutating func beginScroll(at location: CGPoint) {
        scrollLocation = location
        accumulatedScroll = .zero
    }

    mutating func appendScroll(delta: CGSize, precise: Bool) -> ControlGestureCommand? {
        accumulatedScroll.width += delta.width
        accumulatedScroll.height += delta.height
        // Trackpads also emit many samples. Coalesce the entire burst and send
        // one gesture after the 35 ms idle flush.
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
