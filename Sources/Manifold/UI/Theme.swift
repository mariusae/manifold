import AppKit
import ManifoldCore

enum Theme {
    /// Each a colour of the theme in use (`Palette`), as it has it in the
    /// light and in the dark.
    static let windowBackground = NSColor.themed { $0.window }
    static let sidebarWidth: CGFloat = 232
    static let sidebarWidthRange: ClosedRange<CGFloat> = 180...480
    static let sidebarInset: CGFloat = 6
    static let text = NSColor.themed { $0.text.primary }
    /// What's read and edited at length — an editor's, a preview's body —
    /// a step down from white in the dark, against glare over a long read.
    static let bodyText = NSColor.themed { $0.text.body }
    /// Headings and bold in it: brighter, to do the work emphasis does.
    static let strongText = NSColor.themed { $0.text.strong }
    /// Each at least 4.5:1 on a panel or a card, in either appearance
    /// (WCAG AA for text this size): quieter, but read.
    static let secondaryText = NSColor.themed { $0.text.secondary }
    /// Quieter still: a hint, a note at a row's end.
    static let tertiaryText = NSColor.themed { $0.text.tertiary }
    static let hover = NSColor.themed { $0.chrome.hover }
    static let selected = NSColor.themed { $0.chrome.selected }
    /// A selected row in a list: the tint, thin, so the row's own colors stay.
    static let selection = Tints.band
    /// The same, in a list without the keyboard.
    static let selectionInactive = Tints.bandInactive
    static let divider = NSColor.themed { $0.chrome.divider }
    /// The app's tint (`Tints`).
    static let accent = Tints.accent
    /// A block that failed (§3.7).
    static let statusError = Status.failed
    static let dropHighlight = Tints.dropHighlight
    /// Floating panels: the palette, a stack's list.
    /// A text in view mode, as go.dev's docs (the Go spec) set code: on
    /// their grey (#F8F8F8; #2D2D2D in the dark), in their text color
    /// (#202224; #F0F1F2), its line numbers in theirs (#999).
    static let codePage = NSColor.themed { $0.code.page }
    static let codeText = NSColor.themed { $0.code.text }
    static let codeLineNumber = NSColor.themed { $0.code.lineNumber }

    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let panel = NSColor.themed { $0.chrome.panel }
    static let panelBorder = NSColor.themed { $0.chrome.panelBorder }
    /// Over the window, behind the palette.
    static let scrim = NSColor.themed { $0.chrome.scrim }
    /// The sidebar card's edge.
    static let cardBorder = NSColor.themed { $0.chrome.cardBorder }
    /// The sidebar's resize handle.
    static let handle = NSColor.themed { $0.chrome.handle }
    /// A scrubber's knob (§3.1), on no track of its own.
    static let scrubberKnob = NSColor.themed { $0.chrome.scrubberKnob }
    /// The hairline around sheets.
    static func sheetEdge(hovered: Bool) -> NSColor {
        hovered ? sheetEdgeHovered : sheetEdge
    }
    /// A sheet beneath a stack's top, `level` deep: darker further down in
    /// light, lighter nearer the top in dark (as things nearer are lit) —
    /// apart from the backdrop and each other enough to be seen as cards.
    static func sheet(level: Int) -> NSColor { .themed { $0.chrome.sheet(level) } }
    private static let sheetEdge = NSColor.themed { $0.chrome.sheetEdge }
    private static let sheetEdgeHovered = NSColor.themed { $0.chrome.sheetEdgeHovered }

    /// Each as plain as it can be and still say what it is: read at a
    /// bar's 10 points, where a symbol's small parts (a window round a
    /// prompt, a page's lines, a chip's pins) run together.
    static func symbolName(for lens: Lens) -> String {
        switch lens {
        case .terminal: Marks.terminal
        case .preview: "doc.plaintext"
        case .editor: "doc"
        case .directory: "folder"
        case .web: "globe"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .search: "magnifyingglass"
        case .diff: "plus.forwardslash.minus"
        case .git: "arrow.triangle.branch"
        case .smartlog: "arrow.triangle.pull"
        case .process: "gauge.medium"
        case .agent: "sparkle"
        case .card: spaceSymbol
        case .output: "text.alignleft"
        case .notebook: "text.line.first.and.arrowtriangle.forward"
        case .outline: "list.bullet.rectangle"
        case .outliner: "list.bullet.indent"
        case .ui: "slider.horizontal.3"
        case .thread: "bubble.left.and.bubble.right"
        case .threads: "text.bubble"
        }
    }

