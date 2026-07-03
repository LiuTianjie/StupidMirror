import SwiftUI

// Restrained design tokens for a native, "boutique app" feel.
// Deliberately avoids the AI-generated look: no aurora gradients, no
// glowing strokes, no gradient-filled glow buttons, no glass everywhere.
// Solid surfaces, one warm accent, neutral shadows, system light/dark.
enum Theme {
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 10
        static let card: CGFloat = 14
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 36
    }

    enum Palette {
        // A single warm accent — honeyed amber. Distinct without shouting.
        static let accent = Color(red: 0.93, green: 0.58, blue: 0.20)
        static let live = Color(red: 0.22, green: 0.70, blue: 0.42)
        static let pending = Color(red: 0.92, green: 0.62, blue: 0.20)
        static let danger = Color(red: 0.86, green: 0.32, blue: 0.32)
        static let control = Color(red: 0.30, green: 0.56, blue: 0.86)
    }

    // Plain elevated surface for the detail pane content. System adaptive.
    static var surface: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var hairline: Color {
        Color(nsColor: .separatorColor)
    }
}

// Flat semantic pill. No glow, no gradient.
struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(color.opacity(0.12))
        )
    }
}

struct ProgressOrIcon: View {
    let state: MirrorState

    var body: some View {
        switch state {
        case .starting:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.danger)
        case .stopped:
            Image(systemName: "play.circle")
        case .running:
            EmptyView()
        }
    }
}
