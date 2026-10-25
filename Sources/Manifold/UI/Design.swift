import AppKit

/// What a block's state is shown in (§3.7), one palette for the glyphs, the
/// summary cards and the counts: each its own colour in either appearance,
/// darker in the light so it reads as text too (4.5:1 on a panel).
enum Status {
    static let running = Tints.accent
    static let done = NSColor.dynamic(NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.35, green: 0.80, blue: 0.45, alpha: 1))
    static let attention = NSColor.dynamic(NSColor(srgbRed: 0.66, green: 0.38, blue: 0.0, alpha: 1), NSColor(srgbRed: 0.95, green: 0.70, blue: 0.32, alpha: 1))
    static let failed = NSColor.dynamic(NSColor(srgbRed: 0.76, green: 0.15, blue: 0.12, alpha: 1), NSColor(srgbRed: 1.0, green: 0.42, blue: 0.38, alpha: 1))
    static let offline = Theme.secondaryText
}
