import AppKit
import SwiftUI

@MainActor
final class DashboardWindowRegistry {
    static let shared = DashboardWindowRegistry()

    private var window: NSWindow?
    private var delegate: DashboardWindowDelegate?

    private init() {}

    func open(store: DeviceGalleryStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = GalleryView()
            .environmentObject(store)
            .frame(minWidth: 760, minHeight: 520)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StupidMirror"
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()

        let delegate = DashboardWindowDelegate { [weak self] in
            self?.window = nil
            self?.delegate = nil
        }
        window.delegate = delegate
        self.window = window
        self.delegate = delegate

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class DashboardWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
