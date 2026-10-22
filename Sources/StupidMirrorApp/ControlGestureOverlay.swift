import AppKit
import SwiftUI

/// Everything the mirror surface can send to the device, in normalized
/// (0...1, top-left origin) coordinates.
struct ControlGestureHandlers {
    var onTap: (CGPoint) -> Void = { _ in }
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    var onLongPress: (CGPoint, Int) -> Void = { _, _ in }
    var onSwipe: (CGPoint, CGPoint, Int) -> Void = { _, _, _ in }
    var onDrag: ([ControlPathSample]) -> Void = { _ in }
    var onPinch: (CGPoint, Double, Double) -> Void = { _, _, _ in }
    var onRotate: (CGPoint, Double, Double) -> Void = { _, _, _ in }
}

struct ControlGestureOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var aspectRatio: Double
    var handlers: ControlGestureHandlers

    func makeNSView(context: Context) -> ControlGestureNSView {
        let view = ControlGestureNSView()
        view.isEnabled = isEnabled
        view.aspectRatio = aspectRatio
        view.handlers = handlers
        return view
    }

    func updateNSView(_ nsView: ControlGestureNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.aspectRatio = aspectRatio
        nsView.handlers = handlers
        if !isEnabled {
            nsView.cancelPendingGestures()
        }
    }
}

/// Captures mouse, scroll wheel, trackpad pinch and rotate input over the
/// mirror and reduces it to device gestures.
final class ControlGestureNSView: NSView {
    var isEnabled = false
    var aspectRatio = 1.0
    var handlers = ControlGestureHandlers()

    private var gestureReducer = ControlGestureReducer()
    private var scrollFlushWorkItem: DispatchWorkItem?
    private var gestureStart: CGPoint?
    private var gestureCurrent: CGPoint?
    private var magnification = 0.0
    private var magnificationStart: TimeInterval?
    private var magnificationCenter: CGPoint?
    private var rotation = 0.0
    private var rotationStart: TimeInterval?
    private var rotationCenter: CGPoint?

    /// A secondary click stands in for a long press.
    private static let rightClickLongPressMS = 800

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, bounds.contains(point) else { return nil }
        return self
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        cancelScrollFlush()
        gestureStart = location
        gestureCurrent = location
        needsDisplay = true
        gestureReducer.beginMouseDrag(at: location, timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        let location = convert(event.locationInWindow, from: nil)
        gestureCurrent = location
        needsDisplay = true
        if let command = gestureReducer.updateMouseDrag(to: location, timestamp: event.timestamp) {
            sendCommand(command)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let endLocation = convert(event.locationInWindow, from: nil)
        var stroke = gestureReducer.currentPath
        if stroke.last != endLocation { stroke.append(endLocation) }
        if let command = gestureReducer.endMouseDrag(
            at: endLocation,
            timestamp: event.timestamp,
            clickCount: event.clickCount
        ) {
            sendCommand(command)
        }
        // Gestures that begin outside the phone picture are not sent, so
        // they get no acknowledgement either.
        if let first = stroke.first, normalizedPoint(first) != nil {
            showReleaseFeedback(stroke)
        }
        gestureStart = nil
        gestureCurrent = nil
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let location = convert(event.locationInWindow, from: nil)
        sendCommand(.longPress(location, durationMS: Self.rightClickLongPressMS))
    }

    // MARK: Scroll wheel and trackpad

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else {
            super.scrollWheel(with: event)
            return
        }

        // The swipe sent when the fingers lift is replayed at their speed,
        // so the phone coasts on its own. Replaying macOS's momentum as well
        // would scroll twice, the second time late.
        guard event.momentumPhase == [] else { return }

        let location = convert(event.locationInWindow, from: nil)
        let began = event.phase == .began
        if began || !gestureReducer.hasActiveScroll {
            gestureReducer.beginScroll(at: location)
        }

        if let command = gestureReducer.appendScroll(
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            timestamp: event.timestamp
        ) {
            sendCommand(command)
        }

        // A mouse wheel has no phases; its notches are batched by the idle
        // flush like trackpad samples, so a quick spin is one scroll.
        let ended = event.phase == .ended || event.phase == .cancelled

        if ended {
            flushScroll(precise: event.hasPreciseScrollingDeltas)
        } else {
            scheduleScrollFlush(precise: event.hasPreciseScrollingDeltas)
        }
    }

