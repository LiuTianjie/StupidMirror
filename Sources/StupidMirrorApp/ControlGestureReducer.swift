import CoreGraphics
import Foundation

enum ControlGestureCommand: Equatable {
    case tap(CGPoint)
    case swipe(from: CGPoint, to: CGPoint, durationMS: Int)
}

struct ControlGestureReducer {
    var tapDistance: CGFloat = 8
    var dragEmitDistance: CGFloat = 22
    var dragFinishDistance: CGFloat = 3
    var dragDurationMS = 16
    var scrollDurationMS = 45
    var scrollMinimumDistance: CGFloat = 14
    var preciseScrollScale: CGFloat = 3.2
    var discreteScrollScale: CGFloat = 1.8
    var maxScrollDeltaX: CGFloat = 220
    var maxScrollDeltaY: CGFloat = 260

    private var mouseStartLocation: CGPoint?
    private var lastMouseDragLocation: CGPoint?
    private var hasEmittedMouseDrag = false
    private var scrollLocation: CGPoint?
    private var accumulatedScroll = CGSize.zero

    var hasActiveScroll: Bool {
        scrollLocation != nil
    }

    mutating func beginMouseDrag(at location: CGPoint) {
        mouseStartLocation = location
        lastMouseDragLocation = location
        hasEmittedMouseDrag = false
    }

    mutating func updateMouseDrag(to location: CGPoint) -> ControlGestureCommand? {
        guard let start = mouseStartLocation,
              let last = lastMouseDragLocation else {
            return nil
        }

        let totalDistance = distance(from: start, to: location)
        guard totalDistance >= tapDistance else { return nil }
        guard distance(from: last, to: location) >= dragEmitDistance else { return nil }

        lastMouseDragLocation = location
        hasEmittedMouseDrag = true
        return .swipe(from: last, to: location, durationMS: dragDurationMS)
    }

    mutating func endMouseDrag(at location: CGPoint) -> ControlGestureCommand? {
        guard let start = mouseStartLocation else { return nil }
        let last = lastMouseDragLocation ?? start
        let didEmit = hasEmittedMouseDrag
        mouseStartLocation = nil
        lastMouseDragLocation = nil
        hasEmittedMouseDrag = false

        let totalDistance = distance(from: start, to: location)
        if !didEmit, totalDistance < tapDistance {
            return .tap(location)
        }
        guard distance(from: last, to: location) >= dragFinishDistance else { return nil }
        return .swipe(from: didEmit ? last : start, to: location, durationMS: dragDurationMS)
    }

    mutating func beginScroll(at location: CGPoint) {
        scrollLocation = location
        accumulatedScroll = .zero
    }

    mutating func appendScroll(delta: CGSize, precise: Bool) -> ControlGestureCommand? {
        accumulatedScroll.width += delta.width
        accumulatedScroll.height += delta.height
        return makeScrollCommand(precise: precise, clearsScroll: false)
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
        mouseStartLocation = nil
        lastMouseDragLocation = nil
        hasEmittedMouseDrag = false
        scrollLocation = nil
        accumulatedScroll = .zero
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}
