import AppKit
import SwiftUI

// One neutral system for every StupidMirror surface, in light and dark.
//
// Elevation comes from lightness steps, never glow: the window ground, a
// panel one step away from it with a hairline, and a well inside the panel
// for the phone screen and other content. Colour is reserved for state
// (live, pending, failed, control) and always sits on a dark tint of
// itself. The only filled-white control on a screen is its primary action.
enum Theme {
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 10
        static let well: CGFloat = 16
        static let card: CGFloat = 16
        static let panel: CGFloat = 22
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 36
    }

    /// The window ground as an AppKit colour, for `NSWindow.backgroundColor`,
    /// so a live resize never flashes a different tone.
    static let groundNSColor = adaptiveNSGray(light: 0.925, dark: 0.105)

    // Neutral greys only: no navy, no slate, no cream. Dark mode steps
    // down from the ground (panels are darker than the window); light mode
    // steps up (white panels on a grey window, a grey well inside).
    enum Surface {
        /// The window itself; panels sit on it one step away.
        static let ground = Color(nsColor: Theme.groundNSColor)
        /// A panel: the sidebar, the device panel, a sheet.
        static let panel = Theme.adaptiveGray(light: 1.0, dark: 0.067)
        /// Content inside a panel: the phone preview, a settings group.
        static let well = Theme.adaptiveGray(light: 0.962, dark: 0.043)
        /// Resting fill of a secondary control and of icon discs.
        static let raised = Theme.adaptiveGray(light: 0.938, dark: 0.135)
        /// The selected segment or the selected sidebar row.
        static let selected = Theme.adaptiveGray(light: 0.895, dark: 0.17)
        /// Panel and well edges.
        static let hairline = Theme.adaptiveGray(light: 0.885, dark: 0.155)
        /// Outlines on things that can be clicked: one step stronger.
        static let controlStroke = Theme.adaptiveGray(light: 0.80, dark: 0.24)
    }

    enum Ink {
        static let primary = Theme.adaptiveGray(light: 0.07, dark: 0.95)
        /// Secondary text, about 8:1 on its panel in both appearances.
        static let secondary = Theme.adaptiveGray(light: 0.30, dark: 0.71)
        /// Meta text and units, at least 4.5:1 on every surface.
        static let tertiary = Theme.adaptiveGray(light: 0.38, dark: 0.59)
        /// Ink on the primary button, which inverts with the appearance.
        static let inverse = Theme.adaptiveGray(light: 1.0, dark: 0.06)
        /// The primary button's fill: white on dark, near-black on light.
        static let primaryFill = Theme.adaptiveGray(light: 0.10, dark: 0.95)
        static let primaryFillPressed = Theme.adaptiveGray(light: 0.26, dark: 0.80)
    }

    /// Hairline drawing greys for the empty-state picture.
    enum Illustration {
        static let line = Theme.adaptiveGray(light: 0.62, dark: 0.34)
        static let faint = Theme.adaptiveGray(light: 0.82, dark: 0.20)
        static let text = Theme.adaptiveGray(light: 0.86, dark: 0.24)
    }

    enum Palette {
        // Keep semantic colors bright on dark surfaces and deliberately darker
        // on light surfaces. Every variant clears 4.5:1 against its normal
        // window background, so these colors remain usable for small labels.
        static let accent = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.64, green: 0.33, blue: 0.04, alpha: 1),
            dark: NSColor(srgbRed: 0.95, green: 0.64, blue: 0.24, alpha: 1)
        )
        static let live = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.08, green: 0.47, blue: 0.23, alpha: 1),
            dark: NSColor(srgbRed: 0.25, green: 0.75, blue: 0.48, alpha: 1)
        )
        static let pending = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.59, green: 0.36, blue: 0.02, alpha: 1),
            dark: NSColor(srgbRed: 0.95, green: 0.64, blue: 0.24, alpha: 1)
        )
        static let danger = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.70, green: 0.16, blue: 0.17, alpha: 1),
            dark: NSColor(srgbRed: 0.90, green: 0.34, blue: 0.44, alpha: 1)
        )
        static let control = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.70, alpha: 1),
            dark: NSColor(srgbRed: 0.53, green: 0.53, blue: 0.98, alpha: 1)
        )
    }

    // Content overlays must not inherit vibrancy from the mirrored phone image.
    // These opaque, adaptive colors keep contrast stable over any screenshot.
    enum Overlay {
        static let surface = Theme.adaptiveColor(
            light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            dark: NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)
        )
        static let primaryText = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1),
            dark: NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        )
        static let secondaryText = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1),
            dark: NSColor(srgbRed: 0.71, green: 0.71, blue: 0.71, alpha: 1)
        )
        static let tertiaryText = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 1),
            dark: NSColor(srgbRed: 0.58, green: 0.58, blue: 0.58, alpha: 1)
        )
        static let stroke = Theme.adaptiveColor(
            light: NSColor(srgbRed: 0.885, green: 0.885, blue: 0.885, alpha: 1),
            dark: NSColor(srgbRed: 0.155, green: 0.155, blue: 0.155, alpha: 1)
        )
    }

    /// Figures, IDs, ports and timers: one monospaced face with one job.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// A state hue on a pale tint of itself.
    static func tint(_ color: Color) -> Color {
        color.opacity(0.15)
    }

    // Kept for call sites that predate the dark system.
    static var surface: Color { Surface.panel }
    static var hairline: Color { Surface.hairline }

    private static func adaptiveNSGray(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        }
    }

    private static func adaptiveGray(light: CGFloat, dark: CGFloat) -> Color {
        adaptiveColor(
            light: NSColor(srgbRed: light, green: light, blue: light, alpha: 1),
            dark: NSColor(srgbRed: dark, green: dark, blue: dark, alpha: 1)
        )
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Surfaces

extension View {
    /// A top-level panel: one step darker than the window, hairline edge.
    func panelSurface(radius: CGFloat = Theme.Radius.panel) -> some View {
        background(Theme.Surface.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Surface.hairline, lineWidth: 1)
            }
    }

    /// Content set into a panel.
    func wellSurface(radius: CGFloat = Theme.Radius.well) -> some View {
        background(Theme.Surface.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Surface.hairline, lineWidth: 1)
            }
    }

    /// A text field set into a well, matching the rest of the dark system.
    func fieldSurface(monospaced: Bool = false) -> some View {
        textFieldStyle(.plain)
            .font(monospaced ? Theme.mono(12.5) : .system(size: 13))
            .foregroundStyle(Theme.Ink.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.Surface.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.Surface.controlStroke, lineWidth: 1)
            }
    }
}

