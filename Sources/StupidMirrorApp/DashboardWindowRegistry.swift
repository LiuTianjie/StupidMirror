import AppKit
import SwiftUI

@MainActor
final class DashboardWindowRegistry {
    static let shared = DashboardWindowRegistry()

    private var window: NSWindow?
    private var delegate: DashboardWindowDelegate?

    private init() {}

    func open(store: DeviceGalleryStore) {
        DockPresence.windowWillShow()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let windowSizes = DashboardWindowLayout.sizes(
            for: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        )
        // NSWindow owns the minimum size. Giving the SwiftUI root the same
        // hard minimum is incorrect because the window toolbar consumes part
        // of the content area; on shorter screens that made the root overflow
        // and pushed the fixed footer below the visible bounds.
        let rootView = GalleryView()
            .environmentObject(store)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSizes.initial),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StupidMirror"
        window.identifier = DockPresence.dashboardIdentifier
        // The dashboard draws its own top strip on the window ground: the
        // title bar is transparent, the traffic lights sit on that strip and
        // the SwiftUI root reserves `topBarHeight` for them.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.groundNSColor
        window.isReleasedWhenClosed = false
        window.contentMinSize = windowSizes.minimum
        window.contentViewController = NSHostingController(rootView: rootView)
        // Installing the hosting controller asks SwiftUI for its fitting size,
        // which is the minimum. Restore the intended first-launch size after
        // the controller is attached.
        window.setContentSize(windowSizes.initial)
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

enum DashboardWindowLayout {
    static let preferredContentSize = NSSize(width: 1_100, height: 700)
    static let minimumContentSize = NSSize(width: 1_000, height: 640)
    static let topBarHeight: CGFloat = 46
    static let bottomBarHeight: CGFloat = 36
    static let sidebarWidth: CGFloat = 264
    /// The gap between panels and between a panel and the window edge.
    static let gutter: CGFloat = 10
    private static let screenMargin: CGFloat = 48

    static func sizes(for visibleFrame: NSRect?) -> (initial: NSSize, minimum: NSSize) {
        guard let visibleFrame else {
            return (preferredContentSize, minimumContentSize)
        }

        let fittingSize = NSSize(
            width: max(1, visibleFrame.width - screenMargin * 2),
            height: max(1, visibleFrame.height - screenMargin * 2)
        )
        let minimum = NSSize(
            width: min(minimumContentSize.width, fittingSize.width),
            height: min(minimumContentSize.height, fittingSize.height)
        )
        let initial = NSSize(
            width: max(minimum.width, min(preferredContentSize.width, fittingSize.width)),
            height: max(minimum.height, min(preferredContentSize.height, fittingSize.height))
        )
        return (initial, minimum)
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
