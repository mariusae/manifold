import AppKit

/// What a block's state is shown in (§3.7), one palette for the glyphs, the
/// summary cards and the counts: each its own colour in either appearance,
/// darker in the light so it reads as text too (4.5:1 on a panel).
enum Status {
    static let running = Tints.accent
    /// Running, as words: the tint, deep enough to read.
    static let runningText = Tints.accentText
    static let done = NSColor.themed { $0.status.done }
    static let attention = NSColor.themed { $0.status.attention }
    static let failed = NSColor.themed { $0.status.failed }
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
    static let heading = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let row = NSFont.systemFont(ofSize: 13)
    /// What's typed in a search over the window — ⇧⌘A, ⌘O, ⌘P, the
    /// footer's menus — and in one in the sidebar or a tile (a folder's, a
    /// tile's outline, Search's, Processes').
    static let hudField = NSFont.systemFont(ofSize: 15)
    static let field = NSFont.systemFont(ofSize: 13)
    static let body = NSFont.systemFont(ofSize: 12)
    static let detail = NSFont.systemFont(ofSize: 11.5)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// A section's small header, everywhere one names a group of rows
    /// (Dia's: small, semibold, in grey).
    static let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// A lens's own header line (a diff's, a git block's, a picture's).
    static let label = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// A note under a table or a pane, a footer's words.
    static let footnote = NSFont.systemFont(ofSize: 11)
    static let count = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    /// A number on a badge at a corner (a tab's count, a key's number).
    static let badge = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
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
///
/// With Reduce motion on (Accessibility ▸ Display) nothing travels, grows or
/// shrinks: a thing that would slide or grow only fades, or is there at
/// once; fades stay, as the system's do, and so does what says something
/// by moving (the status spinner).
enum Motion {
    static var fast: TimeInterval { 0.12 * slowdown }
    static var base: TimeInterval { 0.16 * slowdown }
    static var spatial: TimeInterval { 0.24 * slowdown }
    /// One thing becoming another where it goes (a tile its card, a card
    /// its tile): a little longer than a move, for the change to be seen.
    static var morph: TimeInterval { spatial * 1.5 }
    /// How long the pointer rests on something before what it shows comes
    /// (a space's peek, a recent group opening).
    static let hoverIntent: TimeInterval = 0.3
    /// How long something the pointer has left lingers, in case it comes
    /// back (the host picker).
    static let lingerAfterExit: TimeInterval = 0.35
    /// Reduce motion asked for (or, debugging, as if it were).
    static var reduced: Bool { forceReduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var forceReduced = false
    /// Debugging: every transition this many times slower, to be watched,
    /// or pictured, on its way.
    static var slowdown: Double = 1
    /// How far a thing travels: `d`, or nowhere with less motion asked for.
    static func distance(_ d: CGFloat) -> CGFloat { reduced ? 0 : d }
    static var appear: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    static var disappear: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
    static var travel: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1) }
    static var settle: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.15) }
    /// Flown from one place into another (a bar into its row, a tile into
    /// its card): eased away and eased in.
    static var flight: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
}

/// The edges things are drawn with: a panel's hairline, a card's (subtler),
/// and a strong one where things stack (a sheet, a tab).
enum EdgeColor {
    static let hairline = Theme.panelBorder
    static let subtle = Theme.cardBorder
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

/// A block's link as a capsule — a tile's links on its bar, a note's
/// link to a block in its text: one look.
enum LinkCapsule {
    static let font = UIType.caption
    static let symbolSize: CGFloat = 10
    static var fill: NSColor { Theme.panel }
    static var edge: NSColor { EdgeColor.hairline }
    static let edgeWidth: CGFloat = 0.5

    /// A block's pill (§7) in `r`, in a flipped context: its symbol, name
    /// and status, as its tile wears them — one look wherever a reference
    /// is drawn (the editor's Markdown, a comment's words).
    static func drawPill(_ look: PillLook, in r: NSRect, phase: Double, _ ctx: CGContext) {
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        fill.setFill()
        capsule.fill()
        edge.setStroke()
        capsule.lineWidth = edgeWidth
        capsule.stroke()
        var x = r.minX + 8
        if let image = tinted(look.symbol, size: symbolSize, color: Theme.secondaryText) {
            image.draw(in: NSRect(x: x, y: r.midY - 6, width: 13, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 18
        let title = NSAttributedString(string: look.title, attributes: [.font: font, .foregroundColor: Theme.text])
        let size = title.size()
        title.draw(at: NSPoint(x: x, y: r.midY - size.height / 2))
        if let status = look.status {
            let g = NSRect(x: r.maxX - 8 - 11, y: r.midY - 5.5, width: 11, height: 11)
            // The glyph is drawn y up: the square flipped back for it.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: g.minY + g.maxY)
            ctx.scaleBy(x: 1, y: -1)
            StatusGlyph.draw(status, in: g, phase: phase)
            ctx.restoreGState()
        }
    }

    /// A pill's width for a look: its symbol, its name, its status.
    static func pillWidth(_ look: PillLook) -> CGFloat {
        let text = ceil((look.title as NSString).size(withAttributes: [.font: font]).width)
        return 8 + 13 + 5 + text + (look.status == nil ? 0 : 4 + 11) + 8
    }

    /// A pill as an image `height` tall (text's attachment), drawn in
    /// whatever appearance it's drawn in.
    static func pillImage(_ look: PillLook, height: CGFloat) -> NSImage {
        let size = NSSize(width: min(pillWidth(look), 360), height: height)
        return NSImage(size: size, flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawPill(look, in: r.insetBy(dx: 0.5, dy: 0.5), phase: 0, ctx)
            return true
        }
    }

    private static var tintedSymbols: [String: NSImage] = [:]
    /// A symbol in a colour, for drawing by hand.
    static func tinted(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)/\(size)/\(color.description)"
        if let i = tintedSymbols[key] { return i }
        guard let symbol = Theme.symbol(name, size: size) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tintedSymbols[key] = image
        return image
    }
}

/// A pill: a count, an age — a few figures on a grey capsule, one look
/// wherever it's drawn (a sidebar row's count, a card's age).
enum Pill {
    static let height: CGFloat = 16
    static let font = UIType.count
    static let ground = NSColor.themed { $0.chrome.pill }

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
