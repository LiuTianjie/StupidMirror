import AppKit
import SwiftUI
import XCTest
@testable import StupidMirrorApp

/// Renders the dark design system's pieces into PNGs without starting the
/// device store, so the look can be checked while another StupidMirror owns
/// the phones. Runs only when STUPIDMIRROR_DESIGN_SNAPSHOT_DIR is set.
@MainActor
final class DesignSpecimenSnapshotTests: XCTestCase {
    func testRenderSpecimens() throws {
        guard let directory = ProcessInfo.processInfo.environment["STUPIDMIRROR_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STUPIDMIRROR_DESIGN_SNAPSHOT_DIR to render design specimens.")
        }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            try render(DashboardSpecimen(), size: CGSize(width: 1100, height: 700), appearance: appearance, to: "\(directory)/dashboard-\(suffix).png")
            try render(EmptySpecimen(), size: CGSize(width: 1100, height: 700), appearance: appearance, to: "\(directory)/empty-\(suffix).png")
            try render(SheetSpecimen(), size: CGSize(width: 720, height: 660), appearance: appearance, to: "\(directory)/settings-\(suffix).png")
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to path: String) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}

private struct SpecimenTopBar: View {
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<3) { _ in Circle().fill(Color(white: 0.3)).frame(width: 12, height: 12) }
            }
            .frame(width: 76, alignment: .leading)
            Text("StupidMirror")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Ink.secondary)
            Spacer()
            Button {} label: { Label("Not activated", systemImage: "key") }
                .buttonStyle(TintedPillStyle(color: Theme.Palette.pending))
            Button {} label: {
                HStack(spacing: 7) {
                    Circle().fill(Theme.Palette.live).frame(width: 6, height: 6)
                    Text("MCP").font(.system(size: 12, weight: .medium))
                    Text(":8765").font(Theme.mono(11.5)).foregroundStyle(Theme.Ink.tertiary)
                }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            Button {} label: { Label("Wi-Fi", systemImage: "wifi") }.buttonStyle(IconButtonStyle(isOn: true))
            Button {} label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(IconButtonStyle())
            Button {} label: { Label("Diagnostics", systemImage: "stethoscope") }.buttonStyle(IconButtonStyle())
            Button {} label: { Label("Settings", systemImage: "gearshape") }.buttonStyle(IconButtonStyle())
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: DashboardWindowLayout.topBarHeight)
    }
}

private struct SpecimenSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(icon: "iphone.gen3.radiowaves.left.and.right", title: "Devices", subtitle: "2 connected") {
                QuietChip(title: "3")
            }
            .padding(14)
            VStack(spacing: 2) {
                row("iPhone 16 Pro", "Live · USB", Theme.Palette.live, selected: true, control: true)
                row("Pixel 8", "Stopped · ADB", Theme.Ink.tertiary.opacity(0.6), selected: false, control: false)
                row("iPad mini", "Reconnecting · Wireless", Theme.Palette.pending, selected: false, control: false)
                    .opacity(0.6)
            }
            .padding(.horizontal, 8)
            Spacer()
            Rectangle().fill(Theme.Surface.hairline).frame(height: 1)
            switchRow("Auto-start", "bolt", true)
            switchRow("Mac Audio", "speaker.wave.2", false)
            Button {} label: { Label("Stop All Mirrors", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .panelSurface()
    }

    private func row(_ name: String, _ status: String, _ dot: Color, selected: Bool, control: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Theme.Ink.primary : Theme.Ink.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.Ink.primary : Theme.Ink.secondary)
                Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.Ink.tertiary)
            }
            Spacer()
            if control {
                Image(systemName: "hand.tap").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Palette.control)
            }
            Circle().fill(dot).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.Surface.selected : .clear))
    }

    private func switchRow(_ title: String, _ icon: String, _ on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Ink.tertiary).frame(width: 18)
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.Ink.secondary)
            Spacer()
            SettingSwitch(isOn: .constant(on), label: title)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }
}

