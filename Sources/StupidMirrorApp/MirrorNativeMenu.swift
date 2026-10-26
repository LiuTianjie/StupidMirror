import AppKit
import SwiftUI

/// Menus are snapshots made when opened, independent of preview-frame updates.
@MainActor
enum MirrorNativeMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    static func add(
        _ title: String,
        to menu: NSMenu,
        symbol: String? = nil,
        enabled: Bool = true,
        checked: Bool = false,
        action: @escaping () -> Void
    ) {
        let item = MirrorActionMenuItem(title: title, action: action)
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }

    static func addSubmenu(_ title: String, to menu: NSMenu, items: (NSMenu) -> Void) {
        let submenu = make()
        submenu.title = title
        items(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}

@MainActor
private final class MirrorActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

struct MirrorNativeMenuButton: NSViewRepresentable {
    let help: String
    let onOpen: () -> Void
    let onClose: () -> Void
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> MirrorMenuButton {
        let button = MirrorMenuButton()
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: MirrorMenuButton, context: Context) {
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.onOpen = onOpen
        button.onClose = onClose
        button.makeMenu = makeMenu
    }
}

final class MirrorMenuButton: NSButton {
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var makeMenu: () -> NSMenu = { MirrorNativeMenu.make() }
    private var isPresentingMenu = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // NSMenu owns mouse tracking until dismissal; do not also start the
        // NSButton tracking loop, whose mouse-up may be consumed by the menu.
        openMenu()
    }

    @objc private func openMenu() {
        guard !isPresentingMenu else { return }
        isPresentingMenu = true
        // Keep callbacks and menu alive for this tracking session even if a
        // SwiftUI refresh updates the button's configuration while it is open.
        let didClose = onClose
        onOpen()
        defer {
            isPresentingMenu = false
            didClose()
        }
        let menu = makeMenu()
        let origin = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
        menu.popUp(positioning: nil, at: origin, in: self)
    }
}
