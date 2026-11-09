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

extension NSView {
    /// The view as it draws, a bitmap at `scale` pixels a point (its
    /// window's, by default); nil when it has no size.
    func bitmap(scale: CGFloat? = nil) -> NSBitmapImageRep? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = scale ?? backingScale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// The view as it draws, as an image (a drag's, a card's).
    func picture(scale: CGFloat? = nil) -> NSImage? {
        guard let rep = bitmap(scale: scale) else { return nil }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A modifier held (⌘ for ⌘`, ⌃ for ⌃⇥): `released` when it's let go —
/// or the app's left, so its letting go won't be heard — and `escaped`
/// for ⎋ (taken, not passed on). Watched until `stop`.
final class ModifierHold {
    private var monitors: [Any] = []
    private var leaving: NSObjectProtocol?

    init(_ key: NSEvent.ModifierFlags, released: @escaping () -> Void, escaped: @escaping () -> Void) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            if !e.modifierFlags.contains(key) { released() }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53 else { return e }
            escaped()
            return nil
        } as Any)
        leaving = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.unchecked { released() }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let leaving { NotificationCenter.default.removeObserver(leaving) }
        leaving = nil
    }

    deinit { stop() }
}

extension URL {
    /// Its port, else its scheme's (443 for https, 80 otherwise).
    var effectivePort: Int { port ?? (scheme == "https" ? 443 : 80) }
    /// What follows the host: its path ("/" for none), query and fragment.
    var pathQueryFragment: String {
        (path.isEmpty ? "/" : path) + (query.map { "?" + $0 } ?? "") + (fragment.map { "#" + $0 } ?? "")
    }
}

extension NSImage {
    /// Drawn at its own size, its centre on `p` (on whole points, so a
    /// symbol stays crisp), flipped views as well.
    func draw(centeredAt p: NSPoint, fraction: CGFloat = 1) {
        let z = size
        draw(in: NSRect(x: (p.x - z.width / 2).rounded(), y: (p.y - z.height / 2).rounded(), width: z.width, height: z.height),
             from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
    }
}