extension View {
    /// A filled capsule with an optional 1pt edge. The edge is a second,
    /// larger fill rather than a stroke: stroking a shape whose radius is
    /// half its height draws stray vertical ticks at both ends on macOS 26.
    func outlinedCapsule(fill: Color, stroke: Color?) -> some View {
        background {
            ZStack {
                if let stroke {
                    Capsule().fill(stroke)
                    Capsule().fill(fill).padding(1)
                } else {
                    Capsule().fill(fill)
                }
            }
        }
    }
}

/// A neutral disc carrying a 15pt outline icon; the header mark of a panel.
struct IconDisc: View {
    let systemName: String
    var size: CGFloat = 36
    var tint: Color = Theme.Ink.secondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Theme.Surface.raised, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Icon disc, a title and a one-line subtitle joined by middots, then the
/// panel's own controls on the trailing edge.
struct PanelHeader<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconDisc(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// The header row of a sheet: a panel header with a round close button.
struct SheetHeader: View {
    let icon: String
    let title: String
    let subtitle: String?
    let closeHelp: String
    var closeDisabled = false
    let close: () -> Void

    var body: some View {
        PanelHeader(icon: icon, title: title, subtitle: subtitle) {
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(closeDisabled)
            .help(closeHelp)
            .accessibilityLabel(closeHelp)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

/// A group label above a well: 12pt, sentence case, grey.
struct GroupLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Ink.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// One row of a settings well: title and optional help on the left, the
/// control on the right. Rows are separated by `RowDivider`.
struct SettingRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.help = help
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Ink.primary)
                if let help, !help.isEmpty {
                    Text(help)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Surface.hairline)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

// MARK: - Controls

/// Pill buttons. `.primary` is the inverted pill (white on dark, near-black
/// on light) and appears once per screen; `.secondary` is a grey fill with an
/// outline; `.quiet` is text until hovered.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case quiet
        case destructive
    }

    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 11 : 15)
            .frame(height: compact ? 26 : 32)
            .outlinedCapsule(
                fill: background,
                stroke: kind == .secondary || kind == .destructive ? Theme.Surface.controlStroke : nil
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.Ink.inverse
        case .secondary: Theme.Ink.primary
        case .quiet: isHovered ? Theme.Ink.primary : Theme.Ink.secondary
        case .destructive: Theme.Palette.danger
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary:
            return pressed || isHovered ? Theme.Ink.primaryFillPressed : Theme.Ink.primaryFill
        case .secondary, .destructive:
            return pressed || isHovered ? Theme.Surface.selected : Theme.Surface.raised
        case .quiet:
            return pressed || isHovered ? Theme.Surface.raised : .clear
        }
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// A round icon-only control, 30pt, used for close, Back, Home and the like.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, isOn: isOn)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(isOn || isHovered ? Theme.Ink.primary : Theme.Ink.secondary)
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    configuration.isPressed || isOn || isHovered ? Theme.Surface.selected : Theme.Surface.raised
                )
            )
            .overlay {
                Circle().strokeBorder(Theme.Surface.hairline, lineWidth: 1)
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }
}