    override func magnify(with event: NSEvent) {
        guard isEnabled else { return }
        if event.phase == .began {
            magnification = 0
            magnificationStart = event.timestamp
            magnificationCenter = convert(event.locationInWindow, from: nil)
        }
        magnification += event.magnification
        guard event.phase == .ended || event.phase == .cancelled else { return }
        defer {
            magnification = 0
            magnificationStart = nil
            magnificationCenter = nil
        }
        guard event.phase == .ended,
              abs(magnification) >= 0.08,
              let center = magnificationCenter,
              let normalized = normalizedPoint(center) else { return }
        let elapsed = max(event.timestamp - (magnificationStart ?? event.timestamp), 0.1)
        // The trackpad reports a relative change; XCUITest wants a scale factor.
        let scale = max(0.2, min(1 + magnification, 5))
        handlers.onPinch(normalized, scale, (scale - 1) / elapsed)
    }

    override func rotate(with event: NSEvent) {
        guard isEnabled else { return }
        if event.phase == .began {
            rotation = 0
            rotationStart = event.timestamp
            rotationCenter = convert(event.locationInWindow, from: nil)
        }
        rotation += Double(event.rotation)
        guard event.phase == .ended || event.phase == .cancelled else { return }
        defer {
            rotation = 0
            rotationStart = nil
            rotationCenter = nil
        }
        guard event.phase == .ended,
              abs(rotation) >= 5,
              let center = rotationCenter,
              let normalized = normalizedPoint(center) else { return }
        let elapsed = max(event.timestamp - (rotationStart ?? event.timestamp), 0.1)
        handlers.onRotate(normalized, rotation, rotation / elapsed)
    }

