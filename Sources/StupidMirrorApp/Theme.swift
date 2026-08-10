import AppKit
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
        // Keep semantic colors bright on dark surfaces and deliberately darker
        // on light surfaces. Every variant clears 4.5:1 against its normal
        // window background, so these colors remain usable for small labels.
        static let accent = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.64, green: 0.33, blue: 0.04, alpha: 1),
            dark: NSColor(srgbRed: 0.93, green: 0.58, blue: 0.20, alpha: 1)
        )
        static let live = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.08, green: 0.47, blue: 0.23, alpha: 1),
            dark: NSColor(srgbRed: 0.22, green: 0.70, blue: 0.42, alpha: 1)
        )
        static let pending = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.59, green: 0.36, blue: 0.02, alpha: 1),
            dark: NSColor(srgbRed: 0.92, green: 0.62, blue: 0.20, alpha: 1)
        )
        static let danger = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.70, green: 0.16, blue: 0.17, alpha: 1),
            dark: NSColor(srgbRed: 0.90, green: 0.39, blue: 0.39, alpha: 1)
        )
        static let control = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.16, green: 0.40, blue: 0.68, alpha: 1),
            dark: NSColor(srgbRed: 0.36, green: 0.62, blue: 0.92, alpha: 1)
        )
    }

    // Content overlays must not inherit vibrancy from the mirrored phone image.
    // These opaque, adaptive colors keep contrast stable over any screenshot.
    enum Overlay {
        static let surface = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
            dark: NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1)
        )
        static let primaryText = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1),
            dark: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        )
        static let secondaryText = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1),
            dark: NSColor(srgbRed: 0.80, green: 0.80, blue: 0.83, alpha: 1)
        )
        static let tertiaryText = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 1),
            dark: NSColor(srgbRed: 0.70, green: 0.70, blue: 0.73, alpha: 1)
        )
        static let stroke = Theme.adaptiveColor(
            light: NSColor.black.withAlphaComponent(0.14),
            dark: NSColor.white.withAlphaComponent(0.18)
        )
    }

    // Plain elevated surface for the detail pane content. System adaptive.
    static var surface: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var hairline: Color {
        Color(nsColor: .separatorColor)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
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
