import AppKit
import ManifoldCore

/// ⌘` (§3.6): the spaces, the most recently settled on first, as cards
/// over the window while ⌘ is held — each a picture of
/// its grid: its tiles in their columns at their sizes, each its last
/// picture (else its symbol and name), the focused one ringed; over it
/// its square, its name, its host, what wants you there. ` steps on, ⇧`
/// back; letting go of ⌘ goes to the one chosen, ⎋ stays.
final class SpaceSwitcherView: NSView {
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
        var letter: String
        var symbol: String?
        var color: NSColor
        var status: StatusGlyph.Look?
        var tiles: [Tile]
        var docked: Int
    }

    var cards: [Card] = [] { didSet { needsLayout = true; canvas.needsDisplay = true } }
    var chosen = 0 { didSet { if chosen != oldValue { canvas.needsDisplay = true } } }
    /// What the cards are drawn in, over the frosted ground.
    private let canvas = Canvas()
    var onPick: ((Int) -> Void)?

    static let cardSize = NSSize(width: 236, height: 176)
    static let gap: CGFloat = 14
    static let pad: CGFloat = 18
    static let perRow = 4
    private let ground = NSVisualEffectView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        shadow = NSShadow()
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 24
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        ground.material = .popover
        ground.blendingMode = .withinWindow
        ground.state = .active
        ground.wantsLayer = true
        ground.layer?.cornerRadius = 16
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        addSubview(ground)
        canvas.owner = self
        addSubview(canvas)
    }

    private final class Canvas: NSView {
        weak var owner: SpaceSwitcherView?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { owner?.drawCards() }
        // A card clicked goes there: the pointing hand.
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { owner?.mouseUp(with: event) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its size for its cards, as many rows as they take (three at most shown).
    var wantedSize: NSSize {
        let n = max(cards.count, 1)
        let cols = min(n, Self.perRow), rows = min((n + Self.perRow - 1) / Self.perRow, 3)
        return NSSize(width: Self.pad * 2 + CGFloat(cols) * Self.cardSize.width + CGFloat(cols - 1) * Self.gap,
                      height: Self.pad * 2 + CGFloat(rows) * Self.cardSize.height + CGFloat(rows - 1) * Self.gap)
    }

    private func cardRect(_ i: Int) -> NSRect {
        let col = i % Self.perRow, row = i / Self.perRow
        return NSRect(x: Self.pad + CGFloat(col) * (Self.cardSize.width + Self.gap),
                      y: Self.pad + CGFloat(row) * (Self.cardSize.height + Self.gap),
                      width: Self.cardSize.width, height: Self.cardSize.height)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        canvas.frame = bounds
    }

    fileprivate func drawCards() {
        for (i, c) in cards.enumerated() where i < Self.perRow * 3 {
            let r = cardRect(i)
            let lit = i == chosen
            // The card: a band of its colour under it when chosen.
            let body = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            (lit ? c.color.withAlphaComponent(0.22) : Theme.text.withAlphaComponent(0.04)).setFill()
            body.fill()
            if lit {
                body.lineWidth = 2
                c.color.withAlphaComponent(0.85).setStroke()
                body.stroke()
            }
            // Its head: its square, its name, its host; what wants you there.
            let sq = NSRect(x: r.minX + 10, y: r.minY + 10, width: 20, height: 20)
            c.color.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: sq, xRadius: 5, yRadius: 5).fill()
            let ink = c.color.blended(withFraction: 0.25, of: Theme.text) ?? c.color
            if let s = c.symbol, let image = Theme.symbol(s, size: 10, weight: .semibold, color: ink) {
                let z = image.size
                image.draw(in: NSRect(x: sq.midX - z.width / 2, y: sq.midY - z.height / 2, width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let t = NSAttributedString(string: c.letter, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: ink])
                let z = t.size()
                t.draw(at: NSPoint(x: sq.midX - z.width / 2, y: sq.midY - z.height / 2))
            }
            var right = r.maxX - 10
            if let tone = SpaceStripView.tone(c.status) {
                tone.setFill()
                NSBezierPath(ovalIn: NSRect(x: right - 8, y: sq.midY - 4, width: 8, height: 8)).fill()
                right -= 14
            }
            let name = NSAttributedString(string: c.name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
            name.draw(with: NSRect(x: sq.maxX + 8, y: sq.minY + 1, width: max(0, right - sq.maxX - 8), height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            // The grid, in miniature.
            let foot: CGFloat = c.docked > 0 || c.host != nil ? 18 : 6
            let map = NSRect(x: r.minX + 10, y: sq.maxY + 8, width: r.width - 20, height: r.maxY - sq.maxY - 8 - 10 - foot)
            drawMap(c, in: map)
            var words: [String] = []
            if let h = c.host { words.append(h) }
            if c.docked > 0 { words.append(c.docked == 1 ? "1 docked" : "\(c.docked) docked") }
            if !words.isEmpty {
                NSAttributedString(string: words.joined(separator: " · "), attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])
                    .draw(with: NSRect(x: map.minX, y: map.maxY + 4, width: map.width, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    private func drawMap(_ c: Card, in map: NSRect) {
        guard !c.tiles.isEmpty else {
            Theme.text.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: map, xRadius: 6, yRadius: 6).fill()
            NSAttributedString(string: "Empty", attributes: [.font: UIType.footnote, .foregroundColor: Theme.tertiaryText])
                .draw(at: NSPoint(x: map.midX - 14, y: map.midY - 7))
            return
        }
        for t in c.tiles {
            let f = NSRect(x: map.minX + t.frame.minX * map.width, y: map.minY + t.frame.minY * map.height,
                           width: t.frame.width * map.width, height: t.frame.height * map.height).insetBy(dx: 1.5, dy: 1.5)
            guard f.width > 4, f.height > 3 else { continue }
            let path = NSBezierPath(roundedRect: f, xRadius: 4, yRadius: 4)
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
            Theme.text.withAlphaComponent(0.05).setFill()
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
            if t.picture == nil, f.height > 30, let image = Theme.symbol(t.symbol, size: 14, weight: .regular, color: Theme.tertiaryText) {
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
    /// The spaces, as ⌘` walks them: here, then those settled on, the
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
        return .init(id: id, name: name, host: hosts.ordered.count > 1 ? hosts.label(of: id.host) : nil,
                     letter: SpaceLook.letter(of: name), symbol: SpaceLook.symbol(of: b), color: SpaceLook.color(of: b),
                     status: spaceStatus(a), tiles: tiles, docked: a.docked.count)
    }

    /// ⌘` (⇧⌘` back): a step through the spaces with ⌘ held, their cards
    /// shown a moment after (a quick ⌘` flashes nothing, and goes back to
    /// the space before); letting go of ⌘ goes to the one chosen. With one
    /// space, the app's next window, as macOS has it.
    @objc func switchSpace(_ sender: Any?) { stepSpaces(1) }
    @objc func switchSpaceBack(_ sender: Any?) { stepSpaces(-1) }

    private func stepSpaces(_ step: Int) {
        if let s = spaceSwitch {
            // Its key let go unheard (the app left meanwhile): over.
            guard NSEvent.modifierFlags.contains(.command) || debugHeld else { return endSpaceSwitch(going: true) }
            let n = s.order.count
            spaceSwitch?.index = ((s.index + step) % n + n) % n
            spaceSwitcher?.chosen = spaceSwitch!.index
            return
        }
        let order = spaceTrail()
        guard order.count > 1 else { return cycleWindows(back: step < 0) }
        let index = ((step) % order.count + order.count) % order.count
        // From the menu, ⌘ not held: one step, gone.
        guard NSEvent.modifierFlags.contains(.command) || debugHeld else { return hosts.select(order[index]) }
        spaceSwitch = (order, index)
        // Shown in a moment, if ⌘'s still held.
        spaceSwitchShow.schedule(after: 0.2) { [weak self] in self?.showSpaceSwitcher() }
        spaceSwitchHold = ModifierHold(.command, released: { [weak self] in self?.endSpaceSwitch(going: true) },
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