    /// A space's: two panes side by side.
    static let spaceSymbol = "square.split.2x1"

    static func symbolName(for kind: BlockKind, path: String? = nil) -> String {
        kind == .text && path == nil ? noteSymbol : symbolName(for: Lens.default(for: kind, path: path), path: path)
    }

    /// A block's symbol: its kind's, or for a coding agent at work in it
    /// (an agent block, a terminal running one) the agent's own mark.
    static func symbolName(for block: Block) -> String {
        if let a = block.agent, AgentIcons.has(a.command) { return AgentIcons.prefix + a.command }
        return symbolName(for: block.kind, path: block.path)
    }

    /// A note's: a text not saved anywhere yet, unlike a file's page — a
    /// sticky note, its corner turned up (`Marks`).
    static let noteSymbol = Marks.note

    /// A lens's symbol for a text at `path`: viewed, Markdown is rich
    /// text and anything else still a page of text.
    static func symbolName(for lens: Lens, path: String?) -> String {
        lens == .preview && Lens.viewRendering(for: path) != .markdown ? symbolName(for: .editor) : symbolName(for: lens)
    }

    /// Older names for symbols a macOS before this one's may not have,
    /// tried in turn; last, a dot, so nothing is ever blank.
    static let symbolFallbacks: [String: [String]] = [
        "eraser": ["eraser.fill", "xmark.circle"],
        "rectangle.expand.vertical": ["arrow.up.and.down.square", "arrow.up.and.down"],
        "point.3.connected.trianglepath.dotted": ["link", "circle.hexagongrid"],
        "tray.and.arrow.down": ["tray", "square.and.arrow.down"],
        "arrow.up.left.and.arrow.down.right": ["arrow.up.left.and.down.right.magnifyingglass", "arrow.up.and.down"],
        "arrow.down.right.and.arrow.up.left": ["arrow.down.right.and.arrow.up.left.circle", "arrow.up.and.down"],
        "gauge.medium": ["gauge", "speedometer"],
        "text.line.first.and.arrowtriangle.forward": ["list.bullet.indent", "terminal"],
        "plus.forwardslash.minus": ["plusminus", "arrow.left.arrow.right"],
        "doc.plaintext": ["doc.text"],
        "sparkle": ["sparkles"],
        "arrow.triangle.pull": ["arrow.triangle.branch"],
        "number": ["number.square", "textformat"],
    ]

    /// A symbol at a size and weight. Made once and kept: an image made
    /// afresh is drawn afresh, each row of a list rasterizing its symbol
    /// again whenever the list is made again.
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)/\(size)/\(weight.rawValue)"
        if let image = symbols[key] { return image }
        // A coding agent's mark, drawn to the size a symbol would be; one of our own.
        if name.hasPrefix(AgentIcons.prefix), let image = AgentIcons.image(String(name.dropFirst(AgentIcons.prefix.count)), size: size) {
            symbols[key] = image
            return image
        }
        if let image = Marks.image(name, size: size, weight: weight) {
            symbols[key] = image
            return image
        }
        for candidate in [name] + (symbolFallbacks[name] ?? []) + ["circle.fill"] {
            if let image = NSImage(systemSymbolName: candidate, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight)) {
                symbols[key] = image
                return image
            }
        }
        return nil
    }

    private static var symbols: [String: NSImage] = [:]

    /// A symbol drawn in a colour, at a size and weight — the system's, one
    /// of our own (`Marks`), or an agent's mark (in its own colours).
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        if name.hasPrefix(AgentIcons.prefix) { return symbol(name, size: size, weight: weight) }
        if let mark = Marks.image(name, size: size, weight: weight) { return mark.tinted(color) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [color])))
            ?? symbol(name, size: size, weight: weight)
    }
}

/// Marks of our own, where the system's symbol is too busy to read at a
/// row's size: drawn as templates, a stroke as heavy as the weight asked
/// for, in a box a symbol of that size would take.
enum Marks {
    static let prefix = "manifold."
    /// A terminal: a prompt, `>_` — no window around it.
    static let terminal = prefix + "terminal"
    /// A note: a square, its lower right corner turned up.
    static let note = prefix + "note"

