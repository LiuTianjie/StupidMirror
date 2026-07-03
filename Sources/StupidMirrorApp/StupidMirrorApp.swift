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
        MenuBarExtra("StupidMirror", systemImage: "iphone.gen3.radiowaves.left.and.right") {
            MenuBarContentView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(store.t("menu.refreshDevices")) {
                    store.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(store.t("menu.stopAll")) {
                    store.stopAll()
                }
                .keyboardShortcut(".", modifiers: [.command])

                Button(store.t("toolbar.diagnostics")) {
                    store.showsDiagnostics.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(store.t("toolbar.settings")) {
                    store.showsSettings.toggle()
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
                for session in store.sessions {
                    store.start(session)
                }
            }
        }

        Divider()

        Button(store.t("menu.stopAll")) {
            store.stopAll()
        }

        Button(store.t("toolbar.settings")) {
            showDashboard()
            store.showsSettings = true
        }

        Button(store.t("toolbar.diagnostics")) {
            showDashboard()
            store.showsDiagnostics = true
        }

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
