import AppKit
import ManifoldCore

/// The app's tint (§3.1): the color of its own marks — the focus ring,
/// what's chosen or toggled, progress, the selection bands, the caret
/// and text selection, a pool of light in the backdrop. Each in light
/// and in dark: in the light a tint is deep enough to read as a thin
/// line on white (orange most of all), in the dark bright enough to on
/// near-black. Colors that say something — links, matches, status,
/// diffs, a terminal's palette — keep their own.
extension Tint {
    var title: String {
        switch self {
        case .system: "System"
        case .blue: "Blue"
        case .orange: "Orange"
        case .purple: "Purple"
        case .pink: "Pink"
        case .green: "Green"
        case .graphite: "Graphite"
        }
    }

    /// The tint itself: lines, fills, symbols.
    var accent: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .blue: Theme.hex(0x3373F2)
        // Overcast's orange (#FC7E0F) in the dark; deeper in the light.
        case .orange: .dynamic(Theme.hex(0xE36A00), Theme.hex(0xFC7E0F))
        case .purple: .dynamic(Theme.hex(0x9550D6), Theme.hex(0xBF7AF0))
        case .pink: .dynamic(Theme.hex(0xDC3F78), Theme.hex(0xFF6B9C))
        case .green: .dynamic(Theme.hex(0x2A9A4A), Theme.hex(0x3FCB68))
        case .graphite: .dynamic(Theme.hex(0x6E6E73), Theme.hex(0x98989D))
        }
    }

    /// An editor's and a terminal's caret.
    var caret: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .blue: .dynamic(Theme.hex(0x007AFF), Theme.hex(0x0A84FF))
        case .orange: .dynamic(Theme.hex(0xEB7300), Theme.hex(0xFF8A26))
        case .graphite: .dynamic(Theme.hex(0x48484D), Theme.hex(0xC7C7CC))
        default: accent
        }
    }

    /// Selected text, behind it: a soft, opaque wash of the tint.
    var textSelection: NSColor {
        switch self {
        case .system: .selectedTextBackgroundColor
        case .blue: .dynamic(Theme.hex(0xCFE2FB), Theme.hex(0x264F78))
        case .orange: .dynamic(Theme.hex(0xFDE1C4), Theme.hex(0x6E3D12))
        case .purple: .dynamic(Theme.hex(0xEADCF8), Theme.hex(0x4B2F68))
        case .pink: .dynamic(Theme.hex(0xFADAE6), Theme.hex(0x6B2B43))
        case .green: .dynamic(Theme.hex(0xD5EFDC), Theme.hex(0x25512F))
        case .graphite: .dynamic(Theme.hex(0xE1E1E4), Theme.hex(0x4A4A4E))
        }
    }

    /// A chosen row: the tint, thin, over the row — its own colors show
    /// through. `active`: the list has the keyboard.
    func band(active: Bool) -> NSColor {
        let tint = accent
        return NSColor(name: nil) { appearance in
            var c = tint
            appearance.performAsCurrentDrawingAppearance { c = tint.usingColorSpace(.sRGB) ?? tint }
            let alpha: CGFloat = appearance.isDark ? (active ? 0.30 : 0.20) : (active ? 0.16 : 0.10)
            return c.withAlphaComponent(alpha)
        }
    }
}

/// The tint in use, and word of its changing.
enum Tints {
    private(set) static var current: Tint = .blue

    /// Colors that are always the current tint's: one object each, so
    /// whatever holds one (a stored palette, a button's tint) is recolored
    /// when it's next drawn — what a layer holds, by its theme hook.
    static let accent = live { $0.accent }
    static let caret = live { $0.caret }
    static let textSelection = live { $0.textSelection }
    static let band = live { $0.band(active: true) }
    static let bandInactive = live { $0.band(active: false) }
    static let dropHighlight = live { $0.accent.withAlphaComponent(0.18) }
    /// The tint as text — a note that's running, a match, a toggled
    /// button's title: darkened in the light, lightened in the dark, as
    /// far as it takes to read on a panel (4.5:1, and a little over for a
    /// band behind it).
    static let accentText = NSColor(name: nil) { appearance in
        var out = current.accent
        appearance.performAsCurrentDrawingAppearance {
            let tint = current.accent.usingColorSpace(.sRGB) ?? current.accent
            let ground = Theme.panel.usingColorSpace(.sRGB) ?? .white
            out = reaching(4.8, from: tint, on: ground, toward: appearance.isDark ? .white : .black)
        }
        return out
    }
    /// The tint behind white — a primary button, a checked box: darkened
    /// as far as it takes for white on it to read (4.5:1).
    static let accentFill = NSColor(name: nil) { appearance in
        var out = current.accent
        appearance.performAsCurrentDrawingAppearance {
            let tint = current.accent.usingColorSpace(.sRGB) ?? current.accent
            out = reaching(4.5, from: tint, on: .white, toward: .black)
        }
        return out
    }

    /// `color` blended toward `toward` in small steps until it stands off
    /// `ground` by `ratio`.
    private static func reaching(_ ratio: CGFloat, from color: NSColor, on ground: NSColor, toward: NSColor) -> NSColor {
        var c = color
        var f: CGFloat = 0
        while contrast(c, ground) < ratio, f < 1 {
            f += 0.04
            c = (color.blended(withFraction: f, of: toward) ?? c).usingColorSpace(.sRGB) ?? c
        }
        return c
    }

    /// WCAG's contrast between two colors: 1 to 21.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// WCAG's relative luminance of a color, in sRGB.
    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private static func live(_ pick: @escaping (Tint) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let color = pick(current)
            var out = color
            appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
            return out
        }
    }

    /// The tint set: every mark recolored — what's held in layers by the
    /// hooks that set them, what's drawn by drawing again.
    static func apply(_ tint: Tint) {
        guard tint != current else { return }
        current = tint
        changed()
    }

    /// The system's accent color changed: the System tint follows it.
    static func watchSystemAccent() {
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            guard current == .system else { return }
            changed()
            GhosttyRuntime.shared.reapply()
        }
    }

    private static func changed() {
        NotificationCenter.default.post(name: .manifoldTintChanged, object: nil)
        NotificationCenter.default.post(name: .manifoldAppearanceChanged, object: nil)
        for window in NSApp.windows { window.contentView.map(redraw) }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    /// The terminal's glow (a predicted echo, a copy): the tint, and in the
    /// dark a step toward white, as the blue it was (#73BFFF).
    static func glow(dark: Bool) -> NSColor {
        var out = current.accent
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let c = current.accent.usingColorSpace(.sRGB) ?? current.accent
            out = dark ? (c.blended(withFraction: 0.4, of: .white) ?? c) : c
        }
        return out
    }

    /// A color as #rrggbb in an appearance (for a terminal's config).
    static func hex(_ color: NSColor, dark: Bool) -> String {
        var out = "#000000"
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? color
            func b(_ v: CGFloat) -> Int { Int(max(0, min(255, (v * 255).rounded()))) }
            out = String(format: "#%02x%02x%02x", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
        }
        return out
    }
}

extension Notification.Name {
    /// The app's tint changed.
    static let manifoldTintChanged = Notification.Name("ManifoldTintChanged")
}
