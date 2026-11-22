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

/// A block's links by hand (§3.5), in its tile's bar: a button among
/// the bar's, a link — with a small count at its corner when there's more
/// than one. Clicked, its links in a menu of cards, each followed by the
/// one rule (⌘ beside, ⌥ over, as held when it's chosen), and the map;
/// right-clicked, the one link's own menu (several: the same cards);
/// dragged, the one link's block. (It was a stack of the linked blocks'
/// faces, folded, a chevron in each for the direction: a picture of the
/// links, where a button that says there are some was all the bar needed.)
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
            if !cards.isEmpty, chips.count == 1 { dress(chips[0]); return }
            rebuild()
        }
    }

    static let capsuleHeight: CGFloat = 22
    /// The links' menu's cards: one width, whatever they say.
    static let menuCardWidth: CGFloat = 360
    /// As wide as the bar's other buttons.
    static let chip: CGFloat = 16

    /// At a tile's upper right: kept for the grid, which places it in the bar.
    var fansDown = false
    /// Its one face (none, no links).
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
    /// Its width: a button's.
    var foldedWidth: CGFloat { cards.isEmpty ? 0 : Self.chip }
    var capsuleWantedWidth: CGFloat { foldedWidth }
    var wantedSize: NSSize { NSSize(width: foldedWidth, height: Self.capsuleHeight) }

    // MARK: Its face

    private func rebuild() {
        for c in chips { c.removeFromSuperview() }
        chips = []
        guard !cards.isEmpty else { return }
        let c = Chip()
        dress(c)
        c.onClick = { [weak self, weak c] _ in if let self, let c { self.showLinks(from: c) } }
        c.onMenu = { [weak self, weak c] in
            guard let self, let c else { return }
            if self.cards.count == 1 { self.showMenu(for: self.cards[0], from: c) } else { self.showLinks(from: c) }
        }
        c.onDragStart = { [weak self, weak c] event in
            guard let self, let c, self.cards.count == 1 else { return }
            self.drag(self.cards[0].block, from: c, event)
        }
        chips = [c]
        addSubview(c)
        needsLayout = true
    }

    private func dress(_ c: Chip) {
        c.count = cards.count
        if cards.count == 1, let card = cards.first {
            c.toolTip = (card.breakable ? (card.outbound ? "Links to " : "Linked from ") : (card.outbound ? "Shows " : "Shown in ")) + card.title
        } else {
            c.toolTip = "\(cards.count) links — click for them"
        }
    }

    override func layout() {
        super.layout()
        let y = ((bounds.height - Self.chip) / 2).rounded()
        for c in chips {
            c.frame = NSRect(x: bounds.maxX - Self.chip, y: y, width: Self.chip, height: Self.chip)
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
    /// The count at its corner (0, one link: none).
    var debugSheets: Int { cards.count > 1 ? cards.count : 0 }
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

    /// The links' button: a link, drawn as the bar's buttons are (the
    /// hover's rounded ground, the bar's ink), and with several, how many
    /// at its lower corner, small, on the bar's ground.
    final class Chip: NSView {
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onMenu: (() -> Void)?
        var onDragStart: ((NSEvent) -> Void)?
        var count = 1 { didSet { if count != oldValue { needsDisplay = true } } }
        private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
        private var downAt: NSPoint?

        override init(frame: NSRect) {
            super.init(frame: frame)
            themed { $0.needsDisplay = true }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            if hovered {
                (downAt != nil ? Flat.pressed : Flat.hovered).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: Radius.control, yRadius: Radius.control).fill()
            }
            let several = count > 1
            if let image = Theme.symbol("link", size: 10, weight: .medium, color: Theme.secondaryText) {
                let s = image.size
                // With a count, up and to the left a little, for it.
                let r = NSRect(x: ((bounds.width - s.width) / 2 - (several ? 1.5 : 0)).rounded(),
                               y: ((bounds.height - s.height) / 2 + (several ? 1.5 : 0)).rounded(), width: s.width, height: s.height)
                image.draw(in: r)
            }
            guard several else { return }
            let words = NSAttributedString(string: count > 9 ? "9+" : "\(count)", attributes: [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .bold), .foregroundColor: Theme.secondaryText])
            let size = words.size()
            let at = NSPoint(x: bounds.maxX - size.width + 1, y: -2)
            // A ground of the bar's own behind it, where it crosses the link.
            Theme.tileBar.setFill()
            NSBezierPath(roundedRect: NSRect(x: at.x - 1, y: at.y + 2, width: size.width + 2, height: size.height - 3), xRadius: 2, yRadius: 2).fill()
            words.draw(at: at)
        }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        // Set here, not passed on (see SidebarView's).
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        /// A click in a window not yet active goes to the link too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow; needsDisplay = true }
        override func rightMouseDown(with event: NSEvent) { onMenu?() }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt, onDragStart != nil else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            downAt = nil
            needsDisplay = true
            onDragStart?(event)
        }
        override func mouseUp(with event: NSEvent) {
            defer { downAt = nil; needsDisplay = true }
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
