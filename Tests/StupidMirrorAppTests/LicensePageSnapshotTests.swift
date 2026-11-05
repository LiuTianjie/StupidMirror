import AppKit
import SwiftUI
import XCTest
@testable import StupidMirrorApp

/// Renders the Settings Membership page offscreen with in-memory storage,
/// so the layout can be reviewed without the Keychain or a running app.
/// Runs only when STUPIDMIRROR_DESIGN_SNAPSHOT_DIR is set.
@MainActor
final class LicensePageSnapshotTests: XCTestCase {
    func testRenderLicensePage() async throws {
        guard let directory = ProcessInfo.processInfo.environment["STUPIDMIRROR_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STUPIDMIRROR_DESIGN_SNAPSHOT_DIR to render the membership page.")
        }
        UserDefaults.standard.set(false, forKey: MCPServerManager.enabledDefaultsKey)

        let session = LicenseAuthSession(
            userID: UUID(),
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            email: "name@example.com"
        )
        let now = Date()
        func entitlement(_ active: Bool, _ tier: MembershipTier) -> MembershipEntitlement {
            MembershipEntitlement(
                active: active,
                tier: tier,
                validUntil: active ? now.addingTimeInterval(300 * 86_400) : nil,
                memberUntil: tier == .free ? nil : now.addingTimeInterval(20 * 86_400),
                yearlyUntil: tier == .yearly ? now.addingTimeInterval(300 * 86_400) : nil,
                serverTime: now
            )
        }
        let cases: [(String, LicenseAuthSession?, MembershipEntitlement?)] = [
            ("signed-out", nil, nil),
            ("free-account", session, entitlement(false, .free)),
            ("monthly", session, entitlement(false, .monthly)),
            ("yearly", session, entitlement(true, .yearly)),
        ]
        for (name, session, answer) in cases {
            let manager = LicenseManager(
                cacheStore: MemoryEntitlementStore(),
                remote: SnapshotLicenseRemote(answer: answer),
                authStore: MemoryLicenseAuthStore(session: session)
            )
            await manager.bootstrap()
            await manager.waitForBackgroundValidation()
            let store = DeviceGalleryStore(licenseManager: manager)
            for (language, code) in [(AppLanguage.zhHans, "zh"), (.en, "en")] {
                store.language = language
                for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    let view = SettingsView(initialTab: .license)
                        .environmentObject(store)
                        .background(Theme.Surface.panel)
                    try render(view, appearance: appearance, to: "\(directory)/license-\(name)-\(code)-\(suffix).png")
                }
            }
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, to path: String) throws {
        let size = CGSize(width: 800, height: 600)
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

struct SnapshotLicenseRemote: MembershipEntitlementServicing {
    var answer: MembershipEntitlement?

    func entitlement(accessToken: String) async throws -> MembershipEntitlement {
        guard let answer else { throw MembershipCheckError.temporarilyUnavailable }
        return answer
    }
}