    private static var made: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard name.hasPrefix(prefix) else { return nil }
        let key = "\(name)/\(size)/\(weight.rawValue)"
        if let i = made[key] { return i }
        guard parts(name, size: size, weight: weight, in: CGRect(origin: .zero, size: box(size))) != nil else { return nil }
        let image = NSImage(size: box(size), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext, let parts = parts(name, size: size, weight: weight, in: r) else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(stroke(size, weight))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for part in parts where !part.drawsOn && !part.fills {
                ctx.addPath(part.rest)
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        made[key] = image
        return image
    }

    /// The box a mark is drawn in, as a symbol of that size would take.
    static func box(_ size: CGFloat) -> CGSize { CGSize(width: (size * 1.25).rounded(), height: (size * 1.1).rounded()) }

    /// A stroke as a symbol's at that weight: about a tenth of its size.
    static func stroke(_ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        size * (weight >= .bold ? 0.15 : weight >= .semibold ? 0.135 : weight >= .medium ? 0.12 : 0.105)
    }

    /// One stroke of a mark, at rest (as its image draws it) and unfolded
    /// — the same points, moved — for a tile's icon to unfold under the
    /// pointer (`IconHandle`).
    struct Part {
        var rest: CGPath
        var out: CGPath
        /// Drawn on as it unfolds, none of it at rest (a window round a prompt).
        var drawsOn = false
        /// Filled faintly as it unfolds, not stroked (a turned corner's back).
        var fills = false
    }

    /// A mark's strokes in `r` (its box, y up): a terminal's prompt, which
    /// unfolding draws a window round as it steps in; a note's page, whose
    /// turned corner peels further up, its back shaded.
    static func parts(_ name: String, size: CGFloat, weight: NSFont.Weight, in r: CGRect) -> [Part]? {
        let stroke = stroke(size, weight), u = size / 13
        func path(_ points: [CGPoint], closed: Bool = false) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: points)
            if closed { p.closeSubpath() }
            return p
        }
        switch name {
        case terminal:
            // Its points from the box's left (the image's own), moved there.
            let midY = r.midY, inset = stroke / 2 + 1 * u
            func prompt(_ t: CGAffineTransform) -> (CGPath, CGPath) {
                (path([CGPoint(x: inset + 1 * u, y: midY + 4 * u), CGPoint(x: inset + 5.2 * u, y: midY), CGPoint(x: inset + 1 * u, y: midY - 4 * u)].map { $0.applying(t) }),
                 path([CGPoint(x: inset + 7.4 * u, y: midY - 4 * u), CGPoint(x: min(r.width - inset, inset + 13.2 * u), y: midY - 4 * u)].map { $0.applying(t) }))
            }
            let shift = CGAffineTransform(translationX: r.minX, y: 0)
            // Unfolded, the prompt smaller, up and in from the window's left.
            let inside = CGAffineTransform(translationX: -r.width / 2, y: -r.midY).concatenating(CGAffineTransform(scaleX: 0.58, y: 0.58))
                .concatenating(CGAffineTransform(translationX: r.width / 2 - 1.2 * u, y: r.midY + 0.6 * u)).concatenating(shift)
            let (c0, s0) = prompt(shift), (c1, s1) = prompt(inside)
            let window = CGPath(roundedRect: r.insetBy(dx: stroke / 2, dy: stroke / 2), cornerWidth: 2.4 * u, cornerHeight: 2.4 * u, transform: nil)
            return [Part(rest: c0, out: c1), Part(rest: s0, out: s1), Part(rest: window, out: window, drawsOn: true)]
        case note:
            let side = 11.6 * u
            let sq = CGRect(x: (r.midX - side / 2).rounded(), y: r.midY - side / 2, width: side, height: side).insetBy(dx: stroke / 2, dy: stroke / 2)
            func page(_ f: CGFloat, tip: CGFloat) -> (CGPath, CGPath, CGPath) {
                let corner = CGPoint(x: sq.maxX - f * tip, y: sq.minY + f * tip)
                return (path([CGPoint(x: sq.minX, y: sq.maxY), CGPoint(x: sq.maxX, y: sq.maxY), CGPoint(x: sq.maxX, y: sq.minY + f),
                              CGPoint(x: sq.maxX - f, y: sq.minY), CGPoint(x: sq.minX, y: sq.minY)], closed: true),
                        path([CGPoint(x: sq.maxX, y: sq.minY + f), corner, CGPoint(x: sq.maxX - f, y: sq.minY)]),
                        path([CGPoint(x: sq.maxX, y: sq.minY + f), corner, CGPoint(x: sq.maxX - f, y: sq.minY)], closed: true))
            }
            // Unfolded, the corner turned up half as far again, its tip
            // lifting past the fold.
            let (p0, c0, b0) = page(3.6 * u, tip: 1), (p1, c1, b1) = page(5.8 * u, tip: 1.15)
            return [Part(rest: b0, out: b1, fills: true), Part(rest: p0, out: p1), Part(rest: c0, out: c1)]
        default:
            return nil
        }
    }
}

