import AppKit
import SwiftUI
import XCTest
@testable import StupidMirrorApp

/// Renders every Settings tab offscreen so the whole window can be reviewed
/// without launching the app. Runs only when STUPIDMIRROR_DESIGN_SNAPSHOT_DIR is set.
@MainActor
final class SettingsPagesSnapshotTests: XCTestCase {
    func testRenderSettingsPages() async throws {
        guard let directory = ProcessInfo.processInfo.environment["STUPIDMIRROR_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STUPIDMIRROR_DESIGN_SNAPSHOT_DIR to render the settings pages.")
        }
        UserDefaults.standard.set(false, forKey: MCPServerManager.enabledDefaultsKey)
        let tabs: [(String, DashboardSettingsTab)] = [
            ("general", .general), ("mirroring", .mirroring), ("mcp", .mcp), ("license", .license),
        ]
        for (language, code) in [(AppLanguage.zhHans, "zh"), (.en, "en")] {
            let manager = LicenseManager(
                store: SnapshotLicenseStore(record: nil),
                remote: SnapshotLicenseRemote(),
                validationInterval: .greatestFiniteMagnitude,
                authStore: MemoryLicenseAuthStore(session: nil)
            )
            await manager.bootstrap()
            let store = DeviceGalleryStore(licenseManager: manager)
            store.language = language
            for (name, tab) in tabs {
                for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    for (sizeName, size) in [("window", CGSize(width: 800, height: 600)), ("tall", CGSize(width: 800, height: 1800))] {
                        if sizeName == "tall" && suffix == "light" { continue }
                        let view = SettingsView(initialTab: tab)
                            .environmentObject(store)
                        try render(view, size: size, appearance: appearance,
                                   to: "\(directory)/settings-\(name)-\(code)-\(suffix)-\(sizeName).png")
                    }
                }
            }
        }
    }

    func testDeviceModelIconResolvesKnownModelsOnly() {
        XCTAssertNotNil(DeviceModelIcon.image(for: "iPhone17,1"))
        XCTAssertNil(DeviceModelIcon.image(for: "iPhone 17 Pro"))
        XCTAssertNil(DeviceModelIcon.image(for: "Pixel 9"))
        XCTAssertNil(DeviceModelIcon.image(for: ""))
    }

    func testRenderSidebarDeviceRows() async throws {
        guard let directory = ProcessInfo.processInfo.environment["STUPIDMIRROR_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STUPIDMIRROR_DESIGN_SNAPSHOT_DIR to render the sidebar rows.")
        }
        let manager = LicenseManager(
            store: SnapshotLicenseStore(record: nil),
            remote: SnapshotLicenseRemote(),
            validationInterval: .greatestFiniteMagnitude,
            authStore: MemoryLicenseAuthStore(session: nil)
        )
        await manager.bootstrap()
        let store = DeviceGalleryStore(licenseManager: manager)
        store.language = .zhHans
        let devices: [(String, String, DeviceConnectionState)] = [
            ("iPhone 16 Pro", "iPhone17,1", .connected),
            ("iPhone 17 Pro Max", "iPhone18,2", .connected),
            ("iPad Pro", "iPad16,3", .disconnected),
            ("iPhone 17 Pro 模拟器", "iPhone 17 Pro", .connected),
        ]
        let sessions = devices.enumerated().map { index, entry in
            DeviceSession(device: DeviceIdentity(
                id: "row-\(index)", udid: "row-\(index)", name: entry.0, productType: entry.1,
                osVersion: "26.5", connectionState: entry.2, trustState: .trusted
            ), captureDevice: nil)
        }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let view = VStack(spacing: 2) {
                ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                    DeviceRowView(session: session, isSelected: index == 0, select: {})
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.Surface.ground)
            .environmentObject(store)
            try render(view, size: CGSize(width: 264, height: 240), appearance: appearance,
                       to: "\(directory)/sidebar-rows-\(suffix).png")
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
