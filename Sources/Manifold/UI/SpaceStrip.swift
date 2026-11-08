import AppKit
import ManifoldCore

/// The spaces, along the sidebar's foot (§3.6): the sidebar shows one at
/// a time, and here are all of them, as Arc's spaces — each a small
/// square in its colour, its letter or symbol in it; the one shown
/// outlined; a dot at a corner for what most wants you in it (needs you,
/// failed, done and not read); a hairline between one host's and the
/// next's. Clicked, a space is gone to; the pointer on one peeks at it;
/// right-clicked, its menu (its colour, its symbol, its name). After
/// them a +: clicked, a new space, on the shown one's host; the pointer
/// on it, with more than one host, a list of them to make it on.
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

    /// One row's height; more rows, each `side + gap` more.
    static let height: CGFloat = 36
    static let side: CGFloat = 24
    static let gap: CGFloat = 6
    static let inset: CGFloat = SidebarView.margin

    var onPick: ((BlockID) -> Void)?
    /// The pointer on one (its rect in the window), or off them.
    var onHover: ((BlockID?, NSRect) -> Void)?
    var onMenu: ((BlockID) -> NSMenu?)?
    /// The + clicked.
    var onNew: (() -> Void)?
    /// The pointer on the + (its rect in the window), or off it.
    var onPlusHover: ((NSRect?) -> Void)?

    private(set) var chips: [Chip] = []
    private var frames: [NSRect] = []
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    /// Something dragged onto a space's square (its rect in the window),
    /// with ⌥ (copied) or not; true if it was taken.
    var onDrop: ((NSPasteboard, BlockID, Bool, NSRect) -> Bool)?
    /// Held over a square a moment, mid-drag: that space gone to, for the
    /// drop to land where it's wanted in it.
    var onSpring: ((BlockID) -> Void)?
    private var dropTarget: Int? { didSet { if dropTarget != oldValue { needsDisplay = true } } }
    private var spring: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.manifoldPlacement, .manifoldBlock])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let i = chips.indices.first { frames.indices.contains($0) && rect($0).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(p) && !chips[$0].current }
        if i != dropTarget {
            dropTarget = i
            spring?.cancel()
            if let i {
                let id = chips[i].id
                let work = DispatchWorkItem { [weak self] in
                    self?.dropTarget = nil
                    self?.onSpring?(id)
                }
                spring = work
                // As long as the system springs a folder open (none, if it's off).
                if let delay = OrganizationView.springDelay { DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3, execute: work) }
            }
        }
        guard i != nil else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        spring?.cancel()
        dropTarget = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        spring?.cancel()
        defer { dropTarget = nil }
        guard let i = dropTarget else { return false }
        return onDrop?(sender.draggingPasteboard, chips[i].id, NSEvent.modifierFlags.contains(.option), convert(rect(i), to: nil)) ?? false
    }

    func show(_ new: [Chip]) {
        guard new != chips else { return }
        let rows = wantedHeight(width: bounds.width)
        chips = new
        if wantedHeight(width: bounds.width) != rows { superview?.superview?.needsLayout = true }
        needsLayout = true
        needsDisplay = true
    }

    /// Where each goes at a width, the + last: in rows from the left,
    /// another row when one's full; between hosts a hairline's room (none
    /// at a row's start). And which squares have a hairline before them.
    private func place(width: CGFloat) -> (frames: [NSRect], breaks: Set<Int>) {
        var out: [NSRect] = [], breaks: Set<Int> = []
        var x = Self.inset, y = (Self.height - Self.side) / 2
        for i in 0...chips.count {
            let isPlus = i == chips.count
            var lead: CGFloat = isPlus ? 2 : chips[i].hostBreak ? 7 : 0
            if x > Self.inset, x + lead + Self.side > width - 8 {
                x = Self.inset
                y += Self.side + Self.gap
                lead = 0
            }
            if lead == 7 { breaks.insert(i) }
            x += lead
            out.append(NSRect(x: x, y: y.rounded(), width: Self.side, height: Self.side))
            x += Self.side + Self.gap
        }
        return (out, breaks)
    }

    /// Its height at a width: as many rows as it takes.
    func wantedHeight(width: CGFloat) -> CGFloat {
        guard let last = place(width: width).frames.last else { return Self.height }
        return last.maxY + (Self.height - Self.side) / 2
    }

    private var breaks: Set<Int> = []

    override func layout() {
        super.layout()
        (frames, breaks) = place(width: bounds.width)
    }

    /// The +'s index among the frames.
    private var plus: Int { chips.count }
    /// Where the + is.
    var plusRect: NSRect { frames.indices.contains(plus) ? rect(plus) : .zero }

    private func rect(_ i: Int) -> NSRect { frames[i] }
    func squareRect(_ i: Int) -> NSRect { frames.indices.contains(i) ? frames[i] : .zero }

    override func draw(_ dirtyRect: NSRect) {
        if frames.indices.contains(plus) {
            // The +: quiet, outlined, filled a little under the pointer.
            let r = rect(plus)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            if hovered == plus {
                Theme.text.withAlphaComponent(0.08).setFill()
                path.fill()
            }
            Theme.text.withAlphaComponent(hovered == plus ? 0.3 : 0.16).setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.stroke()
            if let image = Theme.symbol("plus", size: 11, weight: .semibold, color: hovered == plus ? Theme.text : Theme.secondaryText) {
                let z = image.size
                image.draw(in: NSRect(x: (r.midX - z.width / 2).rounded(), y: (r.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        for (i, c) in chips.enumerated() where frames.indices.contains(i) {
            let r = rect(i)
            if breaks.contains(i) {
                Theme.divider.setFill()
                NSRect(x: r.minX - 7, y: r.midY - 7, width: 1, height: 14).fill()
            }
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            c.color.withAlphaComponent(c.current ? 0.32 : hovered == i || dropTarget == i ? 0.26 : 0.18).setFill()
            path.fill()
            if dropTarget == i {
                // Something held over it, to go there.
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: 8, yRadius: 8)
                ring.lineWidth = 2
                Theme.accent.setStroke()
                ring.stroke()
            }
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

    /// The square under the pointer, or the + (`plus`).
    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return frames.indices.first { rect($0).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(p) }
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
        let was = hovered
        hovered = i
        if i == plus {
            onHover?(nil, .zero)
            if was != plus { onPlusHover?(convert(rect(plus), to: nil)) }
            return
        }
        if was == plus { onPlusHover?(nil) }
        guard let i else { return onHover?(nil, .zero) ?? () }
        onHover?(chips[i].id, convert(rect(i), to: nil))
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        onHover?(nil, .zero)
        if i == plus { return onNew?() ?? () }
        onPick?(chips[i].id)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = index(at: event), i != plus, let menu = onMenu?(chips[i].id) else { return }
        onHover?(nil, .zero)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Debugging: each, in order — the one shown starred, its status after it.
    var debugChips: String {
        chips.map { c in (c.current ? "*" : "") + (c.hostBreak ? "| " : "") + c.title + " [\(c.symbol ?? c.letter)]" + (c.status.map { " (\($0))" } ?? "") }.joined(separator: "  ")
    }

    func debugHover(_ i: Int?) {
        guard let i, frames.indices.contains(i) else { return hover(nil) }
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
    static let symbols: [(symbol: String, name: String)] = [
        ("folder", "Folder"), ("terminal", "Terminal"), ("hammer", "Hammer"), ("wrench.and.screwdriver", "Tools"),
        ("book", "Book"), ("doc.text", "Document"), ("flask", "Flask"), ("globe", "Globe"),
        ("server.rack", "Server"), ("cpu", "Chip"), ("chart.bar", "Chart"), ("bubble.left.and.bubble.right", "Conversation"),
        ("star", "Star"), ("bolt", "Bolt"), ("leaf", "Leaf"), ("flame", "Flame"),
        ("paintbrush", "Brush"), ("music.note", "Music"), ("gamecontroller", "Game"), ("house", "House"),
    ]

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
            strip.onDrop = { [weak self] pb, id, copy, square in
                guard let self, let item = OrgDragItem(pb) else { return false }
                return self.dropOnSpace(item, space: id, copy: copy, square: self.root.convert(square, from: nil))
            }
            strip.onSpring = { [weak self] id in
                guard let self, id != self.selected else { return }
                self.hosts.select(id)
            }
            wirePlus()
            sidebar.footer.threads.onClick = { [weak self] in self?.showFooterMenu(.threads) }
            sidebar.footer.tiles.onClick = { [weak self] in self?.showFooterMenu(.tiles) }
        }
        // Threads with something not seen, in the space shown.
        if let space = selected {
            let n = hosts.threads(inSpace: space).filter { !hosts.unseen($0).isEmpty }.count
            if sidebar.footer.threads.count != n { sidebar.footer.threads.count = n; sidebar.footer.needsLayout = true }
        }
        strip.show(spaceChips())
        refreshNeedsYou()
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
            item.showImage()
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
        for (s, name) in SpaceLook.symbols {
            let item = NSMenuItem(title: name, action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (id, SpaceLook.symbolKey, s)
            item.setSymbol(s, size: 13)
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
        case "needs": return sidebar.needsYou.debugRows
        case "host":
            // "spaces host [hover]": the heading's host line; with hover, its card.
            if w.dropFirst().first == "hover" {
                let v = sidebar.spaceHost
                v.onHover?(v.convert(NSRect(x: 0, y: 0, width: 80, height: v.bounds.height), to: nil))
            }
            return sidebar.spaceHost.debugText
        case "plus":
            // "spaces plus": the hosts' list over the + (even for one host);
            // "spaces plus new": the + clicked; "spaces plus pick <i>": host i chosen.
            switch w.dropFirst().first {
            case "new": strip.onNew?()
            case "pick":
                let rows = sidebar.hostPicker.rows
                if let i = w.dropFirst(2).first.flatMap(Int.init), rows.indices.contains(i) { sidebar.hostPicker.onPick?(rows[i].host) }
            case "off": hideHostPicker(now: true)
            default:
                showHostPicker(over: strip.convert(strip.plusRect, to: nil), always: true)
                return sidebar.hostPicker.debugRows + " · picker \(sidebar.hostPicker.frame.integral)"
            }
        case "drop":
            // "spaces drop <i> [copy]": the focused tile dropped on square i.
            guard let i = w.dropFirst().first.flatMap(Int.init), strip.chips.indices.contains(i), let f = arrangement?.focused else { return "no" }
            let square = root.convert(strip.convert(strip.squareRect(i), to: nil), from: nil)
            _ = dropOnSpace(.placement(f), space: strip.chips[i].id, copy: w.last == "copy", square: square)
        case "needspick": if let i = w.dropFirst().first.flatMap(Int.init), sidebar.needsYou.items.indices.contains(i) { sidebar.needsYou.onPick?(sidebar.needsYou.items[i]) }
        case "color", "symbol":
            if let id = chip(w.dropFirst().first) { setSpaceLook(id, w[0] == "color" ? SpaceLook.colorKey : SpaceLook.symbolKey, w.count > 2 ? w[2] : "") }
        default: break
        }
        return strip.debugChips
    }
}

/// What needs you, in every space (§3.6), at the sidebar's foot, always
/// there whichever space is shown: a row each — its space's square, its
/// symbol and name, what it needs in a pill — the space shown's too, as
/// the strip has them, left to right, then as each grid has them. Clicked,
/// gone to, in its space. Five at most, then how many more, clicked, all
/// of them (and "Fewer" again); none, nothing there at all.
final class NeedsYouView: NSView {
    struct Item: Equatable {
        var space: BlockID
        var tile: PlacementID
        var title: String
        var symbol: String
        var spaceLetter: String
        var spaceSymbol: String?
        var spaceColor: NSColor
        var need: String
    }

    static let headHeight: CGFloat = 22
    static let rowHeight: CGFloat = 24
    static let most = 5

    var onPick: ((Item) -> Void)?
    /// Its height changed (more shown, or fewer).
    var onResize: (() -> Void)?
    private(set) var items: [Item] = []
    /// All of them shown, not the first five.
    private var all = false
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    func show(_ new: [Item]) {
        guard new != items else { return }
        items = new
        if items.count <= Self.most { all = false }
        hovered = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Rows of items shown, and whether a row after them says more (or fewer).
    private var shown: Int { all ? items.count : min(items.count, Self.most) }
    private var hasMoreRow: Bool { items.count > Self.most }

    var wantedHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        let rows = shown + (hasMoreRow ? 1 : 0)
        return Self.headHeight + CGFloat(rows) * Self.rowHeight + 4
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 6, y: Self.headHeight + CGFloat(i) * Self.rowHeight, width: bounds.width - 12, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return }
        // A hairline over it, apart from the space's rows.
        Theme.divider.setFill()
        NSRect(x: 12, y: 0, width: bounds.width - 24, height: 1).fill()
        NSAttributedString(string: "Needs you", attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: Status.attention])
            .draw(at: NSPoint(x: SidebarView.margin + 2, y: 5))
        if items.count > 1 {
            let n = NSAttributedString(string: "\(items.count)", attributes: [.font: UIType.count, .foregroundColor: Theme.secondaryText])
            n.draw(at: NSPoint(x: bounds.width - 18 - n.size().width, y: 6))
        }
        for (i, item) in items.prefix(shown).enumerated() {
            let r = rowRect(i)
            if hovered == i {
                Theme.text.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            // Its space's square, small.
            let sq = NSRect(x: SidebarView.margin, y: r.midY - 8, width: 16, height: 16)
            item.spaceColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: sq, xRadius: 4, yRadius: 4).fill()
            let sInk = item.spaceColor.blended(withFraction: 0.25, of: Theme.text) ?? item.spaceColor
            if let s = item.spaceSymbol, let image = Theme.symbol(s, size: 8.5, weight: .semibold, color: sInk) {
                let z = image.size
                image.draw(in: NSRect(x: (sq.midX - z.width / 2).rounded(), y: (sq.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let t = NSAttributedString(string: item.spaceLetter, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: sInk])
                let z = t.size()
                t.draw(at: NSPoint(x: (sq.midX - z.width / 2).rounded(), y: (sq.midY - z.height / 2).rounded()))
            }
            if let image = Theme.symbol(item.symbol, size: 11, weight: .regular, color: Theme.secondaryText) {
                let z = image.size
                image.draw(in: NSRect(x: sq.maxX + 8, y: (r.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let pill = StatusPill.Kind.needs(item.need)
            let ps = StatusPill.size(pill)
            let pr = NSRect(x: r.maxX - 6 - ps.width, y: (r.midY - ps.height / 2).rounded(), width: ps.width, height: ps.height)
            StatusPill.draw(pill, in: pr)
            let x = sq.maxX + 28
            NSAttributedString(string: item.title, attributes: [.font: UIType.row, .foregroundColor: Theme.text])
                .draw(with: NSRect(x: x, y: r.midY - 8, width: max(0, pr.minX - 8 - x), height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if hasMoreRow {
            let r = rowRect(shown)
            NSAttributedString(string: all ? "Fewer" : "\(items.count - Self.most) more…", attributes: [.font: UIType.detail, .foregroundColor: hovered == shown ? Theme.text : Theme.secondaryText])
                .draw(at: NSPoint(x: SidebarView.margin + 2, y: r.midY - 7))
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let n = shown + (hasMoreRow ? 1 : 0)
        return (0..<n).first { rowRect($0).contains(p) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        if hasMoreRow, i == shown {
            all.toggle()
            hovered = nil
            needsDisplay = true
            onResize?()
        } else {
            onPick?(items[i])
        }
    }

    var debugRows: String {
        items.isEmpty ? "nothing needs you" : items.map { "\($0.spaceLetter) \($0.title) [\($0.need)]" }.joined(separator: " | ")
    }
}

extension MainWindowController {
    /// What needs you, in every space: as the strip has them, then as each
    /// grid has them (on screen, then docked).
    func needsYouItems() -> [NeedsYouView.Item] {
        var out: [NeedsYouView.Item] = []
        for chip in sidebar.spaces.chips {
            guard let a = hosts.arrangement(chip.id) else { continue }
            for p in a.columns.flatMap({ $0 }) + a.docked.reversed().map(\.placement) {
                guard let b = hosts.block(p.block), StatusGlyph.look(of: b) == .needsYou else { continue }
                out.append(.init(space: chip.id, tile: p.id, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b),
                                 spaceLetter: chip.letter, spaceSymbol: chip.symbol, spaceColor: chip.color,
                                 need: StatusPill.words(b.statusRecord?.kind)))
            }
        }
        return out
    }

    func refreshNeedsYou() {
        let v = sidebar.needsYou
        if v.onPick == nil {
            v.onPick = { [weak self] item in self?.go(to: Settled(space: item.space, tile: item.tile)) }
            v.onResize = { [weak self] in self?.sidebar.needsLayout = true }
        }
        let before = v.wantedHeight
        v.show(needsYouItems())
        if v.wantedHeight != before { sidebar.needsLayout = true }
    }
}

/// The hosts to make a new space on (§3.6), over the strip's + while the
/// pointer's on it: a row each — whether it's connected, its name, how
/// many spaces it has — the shown space's host marked. Clicked, a new
/// space there.
final class HostPickerView: NSView {
    struct Row: Equatable {
        var host: HostID
        var label: String
        var spaces: Int
        var connected: Bool
        var here: Bool
    }

    static let headHeight: CGFloat = 24
    static let rowHeight: CGFloat = 26
    static let width: CGFloat = 220

    var onPick: ((HostID) -> Void)?
    /// The pointer in it, or gone out of it.
    var onInside: ((Bool) -> Void)?
    private(set) var rows: [Row] = []
    private(set) var inside = false
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        themed { v in
            v.layer?.backgroundColor = Theme.panel.cgColor
            v.layer?.borderColor = Theme.panelBorder.cgColor
            v.layer?.borderWidth = 0.5
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ new: [Row]) {
        rows = new
        hovered = nil
        needsDisplay = true
    }

    var wantedHeight: CGFloat { Self.headHeight + CGFloat(rows.count) * Self.rowHeight + 6 }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 4, y: Self.headHeight + CGFloat(i) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: "New space on", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.secondaryText])
            .draw(at: NSPoint(x: 12, y: 6))
        for (i, row) in rows.enumerated() {
            let r = rowRect(i)
            if hovered == i {
                Theme.accent.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let lit = hovered == i
            let dot = NSRect(x: r.minX + 9, y: r.midY - 3.5, width: 7, height: 7)
            (row.connected ? Status.done : Theme.tertiaryText).withAlphaComponent(lit ? 1 : 0.9).setFill()
            NSBezierPath(ovalIn: dot).fill()
            let count = NSAttributedString(string: row.spaces == 1 ? "1 space" : "\(row.spaces) spaces",
                                           attributes: [.font: UIType.detail, .foregroundColor: lit ? NSColor.white.withAlphaComponent(0.8) : Theme.tertiaryText])
            let cz = count.size()
            count.draw(at: NSPoint(x: r.maxX - 10 - cz.width, y: r.midY - cz.height / 2))
            var x = dot.maxX + 9
            if row.here, let image = Theme.symbol("checkmark", size: 10, weight: .semibold, color: lit ? .white : Theme.accent) {
                let z = image.size
                image.draw(in: NSRect(x: x, y: (r.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += z.width + 6
            }
            NSAttributedString(string: row.label, attributes: [.font: UIType.row, .foregroundColor: lit ? NSColor.white : row.connected ? Theme.text : Theme.secondaryText])
                .draw(with: NSRect(x: x, y: r.midY - 8, width: max(0, r.maxX - 16 - cz.width - x), height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return rows.indices.first { rowRect($0).contains(p) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { inside = true; hovered = index(at: event); onInside?(true) }
    override func mouseMoved(with event: NSEvent) { hovered = index(at: event) }
    override func mouseExited(with event: NSEvent) { inside = false; hovered = nil; onInside?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        onPick?(rows[i].host)
    }

    var debugRows: String {
        rows.map { ($0.here ? "✓ " : "") + $0.label + " (\($0.spaces))" + ($0.connected ? "" : " offline") }.joined(separator: " | ")
    }
}

extension MainWindowController {
    /// The hosts a new space can go on, for the +'s list.
    func hostPickerRows() -> [HostPickerView.Row] {
        let here = selected?.host ?? focusedHost
        return hosts.ordered.map { c in
            .init(host: c.host, label: hosts.label(of: c.host), spaces: allWorkspaces.filter { $0.host == c.host }.count,
                  connected: c.isConnected || c === hosts.local, here: c.host == here)
        }
    }

    /// The + in the strip: clicked, a new space on the shown space's host;
    /// the pointer on it, with more than one host, the list of them over
    /// it, kept while the pointer's on either.
    func wirePlus() {
        let strip = sidebar.spaces, picker = sidebar.hostPicker
        strip.onNew = { [weak self] in
            guard let self else { return }
            self.hideHostPicker(now: true)
            self.newWorkspace(on: self.selected?.host ?? self.focusedHost, cwd: nil)
        }
        strip.onPlusHover = { [weak self] rect in
            guard let self else { return }
            guard let rect else { return self.hideHostPicker() }
            self.showHostPicker(over: rect)
        }
        picker.onInside = { [weak self] inside in if !inside { self?.hideHostPicker() } }
        picker.onPick = { [weak self] host in
            guard let self else { return }
            self.hideHostPicker(now: true)
            if self.stateView != nil { self.hideStateView() }
            self.newWorkspace(on: host, cwd: nil)
        }
    }

    func showHostPicker(over rect: NSRect, always: Bool = false) {
        pickerHide?.cancel()
        let rows = hostPickerRows()
        guard rows.count > 1 || always else { return }
        sidebar.showHostPicker(rows, over: rect)
    }

    /// Put away a moment after the pointer leaves the + and the list, if
    /// it hasn't come back to either.
    func hideHostPicker(now: Bool = false) {
        pickerHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, now || !self.sidebar.hostPicker.inside else { return }
            self.sidebar.hideHostPicker()
        }
        pickerHide = work
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work) }
    }
}
