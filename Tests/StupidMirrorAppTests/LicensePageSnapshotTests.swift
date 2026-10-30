import AppKit
import SwiftUI
import XCTest
@testable import StupidMirrorApp

/// Renders the Settings License page offscreen with in-memory license
/// storage, so the layout can be reviewed without the Keychain or a
/// running app. Runs only when STUPIDMIRROR_DESIGN_SNAPSHOT_DIR is set.
@MainActor
final class LicensePageSnapshotTests: XCTestCase {
    func testRenderLicensePage() async throws {
        guard let directory = ProcessInfo.processInfo.environment["STUPIDMIRROR_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STUPIDMIRROR_DESIGN_SNAPSHOT_DIR to render the license page.")
        }
        UserDefaults.standard.set(false, forKey: MCPServerManager.enabledDefaultsKey)

        var activated = LocalLicenseRecord(installationID: UUID())
        activated.activationReceipt = UUID().uuidString.lowercased()
        let session = LicenseAuthSession(
            userID: UUID(),
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            email: "name@example.com"
        )
        let cases: [(String, LocalLicenseRecord?, LicenseAuthSession?)] = [
            ("unlicensed", nil, nil),
            ("licensed", activated, session),
        ]
        for (name, record, session) in cases {
            let manager = LicenseManager(
                store: SnapshotLicenseStore(record: record),
                remote: SnapshotLicenseRemote(),
                validationInterval: .greatestFiniteMagnitude,
                authStore: MemoryLicenseAuthStore(session: session)
            )
            await manager.bootstrap()
            let store = DeviceGalleryStore(licenseManager: manager)
            store.language = .zhHans
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let view = SettingsView(initialTab: .license)
                    .environmentObject(store)
                    .background(Theme.Surface.panel)
                try render(view, appearance: appearance, to: "\(directory)/license-\(name)-\(suffix).png")
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

final class SnapshotLicenseStore: LicenseRecordStoring, @unchecked Sendable {
    private var record: LocalLicenseRecord?
    init(record: LocalLicenseRecord?) { self.record = record }
    func load() throws -> LocalLicenseRecord? { record }
    func save(_ record: LocalLicenseRecord) throws { self.record = record }
}

struct SnapshotLicenseRemote: LicenseRemoteServicing {
    struct Unavailable: Error {}
    func activate(code: String, installationID: UUID) async throws -> LicenseActivation { throw Unavailable() }
    func validate(receipt: String, installationID: UUID) async throws -> LicenseValidation { throw Unavailable() }
    func redeem(code: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation { throw Unavailable() }
    func claim(receipt: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation { throw Unavailable() }
    func validateAccount(installationID: UUID, accessToken: String) async throws -> LicenseValidation { throw Unavailable() }
}
