import AppKit
import ManifoldCore

/// A link a block has by hand, as its tile's links show it: to a block
/// (outbound, →) or from one (inbound, ←).
struct LinkCard: Equatable {
    /// The edge's id, to break it by.
    var link: String
    var block: BlockID
    var title: String
    var symbol: String
    var outbound: Bool
    /// Not an embed (a note's image), which goes when the note no longer
    /// shows it.
    var breakable = true
}

/// A block's links by hand (§3.5), in its tile's bar: each linked block's
/// own face, a small rounded square with a chevron in it for the
/// direction (right, links to; left, linked from) — the most recent in
/// front, two more peeking out behind it, folded always. Clicked, its
/// links in a menu, each followed by the one rule (⌘ beside, ⌥ over, as
/// held when it's chosen), and the map; right-clicked, the face's own
/// menu; dragged, the block. (It fanned out under the pointer, a card
/// rising on each, the rest a stack scrubbed through over the title:
/// five ways of showing, every one hidden till hovered.)
final class LinkBadge: NSView {
    /// A link chosen: the block, and the keys held (⌘ beside, ⌥ over,
    /// ⇧⌘ the system's app).
    var onOpen: ((BlockID, NSEvent.ModifierFlags) -> Void)?
    var onBreak: ((String) -> Void)?
    /// The neighborhood map, the big view of the links.
    var onMap: (() -> Void)?
    /// A linked block's summary card, for its links' menu.
    var summary: ((BlockID) -> SummaryCardContent?)?
    var cards: [LinkCard] = [] {
        didSet {
            guard cards != oldValue else { return }
            // The same links, only what they say changed (a note's title as
            // it's typed): the faces dressed again, not made again.
            if cards.map(\.link) == oldValue.map(\.link), cards.map(\.block) == oldValue.map(\.block), chips.count == min(cards.count, 3) {
                for (c, card) in zip(chips, cards) { dress(c, card) }
                return
            }
            rebuild()
        }
    }

    static let capsuleHeight: CGFloat = 22
    /// The links' menu's cards: one width, whatever they say.
    static let menuCardWidth: CGFloat = 360
    static let chip: CGFloat = 22
    /// How far each one behind peeks out past the one before.
    static let peek: CGFloat = 4

    /// At a tile's upper right: kept for the grid, which places it in the bar.
    var fansDown = false
    /// A face for each of the first three links: the front, two edges behind it.
    private var chips: [Chip] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The faces' badges reach past its frame.
        clipsToBounds = false
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Size, as the bar gives it

    /// What the bar gives the stack; under its own width, it hides.
    var capsuleLimit: CGFloat = .infinity { didSet { if capsuleLimit != oldValue { isHidden = capsuleLimit < foldedWidth; needsLayout = true } } }
    /// The stack's width: one face, and the edges of two more.
    var foldedWidth: CGFloat { cards.isEmpty ? 0 : Self.chip + CGFloat(min(cards.count, 3) - 1) * Self.peek }
    var capsuleWantedWidth: CGFloat { foldedWidth }
    var wantedSize: NSSize { NSSize(width: foldedWidth, height: Self.capsuleHeight) }

    // MARK: Faces

    /// Its faces in the bar's ground (every bar's the same, focused or not).
    private var barGround: NSColor { Theme.tileBar }

    private func rebuild() {
        for c in chips { c.removeFromSuperview() }
        chips = cards.prefix(3).map { card in
            let c = Chip()
            c.ground = barGround
            dress(c, card)
            c.onClick = { [weak self, weak c] _ in if let self, let c { self.showLinks(from: c) } }
            c.onMenu = { [weak self, weak c] in if let c { self?.showMenu(for: card, from: c) } }
            c.onDragStart = { [weak self, weak c] event in if let self, let c { self.drag(card.block, from: c, event) } }
            return c
        }
        // The most recent on top of the ones behind it: added last.
        for c in chips.reversed() { addSubview(c) }
        needsLayout = true
    }

