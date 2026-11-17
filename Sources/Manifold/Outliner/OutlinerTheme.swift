import AppKit
import ManifoldCore

/// How the outliner looks: Manifold's colours (`Theme`, light and dark
/// alike) and the face and size its text is set in — any face, given as a
/// font (`init(font:mono:)`). Every measure is the size's: an outline's
/// step is round(size × 1.6), its rows 1.4 lines tall, as Weft's are.
public struct OutlinerTheme {
    public var text: NSColor
    public var secondary: NSColor
    /// Bullets, the strike through what's done, a quote's rule.
    public var faint: NSColor
    public var accent: NSColor
    /// A link's words.
    public var link: NSColor
    public var highlight: NSColor
    /// What the text stands on: behind a row lifted to be carried.
    public var background: NSColor
    /// What is written: its face and size.
    public var body: NSFont
    /// Code's face (its size is the body's, a little smaller where used).
    public var monoFace: NSFont

    public var size: CGFloat { body.pointSize }
    /// How far each level of an outline is set in.
    public var step: CGFloat { (size * 1.6).rounded() }

    /// A theme set in a face — its family, at its size — in Manifold's colours.
    public init(font: NSFont, mono: NSFont? = nil) {
        body = font
        monoFace = mono ?? NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
        text = Theme.bodyText
        secondary = Theme.secondaryText
        faint = Theme.tertiaryText
        accent = Theme.accent
        link = Tints.accentText
        highlight = NSColor.systemYellow.withAlphaComponent(0.4)
        background = Theme.windowBackground
    }

    /// The theme a font theme sets notes in: its editing face at 14.5, its
    /// monospaced one for code.
    static func manifold(_ fonts: FontTheme) -> OutlinerTheme {
        OutlinerTheme(font: fonts.font(.proportional, size: 14.5), mono: fonts.font(.monospaced, size: 13))
    }

    /// What is written, at a size: the body's face, made heavier or slanted
    /// as its family has it.
    public func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let base = NSFont(descriptor: body.fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
        return base.emphasized(bold: weight >= .semibold, italic: italic)
    }

    /// A heading's face: the body's, heavier.
    public func display(_ size: CGFloat, weight: NSFont.Weight = .semibold, italic: Bool = false) -> NSFont {
        font(size, weight: weight, italic: italic)
    }

    /// What is said about a note — a property's name — in the system's sans.
    public func label(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    public func mono(_ size: CGFloat) -> NSFont {
        NSFont(descriptor: monoFace.fontDescriptor, size: size) ?? NSFont.systemMono(ofSize: size)
    }
}

extension NSFont {
    /// Whether it is set heavy: bold, or a weight that stands for it.
    var outlinerIsBold: Bool {
        if fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return ((traits?[.weight] as? CGFloat) ?? 0) >= NSFont.Weight.semibold.rawValue
    }

    var outlinerIsItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}
