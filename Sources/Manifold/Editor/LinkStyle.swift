import AppKit

/// How a link ⌘ shows looks, in an editor and a terminal alike.
enum LinkStyle {
    /// Its letters' color (and its glow's, `LinkGlow`).
    static let color = NSColor.themed { $0.code.link }
    /// Behind the link under the pointer (⌘ held): a band a step lighter
    /// in the dark, darker in the light — a lightness, not a hue, as a
    /// chosen row's, so every eye sees it.
    static let hover = NSColor.themed { $0.code.linkHover }
}

/// The light ⌘ puts around the links' letters, in an editor and a
/// terminal alike: soft, in the links' color, under the text.
enum LinkGlow {
    /// How far it spreads for rows so high: a layer's shadow radius (Core
    /// Graphics' blur is twice it).
    static func radius(rowHeight: CGFloat) -> CGFloat { max(3, rowHeight * 0.28) }

    /// How strong: on light paper a glow is a smudge unless it's faint.
    static func opacity(dark: Bool) -> CGFloat { dark ? 0.85 : 0.55 }

    /// Laid over what's under it: lightening in the dark, tinting in the light.
    static func blend(dark: Bool) -> CGBlendMode { dark ? .screen : .multiply }
    static func filter(dark: Bool) -> String { dark ? "screenBlendMode" : "multiplyBlendMode" }
}
