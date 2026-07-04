import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var store: DeviceGalleryStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let store = Self.store else { return }
            DashboardWindowRegistry.shared.open(store: store)
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        guard let store = Self.store else { return }
        store.stopAll()
        store.appiumService.stop()
    }
}