    private func dress(_ c: Chip, _ card: LinkCard) {
        c.symbol = card.symbol
        c.outbound = card.outbound
        c.toolTip = (card.breakable ? (card.outbound ? "Links to " : "Linked from ") : (card.outbound ? "Shows " : "Shown in ")) + card.title
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.chip) / 2
        let left = bounds.maxX - foldedWidth
        for (i, c) in chips.enumerated() {
            c.depth = i
            c.frame = NSRect(x: left + CGFloat(i) * Self.peek, y: y, width: Self.chip, height: Self.chip)
            window?.invalidateCursorRects(for: c)
        }
    }

    // MARK: The pointer

    /// The faces take the mouse; elsewhere, the bar does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for v in chips where !v.isHidden && v.frame.contains(p) { return v }
        return nil
    }

    /// Its links, in a menu under the face clicked: the most recent first,
    /// each going there (⌘ beside, ⌥ over, as held when it's chosen); then
    /// the neighbourhood map.
    private func showLinks(from chip: NSView) {
        linksMenu().popUp(positioning: nil, at: NSPoint(x: chip.frame.minX, y: chip.frame.minY - 4), in: self)
    }

    private func linksMenu() -> NSMenu {
        let menu = NSMenu()
        // Each a card — what it is, where, what it says — all one width.
        for card in cards {
            let go = { [weak self] in
                self?.onOpen?(card.block, NSApp.currentEvent?.modifierFlags.intersection([.command, .option, .shift]) ?? []) ?? ()
            }
            let item = ClosureMenuItem((card.outbound ? "→ " : "← ") + card.title, symbol: card.symbol, go)
            var content = summary?(card.block) ?? SummaryCardContent(id: "", symbol: card.symbol, summary: BlockSummary(title: card.title))
            content.summary.title = (card.outbound ? "→ " : "← ") + content.summary.title
            item.view = LinkCardItem(content, width: Self.menuCardWidth, pick: go)
            item.toolTip = card.breakable ? (card.outbound ? "Links to it" : "Linked from it") : (card.outbound ? "Shows it" : "Shown in it")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.onMap?() })
        return menu
    }

    /// Debugging: the links menu's cards drawn one under another, the
    /// `lit`th as the highlight has it, to `path`.
    func debugMenuImage(_ path: String, lit: Int?) -> String {
        let views = linksMenu().items.compactMap(\.view)
        guard let w = views.map(\.frame.width).max() else { return "no cards" }
        let h = views.map(\.frame.height).reduce(0, +)
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        var y = h
        for (i, v) in views.enumerated() {
            y -= v.frame.height
            (v as? LinkCardItem)?.debugLit = i == lit
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                rep.draw(in: NSRect(x: 0, y: y, width: v.frame.width, height: v.frame.height))
            }
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return "no image" }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return "wrote \(views.count) cards, \(Int(w))×\(Int(h)), to \(path)"
    }

    /// A face's menu: the one rule's three ways, the link broken, the map.
    private func showMenu(for card: LinkCard, from chip: NSView) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Go To", symbol: "arrow.right.circle") { [weak self] in self?.onOpen?(card.block, []) })
        menu.addItem(ClosureMenuItem("Show Beside", symbol: "rectangle.split.1x2") { [weak self] in self?.onOpen?(card.block, .command) })
        menu.addItem(ClosureMenuItem("Show Over", symbol: "square.stack") { [weak self] in self?.onOpen?(card.block, .option) })
        menu.addItem(.separator())
        if card.breakable {
            menu.addItem(ClosureMenuItem("Remove Link", symbol: "link.badge.plus") { [weak self] in self?.onBreak?(card.link) })
        }
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.onMap?() })
        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: chip)
    }

    /// A face dragged: the block, to bring where it's dropped; with ⇧ what
    /// it stands for (its path, its link), as a tile's bar is.
    private func drag(_ block: BlockID, from view: NSView, _ event: NSEvent) {
        guard let item = Drags.block?(block, event.modifierFlags) else { return }
        let drag = NSDraggingItem(pasteboardWriter: Drags.writer(item) ?? item)
        drag.setDraggingFrame(view.bounds, contents: view.picture() ?? NSImage(size: view.bounds.size))
        dragIsPath = event.modifierFlags.contains(.shift)
        let session = view.beginDraggingSession(with: [drag], event: event, source: self)
        DragPill.dress(session, from: view, at: NSEvent.mouseLocation)
    }

    private var dragIsPath = false

    // MARK: Debugging

    /// Where the nth face's middle is, in the window.
    func debugChipCenter(_ n: Int) -> NSPoint? {
        guard chips.indices.contains(n), !chips[n].isHidden else { return nil }
        let f = chips[n].convert(chips[n].bounds, to: nil)
        return NSPoint(x: f.midX, y: f.midY)
    }
    var debugTitles: [String] { cards.map { ($0.outbound ? "→ " : "← ") + $0.title } }
    /// How many faces peek out behind the front one.
    var debugSheets: Int { max(0, min(cards.count, 3) - 1) }
    var debugGeometry: String { chips.filter { !$0.isHidden }.map { NSStringFromRect($0.frame) }.joined(separator: " ") }
    /// Debugging: the front face's middle, in the window from its top left.
    var debugCapsuleCenter: NSPoint? {
        guard let first = chips.first, let frameView = window?.contentView?.superview else { return nil }
        let r = first.convert(first.bounds, to: nil)
        return NSPoint(x: r.midX, y: frameView.bounds.height - r.midY)
    }
    /// Debugging: the nth link broken, as its menu's Remove Link does.
    func debugBreak(_ n: Int) -> Bool {
        guard n < cards.count, cards[n].breakable else { return false }
        onBreak?(cards[n].link)
        return true
    }

    // MARK: A face

    /// One linked block: its symbol on a small rounded square, a chevron
    /// in it on the side it points — right, links to; left, linked from.
    final class Chip: NSView {
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onMenu: (() -> Void)?
        var onDragStart: ((NSEvent) -> Void)?
        var symbol = "link" { didSet { icon.image = Theme.symbol(symbol, size: 13) } }
        var outbound = true { didSet { chevron.image = Self.chevron(outbound); needsLayout = true } }
        /// The ground of the bar it's on.
        var ground: NSColor = Theme.tileBar { didSet { colour() } }
        private static func chevron(_ outbound: Bool) -> NSImage? { Theme.symbol(outbound ? "chevron.right" : "chevron.left", size: 9, weight: .bold) }
        /// Folded behind the front one (1, 2), only its edge showing: nothing
        /// on it, a step darker than the front for each one back, so the
        /// front leads.
        var depth = 0 {
            didSet {
                guard depth != oldValue else { return }
                icon.isHidden = depth > 0
                chevron.isHidden = depth > 0
                colour()
            }
        }
        private func colour() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // The bar's own ground (a warm theme's bar isn't its panel's
                // white); those behind, a step darker for each.
                layer?.backgroundColor = (depth > 0 ? (ground.blended(withFraction: 0.05 * CGFloat(depth), of: Theme.text) ?? Self.behind(depth)) : ground).cgColor
                layer?.borderColor = (hovered ? Theme.text.withAlphaComponent(0.3) : LinkCapsule.edge).cgColor
            }
        }
        /// The greys behind the front face: darker than its fill, light or dark.
        private static func behind(_ depth: Int) -> NSColor {
            .themed { $0.chrome.linkBehind(depth) }
        }
        var hovered = false {
            didSet {
                guard hovered != oldValue else { return }
                colour()
                layer?.borderWidth = hovered ? 1.5 : LinkCapsule.edgeWidth
            }
        }
        private let icon = NSImageView()
        private let chevron = NSImageView()
        private var downAt: NSPoint?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = Radius.control
            layer?.cornerCurve = .continuous
            layer?.borderWidth = LinkCapsule.edgeWidth
            layer?.masksToBounds = false
            icon.contentTintColor = Theme.secondaryText
            icon.image = Theme.symbol(symbol, size: 13)
            // The direction in the text's own colour, stronger than the symbol.
            chevron.contentTintColor = Theme.text
            chevron.image = Self.chevron(outbound)
            themed { $0.colour() }
            addSubview(icon)
            addSubview(chevron)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let s: CGFloat = 12, c: CGFloat = 5
            // The symbol and the chevron side by side, the chevron on the
            // side it points, the two together centred.
            let left = (bounds.width - s - c - 1) / 2
            let iy = (bounds.height - s) / 2, cy = (bounds.height - 8) / 2
            if outbound {
                icon.frame = NSRect(x: left, y: iy, width: s, height: s)
                chevron.frame = NSRect(x: left + s + 1, y: cy, width: c, height: 8)
            } else {
                chevron.frame = NSRect(x: left, y: cy, width: c, height: 8)
                icon.frame = NSRect(x: left + c + 1, y: iy, width: s, height: s)
            }
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        // Set here, not passed on (see SidebarView's).
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        /// A click in a window not yet active goes to the link too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
        override func rightMouseDown(with event: NSEvent) { onMenu?() }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt, onDragStart != nil else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            downAt = nil
            onDragStart?(event)
        }
        override func mouseUp(with event: NSEvent) {
            defer { downAt = nil }
            guard downAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // ⌃-click is a right-click, on the Mac: the menu.
            if event.modifierFlags.contains(.control) { return onMenu?() ?? () }
            onClick?(event.modifierFlags)
        }
    }

    /// The card under the bar: a summary card, which the pointer passes
    /// through (it's a look, not a place to click).
}