extension NSMutableAttributedString {
    /// One line, cut with an ellipsis: attributed strings in labels don't
    /// take the label's line breaking.
    func truncatingTail() -> NSMutableAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: length))
        return self
    }

    /// One line, cut at its start (a path, its name kept).
    func truncatingHead() -> NSMutableAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingHead
        addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: length))
        return self
    }
}

extension NSPasteboard.PasteboardType {
    /// An arrangement being dragged, by id.
    static let manifoldArrangement = NSPasteboard.PasteboardType("com.manifold.arrangement")
    /// A placement (a column's block) being dragged, by id.
    static let manifoldPlacement = NSPasteboard.PasteboardType("com.manifold.placement")
    /// A block being dragged from the sidebar, by id.
    static let manifoldBlock = NSPasteboard.PasteboardType("com.manifold.block")
    /// A block's link as Copy Link puts it on the clipboard, for a note to paste.
    static let manifoldBlockLink = NSPasteboard.PasteboardType("com.manifold.blocklink")
    /// A host's row in the sidebar being dragged, by session id.
    static let manifoldHost = NSPasteboard.PasteboardType("com.manifold.host")
}

/// A small borderless button showing a symbol, with a hover background.
final class IconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    /// The pointer come over it (true) or gone (false).
    var onHover: ((Bool) -> Void)?
    /// Clicked, in place of a target and action.
    var onClick: (() -> Void)? {
        didSet {
            target = onClick == nil ? nil : self
            action = onClick == nil ? nil : #selector(runClick)
        }
    }
    @objc private func runClick() { onClick?() }

    init(symbol: String, size: CGFloat = 11, weight: NSFont.Weight = .semibold, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        image = Theme.symbol(symbol, size: size, weight: weight)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Theme.secondaryText
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
        recheckHover()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }

    // Moved out from under a still pointer (its tile maximized and back,
    // clicked: the button somewhere else) there's no exit to say so; what
    // it thinks is checked against where the pointer is.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        recheckHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recheckHover()
    }

    override func viewDidHide() {
        super.viewDidHide()
        recheckHover()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        recheckHover()
    }

    private func recheckHover() {
        guard hovering else { return }
        guard let window, !isHiddenOrHasHiddenAncestor else { hovering = false; onHover?(false); return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(p) {
            hovering = false
            onHover?(false)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    // Set here, not passed on (see SidebarView's).
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            (isHighlighted ? Flat.pressed : Flat.hovered).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Radius.control, yRadius: Radius.control).fill()
        }
        // Its symbol, in its tint, centred: drawn from a tinted copy kept by
        // symbol and colour. Through the button's cell it was measured (an
        // empty title too) and drawn through the system's image effects at
        // every draw — most of a new tile's bar, and every bar at a theme.
        guard let image else { return super.draw(dirtyRect) }
        let color = contentTintColor ?? Theme.secondaryText
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        let tinted = Self.tinted(image, resolved)
        let size = image.size
        let scale = window?.backingScaleFactor ?? 2
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let r = NSRect(x: px((bounds.width - size.width) / 2), y: px((bounds.height - size.height) / 2), width: size.width, height: size.height)
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil)
    }

    private struct TintKey: Hashable {
        var image: ObjectIdentifier
        var rgba: [CGFloat]
    }
    /// The tinted copies, each with the symbol it's of (kept, so its
    /// identity isn't another image's while the copy is here).
    private static var tints: [TintKey: (source: NSImage, tinted: NSImage)] = [:]

    /// The symbol in that colour, made once.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let key = TintKey(image: ObjectIdentifier(image), rgba: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent])
        if let kept = tints[key] { return kept.tinted }
        let t = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        t.cacheMode = .always
        if tints.count > 2000 { tints = [:] }
        tints[key] = (image, t)
        return t
    }
}

