import AppKit
import ManifoldCore

/// The spaces, along the sidebar's foot (§3.6): the sidebar shows one at
/// a time, and here are all of them, as Arc's spaces — each a small
/// square in its colour, its letter or symbol in it; the one shown
/// outlined; a dot at a corner for what most wants you in it (needs you,
/// failed, done and not read); a hairline between one host's and the
/// next's. Clicked, a space is gone to; the pointer on one peeks at it;
/// right-clicked, its menu (its colour, its symbol, its name).
final class SpaceStripView: NSView {
    struct Chip: Equatable {
        var id: BlockID
        var title: String
        /// An SF Symbol, else a letter or two.
        var symbol: String?
        var letter: String
        var color: NSColor
        var current: Bool
        var status: StatusGlyph.Look?
        /// The first of another host's.
        var hostBreak: Bool
    }

    static let height: CGFloat = 36
    static let side: CGFloat = 24
    static let gap: CGFloat = 6

    var onPick: ((BlockID) -> Void)?
    /// The pointer on one (its rect in the window), or off them.
    var onHover: ((BlockID?, NSRect) -> Void)?
    var onMenu: ((BlockID) -> NSMenu?)?

    private(set) var chips: [Chip] = []
    private var frames: [NSRect] = []
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    func show(_ new: [Chip]) {
        guard new != chips else { return }
        chips = new
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // In a row from the left; between hosts a hairline's room.
        var x: CGFloat = 10
        let y = ((bounds.height - Self.side) / 2).rounded()
        frames = chips.map { c in
            if c.hostBreak { x += 7 }
            defer { x += Self.side + Self.gap }
            return NSRect(x: x, y: y, width: Self.side, height: Self.side)
        }
    }

    /// Short of room, they're narrowed together, to as little as a sliver.
    private var squeeze: CGFloat {
        guard let last = frames.last, last.maxX > bounds.width - 8 else { return 1 }
        return max(0.4, (bounds.width - 18) / (last.maxX - 10))
    }

