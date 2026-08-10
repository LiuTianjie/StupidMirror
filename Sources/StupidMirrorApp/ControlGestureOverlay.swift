import AppKit
import SwiftUI

struct ControlGestureOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var aspectRatio: Double
    var onTap: (CGPoint) -> Void
    var onSwipe: (CGPoint, CGPoint, Int) -> Void
    var onFlick: (ControlFlickDirection) -> Void

    func makeNSView(context: Context) -> ControlGestureNSView {
        let view = ControlGestureNSView()
        view.isEnabled = isEnabled
        view.aspectRatio = aspectRatio
        view.onTap = onTap
        view.onSwipe = onSwipe
        view.onFlick = onFlick
        return view
    }

    func updateNSView(_ nsView: ControlGestureNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.aspectRatio = aspectRatio
        nsView.onTap = onTap
        nsView.onSwipe = onSwipe
        nsView.onFlick = onFlick
        if !isEnabled {
            nsView.cancelPendingGestures()
        }
    }
}

final class ControlGestureNSView: NSView {
    var isEnabled = false
    var aspectRatio = 1.0
    var onTap: (CGPoint) -> Void = { _ in }
    var onSwipe: (CGPoint, CGPoint, Int) -> Void = { _, _, _ in }
    var onFlick: (ControlFlickDirection) -> Void = { _ in }

    private var gestureReducer = ControlGestureReducer()
    private var scrollFlushWorkItem: DispatchWorkItem?
    private var gestureStart: CGPoint?
    private var gestureCurrent: CGPoint?

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
        if let command = gestureReducer.endMouseDrag(at: endLocation) {
            sendCommand(command)
        }
        gestureStart = nil
        gestureCurrent = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else {
            super.scrollWheel(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let began = event.phase == .began || event.momentumPhase == .began
        if began || !gestureReducer.hasActiveScroll {
            gestureReducer.beginScroll(at: location)
        }

        if let command = gestureReducer.appendScroll(
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas
        ) {
            sendCommand(command)
        }

        let hasExplicitPhase = event.phase != [] || event.momentumPhase != []
        let ended = event.phase == .ended
            || event.phase == .cancelled
            || event.momentumPhase == .ended
            || event.momentumPhase == .cancelled
            || (!hasExplicitPhase && !event.hasPreciseScrollingDeltas)

        if ended {
            flushScroll(precise: event.hasPreciseScrollingDeltas)
        } else {
            scheduleScrollFlush(precise: event.hasPreciseScrollingDeltas)
        }
    }

    func cancelPendingGestures() {
        cancelScrollFlush()
        gestureReducer.cancel()
        gestureStart = nil
        gestureCurrent = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let start = gestureStart, let current = gestureCurrent else { return }
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: current)
        path.lineWidth = 3
        path.lineCapStyle = .round
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

    private func scheduleScrollFlush(precise: Bool) {
        cancelScrollFlush()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushScroll(precise: precise)
        }
        scrollFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: workItem)
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

    private func sendCommand(_ command: ControlGestureCommand) {
        switch command {
        case let .tap(point):
            guard let normalized = normalizedPoint(point) else { return }
            onTap(normalized)
        case let .swipe(start, end, durationMS):
            guard let startPoint = normalizedPoint(start),
                  let endPoint = normalizedPoint(end) else {
                return
            }
            onSwipe(startPoint, endPoint, durationMS)
        case let .flick(start, current, durationMS):
            guard let startPoint = normalizedPoint(start),
                  let currentPoint = normalizedPoint(current) else {
                return
            }
            _ = durationMS
            onFlick(Self.flickDirection(from: startPoint, toward: currentPoint))
        }
    }

    nonisolated static func flickDirection(from start: CGPoint, toward current: CGPoint) -> ControlFlickDirection {
        let dx = current.x - start.x
        let dy = current.y - start.y
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }

    private func normalizedPoint(_ point: CGPoint) -> CGPoint? {
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
        guard point.x >= originX,
              point.x <= originX + contentWidth,
              point.y >= originY,
              point.y <= originY + contentHeight else {
            return nil
        }

        return CGPoint(
            x: min(max((point.x - originX) / contentWidth, 0), 1),
            y: min(max(1 - ((point.y - originY) / contentHeight), 0), 1)
        )
    }
}