/// A scroll view whose content ends at its edges. Without this, the
/// content ran on past the frame — a list's rows drawn over the header
/// above it and the rows below — since nothing here is meant to show
/// through under bars the way the system's own lists do.
final class ClippingScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }
}

/// A list's row, flat: chosen, a thin band of the tint (`Tints.band`, a
/// little stronger with the keyboard); under the pointer, a faint grey one
/// — both `Flat.rowBand`. The row's text and highlights keep their colors
/// (`interiorBackgroundStyle` stays normal). Every table and outline makes
/// its rows from this.
final class SelectionRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    /// Marked: a bar in the accent at the left edge (the current workspace's row).
    var marked = false { didSet { needsDisplay = true } }
    /// One of a run of rows on a panel of their own (a block and its
    /// processes): a card's fill as wide as what's in view, its top
    /// rounded on the first row, after `lead` of air, and its foot on the
    /// last. `quiet`: a row there to be read, not chosen (no hover).
    struct Panel: Equatable { var first = false; var last = false; var lead: CGFloat = 0; var quiet = false }
    var panel: Panel? { didSet { if panel != oldValue { needsDisplay = true } } }
    /// Nothing to do with it — a label, a hairline, a line to read: no
    /// band under the pointer, nothing to suggest it can be clicked.
    var inert = false { didSet { needsDisplay = true } }
    override var isFloating: Bool { didSet { needsDisplay = true } }
    /// Under the pointer: one row at a time, in every list — a row taking
    /// it takes it from the last. Rows are reused and move under a still
    /// pointer (scrolled, reloaded) with no exit to say so, so what a row
    /// thinks is checked against where the pointer is whenever it moves.
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            if hovered {
                if let last = Self.hoveredRow, last !== self { last.hovered = false }
                Self.hoveredRow = self
            } else if Self.hoveredRow === self {
                Self.hoveredRow = nil
            }
        }
    }
    private static weak var hoveredRow: SelectionRowView?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        recheckHover()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        recheckHover()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        if hovered { recheckHover() }
    }

    /// Hovered only if the pointer is over it now, in the key window.
    private func recheckHover() {
        guard let window, window.isKeyWindow, superview != nil else { return hovered = false }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hovered = bounds.contains(p) && isUnderPointer
    }



    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // A section's header kept at the top as its rows scroll under it:
        // a background of its own, so they don't show through it.
        if isGroupRowStyle, isFloating {
            Theme.windowBackground.setFill()
            bounds.fill()
        }
        if let p = panel { drawPanel(p) }
        if hovered, !isSelected, !isGroupRowStyle, !inert, panel?.quiet != true {
            Flat.hovered.setFill()
            Flat.rowBand(band).fill()
        }
        guard marked else { return }
        Flat.mark.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: Flat.markWidth, height: bounds.height - 10), xRadius: Radius.hair, yRadius: Radius.hair).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Flat.chosen(emphasized: isEmphasized).setFill()
        Flat.rowBand(band).fill()
    }

    /// What's in view of it, across: a panel's rows are as wide as that,
    /// whatever their columns run on to.
    private var seen: NSRect {
        guard panel != nil, let clip = enclosingScrollView?.contentView else { return bounds }
        let r = convert(clip.bounds, from: clip)
        return NSRect(x: max(bounds.minX, r.minX), y: bounds.minY, width: min(bounds.maxX, r.maxX) - max(bounds.minX, r.minX), height: bounds.height)
    }

    /// Where its hover and selection go: on a panel, inside it.
    private var band: NSRect { panel == nil ? bounds : seen.insetBy(dx: 6, dy: 0) }

    private func drawPanel(_ p: Panel) {
        // Carried past the edges it runs on over, and cut there.
        let reach = Radius.surface * 2
        let (low, high) = isFlipped ? (p.first, p.last) : (p.last, p.first)
        let minY = low ? bounds.minY + (isFlipped ? p.lead : 0) : bounds.minY - reach
        let maxY = high ? bounds.maxY - (isFlipped ? 0 : p.lead) : bounds.maxY + reach
        let s = seen
        let r = NSRect(x: s.minX + 6, y: minY, width: max(0, s.width - 12), height: maxY - minY)
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: Radius.surface, yRadius: Radius.surface)
        SummaryCard.fill.setFill()
        path.fill()
        EdgeColor.subtle.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
