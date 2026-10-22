import SwiftUI

@main
struct StupidMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: DeviceGalleryStore

    init() {
        let store = DeviceGalleryStore()
        _store = StateObject(wrappedValue: store)
        AppDelegate.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("StupidMirror")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
                    .environmentObject(store)

                Button(store.t("menu.refreshDevices")) {
                    store.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(store.t("menu.stopAll")) {
                    store.stopAll()
                }
                .keyboardShortcut(".", modifiers: [.command])

                Button(store.t("license.menu")) {
                    store.presentActivation()
                }

                Button(store.t("toolbar.diagnostics")) {
                    store.toggleDiagnostics()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(store.t("toolbar.settings")) {
                    store.toggleSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var store: DeviceGalleryStore

    var body: some View {
        Button(store.t("menu.showDashboard")) {
            showDashboard()
        }

        Button(store.t("menu.refreshDevices")) {
            store.refresh()
        }

        Button(store.t("toolbar.discoverWireless")) {
            store.discoverWirelessDevices()
        }

        Divider()

        Text("\(store.t("menu.devices")) (\(store.sessions.count))")

        if store.sessions.isEmpty {
            Text(store.t("menu.noDevices"))
        } else {
            ForEach(store.sessions) { session in
                Button {
                    store.start(session)
                } label: {
                    Label(
                        deviceMenuTitle(for: session),
                        systemImage: deviceMenuIcon(for: session)
                    )
                }
                .disabled(session.device.connectionState != .connected)
            }

            Button(store.t("menu.openAll")) {
                store.startAll()
            }
        }

        Divider()

        Button(store.t("menu.stopAll")) {
            store.stopAll()
        }

        Button(store.t("license.menu")) {
            store.presentActivation()
        }

        Picker(store.t("settings.appearance"), selection: $store.appearance) {
            ForEach(AppAppearance.allCases) { appearance in
                Text(store.t(appearance.titleKey)).tag(appearance)
            }
        }

        Button(store.t("toolbar.settings")) {
            showDashboard()
            store.presentSettings()
        }

        Button(store.t("toolbar.diagnostics")) {
            showDashboard()
            store.presentDiagnostics()
        }

        CheckForUpdatesButton()

        Divider()

        Button(store.t("menu.quit")) {
            NSApp.terminate(nil)
        }
    }

    private func deviceMenuTitle(for session: DeviceSession) -> String {
        let suffix: String
        if session.device.connectionState != .connected {
            suffix = store.t("menu.reconnecting")
        } else {
            suffix = session.mirrorSession.state == .running ? store.t("menu.live") : store.t("menu.open")
        }
        return "\(session.device.name)  \(suffix)"
    }

    private func deviceMenuIcon(for session: DeviceSession) -> String {
        if session.device.connectionState != .connected {
            return "arrow.triangle.2.circlepath"
        }
        return session.mirrorSession.state == .running ? "checkmark.circle.fill" : "iphone.gen3"
    }

    private func showDashboard() {
        DashboardWindowRegistry.shared.open(store: store)
    }
}

/// Shown only in a build that can update itself; names the new version once
/// a check has found one.
struct CheckForUpdatesButton: View {
    @EnvironmentObject private var store: DeviceGalleryStore
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isConfigured {
            Button(title) {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }

    private var title: String {
        if let version = updater.availableVersion {
            return String(format: store.t("menu.updateAvailable"), version)
        }
        return store.t("menu.checkForUpdates")
    }
}
