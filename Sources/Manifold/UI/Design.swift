import AppKit

/// What a block's state is shown in (§3.7), one palette for the glyphs, the
/// summary cards and the counts: each its own colour in either appearance,
/// darker in the light so it reads as text too (4.5:1 on a panel).
enum Status {
    static let running = Tints.accent
    /// Running, as words: the tint, deep enough to read.
    static let runningText = Tints.accentText
    static let done = NSColor.dynamic(NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.35, green: 0.80, blue: 0.45, alpha: 1))
    static let attention = NSColor.dynamic(NSColor(srgbRed: 0.66, green: 0.38, blue: 0.0, alpha: 1), NSColor(srgbRed: 0.95, green: 0.70, blue: 0.32, alpha: 1))
    static let failed = NSColor.dynamic(NSColor(srgbRed: 0.76, green: 0.15, blue: 0.12, alpha: 1), NSColor(srgbRed: 1.0, green: 0.42, blue: 0.38, alpha: 1))
    static let offline = Theme.secondaryText
}

/// Corner radii, by what's rounded (DESIGN.md §11): a hairline's ends, a chip in
/// text, a control (a button, a field, a row's band, a thumbnail), a
/// surface (a tile, a card, a sheet, a tab, a panel), and a capsule (a pill:
/// half its height).
enum Radius {
    static let hair: CGFloat = 1.5
    static let inline: CGFloat = 4
    static let control: CGFloat = 6
    static let surface: CGFloat = 10
    static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
}

/// The type set in the app's own chrome, by role (the reading and editing
/// faces are the theme's): a big field, a heading, a block's title, a
/// row, body, a detail beside or under it, a caption, a count.
enum UIType {
    static let display = NSFont.systemFont(ofSize: 22)
    static let heading = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let row = NSFont.systemFont(ofSize: 13)
    static let body = NSFont.systemFont(ofSize: 12)
    static let detail = NSFont.systemFont(ofSize: 11.5)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// A lens's own header line (a diff's, a git block's, a picture's).
    static let label = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// A note under a table or a pane, a footer's words.
    static let footnote = NSFont.systemFont(ofSize: 11)
    static let count = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    /// A block's symbol beside its title, as a row or a card sets it.
    static let symbolSize: CGFloat = 13
}

/// How far a thing stands off what's under it: resting on a surface (a
/// sheet, a tab, a card), a tile in the light, a panel floating over the
/// window. One shadow each.
enum Elevation {
    case resting, tile, float

    /// As an AppKit shadow, for what draws itself.
    var shadow: NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(opacity)
        s.shadowBlurRadius = radius
        s.shadowOffset = NSSize(width: 0, height: offset)
        return s
    }

    /// On a layer.
    func apply(to l: CALayer) {
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = Float(opacity)
        l.shadowRadius = radius
        l.shadowOffset = CGSize(width: 0, height: offset)
    }

    private var opacity: CGFloat { switch self { case .resting: 0.18; case .tile: 0.10; case .float: Self.floatOpacity } }

    /// A floating panel's shadow at full strength (the sidebar fades it).
    static let floatOpacity: CGFloat = 0.16
    private var radius: CGFloat { switch self { case .resting: 3; case .tile: 10; case .float: 12 } }
    /// Light from above: the shadow falls below (negative is down).
    private var offset: CGFloat { switch self { case .resting: -1; case .tile: -4; case .float: -3 } }
}

/// How long things take to move: a fade or a reveal on hover, a thing
/// appearing (easing out) or going (easing in), and a thing travelling
/// across the window (one curve, and one that overshoots a little).
enum Motion {
    static let fast: TimeInterval = 0.12
    static let base: TimeInterval = 0.16
    static let spatial: TimeInterval = 0.24
    static var appear: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    static var disappear: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
    static var travel: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1) }
    static var settle: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.15) }
}

/// The edges things are drawn with: a panel's hairline, a card's (subtler),
/// and a strong one where things stack (a sheet, a tab).
enum EdgeColor {
    static let hairline = Theme.panelBorder
    static let subtle = Theme.cardBorder
    static let strong = Theme.sheetEdge(hovered: false)
    /// A control's edge that must show on any ground — a checkbox, a
    /// slider's knob, a badge — and a sheet's or a tab's behind a tile;
    /// a step darker under the pointer.
    static var control: NSColor { Theme.text.withAlphaComponent(0.3) }
    static var controlHovered: NSColor { Theme.text.withAlphaComponent(0.5) }
    /// The tint as an edge: strong round what has the keyboard, is chosen
    /// or is the pointer's target; soft round what's on or focused within.
    static var accentStrong: NSColor { Theme.accent.withAlphaComponent(0.75) }
    static var accentSoft: NSColor { Theme.accent.withAlphaComponent(0.45) }
}

/// A pill: a count, an age — a few figures on a grey capsule, one look
/// wherever it's drawn (a sidebar row's count, a card's age).
enum Pill {
    static let height: CGFloat = 16
    static let font = UIType.count
    static let ground = NSColor.dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.1))

    static func size(_ text: String) -> NSSize {
        NSSize(width: max(20, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12), height: height)
    }

    static func draw(_ text: String, in r: NSRect) {
        ground.setFill()
        NSBezierPath(roundedRect: r, xRadius: Radius.capsule(r.height), yRadius: Radius.capsule(r.height)).fill()
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Theme.secondaryText])
        let w = s.size().width
        // By the figures' own height (cap height), not the line's, so they
        // sit in the middle: the baseline that far under the centre.
        let baseline = r.minY + (r.height - font.capHeight) / 2
        s.draw(at: NSPoint(x: (r.midX - w / 2).rounded(), y: baseline + font.descender))
    }
}