extension LinkBadge: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragIsPath ? [.copy, .link, .generic] : (context == .withinApplication ? [.copy, .move] : [])
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { DragCursor.began() }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { DragCursor.moved() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { DragCursor.ended() }
}

/// A link in its tile's links menu: its block's summary card, at the menu's
/// one width — lit as the menu's chosen row is, chosen by a click or ↩.
private final class LinkCardItem: NSView {
    private let card: SummaryCard
    private let pick: () -> Void
    private static let inset: CGFloat = 5

    init(_ content: SummaryCardContent, width: CGFloat, pick: @escaping () -> Void) {
        card = SummaryCard(content)
        self.pick = pick
        let h = SummaryCard.height(for: content)
        super.init(frame: NSRect(x: 0, y: 0, width: width + Self.inset * 2, height: h + 4))
        card.frame = NSRect(x: Self.inset, y: 2, width: width, height: h)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Debugging: lit or not whatever the menu says.
    var debugLit: Bool?

    // Lit as the menu's highlight moves (the menu draws an item's view again
    // then) — before anything's drawn, so the card's drawn as it is.
    override func viewWillDraw() {
        let lit = debugLit ?? enclosingMenuItem?.isHighlighted ?? false
        if card.chosen != lit { card.chosen = lit }
        super.viewWillDraw()
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        pick()
    }
}
