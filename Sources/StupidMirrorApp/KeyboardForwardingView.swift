import AppKit
import SwiftUI

struct KeyboardForwardingView: NSViewRepresentable {
    var isEnabled: Bool
    var onText: (String) -> Void

    func makeNSView(context: Context) -> KeyboardForwardingNSView {
        let view = KeyboardForwardingNSView()
        view.isForwardingEnabled = isEnabled
        view.onText = onText
        return view
    }

    func updateNSView(_ nsView: KeyboardForwardingNSView, context: Context) {
        nsView.isForwardingEnabled = isEnabled
        nsView.onText = onText
        nsView.becomeFirstResponderWhenPossible()
    }
}

final class KeyboardForwardingNSView: NSView {
    var isForwardingEnabled = false
    var onText: (String) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        becomeFirstResponderWhenPossible()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func becomeFirstResponderWhenPossible() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder !== self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isForwardingEnabled,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }
        forwardPasteboardText()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isForwardingEnabled else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            forwardPasteboardText()
            return
        }

        if let specialText = specialText(for: event) {
            onText(specialText)
            return
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
              let text = event.characters,
              !text.isEmpty else {
            return
        }
        onText(text)
    }

    private func specialText(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76:
            "\u{E007}"
        case 48:
            "\u{E004}"
        case 51:
            "\u{E003}"
        default:
            nil
        }
    }

    private func forwardPasteboardText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onText(text)
    }
}