    private func rect(_ i: Int) -> NSRect {
        let k = squeeze, f = frames[i]
        guard k < 1 else { return f }
        let side = (Self.side * max(0.75, k)).rounded()
        return NSRect(x: (10 + (f.minX - 10) * k).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in chips.enumerated() where frames.indices.contains(i) {
            let r = rect(i)
            if c.hostBreak {
                Theme.divider.setFill()
                NSRect(x: r.minX - 7, y: r.midY - 7, width: 1, height: 14).fill()
            }
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            c.color.withAlphaComponent(c.current ? 0.32 : hovered == i ? 0.26 : 0.18).setFill()
            path.fill()
            if c.current {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
                ring.lineWidth = 1.5
                c.color.withAlphaComponent(0.85).setStroke()
                ring.stroke()
            }
            let ink = c.color.blended(withFraction: 0.25, of: Theme.text) ?? c.color
            if let s = c.symbol, let image = Theme.symbol(s, size: 11.5, weight: .semibold, color: ink) {
                let z = image.size
                image.draw(in: NSRect(x: (r.midX - z.width / 2).rounded(), y: (r.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let t = NSAttributedString(string: c.letter, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: ink])
                let z = t.size()
                t.draw(at: NSPoint(x: (r.midX - z.width / 2).rounded(), y: (r.midY - z.height / 2).rounded()))
            }
            // What most wants you there, at its top right.
            if let tone = Self.tone(c.status) {
                let d = NSRect(x: r.maxX - 5, y: r.minY - 2, width: 7, height: 7)
                Theme.panel.setFill()
                NSBezierPath(ovalIn: d.insetBy(dx: -1.5, dy: -1.5)).fill()
                tone.setFill()
                NSBezierPath(ovalIn: d).fill()
            }
        }
    }

    static func tone(_ look: StatusGlyph.Look?) -> NSColor? {
        switch look {
        case .needsYou: Status.attention
        case .failed(read: false): Status.failed
        case .done(read: false): Status.done
        case .working: Status.runningText
        default: nil
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return chips.indices.first { frames.indices.contains($0) && rect($0).insetBy(dx: -Self.gap / 2, dy: -6).contains(p) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { hover(index(at: event)) }
    override func mouseEntered(with event: NSEvent) { hover(index(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ i: Int?) {
        hovered = i
        guard let i else { return onHover?(nil, .zero) ?? () }
        onHover?(chips[i].id, convert(rect(i), to: nil))
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        onHover?(nil, .zero)
        onPick?(chips[i].id)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = index(at: event), let menu = onMenu?(chips[i].id) else { return }
        onHover?(nil, .zero)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Debugging: each, in order — the one shown starred, its status after it.
    var debugChips: String {
        chips.map { c in (c.current ? "*" : "") + (c.hostBreak ? "| " : "") + c.title + " [\(c.symbol ?? c.letter)]" + (c.status.map { " (\($0))" } ?? "") }.joined(separator: "  ")
    }

    func debugHover(_ i: Int?) {
        guard let i, chips.indices.contains(i) else { return hover(nil) }
        hover(i)
    }
}

/// A space's colour and symbol (§3.6), kept on it as annotations
/// (`space.color`, `space.symbol`), so `mani annotate` sets them too.
enum SpaceLook {
    static let colorKey = "space.color"
    static let symbolKey = "space.symbol"

    static let colors: [(name: String, color: NSColor)] = [
        ("red", .systemRed), ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen),
        ("mint", .systemMint), ("teal", .systemTeal), ("blue", .systemBlue), ("indigo", .systemIndigo),
        ("purple", .systemPurple), ("pink", .systemPink), ("brown", .systemBrown), ("gray", .systemGray),
    ]

    /// Symbols to choose from, as the menu offers them.
    static let symbols = ["folder", "terminal", "hammer", "wrench.and.screwdriver", "book", "doc.text", "flask", "globe",
                          "server.rack", "cpu", "chart.bar", "bubble.left.and.bubble.right", "star", "bolt", "leaf", "flame",
                          "paintbrush", "music.note", "gamecontroller", "house"]

    /// Its colour: chosen, else one of the twelve by its name's hash, steady.
    static func color(of block: Block?) -> NSColor {
        if let name = block?.annotations?[colorKey], let c = colors.first(where: { $0.name == name }) { return c.color }
        var h: UInt32 = 2166136261
        for b in (block?.id.description ?? "").utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return colors[Int(h % UInt32(colors.count))].color
    }

    /// Its symbol, if one's chosen.
    static func symbol(of block: Block?) -> String? {
        guard let s = block?.annotations?[symbolKey], !s.isEmpty, NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil else { return nil }
        return s
    }

    /// Its letter: its name's last part's first (`~/src/manifold`, M).
    static func letter(of title: String) -> String {
        let last = title.split(separator: "/").last.map(String.init) ?? title
        let word = last.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return word.first.map { String($0).uppercased() } ?? "·"
    }
}

extension MainWindowController {
    /// The strip's chips: each host's spaces, in its desk's order, a host's
    /// first set apart from the one before.
    func spaceChips() -> [SpaceStripView.Chip] {
        var out: [SpaceStripView.Chip] = []
        for c in hosts.ordered {
            var ids = c.desk.order.filter { $0.host == c.host && allWorkspaces.contains($0) }
            for id in allWorkspaces where id.host == c.host && !ids.contains(id) { ids.append(id) }
            for (i, id) in ids.enumerated() {
                guard let b = hosts.block(id), let a = hosts.arrangement(id) else { continue }
                let name = title(of: a)
                out.append(.init(id: id, title: name, symbol: SpaceLook.symbol(of: b), letter: SpaceLook.letter(of: name),
                                 color: SpaceLook.color(of: b), current: id == selected, status: spaceStatus(a),
                                 hostBreak: i == 0 && !out.isEmpty))
            }
        }
        return out
    }

    /// What most wants you in a space: needs you, then failed, then done
    /// (neither read), then working.
    func spaceStatus(_ a: ArrangementState) -> StatusGlyph.Look? {
        let looks = a.placements.compactMap { StatusGlyph.look(of: hosts.block($0.block)) }
        func rank(_ l: StatusGlyph.Look) -> Int? {
            switch l {
            case .needsYou: 0
            case .failed(read: false): 1
            case .done(read: false): 2
            case .working: 3
            default: nil
            }
        }
        return looks.filter { rank($0) != nil }.min { rank($0)! < rank($1)! }
    }

    func refreshSpaceStrip() {
        let strip = sidebar.spaces
        if strip.onPick == nil {
            strip.onPick = { [weak self] id in
                guard let self, id != self.selected else { return }
                if self.stateView != nil { self.hideStateView() }
                self.hosts.select(id)
            }
            strip.onHover = { [weak self] id, rect in
                guard let self, let window = self.window, let id else { return HoverCard.shared.hide() }
                self.peekSpace(id, beside: rect, in: window)
            }
            strip.onMenu = { [weak self] id in self?.spaceMenu(id) }
            sidebar.onSwipe = { [weak self] step in self?.switchSpace(by: step) }
        }
        strip.show(spaceChips())
    }

    /// The space `step` along the strip from the one shown (1, the next),
    /// gone to — a swipe across the sidebar; none past either end.
    func switchSpace(by step: Int) {
        let order = sidebar.spaces.chips.map(\.id)
        guard let here = selected, let i = order.firstIndex(of: here), order.indices.contains(i + step) else { return NSSound.beep() }
        if stateView != nil { hideStateView() }
        hosts.select(order[i + step])
    }

    /// A space peeked at from the strip: its name, where, and its tiles —
    /// what wants you first, each with what its status says.
    private func peekSpace(_ id: BlockID, beside rect: NSRect, in window: NSWindow) {
        guard let a = hosts.arrangement(id) else { return HoverCard.shared.hide() }
        var detail = a.placements.count == 1 ? "1 tile" : "\(a.placements.count) tiles"
        if !a.docked.isEmpty { detail += ", \(a.docked.count) docked" }
        if hosts.ordered.count > 1 { detail += " · on \(hosts.label(of: id.host))" }
        func line(_ p: Placement, docked: Bool) -> (Int, String) {
            let b = hosts.block(p.block)
            let rank = switch StatusGlyph.look(of: b) { case .needsYou: 0; case .failed(read: false): 1; case .done(read: false): 2; default: 3 }
            var s = (b.map(Self.linkTitle) ?? "?")
            if let r = StatusGlyph.remark(b) { s += " — " + r }
            if docked { s += "  (docked)" }
            return (rank, s)
        }
        let lines = (a.columns.flatMap { $0 }.map { line($0, docked: false) } + a.docked.reversed().map { line($0.placement, docked: true) })
            .enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        let body = lines.prefix(12).joined(separator: "\n") + (lines.count > 12 ? "\n…and \(lines.count - 12) more" : "")
        HoverCard.shared.show(key: "space/" + id.description, title: title(of: a), detail: detail, body: body, font: nil,
                              beside: rect, in: window, delay: 0.3, above: true)
    }

    /// A space's menu, from its square in the strip: its colour, its
    /// symbol, its name; taken off the desk.
    private func spaceMenu(_ id: BlockID) -> NSMenu? {
        guard let b = hosts.block(id) else { return nil }
        let menu = NSMenu()
        let colors = NSMenu()
        let chosenColor = b.annotations?[SpaceLook.colorKey]
        for (name, color) in SpaceLook.colors {
            let item = NSMenuItem(title: name.capitalized, action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (id, SpaceLook.colorKey, name)
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                color.setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            item.state = chosenColor == name ? .on : .off
            colors.addItem(item)
        }
        colors.addItem(.separator())
        let auto = NSMenuItem(title: "Automatic", action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = (id, SpaceLook.colorKey, "")
        auto.state = chosenColor == nil ? .on : .off
        colors.addItem(auto)
        let colorItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        let symbols = NSMenu()
        let chosenSymbol = SpaceLook.symbol(of: b)
        let letter = NSMenuItem(title: "Letter (\(SpaceLook.letter(of: b.arrangement.map(title(of:)) ?? "")))", action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
        letter.target = self
        letter.representedObject = (id, SpaceLook.symbolKey, "")
        letter.state = chosenSymbol == nil ? .on : .off
        symbols.addItem(letter)
        symbols.addItem(.separator())
        for s in SpaceLook.symbols {
            let item = NSMenuItem(title: s, action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (id, SpaceLook.symbolKey, s)
            item.image = Theme.symbol(s, size: 13)
            item.state = chosenSymbol == s ? .on : .off
            symbols.addItem(item)
        }
        let symbolItem = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "")
        symbolItem.submenu = symbols
        menu.addItem(symbolItem)
        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameSpaceFromStrip(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = id
        menu.addItem(rename)
        let remove = NSMenuItem(title: "Take Off the Desk", action: #selector(removeSpaceFromStrip(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        menu.addItem(remove)
        return menu
    }

    @objc func chooseSpaceLook(_ sender: NSMenuItem) {
        guard let (id, key, value) = sender.representedObject as? (BlockID, String, String) else { return }
        setSpaceLook(id, key, value)
    }

    func setSpaceLook(_ id: BlockID, _ key: String, _ value: String) {
        hosts.append(.annotate([key: value]), to: .block(id))
    }

    @objc func renameSpaceFromStrip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? BlockID { sidebarRename(id) }
    }

    @objc func removeSpaceFromStrip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? BlockID { sidebarRemove(id) }
    }

    /// Debugging the strip: `spaces` its squares; `spaces hover <i>|off`;
    /// `spaces pick <i>`; `spaces color <i> <name>`; `spaces symbol <i> <name>`.
    func debugSpaces(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        let strip = sidebar.spaces
        refreshSpaceStrip()
        func chip(_ s: String?) -> BlockID? { s.flatMap(Int.init).flatMap { strip.chips.indices.contains($0) ? strip.chips[$0].id : nil } }
        switch w.first {
        case "hover": strip.debugHover(w.dropFirst().first.flatMap(Int.init))
        case "pick": if let id = chip(w.dropFirst().first) { strip.onPick?(id) }
        case "swipe": switchSpace(by: w.dropFirst().first == "back" ? -1 : 1)
        case "color", "symbol":
            if let id = chip(w.dropFirst().first) { setSpaceLook(id, w[0] == "color" ? SpaceLook.colorKey : SpaceLook.symbolKey, w.count > 2 ? w[2] : "") }
        default: break
        }
        return strip.debugChips
    }
}
