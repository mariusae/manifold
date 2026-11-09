import AppKit

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