private struct SpecimenPhone: View {
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let width = height * 0.46
            let radius = width * 0.12 / 0.46 * 0.46
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.93))
                VStack(alignment: .leading, spacing: 10) {
                    Text("9:41").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                    Text("Today").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                    ForEach(0..<5) { index in
                        RoundedRectangle(cornerRadius: 10).fill(Color(white: index == 0 ? 0.2 : 0.84)).frame(height: index == 0 ? 90 : 44)
                    }
                    Spacer()
                }
                .padding(18)
                .frame(width: width, height: height)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.Surface.controlStroke, lineWidth: 1) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DashboardSpecimen: View {
    var body: some View {
        VStack(spacing: 0) {
            SpecimenTopBar()
            HStack(alignment: .top, spacing: 10) {
                SpecimenSidebar().frame(width: DashboardWindowLayout.sidebarWidth)
                VStack(alignment: .leading, spacing: 0) {
                    PanelHeader(icon: "iphone.gen3", title: "iPhone 16 Pro", subtitle: "iPhone17,1 · iOS 27.0 · 00008130") {
                        QuietChip(title: "USB")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    VStack(alignment: .leading, spacing: 10) {
                        CheckLine(glyph: .done, lead: "Mirror", object: "Live", detail: "USB · portrait", detailColor: Theme.Palette.live)
                        CheckLine(glyph: .control, lead: "Control", object: "Ready", detail: "tap · swipe · type", detailColor: Theme.Palette.control)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                    SpecimenPhone()
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .wellSurface()
                        .padding(.horizontal, 10)
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Button {} label: { Label("Back", systemImage: "chevron.backward") }
                            Button {} label: { Label("Home", systemImage: "house") }
                            Button {} label: { Label("Switcher", systemImage: "rectangle.grid.2x2") }
                        }
                        .buttonStyle(IconButtonStyle())
                        .padding(3)
                        .outlinedCapsule(fill: Theme.Surface.well, stroke: Theme.Surface.hairline)
                        Spacer()
                        Button {} label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(IconButtonStyle())
                        Button {} label: { Label("More", systemImage: "ellipsis") }.buttonStyle(IconButtonStyle())
                        Button {} label: { Label("Disconnect", systemImage: "bolt.slash") }.buttonStyle(PillButtonStyle(kind: .secondary))
                        Button {} label: { Label("Open Mirror Window", systemImage: "play.fill") }.buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .panelSurface()
            }
            .padding(.horizontal, 10)
            HStack(spacing: 10) {
                Circle().fill(Theme.Palette.live).frame(width: 6, height: 6)
                Text("Mirroring iPhone 16 Pro over USB").font(.system(size: 12)).foregroundStyle(Theme.Ink.tertiary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: DashboardWindowLayout.bottomBarHeight)
        }
        .background(Theme.Surface.ground)
        .foregroundStyle(Theme.Ink.primary)
    }
}

private struct EmptySpecimen: View {
    var body: some View {
        VStack(spacing: 0) {
            SpecimenTopBar()
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    PanelHeader(icon: "iphone.gen3.radiowaves.left.and.right", title: "Devices", subtitle: "0 connected") {
                        QuietChip(title: "0")
                    }
                    .padding(14)
                    Text("No devices")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Surface.controlStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        .padding(.horizontal, 8)
                    Spacer()
                }
                .frame(width: DashboardWindowLayout.sidebarWidth)
                .panelSurface()

                VStack(alignment: .leading, spacing: 0) {
                    PanelHeader(icon: "tray", title: "No Supported Devices", subtitle: "Nothing connected yet") {
                        QuietChip(title: "USB · Wi-Fi · ADB")
                    }
                    .padding(16)
                    ConnectPhoneIllustration()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .wellSurface()
                        .padding(.horizontal, 12)
                    VStack(spacing: 6) {
                        Text("Plug in a phone to start").font(.system(size: 14, weight: .semibold))
                        Text("Connect an iPhone, or connect an Android 11+ device with USB debugging enabled, then refresh.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Ink.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    HStack(spacing: 8) {
                        Button {} label: { Label("iPhone Setup", systemImage: "iphone.gen3") }.buttonStyle(PillButtonStyle(kind: .secondary))
                        Button {} label: { Label("Wi-Fi Devices", systemImage: "wifi") }.buttonStyle(PillButtonStyle(kind: .secondary))
                        Button {} label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(PillButtonStyle(kind: .primary))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
                }
                .panelSurface()
            }
            .padding(.horizontal, 10)
            Spacer().frame(height: DashboardWindowLayout.bottomBarHeight)
        }
        .background(Theme.Surface.ground)
        .foregroundStyle(Theme.Ink.primary)
    }
}

private struct SheetSpecimen: View {
    @State private var tab = 0
    @State private var language = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: "gearshape", title: "Settings", subtitle: "Mirror startup and advanced control-agent settings.", closeHelp: "Close") {}
            SegmentedPills(selection: $tab, items: [.init(value: 0, title: "General"), .init(value: 1, title: "MCP Automation")])
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 20) {
                SettingsGroup(title: "License") {
                    HStack(spacing: 12) {
                        StatusGlyph(kind: .done)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Activated").font(.system(size: 13, weight: .medium))
                            Text("Control and up to 3 devices at once.").font(.system(size: 12)).foregroundStyle(Theme.Ink.tertiary)
                        }
                        Spacer()
                        Button {} label: { Label("Manage", systemImage: "key") }.buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                SettingsGroup(title: "Language") {
                    SettingRow("Language") {
                        SegmentedPills(selection: $language, items: [.init(value: 0, title: "System"), .init(value: 1, title: "中文"), .init(value: 2, title: "English")])
                    }
                }
                SettingsGroup(title: "Mirroring") {
                    SettingRow("Open mirror windows automatically") { SettingSwitch(isOn: .constant(true), label: "") }
                    RowDivider()
                    SettingRow("Wireless mirroring", help: "Find iPhones on the same Wi-Fi after they were prepared over USB once.") { SettingSwitch(isOn: .constant(false), label: "") }
                    RowDivider()
                    SettingRow("iPhone Setup", help: "Prepare an iPhone for control and wireless mirroring.") {
                        Button("Open Guide") {}.buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                }
                SettingsGroup(title: "Control") {
                    HStack(spacing: 10) {
                        StatusPill(title: "Running", color: Theme.Palette.live)
                        Text("Appium 2.11 on 127.0.0.1:4723").font(.system(size: 12)).foregroundStyle(Theme.Ink.secondary)
                        Spacer()
                        Button {} label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    RowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledField("Appium server", text: .constant("http://127.0.0.1:4723"))
                    }
                    .padding(14)
                }
            }
            .padding(.horizontal, 20)
            Spacer()
        }
        .background(Theme.Surface.panel)
        .foregroundStyle(Theme.Ink.primary)
    }
}