    func cancelPendingGestures() {
        cancelScrollFlush()
        gestureReducer.cancel()
        gestureStart = nil
        gestureCurrent = nil
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let start = gestureStart, let current = gestureCurrent else { return }
        let path = NSBezierPath()
        path.move(to: start)
        for point in gestureReducer.currentPath.dropFirst() {
            path.line(to: point)
        }
        if gestureReducer.currentPath.last != current {
            path.line(to: current)
        }
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        path.stroke()

        let radius: CGFloat = 7
        let marker = NSBezierPath(ovalIn: NSRect(
            x: current.x - radius,
            y: current.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        marker.fill()
    }

    // MARK: Release feedback

    /// What the user just did, held on screen and faded out over the time
    /// the phone typically needs to answer, so a release never looks ignored.
    /// Core Animation runs the fade, so nothing outlives the view.
    private static let releaseFeedbackDuration: CFTimeInterval = 0.45

    private func showReleaseFeedback(_ stroke: [CGPoint]) {
        guard let layer, let first = stroke.first, let last = stroke.last else { return }
        let isTap = stroke.allSatisfy { hypot($0.x - first.x, $0.y - first.y) < gestureReducer.tapDistance }
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.fillColor = nil
        shape.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        shape.lineCap = .round
        shape.lineJoin = .round

        let path = CGMutablePath()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        var animations: [CAAnimation] = [fade]
        if isTap {
            // A ring growing out of the tap point. The layer is the ring's
            // own square so it scales about the tap.
            shape.frame = CGRect(x: last.x - 8, y: last.y - 8, width: 16, height: 16)
            path.addEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
            shape.lineWidth = 2
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 2.6
            animations.append(grow)
        } else {
            path.move(to: first)
            for point in stroke.dropFirst() { path.addLine(to: point) }
            shape.lineWidth = 3
        }
        shape.path = path
        shape.opacity = 0

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = Self.releaseFeedbackDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { shape.removeFromSuperlayer() }
        layer.addSublayer(shape)
        shape.add(group, forKey: "release")
        CATransaction.commit()
    }

    // MARK: Scroll flushing

    private func scheduleScrollFlush(precise: Bool) {
        cancelScrollFlush()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushScroll(precise: precise)
        }
        scrollFlushWorkItem = workItem
        // Trackpad samples arrive every few milliseconds; wheel notches can
        // be a tenth of a second apart and still be one spin.
        DispatchQueue.main.asyncAfter(deadline: .now() + (precise ? 0.035 : 0.09), execute: workItem)
    }

    private func flushScroll(precise: Bool) {
        cancelScrollFlush()
        if let command = gestureReducer.flushScroll(precise: precise) {
            sendCommand(command)
        }
    }

    private func cancelScrollFlush() {
        scrollFlushWorkItem?.cancel()
        scrollFlushWorkItem = nil
    }

    // MARK: Dispatch

    private func sendCommand(_ command: ControlGestureCommand) {
        switch command {
        case let .tap(point):
            guard let normalized = normalizedPoint(point) else { return }
            handlers.onTap(normalized)
        case let .doubleTap(point):
            guard let normalized = normalizedPoint(point) else { return }
            handlers.onDoubleTap(normalized)
        case let .longPress(point, durationMS):
            guard let normalized = normalizedPoint(point) else { return }
            handlers.onLongPress(normalized, durationMS)
        case let .swipe(start, end, durationMS):
            // A gesture must begin on the phone; where it ends may run past
            // the picture's edge, as a finger runs off a real screen.
            guard let startPoint = normalizedPoint(start) else { return }
            handlers.onSwipe(startPoint, normalizedPoint(end, clamped: true) ?? startPoint, durationMS)
        case let .drag(path):
            guard let first = path.first, let startPoint = normalizedPoint(first.point) else { return }
            let normalizedPath = [ControlPathSample(point: startPoint, timestamp: first.timestamp)]
                + path.dropFirst().compactMap { sample -> ControlPathSample? in
                    guard let point = normalizedPoint(sample.point, clamped: true) else { return nil }
                    return ControlPathSample(point: point, timestamp: sample.timestamp)
                }
            guard normalizedPath.count >= 2 else { return }
            handlers.onDrag(normalizedPath)
        case let .flick(start, current, durationMS):
            guard let startPoint = normalizedPoint(start),
                  let currentPoint = normalizedPoint(current, clamped: true) else { return }
            let fling = Self.fling(from: startPoint, toward: currentPoint, durationMS: durationMS)
            handlers.onSwipe(fling.start, fling.end, fling.durationMS)
        }
    }

    /// How far a flick's stroke continues past the point where it was
    /// recognised, as a multiple of the distance covered so far. The stroke
    /// keeps its start and its speed, so the phone coasts as far as that
    /// speed carries it instead of always turning a full page.
    nonisolated static let flingExtension: CGFloat = 2.5

    /// A flick in normalized coordinates: same start, same direction and
    /// speed, the stroke extended and stopped at the screen edge.
    nonisolated static func fling(
        from start: CGPoint,
        toward current: CGPoint,
        durationMS: Int
    ) -> (start: CGPoint, end: CGPoint, durationMS: Int) {
        let dx = (current.x - start.x) * flingExtension
        let dy = (current.y - start.y) * flingExtension
        // The largest fraction of the extended stroke that stays on screen.
        var fraction: CGFloat = 1
        for (origin, delta) in [(start.x, dx), (start.y, dy)] where delta != 0 {
            let limit = delta > 0 ? (1 - origin) / delta : -origin / delta
            fraction = min(fraction, max(limit, 0))
        }
        let end = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
        let duration = Double(durationMS) * Double(flingExtension) * Double(fraction)
        return (start, end, max(Int(duration.rounded()), 40))
    }

    /// The point in 0...1 phone coordinates. Outside the picture it is nil,
    /// or, when `clamped`, pinned to the nearest edge.
    private func normalizedPoint(_ point: CGPoint, clamped: Bool = false) -> CGPoint? {
        let containerWidth = max(bounds.width, 1)
        let containerHeight = max(bounds.height, 1)
        let ratio = max(CGFloat(aspectRatio), 0.1)
        let containerRatio = containerWidth / containerHeight

        let contentWidth: CGFloat
        let contentHeight: CGFloat
        if containerRatio > ratio {
            contentHeight = containerHeight
            contentWidth = contentHeight * ratio
        } else {
            contentWidth = containerWidth
            contentHeight = contentWidth / ratio
        }

        let originX = (containerWidth - contentWidth) / 2
        let originY = (containerHeight - contentHeight) / 2
        guard clamped
                || (point.x >= originX
                    && point.x <= originX + contentWidth
                    && point.y >= originY
                    && point.y <= originY + contentHeight) else {
            return nil
        }

        return CGPoint(
            x: min(max((point.x - originX) / contentWidth, 0), 1),
            y: min(max(1 - ((point.y - originY) / contentHeight), 0), 1)
        )
    }
}
