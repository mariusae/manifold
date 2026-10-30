import AppKit
import ManifoldCore

enum Theme {
    static let windowBackground = GhosttyRuntime.background
    static let sidebarWidth: CGFloat = 232
    static let sidebarWidthRange: ClosedRange<CGFloat> = 180...480
    static let sidebarInset: CGFloat = 6
    static let text = NSColor.dynamic(NSColor(white: 0.13, alpha: 1), NSColor(white: 0.89, alpha: 1))
    /// What's read and edited at length — an editor's, a preview's body —
    /// a step down from white in the dark, against glare over a long read.
    static let bodyText = NSColor.dynamic(NSColor(white: 0.13, alpha: 1), NSColor(white: 0.86, alpha: 1))
    /// Headings and bold in it: brighter, to do the work emphasis does.
    static let strongText = NSColor.dynamic(NSColor(white: 0.08, alpha: 1), NSColor(white: 0.97, alpha: 1))
    /// Each at least 4.5:1 on a panel or a card, in either appearance
    /// (WCAG AA for text this size): quieter, but read.
    static let secondaryText = NSColor.dynamic(NSColor(white: 0.40, alpha: 1), NSColor(white: 0.68, alpha: 1))
    /// Quieter still: a hint, a note at a row's end.
    static let tertiaryText = NSColor.dynamic(NSColor(white: 0.45, alpha: 1), NSColor(white: 0.62, alpha: 1))
    static let hover = NSColor.dynamic(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.07))
    static let selected = NSColor.dynamic(.white, NSColor(white: 1, alpha: 0.13))
    /// A selected row in a list: the tint, thin, so the row's own colors stay.
    static let selection = Tints.band
    /// The same, in a list without the keyboard.
    static let selectionInactive = Tints.bandInactive
    static let divider = NSColor.dynamic(NSColor(white: 0, alpha: 0.1), NSColor(white: 1, alpha: 0.1))
    /// The app's tint (`Tints`).
    static let accent = Tints.accent
    /// A block that failed (§3.7).
    static let statusError = Status.failed
    static let dropHighlight = Tints.dropHighlight
    /// Floating panels: the palette, a stack's list.
    /// A text in view mode, as go.dev's docs (the Go spec) set code: on
    /// their grey (#F8F8F8; #2D2D2D in the dark), in their text color
    /// (#202224; #F0F1F2), its line numbers in theirs (#999).
    static let codePage = NSColor.dynamic(hex(0xF8F8F8), hex(0x2D2D2D))
    static let codeText = NSColor.dynamic(hex(0x202224), hex(0xF0F1F2))
    static let codeLineNumber = NSColor.dynamic(hex(0x999999), hex(0x848688))

    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let panel = NSColor.dynamic(NSColor(white: 0.995, alpha: 1), NSColor(white: 0.17, alpha: 1))
    static let panelBorder = NSColor.dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.14))
    /// Over the window, behind the palette.
    static let scrim = NSColor.dynamic(NSColor(white: 0.9, alpha: 0.35), NSColor(white: 0, alpha: 0.3))
    /// The sidebar card's edge.
    static let cardBorder = NSColor.dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.1))
    /// The sidebar's resize handle.
    static let handle = NSColor.dynamic(NSColor(white: 0, alpha: 0.22), NSColor(white: 1, alpha: 0.25))
    /// A scrubber's strip and its knob (§3.1).
    static let scrubberTrack = NSColor.dynamic(NSColor(white: 0, alpha: 0.035), NSColor(white: 1, alpha: 0.04))
    static let scrubberKnob = NSColor.dynamic(NSColor(white: 0, alpha: 0.14), NSColor(white: 1, alpha: 0.18))
    /// The hairline around sheets.
    static func sheetEdge(hovered: Bool) -> NSColor {
        hovered ? .dynamic(NSColor(white: 0, alpha: 0.34), NSColor(white: 1, alpha: 0.34))
            : .dynamic(NSColor(white: 0, alpha: 0.2), NSColor(white: 1, alpha: 0.16))
    }
    /// A sheet beneath a stack's top, `level` deep: darker further down in
    /// light, lighter nearer the top in dark (as things nearer are lit) —
    /// apart from the backdrop and each other enough to be seen as cards.
    static func sheet(level: Int) -> NSColor {
        .dynamic(NSColor(white: 0.93 - CGFloat(level) * 0.045, alpha: 1),
                 NSColor(white: 0.36 - CGFloat(level) * 0.05, alpha: 1))
    }

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
        // A stroke as a symbol's at that weight: about a tenth of its size.
        let stroke = size * (weight >= .bold ? 0.15 : weight >= .semibold ? 0.135 : weight >= .medium ? 0.12 : 0.105)
        let box = NSSize(width: (size * 1.25).rounded(), height: (size * 1.1).rounded())
        let image: NSImage
        switch name {
        case terminal:
            image = NSImage(size: box, flipped: false) { r in
                let u = size / 13, midY = r.midY, inset = stroke / 2 + 1 * u
                let chevron = NSBezierPath()
                chevron.move(to: NSPoint(x: inset + 1 * u, y: midY + 4 * u))
                chevron.line(to: NSPoint(x: inset + 5.2 * u, y: midY))
                chevron.line(to: NSPoint(x: inset + 1 * u, y: midY - 4 * u))
                let underscore = NSBezierPath()
                underscore.move(to: NSPoint(x: inset + 7.4 * u, y: midY - 4 * u))
                underscore.line(to: NSPoint(x: min(r.maxX - inset, inset + 13.2 * u), y: midY - 4 * u))
                NSColor.black.setStroke()
                for p in [chevron, underscore] {
                    p.lineWidth = stroke
                    p.lineCapStyle = .round
                    p.lineJoinStyle = .round
                    p.stroke()
                }
                return true
            }
        case note:
            image = NSImage(size: box, flipped: false) { r in
                let u = size / 13, side = 11.6 * u, fold = 3.6 * u
                let s = NSRect(x: (r.midX - side / 2).rounded(), y: r.midY - side / 2, width: side, height: side).insetBy(dx: stroke / 2, dy: stroke / 2)
                let page = NSBezierPath()
                page.move(to: NSPoint(x: s.minX, y: s.maxY))
                page.line(to: NSPoint(x: s.maxX, y: s.maxY))
                page.line(to: NSPoint(x: s.maxX, y: s.minY + fold))
                page.line(to: NSPoint(x: s.maxX - fold, y: s.minY))
                page.line(to: NSPoint(x: s.minX, y: s.minY))
                page.close()
                let corner = NSBezierPath()
                corner.move(to: NSPoint(x: s.maxX, y: s.minY + fold))
                corner.line(to: NSPoint(x: s.maxX - fold, y: s.minY + fold))
                corner.line(to: NSPoint(x: s.maxX - fold, y: s.minY))
                NSColor.black.setStroke()
                for p in [page, corner] {
                    p.lineWidth = stroke
                    p.lineCapStyle = .round
                    p.lineJoinStyle = .round
                    p.stroke()
                }
                return true
            }
        default:
            return nil
        }
        image.isTemplate = true
        made[key] = image
        return image
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
        super.draw(dirtyRect)
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
    /// One of a run of rows drawn round together (a stack's tiles in the
    /// sidebar): a dotted rounded outline, its top on the first row and its
    /// bottom on the last.
    struct Grouped: Equatable { var first: Bool; var last: Bool }
    var grouped: Grouped? { didSet { if grouped != oldValue { needsDisplay = true } } }
    /// One of a run of rows on a panel of their own (a block and its
    /// processes): a card's fill as wide as what's in view, its top
    /// rounded on the first row, after `lead` of air, and its foot on the
    /// last. `quiet`: a row there to be read, not chosen (no hover).
    struct Panel: Equatable { var first = false; var last = false; var lead: CGFloat = 0; var quiet = false }
    var panel: Panel? { didSet { if panel != oldValue { needsDisplay = true } } }
    private static let outlineColor = NSColor.dynamic(NSColor(white: 0, alpha: 0.28), NSColor(white: 1, alpha: 0.28))
    /// Told as the pointer comes and goes (a row with a twin lights it).
    var onHover: ((Bool) -> Void)?
    /// Lit as if hovered: the other row of the same thing is.
    var echo = false { didSet { if echo != oldValue { needsDisplay = true } } }
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
            onHover?(hovered)
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
        onHover = nil
        echo = false
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
        if let g = grouped {
            // Square where it runs on into the next row: the rounded rect
            // carried past that edge, and cut there.
            let reach = Radius.control * 2
            // Its top and bottom edges, as the run reads (flipped or not).
            let (low, high) = isFlipped ? (g.first, g.last) : (g.last, g.first)
            let minY = low ? bounds.minY + 1 : bounds.minY - reach
            let maxY = high ? bounds.maxY - 1 : bounds.maxY + reach
            let r = NSRect(x: bounds.minX + 6, y: minY, width: bounds.width - 12, height: maxY - minY)
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            Self.outlineColor.setStroke()
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.control, yRadius: Radius.control)
            path.lineWidth = 1
            path.setLineDash([1.5, 2.5], count: 2, phase: 0)
            path.lineCapStyle = .round
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let p = panel { drawPanel(p) }
        if hovered || echo, !isSelected, !isGroupRowStyle, panel?.quiet != true {
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