/// Pills in a recessed track; the selected one is a grey step, never a hue.
struct SegmentedPills<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        var count: Int?
        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .foregroundStyle(isSelected ? Theme.Ink.primary : Theme.Ink.secondary)
                        if let count = item.count {
                            Text("\(count)")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.Ink.tertiary)
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background {
                        if isSelected {
                            Capsule().fill(Theme.Surface.selected)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .outlinedCapsule(fill: Theme.Surface.well, stroke: Theme.Surface.hairline)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - State marks

/// A 22pt circular mark for one state: a check on a dark green disc, a
/// spinner, a cross on a dark red disc, an amber bang, or a dashed ring
/// for "not yet".
struct StatusGlyph: View {
    enum Kind: Equatable {
        case done
        case working
        case failed
        case warning
        case idle
        case control
    }

    let kind: Kind
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            switch kind {
            case .done:
                Circle().fill(Theme.tint(Theme.Palette.live))
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Theme.Palette.live)
            case .control:
                Circle().fill(Theme.tint(Theme.Palette.control))
                Image(systemName: "hand.tap")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(Theme.Palette.control)
            case .failed:
                Circle().fill(Theme.tint(Theme.Palette.danger))
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(Theme.Palette.danger)
            case .warning:
                Circle().fill(Theme.tint(Theme.Palette.pending))
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(Theme.Palette.pending)
            case .working:
                Circle().fill(Theme.tint(Theme.Palette.pending))
                SpokeSpinner(color: Theme.Palette.pending)
                    .frame(width: size * 0.5, height: size * 0.5)
            case .idle:
                Circle()
                    .strokeBorder(
                        Theme.Ink.tertiary,
                        style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2.6])
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Eight short spokes turning in steps, like the reference's busy mark.
struct SpokeSpinner: View {
    var color: Color = Theme.Ink.secondary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 10) % 8
            Canvas { graphics, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2
                for index in 0..<8 {
                    let angle = Double(index) / 8 * 2 * .pi
                    let age = (index - step + 8) % 8
                    var path = Path()
                    path.move(to: CGPoint(
                        x: center.x + cos(angle) * outer * 0.42,
                        y: center.y + sin(angle) * outer * 0.42
                    ))
                    path.addLine(to: CGPoint(
                        x: center.x + cos(angle) * outer,
                        y: center.y + sin(angle) * outer
                    ))
                    graphics.stroke(
                        path,
                        with: .color(color.opacity(1 - Double(age) * 0.11)),
                        style: StrokeStyle(lineWidth: max(1.2, outer * 0.24), lineCap: .round)
                    )
                }
            }
        }
    }
}

/// A status line: glyph, a grey verb, the object in white, then figures in
/// the state's colour. Mirrors "Read Northwind.pdf 42 pages".
struct CheckLine: View {
    let glyph: StatusGlyph.Kind
    let lead: String
    let object: String
    var detail: String?
    var detailColor: Color = Theme.Ink.tertiary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            StatusGlyph(kind: glyph)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                .padding(.trailing, 12)
            (Text(lead + " ").foregroundStyle(Theme.Ink.secondary)
                + Text(object).foregroundStyle(Theme.Ink.primary))
                .font(.system(size: 13.5))
                .lineLimit(1)
                .layoutPriority(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A state hue on its own dark tint, used beside a value or inside a row.
struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.tint(color)))
    }
}

/// A grey count or label chip, like "Playbook v3" in the reference header.
struct QuietChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.Ink.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.Surface.raised, in: Capsule())
    }
}

struct ProgressOrIcon: View {
    let state: MirrorState

    var body: some View {
        switch state {
        case .starting:
            StatusGlyph(kind: .working, size: 34)
        case .failed:
            StatusGlyph(kind: .failed, size: 34)
        case .stopped:
            StatusGlyph(kind: .idle, size: 34)
        case .running:
            EmptyView()
        }
    }
}

/// The switch used across settings; green when on, like a live state.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.Palette.live)
    }
}

/// The app's own appearance choice, applied to every window at once.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "StupidMirror.appearance"

    var id: String { rawValue }
    var titleKey: String { "settings.appearance.\(rawValue)" }

    static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    @MainActor
    func apply() {
        NSApp?.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
