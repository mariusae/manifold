import AppKit
import ManifoldCore

/// ⌥⇥ (§3.6): the spaces, the most recently settled on first, as cards
/// over the window while ⌥ is held — each a picture of
/// its grid: its tiles in their columns at their sizes, each its last
/// picture (else its symbol and name), the focused one ringed; over it
/// its square, its name, its host, what wants you there. ` steps on, ⇧`
/// back; letting go of ⌘ goes to the one chosen, ⎋ stays.
final class SpaceSwitcherView: PopoverView {
    struct Card {
        struct Tile {
            var frame: NSRect          // in the unit square, y down
            var symbol: String
            var title: String
            var picture: NSImage?
            var focused: Bool
            var look: StatusGlyph.Look?
        }
        var id: BlockID
        var name: String
        var host: String?
        var mark: SpaceMark
        var badge: String?
        var color: NSColor
        var status: StatusGlyph.Look?
        var tiles: [Tile]
        var docked: Int
        /// What wants you there, under its grid: each tile that needs you,
        /// failed or is done (not yet seen) — its symbol, its name, its
        /// glyph, how long since.
        struct Want { var symbol: String; var title: String; var look: StatusGlyph.Look; var age: String? }
        var wants: [Want] = []
    }

    var cards: [Card] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var chosen = 0 { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onPick: ((Int) -> Void)?

    static let cardSize = NSSize(width: 236, height: 176)
    /// A row of what wants you, under a card's grid; three at most.
    static let wantRow: CGFloat = 20
    static let mostWants = 3
    /// The cards' height: room for the most wants any of them shows.
    private var cardHeight: CGFloat {
        let n = min(cards.map(\.wants.count).max() ?? 0, Self.mostWants)
        return Self.cardSize.height + (n > 0 ? CGFloat(n) * Self.wantRow + 6 : 0)
    }
    static let gap: CGFloat = 14
    static let pad: CGFloat = 18
    static let perRow = 4

    override var isFlipped: Bool { true }

    // A card clicked goes there: the pointing hand.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    /// Its size for its cards, as many rows as they take (three at most shown).
    var wantedSize: NSSize {
        let n = max(cards.count, 1)
        let cols = min(n, Self.perRow), rows = min((n + Self.perRow - 1) / Self.perRow, 3)
        return NSSize(width: Self.pad * 2 + CGFloat(cols) * Self.cardSize.width + CGFloat(cols - 1) * Self.gap,
                      height: Self.pad * 2 + CGFloat(rows) * cardHeight + CGFloat(rows - 1) * Self.gap)
    }

    private func cardRect(_ i: Int) -> NSRect {
        let col = i % Self.perRow, row = i / Self.perRow
        return NSRect(x: Self.pad + CGFloat(col) * (Self.cardSize.width + Self.gap),
                      y: Self.pad + CGFloat(row) * (cardHeight + Self.gap),
                      width: Self.cardSize.width, height: cardHeight)
    }

    override func drawContent(_ dirtyRect: NSRect) {
        for (i, c) in cards.enumerated() where i < Self.perRow * 3 {
            let r = cardRect(i)
            let lit = i == chosen
            // The card: a band of its colour under it when chosen.
            let body = NSBezierPath(roundedRect: r, xRadius: Radius.surface, yRadius: Radius.surface)
            (lit ? c.color.withAlphaComponent(0.22) : Theme.washFaint).setFill()
            body.fill()
            if lit {
                body.lineWidth = 2
                c.color.withAlphaComponent(0.85).setStroke()
                body.stroke()
            }
            // Its head: its square, its name, its host; what wants you there.
            let sq = NSRect(x: r.minX + 10, y: r.minY + 10, width: 20, height: 20)
            SpaceSquare.fill(sq, color: c.color, alpha: 0.3)
            SpaceSquare.drawGlyph(in: sq, color: c.color, mark: c.mark, badge: c.badge)
            var right = r.maxX - 10
            if let tone = SpaceStripView.tone(c.status) {
                tone.setFill()
                NSBezierPath(ovalIn: NSRect(x: right - 8, y: sq.midY - 4, width: 8, height: 8)).fill()
                right -= 14
            }
            let name = NSAttributedString(string: c.name, attributes: [.font: UIType.title, .foregroundColor: Theme.text])
            name.draw(with: NSRect(x: sq.maxX + 8, y: sq.minY + 1, width: max(0, right - sq.maxX - 8), height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            // The grid, in miniature; under it what wants you, row by row.
            let foot: CGFloat = c.docked > 0 || c.host != nil ? 18 : 6
            let wantsHeight = cardHeight - Self.cardSize.height
            let map = NSRect(x: r.minX + 10, y: sq.maxY + 8, width: r.width - 20, height: r.maxY - sq.maxY - 8 - 10 - foot - wantsHeight)
            drawMap(c, in: map)
            var words: [String] = []
            if let h = c.host { words.append(h) }
            if c.docked > 0 { words.append(c.docked == 1 ? "1 docked" : "\(c.docked) docked") }
            if !words.isEmpty {
                NSAttributedString(string: words.joined(separator: " · "), attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])
                    .draw(with: NSRect(x: map.minX, y: map.maxY + 4, width: map.width, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            drawWants(c.wants, from: map.maxY + foot + 4, in: r)
        }
    }

    /// What wants you there: a row each — the tile's symbol and name, how
    /// long since, and its glyph (needs you, failed, done), as the sidebar has them.
    private func drawWants(_ wants: [Card.Want], from top: CGFloat, in r: NSRect) {
        var y = top
        for w in wants.prefix(Self.mostWants) {
            let row = NSRect(x: r.minX + 10, y: y, width: r.width - 20, height: Self.wantRow)
            let side = StatusGlyph.size
            let glyph = NSRect(x: row.maxX - side, y: row.midY - side / 2, width: side, height: side)
            StatusGlyph.drawUpright(w.look, in: glyph)
            var right = glyph.minX - 6
            if let age = w.age {
                let a = NSAttributedString(string: age, attributes: [.font: UIType.footnote, .foregroundColor: Theme.tertiaryText])
                let z = a.size()
                a.draw(at: NSPoint(x: right - z.width, y: row.midY - z.height / 2))
                right -= z.width + 6
            }
            if let image = Theme.symbol(w.symbol, size: 11, weight: .regular, color: Theme.secondaryText) {
                let z = image.size
                image.draw(in: NSRect(x: row.minX, y: row.midY - z.height / 2, width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let t = NSAttributedString(string: w.title, attributes: [.font: UIType.detail, .foregroundColor: Theme.text])
            let h = t.size().height
            t.draw(with: NSRect(x: row.minX + 16, y: row.midY - h / 2, width: max(0, right - row.minX - 16), height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += Self.wantRow
        }
    }

    private func drawMap(_ c: Card, in map: NSRect) {
        guard !c.tiles.isEmpty else {
            Theme.washFaint.setFill()
            NSBezierPath(roundedRect: map, xRadius: Radius.control, yRadius: Radius.control).fill()
            NSAttributedString(string: "Empty", attributes: [.font: UIType.footnote, .foregroundColor: Theme.tertiaryText])
                .draw(at: NSPoint(x: map.midX - 14, y: map.midY - 7))
            return
        }
        for t in c.tiles {
            let f = NSRect(x: map.minX + t.frame.minX * map.width, y: map.minY + t.frame.minY * map.height,
                           width: t.frame.width * map.width, height: t.frame.height * map.height).insetBy(dx: 1.5, dy: 1.5)
            guard f.width > 4, f.height > 3 else { continue }
            let path = NSBezierPath(roundedRect: f, xRadius: Radius.inline, yRadius: Radius.inline)
            Theme.panel.setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // Its bar's line, then its picture (cut to fill), else its symbol and name.
            let bar = min(12, f.height)
            if let p = t.picture, f.height > bar + 4 {
                let body = NSRect(x: f.minX, y: f.minY + bar, width: f.width, height: f.height - bar)
                let s = p.size, k = max(body.width / max(s.width, 1), body.height / max(s.height, 1))
                let drawn = NSRect(x: body.minX, y: body.minY, width: s.width * k, height: s.height * k)
                p.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
            }
            Theme.washFaint.setFill()
            NSRect(x: f.minX, y: f.minY, width: f.width, height: bar).fill()
            if f.width > 22, let image = Theme.symbol(t.symbol, size: 7, weight: .semibold, color: Theme.secondaryText) {
                let z = image.size
                image.draw(in: NSRect(x: f.minX + 4, y: f.minY + (bar - z.height) / 2, width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                if f.width > 40 {
                    NSAttributedString(string: t.title, attributes: [.font: NSFont.systemFont(ofSize: 7.5, weight: .medium), .foregroundColor: Theme.secondaryText])
                        .draw(with: NSRect(x: f.minX + 14, y: f.minY + 1, width: f.width - 18, height: 10), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
            if t.picture == nil, f.height > 30, let image = Theme.symbol(t.symbol, size: 13, weight: .regular, color: Theme.tertiaryText) {
                let z = image.size
                image.draw(in: NSRect(x: f.midX - z.width / 2, y: f.minY + bar + (f.height - bar - z.height) / 2, width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            if t.focused, c.tiles.count > 1 {
                path.lineWidth = 1.5
                Theme.accent.withAlphaComponent(0.8).setStroke()
                path.stroke()
            } else if let tone = SpaceStripView.tone(t.look) {
                path.lineWidth = 1
                tone.setStroke()
                path.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cards.indices.first(where: { cardRect($0).contains(p) }) { onPick?(i) }
    }

    var debugRows: String {
        cards.enumerated().map { (i, c) in (i == chosen ? "> " : "  ") + c.name + " (\(c.tiles.count) tiles, \(c.docked) docked)" }.joined(separator: "\n")
    }
}

extension MainWindowController {
    /// The spaces, as ⌥⇥ walks them: here, then those settled on, the
    /// recent, the rest.
    func spaceTrail() -> [BlockID] {
        let live = Set(allWorkspaces)
        var order: [BlockID] = []
        for id in [selected].compactMap({ $0 }) + settled.map(\.space) + hosts.recentWorkspaces() + allWorkspaces where live.contains(id) && !order.contains(id) {
            order.append(id)
        }
        return order
    }

    func spaceCard(_ id: BlockID) -> SpaceSwitcherView.Card? {
        guard let b = hosts.block(id), let a = hosts.arrangement(id) else { return nil }
        let name = title(of: a)
        var tiles: [SpaceSwitcherView.Card.Tile] = []
        let cols = a.columns
        let fr = a.fractions.count == cols.count ? a.fractions : Array(repeating: 1 / Double(max(cols.count, 1)), count: cols.count)
        var x = 0.0
        for (c, column) in cols.enumerated() {
            let w = fr[c]
            let sum = column.reduce(0) { $0 + a.height(of: $1.id) }
            var y = 0.0
            for p in column {
                let h = sum > 0 ? a.height(of: p.id) / sum : 1 / Double(column.count)
                let tb = hosts.block(p.block)
                tiles.append(.init(frame: NSRect(x: x, y: y, width: w, height: h),
                                   symbol: tb.map { Theme.symbolName(for: $0) } ?? "square.dashed",
                                   title: tb.map(Self.linkTitle) ?? "",
                                   picture: tilePictures[p.block], focused: p.id == a.focused,
                                   look: StatusGlyph.look(of: tb)))
                y += h
            }
            x += w
        }
        // What wants you there: needs you, then failed, then done, not seen.
        var wants: [(rank: Int, want: SpaceSwitcherView.Card.Want)] = []
        var seen = Set<BlockID>()
        for p in a.placements + a.docked.map(\.placement) {
            guard seen.insert(p.block).inserted, let tb = hosts.block(p.block) else { continue }
            guard let look = StatusGlyph.look(of: tb) else { continue }
            let rank: Int
            switch look {
            case .needsYou: rank = 0
            case .failed(read: false): rank = 1
            case .done(read: false): rank = 2
            default: continue
            }
            wants.append((rank, .init(symbol: Theme.symbolName(for: tb), title: Self.linkTitle(tb), look: look, age: StatusGlyph.at(of: tb).map(Age.short))))
        }
        return .init(id: id, name: name, host: hosts.ordered.count > 1 ? hosts.label(of: id.host) : nil,
                     mark: spaceMarks()[id] ?? .letters(SpaceLook.letter(of: name)), badge: SpaceLook.badge(of: b), color: SpaceLook.color(of: b),
                     status: spaceStatus(a), tiles: tiles, docked: a.docked.count,
                     wants: wants.sorted { $0.rank < $1.rank }.map(\.want))
    }

    /// ⌥⇥ (⇧⌥⇥ back), as ⌘⇥ the Mac's apps: a step through the spaces,
    /// the most recent first, with ⌥ held, their cards shown a moment
    /// after (a quick ⌥⇥ flashes nothing, and goes back to the space
    /// before); letting go of ⌥ goes to the one chosen. With one space,
    /// the app's next window.
    @objc func switchSpace(_ sender: Any?) { stepSpaces(1) }
    @objc func switchSpaceBack(_ sender: Any?) { stepSpaces(-1) }

    private func stepSpaces(_ step: Int) {
        if let s = spaceSwitch {
            // Its key let go unheard (the app left meanwhile): over.
            guard NSEvent.modifierFlags.contains(.option) || debugHeld else { return endSpaceSwitch(going: true) }
            let n = s.order.count
            spaceSwitch?.index = ((s.index + step) % n + n) % n
            spaceSwitcher?.chosen = spaceSwitch!.index
            return
        }
        let order = spaceTrail()
        guard order.count > 1 else { return cycleWindows(back: step < 0) }
        let index = ((step) % order.count + order.count) % order.count
        // From the menu, ⌥ not held: one step, gone.
        guard NSEvent.modifierFlags.contains(.option) || debugHeld else { return hosts.select(order[index]) }
        spaceSwitch = (order, index)
        // Shown in a moment, if ⌥'s still held.
        spaceSwitchShow.schedule(after: 0.2) { [weak self] in self?.showSpaceSwitcher() }
        spaceSwitchHold = ModifierHold(.option, released: { [weak self] in self?.endSpaceSwitch(going: true) },
                                       escaped: { [weak self] in self?.endSpaceSwitch(going: false) })
    }

    private func showSpaceSwitcher() {
        guard let s = spaceSwitch else { return }
        let v = SpaceSwitcherView()
        v.cards = s.order.compactMap(spaceCard)
        v.chosen = s.index
        v.onPick = { [weak self] i in
            self?.spaceSwitch?.index = i
            self?.endSpaceSwitch(going: true)
        }
        let size = v.wantedSize
        let b = root.bounds
        v.frame = NSRect(x: (b.midX - size.width / 2).rounded(), y: (b.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        v.alphaValue = 0
        root.addSubview(v)
        spaceSwitcher = v
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            v.animator().alphaValue = 1
        }
    }

    func endSpaceSwitch(going: Bool) {
        spaceSwitchShow.cancel()
        spaceSwitchHold?.stop()
        spaceSwitchHold = nil
        if let v = spaceSwitcher {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.fast
                v.animator().alphaValue = 0
            }, completionHandler: { v.removeFromSuperview() })
        }
        spaceSwitcher = nil
        guard let s = spaceSwitch else { return }
        spaceSwitch = nil
        if going, s.order.indices.contains(s.index), s.order[s.index] != selected { hosts.select(s.order[s.index]) }
    }

    /// Debugging: "spaceswitch step|back|end|escape|picture <png>" and what it shows.
    func debugSpaceSwitch(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        switch w.first {
        case "step": debugHeld = true; stepSpaces(1)
        case "back": debugHeld = true; stepSpaces(-1)
        case "show": showSpaceSwitcher()
        case "end": debugHeld = false; endSpaceSwitch(going: true); return "went to \(selected.flatMap { hosts.arrangement($0) }.map { title(of: $0) } ?? "?")"
        case "escape": debugHeld = false; endSpaceSwitch(going: false); return "stayed"
        case "picture":
            guard let v = spaceSwitcher, w.count > 1, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return "none" }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: w[1]))
            return "wrote"
        default: break
        }
        return spaceSwitcher?.debugRows ?? (spaceSwitch.map { "walking, \($0.index) of \($0.order.count), not shown" } ?? "none")
    }
}
