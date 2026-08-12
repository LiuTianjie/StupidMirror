import Foundation
import SwiftUI

enum AutomationActionVisualKind: String, Equatable, Sendable {
    case target
    case tap
    case doubleTap
    case longPress
    case swipe
    case notice
}

struct AutomationActionVisualization: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: AutomationActionVisualKind
    let label: String
    let normalizedTargetFrame: ScreenElementFrame?
    let normalizedPoint: CGPoint?
    let normalizedStart: CGPoint?
    let normalizedEnd: CGPoint?

    init(
        kind: AutomationActionVisualKind,
        label: String,
        normalizedTargetFrame: ScreenElementFrame? = nil,
        normalizedPoint: CGPoint? = nil,
        normalizedStart: CGPoint? = nil,
        normalizedEnd: CGPoint? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.label = label
        self.normalizedTargetFrame = normalizedTargetFrame?.clampedToUnit()
        self.normalizedPoint = normalizedPoint.map(Self.clamped)
        self.normalizedStart = normalizedStart.map(Self.clamped)
        self.normalizedEnd = normalizedEnd.map(Self.clamped)
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

struct AutomationActionOverlayView: View {
    let actions: [AutomationActionVisualization]

    var body: some View {
        GeometryReader { proxy in
            ForEach(actions) { action in
                AutomationActionMark(
                    action: action,
                    size: proxy.size,
                    showsLabel: action.id == actions.last?.id
                )
                    .id(action.id)
                    .transition(.opacity)
                    .opacity(action.id == actions.last?.id ? 1 : 0.38)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.18), value: actions.map(\.id))
    }
}

private struct AutomationActionMark: View {
    let action: AutomationActionVisualization
    let size: CGSize
    let showsLabel: Bool
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = action.normalizedTargetFrame {
                targetFrame(frame)
            }
            if let start = action.normalizedStart, let end = action.normalizedEnd {
                trajectory(from: point(start), to: point(end))
            }
            if let normalizedPoint = action.normalizedPoint {
                tapMarker(at: point(normalizedPoint))
            } else if let frame = action.normalizedTargetFrame {
                tapMarker(at: point(CGPoint(x: frame.centerX, y: frame.centerY)))
            }
            if showsLabel {
                actionLabel
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }

    private func targetFrame(_ frame: ScreenElementFrame) -> some View {
        let rect = CGRect(
            x: frame.x * size.width,
            y: frame.y * size.height,
            width: frame.width * size.width,
            height: frame.height * size.height
        )
        return RoundedRectangle(cornerRadius: min(10, max(4, min(rect.width, rect.height) * 0.16)))
            .fill(Color.cyan.opacity(0.13))
            .overlay {
                RoundedRectangle(cornerRadius: min(10, max(4, min(rect.width, rect.height) * 0.16)))
                    .stroke(Color.cyan, lineWidth: 2)
            }
            .shadow(color: .cyan.opacity(0.72), radius: 7)
            .frame(width: max(rect.width, 2), height: max(rect.height, 2))
            .position(x: rect.midX, y: rect.midY)
            .scaleEffect(appeared ? 1 : 0.86)
    }

    private func tapMarker(at location: CGPoint) -> some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.2))
                .frame(width: 34, height: 34)
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 16, height: 16)
            Circle()
                .fill(Color.cyan)
                .frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .position(location)
        .scaleEffect(appeared ? 1 : 0.35)
    }

    private func trajectory(from start: CGPoint, to end: CGPoint) -> some View {
        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .trim(from: 0, to: appeared ? 1 : 0)
            .stroke(
                Color.cyan,
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)

            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.cyan, lineWidth: 2))
                .frame(width: 12, height: 12)
                .position(start)

            ZStack {
                Circle().fill(Color.cyan).frame(width: 18, height: 18)
                Image(systemName: "arrow.forward")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.black)
                    .rotationEffect(.radians(atan2(end.y - start.y, end.x - start.x)))
            }
            .position(end)
            .scaleEffect(appeared ? 1 : 0.4)
        }
    }

    private var actionLabel: some View {
        Text(action.label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.76), in: Capsule())
            .overlay(Capsule().stroke(Color.cyan.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .position(labelPosition)
            .opacity(appeared ? 1 : 0)
    }

    private var labelPosition: CGPoint {
        let anchor: CGPoint
        if let frame = action.normalizedTargetFrame {
            anchor = CGPoint(x: frame.centerX, y: frame.y)
        } else if let point = action.normalizedPoint ?? action.normalizedEnd {
            anchor = point
        } else {
            anchor = CGPoint(x: 0.5, y: 0.08)
        }
        let x = min(max(anchor.x * size.width, 58), max(58, size.width - 58))
        let proposedY = anchor.y * size.height - 22
        let y = min(max(proposedY, 18), max(18, size.height - 18))
        return CGPoint(x: x, y: y)
    }

    private func point(_ normalized: CGPoint) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }
}
