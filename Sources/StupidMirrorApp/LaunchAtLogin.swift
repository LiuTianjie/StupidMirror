import AppKit
import OSLog
import ServiceManagement

/// "Open at login" through the system's login items (`SMAppService`). The
/// system owns the setting, so it is read back rather than stored here; it is
/// off until the user turns it on.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "LaunchAtLogin")

    enum State: Equatable {
        case disabled
        case enabled
        /// Registered, but the user has to allow it in System Settings.
        case requiresApproval
        /// Only a packaged app in a stable location can be a login item.
        case unavailable
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var lastError: String?

    var isEnabled: Bool { state == .enabled || state == .requiresApproval }

    init() {
        refresh()
    }

    func refresh() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state = .unavailable
            return
        }
        state = Self.state(for: SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    nonisolated static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    /// Whether this process was started by the login item rather than by the
    /// user, so it can stay in the menu bar instead of opening its window.
    static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else {
            return false
        }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}

/// Shows the Dock icon while one of the app's windows is open, as LinkShell's
/// desktop app does, and goes back to a menu bar-only app when the last one
/// closes. With an icon the app can be found in the Dock and with Command-Tab;
/// reopening it from Spotlight or the Dock brings the dashboard back.
@MainActor
enum DockPresence {
    nonisolated static let dashboardIdentifier = NSUserInterfaceItemIdentifier("StupidMirror.dashboard")
    nonisolated static let mirrorIdentifier = NSUserInterfaceItemIdentifier("StupidMirror.mirror")

    private static var observers: [NSObjectProtocol] = []

    /// Call before showing an app window, so it opens with the Dock icon.
    static func windowWillShow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // A closing window is still visible while this runs.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { update() }
                }
            })
        }
    }

    static func update() {
        let policy = activationPolicy(windows: NSApp.windows.map {
            WindowSnapshot(
                identifier: $0.identifier,
                isVisible: $0.isVisible,
                isMiniaturized: $0.isMiniaturized
            )
        })
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    struct WindowSnapshot: Sendable {
        let identifier: NSUserInterfaceItemIdentifier?
        let isVisible: Bool
        let isMiniaturized: Bool
    }

    /// A minimized window keeps the icon: the Dock is how it comes back.
    nonisolated static func activationPolicy(windows: [WindowSnapshot]) -> NSApplication.ActivationPolicy {
        let hasAppWindow = windows.contains { window in
            guard window.identifier == dashboardIdentifier || window.identifier == mirrorIdentifier else {
                return false
            }
            return window.isVisible || window.isMiniaturized
        }
        return hasAppWindow ? .regular : .accessory
    }
}
