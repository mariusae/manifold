import AppKit

/// Small things AppKit asks for over and over, said once.

extension NSPasteboard {
    /// The general pasteboard holding `text`, and only it (Copy).
    static func copy(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}

extension NSEvent {
    /// ⌘ ⇧ ⌥ ⌃ as held, and nothing else (caps lock, fn, the keypad's).
    var keyMods: NSEvent.ModifierFlags { modifierFlags.intersection([.command, .shift, .option, .control]) }
    /// Return, or the keypad's Enter.
    var isReturn: Bool { keyCode == 36 || keyCode == 76 }
}

/// How far the pointer goes, pressed, before a click is a drag.
enum DragSlop {
    static let distance: CGFloat = 4
    static func exceeded(from a: NSPoint, to b: NSPoint) -> Bool { hypot(b.x - a.x, b.y - a.y) >= distance }
}

extension NSTextField {
    /// A label: its words, font, color, and how it's cut when narrow.
    static func label(_ text: String = "", font: NSFont = UIType.body, color: NSColor = Theme.text,
                      cut: NSLineBreakMode = .byTruncatingTail, align: NSTextAlignment = .natural) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.lineBreakMode = cut
        l.alignment = align
        return l
    }
}

extension NSView {
    /// Its window's backing scale (the main screen's, out of one).
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}
