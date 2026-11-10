import AppKit
import ManifoldCore

/// A space's square — in the strip, beside what needs you, on ⌘`'s
/// cards — at any size alike: rounded a quarter of its height, its symbol
/// (else its letter) in its colour, a little darker, about half its height.
enum SpaceSquare {
    static func radius(_ r: NSRect) -> CGFloat { r.height / 4 }

    /// Its ground: the colour, as strong as `alpha`.
    static func fill(_ r: NSRect, color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius(r), yRadius: radius(r)).fill()
    }

    /// Its symbol, else its letter, centred.
    static func drawGlyph(in r: NSRect, color: NSColor, symbol: String?, letter: String) {
        let ink = color.blended(withFraction: 0.25, of: Theme.text) ?? color
        let size = max(8.5, (r.height * 0.48 * 2).rounded() / 2)
        if let symbol, let image = Theme.symbol(symbol, size: size, weight: .semibold, color: ink) {
            return image.draw(centeredAt: NSPoint(x: r.midX, y: r.midY))
        }
        let t = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: size, weight: r.height >= 24 ? .semibold : .bold), .foregroundColor: ink])
        let z = t.size()
        t.draw(at: NSPoint(x: (r.midX - z.width / 2).rounded(), y: (r.midY - z.height / 2).rounded()))
    }
}

/// The spaces, at the sidebar's top (§3.6): the sidebar shows one at
/// a time, and here are all of them, as Arc's spaces — each a small
/// square in its colour, its letter or symbol in it; the one shown
/// outlined; a dot at a corner for what most wants you in it (needs you,
/// failed, done and not read); a hairline between one host's and the
/// next's. Clicked, a space is gone to; the pointer on one peeks at it;
/// right-clicked, its menu (its colour, its symbol, its name). After
/// them a +: clicked, a new space, on the shown one's host; the pointer
/// on it, with more than one host, a list of them to make it on. A host
/// whose spaces aren't here yet (its first connection under way) is a
/// pill in their place, turning; the pointer on it, the host's card.
final class SpaceStripView: NSView {
    // Clickable: the pointing hand (not the window's arrow), as the rest are.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
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
        /// Its host, when it's another machine's (underlined in its colour).
        var remote: HostID? = nil
    }

    /// A host none of whose spaces are here yet — being reached for the
    /// first time, or not reached before it ever answered: a pill where
    /// its spaces will be, turning while it's being reached.
    struct Pending: Equatable {
        var host: HostID
        var title: String
        /// How many spaces come before it in the strip.
        var at: Int
        /// The first of another host's.
        var hostBreak: Bool
        var connecting: Bool
    }

    /// One row's height; more rows, each `side + gap` more (and room for
    /// an underline under each, when a remote host's are among them).
    static let height: CGFloat = 36
    static let side: CGFloat = 24
    static let gap: CGFloat = 6
    static let inset: CGFloat = SidebarView.margin

    var onPick: ((BlockID) -> Void)?
    /// ⌘ held: each square's number (⌘1 to ⌘8; ⌘9 the last), in a badge.
    var showsNumbers = false { didSet { if showsNumbers != oldValue { needsDisplay = true } } }

    /// The number ⌘ and which goes to square `i`, if any.
    func number(_ i: Int) -> Int? {
        if i == chips.count - 1 { return chips.count <= 9 ? i + 1 : 9 }
        return i < 8 ? i + 1 : nil
    }
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
    private(set) var pending: [Pending] = []
    private var pills: [NSRect] = []
    /// Each remote host's colour, its spaces underlined in it.
    private var hostColors: [HostID: Int] = [:]
    /// More between rows when there are underlines, so each is its row's.
    static let underlineRoom: CGFloat = 8
    /// An underline: how far under its squares (clear of a chosen
    /// square's ring), and how thick.
    static let underlineDrop: CGFloat = 4.5
    static let underlineWidth: CGFloat = 2
    private var hoveredPill: Int? { didSet { if hoveredPill != oldValue { needsDisplay = true } } }
    /// Each pill's turning ring (or a host unreachable's mark), by host.
    private var glyphs: [HostID: StatusGlyph] = [:]
    static let pillWidth: CGFloat = 40
    /// The pointer on a host's pill (its rect in the window), or off it.
    var onHostHover: ((HostID?, NSRect) -> Void)?

    override var isFlipped: Bool { true }

    /// Something dragged onto a space's square (its rect in the window),
    /// with ⌥ (copied) or not; true if it was taken. A tile or a row moved
    /// (or copied) there; anything else dragged (a file, a reference, a
    /// page, words), opened there, as dropped on its grid.
    var onDrop: ((NSPasteboard, BlockID, Bool, NSRect) -> Bool)?
    /// Held over a square a moment, mid-drag — anything dragged — as the
    /// Finder springs a folder open: the square flashes, then its space is
    /// gone to, for the drop to land where it's wanted in it.
    var onSpring: ((BlockID) -> Void)?
    private var dropTarget: Int? { didSet { if dropTarget != oldValue { needsDisplay = true } } }
    private let spring = Debouncer()
    /// The square flashing before its space opens (the flash lit or not).
    private var flashing: (index: Int, lit: Bool)? { didSet { needsDisplay = true } }
    /// The flash: lit and dark twice, this long each.
    static let flashStep: TimeInterval = 0.08

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.manifoldPlacement, .manifoldBlock] + Dragged.types)
    }

    /// A tile, a row, or a thing dragged — what a square takes.
    private static func takes(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        return types.contains(.manifoldPlacement) || types.contains(.manifoldBlock) || Dragged(pb) != nil
    }

    /// Flashed twice (lit, dark, lit, dark), then `done`, unless the
    /// drag's moved off it meanwhile.
    private func flash(_ i: Int, step: Int = 0, then done: @escaping () -> Void) {
        guard dropTarget == i else { return flashing = nil }
        guard step < 4 else {
            flashing = nil
            return done()
        }
        flashing = (i, step % 2 == 0)
        spring.schedule(after: Self.flashStep) { [weak self] in self?.flash(i, step: step + 1, then: done) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let pb = sender.draggingPasteboard
        let i = Self.takes(pb) ? chips.indices.first { frames.indices.contains($0) && rect($0).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(p) && !chips[$0].current } : nil
        if i != dropTarget {
            dropTarget = i
            flashing = nil
            spring.cancel()
            // As long as the system springs a folder open (none, if it's
            // off), then a flash, as the Finder's: its space gone to.
            if let i, let delay = OrganizationView.springDelay {
                let id = chips[i].id
                spring.schedule(after: delay) { [weak self] in
                    self?.flash(i) { [weak self] in
                        self?.dropTarget = nil
                        self?.onSpring?(id)
                    }
                }
            }
        }
        guard i != nil else { return [] }
        // A tile or a row: moved, or copied with ⌥; a thing as its source allows.
        if (pb.types ?? []).contains(where: { $0 == .manifoldPlacement || $0 == .manifoldBlock }) {
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }
        return Dropping.op(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        spring.cancel()
        flashing = nil
        dropTarget = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        spring.cancel()
        flashing = nil
        defer { dropTarget = nil }
        guard let i = dropTarget else { return false }
        return onDrop?(sender.draggingPasteboard, chips[i].id, NSEvent.modifierFlags.contains(.option), convert(rect(i), to: nil)) ?? false
    }

    func show(_ new: [Chip], pending newPending: [Pending] = []) {
        guard new != chips || newPending != pending else { return }
        let rows = wantedHeight(width: bounds.width)
        chips = new
        pending = newPending
        var remotes: [HostID] = []
        for h in chips.compactMap(\.remote) + pending.map(\.host) where !remotes.contains(h) { remotes.append(h) }
        hostColors = Self.colors(for: remotes)
        if wantedHeight(width: bounds.width) != rows { superview?.superview?.needsLayout = true }
        needsLayout = true
        needsDisplay = true
    }

    /// Where each goes at a width, the + last, a host's pill among the
    /// squares where its spaces will be: in rows from the left, another
    /// row when one's full; between hosts a little more room (none at a
    /// row's start: there, its underline says another host's begun).
    private func place(width: CGFloat) -> (frames: [NSRect], pills: [NSRect]) {
        var out: [NSRect] = [], pills: [NSRect] = []
        var x = Self.inset, y = (Self.height - Self.side) / 2
        func put(_ w: CGFloat, lead wanted: CGFloat) -> NSRect {
            var lead = wanted
            if x > Self.inset, x + lead + w > width - 8 {
                x = Self.inset
                y += Self.side + Self.gap + (hostColors.isEmpty ? 0 : Self.underlineRoom)
                lead = 0
            }
            x += lead
            let r = NSRect(x: x, y: y.rounded(), width: w, height: Self.side)
            x += w + Self.gap
            return r
        }
        var p = 0
        for i in 0...chips.count {
            while p < pending.count, pending[p].at <= i {
                pills.append(put(Self.pillWidth, lead: pending[p].hostBreak ? 7 : 0))
                p += 1
            }
            out.append(put(Self.side, lead: i == chips.count ? 2 : chips[i].hostBreak ? 7 : 0))
        }
        return (out, pills)
    }

    /// The colours remote hosts are told apart by: each host's its own,
    /// the same wherever it's seen (from its name), another's if two
    /// would share one. Deep by day and light by night, so a line stands
    /// off the ground by its lightness and not its hue alone; and each
    /// told from every other by anyone (`ColorVision`) — apart in
    /// lightness as well as hue, as eyes that don't tell red from green
    /// see only blue against yellow, and light against dark: an azure, an
    /// orange, a deep plum (by night: sky, amber, a pale pink). Three, as
    /// no more can all be told apart, a line this thin and this light on
    /// a dark wash's brightest pools; a fourth host shares one. No red (a
    /// failure's).
    static let hostPalette: [Shade] = [
        .hex(0x2266FF, 0x99BBFF), .hex(0xBB5500, 0xFFAA00), .hex(0x771155, 0xFFCCDD),
    ]

    /// What a line must stand off its ground by: by day, more than the
    /// 3:1 asked of a mark, the wash being lit and turned a little by the
    /// day; by night 3:1, as a line that stands off a dark wash's
    /// brightest pools by more is too light for colours to be told apart.
    static func lineContrast(dark: Bool) -> CGFloat { dark ? 3.05 : 3.5 }

    /// What a line can be over in a theme: its wash's colours, the pools
    /// of light laid on it, and the panel (the sidebar not pinned).
    static func grounds(_ palette: Palette, dark: Bool) -> [NSColor] {
        let wash = palette.backdrop.wash(dark: dark)
        let pools = wash.stops.map { NSColor(calibratedHue: $0.0, saturation: wash.pool.saturation, brightness: wash.pool.brightness, alpha: 1) }
        return (BackdropView.colors(of: wash) + pools + [palette.chrome.panel.color(dark: dark)]).map { $0.usingColorSpace(.sRGB) ?? $0 }
    }

    /// Host `i`'s line in a theme: its colour, deepened (by day) or
    /// lightened (by night) until it stands off every ground it can be on.
    static func lineColor(_ i: Int, palette: Palette = .current, dark: Bool) -> NSColor {
        var c = hostPalette[i % hostPalette.count].color(dark: dark).usingColorSpace(.sRGB)!
        for g in grounds(palette, dark: dark) {
            c = Tints.reaching(lineContrast(dark: dark), from: c, on: g, toward: dark ? .white : .black)
        }
        return c
    }

    static func colors(for hosts: [HostID]) -> [HostID: Int] {
        var out: [HostID: Int] = [:], taken = Set<Int>()
        for host in hosts {
            var h: UInt32 = 2166136261
            for b in host.description.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            var i = Int(h % UInt32(hostPalette.count))
            for _ in hostPalette.indices where taken.contains(i) { i = (i + 1) % hostPalette.count }
            taken.insert(i)
            out[host] = i
        }
        return out
    }

    /// Each run of a remote host's squares (and its pill) in a row: where
    /// it's underlined, and in what. A run broken by a row's end is
    /// underlined on each row.
    func hostRuns() -> [(host: HostID, rect: NSRect)] {
        var items: [(r: NSRect, host: HostID?)] = []
        for (i, c) in chips.enumerated() where frames.indices.contains(i) { items.append((frames[i], c.remote)) }
        for (j, p) in pending.enumerated() where pills.indices.contains(j) { items.append((pills[j], p.host)) }
        items.sort { ($0.r.minY, $0.r.minX) < ($1.r.minY, $1.r.minX) }
        var runs: [(host: HostID, rect: NSRect)] = []
        var run: (host: HostID, rect: NSRect)?
        for item in items {
            if let r = run, r.host == item.host, r.rect.minY == item.r.minY {
                run = (r.host, r.rect.union(item.r))
                continue
            }
            if let r = run { runs.append(r) }
            run = item.host.map { ($0, item.r) }
        }
        if let r = run { runs.append(r) }
        return runs
    }

    /// Its height at a width: as many rows as it takes.
    func wantedHeight(width: CGFloat) -> CGFloat {
        guard let last = place(width: width).frames.last else { return Self.height }
        // Room under the last row's underline, if it has one.
        return last.maxY + (Self.height - Self.side) / 2 + (hostColors.isEmpty ? 0 : Self.underlineRoom / 2)
    }

    override func layout() {
        super.layout()
        (frames, pills) = place(width: bounds.width)
        // Each pill's ring, at its middle; those of hosts no longer waited on, gone.
        for (j, p) in pending.enumerated() where pills.indices.contains(j) {
            let g = glyphs[p.host] ?? {
                let g = StatusGlyph(frame: .zero)
                addSubview(g)
                glyphs[p.host] = g
                return g
            }()
            g.look = p.connecting ? .connecting : .offline
            let s = StatusGlyph.size
            g.frame = NSRect(x: (pills[j].midX - s / 2).rounded(), y: (pills[j].midY - s / 2).rounded(), width: s, height: s)
        }
        for (host, g) in glyphs where !pending.contains(where: { $0.host == host }) {
            g.removeFromSuperview()
            glyphs.removeValue(forKey: host)
        }
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
                Flat.ground(.hover).setFill()
                path.fill()
            }
            Theme.text.withAlphaComponent(hovered == plus ? 0.3 : 0.16).setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.stroke()
            if let image = Theme.symbol("plus", size: 11, weight: .semibold, color: hovered == plus ? Theme.text : Theme.secondaryText) {
                image.draw(centeredAt: NSPoint(x: r.midX, y: r.midY))
            }
        }
        // Another machine's spaces: underlined in its colour, row by row
        // (this Mac's aren't), so a host's begun even where a row has.
        let dark = effectiveAppearance.isDark
        for run in hostRuns() {
            let line = NSRect(x: run.rect.minX + 2, y: run.rect.maxY + Self.underlineDrop, width: run.rect.width - 4, height: Self.underlineWidth)
            (hostColors[run.host].map { Self.lineColor($0, dark: dark) } ?? Theme.secondaryText).setFill()
            NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
        }
        // A host still being reached: a capsule, its ring turning in it.
        for (j, _) in pending.enumerated() where pills.indices.contains(j) {
            let r = pills[j]
            let capsule = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            Theme.text.withAlphaComponent(hoveredPill == j ? 0.1 : 0.05).setFill()
            capsule.fill()
            Theme.text.withAlphaComponent(0.12).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        }
        for (i, c) in chips.enumerated() where frames.indices.contains(i) {
            let r = rect(i)
            let lit = flashing.map { $0.index == i && $0.lit } ?? false
            SpaceSquare.fill(r, color: c.color, alpha: lit ? 0.6 : c.current ? 0.32 : hovered == i || dropTarget == i ? 0.26 : 0.18)
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
            SpaceSquare.drawGlyph(in: r, color: c.color, symbol: c.symbol, letter: c.letter)
            // ⌘ held: its number, over its bottom right, as a key's badge.
            if showsNumbers, let n = number(i) {
                let t = NSAttributedString(string: "\(n)", attributes: [.font: UIType.badge, .foregroundColor: Theme.panel])
                let z = t.size()
                let b = NSRect(x: r.maxX - 9, y: r.maxY - 9, width: max(13, z.width + 6), height: 13)
                Theme.text.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: b, xRadius: 6.5, yRadius: 6.5).fill()
                t.draw(at: NSPoint(x: b.midX - z.width / 2, y: b.midY - z.height / 2))
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

    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { track(nil) }

    /// The host pill under the pointer.
    private func pill(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return pills.indices.first { pills[$0].insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(p) }
    }

    /// The pointer moved (or left): on a host's pill, its card; else a
    /// square's peek, or the +.
    private func track(_ event: NSEvent?) {
        let onPill = event.flatMap(pill(at:))
        if onPill != hoveredPill {
            hoveredPill = onPill
            if let onPill { onHostHover?(pending[onPill].host, convert(pills[onPill], to: nil)) } else { onHostHover?(nil, .zero) }
        }
        if onPill != nil {
            if hovered != nil { hover(nil) }
            return
        }
        hover(event.flatMap(index(at:)))
    }

    /// Debugging: a drag held over square `i`, as `draggingUpdated` does.
    func debugSpring(_ i: Int) {
        guard chips.indices.contains(i), !chips[i].current else { return }
        dropTarget = i
        spring.cancel()
        let id = chips[i].id
        spring.schedule(after: OrganizationView.springDelay ?? 0.5) { [weak self] in
            self?.flash(i) { [weak self] in
                self?.dropTarget = nil
                self?.onSpring?(id)
            }
        }
    }

    var debugFlashing: String { flashing.map { "flashing \($0.index) \($0.lit ? "lit" : "dark")" } ?? "not flashing" }

    func debugHoverPill(_ j: Int?) {
        hoveredPill = j
        if let j, pills.indices.contains(j) { onHostHover?(pending[j].host, convert(pills[j], to: nil)) } else { onHostHover?(nil, .zero) }
    }

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
        var words = chips.map { c in (c.current ? "*" : "") + (c.hostBreak ? "| " : "") + c.title + " [\(c.symbol ?? c.letter)]" + (c.status.map { " (\($0))" } ?? "") }
        // Each host's pill where it stands among them, last first so the places hold.
        for p in pending.reversed() {
            words.insert((p.hostBreak ? "| " : "") + "(\(p.title): \(p.connecting ? "connecting" : "unreachable"))", at: min(p.at, words.count))
        }
        return words.joined(separator: "  ")
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
    /// The strip's squares, host by host; and a pill for each remote host
    /// that hasn't yet said what it has (its first connection), where its
    /// spaces will be.
    func spaceChips() -> (chips: [SpaceStripView.Chip], pending: [SpaceStripView.Pending]) {
        var out: [SpaceStripView.Chip] = [], pending: [SpaceStripView.Pending] = []
        for c in hosts.ordered {
            let before = !out.isEmpty || !pending.isEmpty
            if c.isRemote, !c.hasState {
                pending.append(.init(host: c.host, title: hosts.label(of: c.host), at: out.count, hostBreak: before,
                                     connecting: c.link == .connecting))
                continue
            }
            var ids = c.desk.order.filter { $0.host == c.host && allWorkspaces.contains($0) }
            for id in allWorkspaces where id.host == c.host && !ids.contains(id) { ids.append(id) }
            var first = true
            for id in ids {
                guard let b = hosts.block(id), let a = hosts.arrangement(id) else { continue }
                let name = title(of: a)
                out.append(.init(id: id, title: name, symbol: SpaceLook.symbol(of: b), letter: SpaceLook.letter(of: name),
                                 color: SpaceLook.color(of: b), current: id == selected, status: spaceStatus(a),
                                 hostBreak: first && before, remote: c.isRemote ? c.host : nil))
                first = false
            }
        }
        return (out, pending)
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
                guard let self, let window = self.window, let id else { self?.hideSpacePeek(); return }
                self.peekSpace(id, beside: rect, in: window)
            }
            strip.onMenu = { [weak self] id in self?.spaceMenu(id) }
            // A host still being reached: its card, how that stands, live.
            strip.onHostHover = { [weak self] host, rect in
                guard let self, let window = self.window, let host, let c = self.hosts.client(host) else { return HoverCard.shared.hide() }
                self.showHostCard(c, beside: rect, in: window)
            }
            sidebar.onSwipe = { [weak self] step in self?.switchSpace(by: step) }
            strip.onDrop = { [weak self] pb, id, copy, square in
                guard let self else { return false }
                if let item = OrgDragItem(pb) { return self.dropOnSpace(item, space: id, copy: copy, square: self.root.convert(square, from: nil)) }
                // A thing (a file, a reference, a page, words): opened in
                // that space, in a column of its own at its right.
                guard let d = Dragged(pb) else { return false }
                if self.stateView != nil { self.hideStateView() }
                self.hosts.select(id)
                self.gridOpen(d, column: self.arrangement?.columns.count ?? 0, at: 0, newColumn: true)
                return true
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
        let (chips, pending) = spaceChips()
        strip.show(chips, pending: pending)
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
    /// The pointer on a square: the space's card, as ⌘` shows it (a picture
    /// of its grid), beside the square — a moment after, and at once when
    /// moving from one square to the next.
    private func peekSpace(_ id: BlockID, beside rect: NSRect, in window: NSWindow) {
        HoverCard.shared.hide()
        spacePeekWork.cancel()
        let show = { [weak self] in
            guard let self, let card = self.spaceCard(id) else { return }
            let v = self.spacePeek ?? SpaceSwitcherView()
            v.cards = [card]
            v.chosen = -1
            let size = v.wantedSize
            let r = self.root.convert(rect, from: nil)
            // Out beside the sidebar (clear of the other squares), its top
            // level with the square's.
            let x = min(self.sidebar.frame.maxX + 8, self.root.bounds.maxX - size.width - 8)
            let y = max(8, min(r.maxY - size.height + 6, self.root.bounds.maxY - size.height - 8))
            v.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            if v.superview == nil {
                v.alphaValue = 0
                self.root.addSubview(v)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.fast
                    v.animator().alphaValue = 1
                }
            }
            self.spacePeek = v
        }
        if spacePeek != nil { return show() }
        spacePeekWork.schedule(after: Motion.hoverIntent, show)
    }

    /// The square's card put away.
    func hideSpacePeek() {
        spacePeekWork.cancel()
        guard let v = spacePeek else { return }
        spacePeek = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            v.animator().alphaValue = 0
        }, completionHandler: { v.removeFromSuperview() })
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
        colorItem.setSymbol("paintpalette", size: 12)
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
        symbolItem.setSymbol("star.square", size: 12)
        menu.addItem(symbolItem)
        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename Space…", action: #selector(renameSpaceFromStrip(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = id
        rename.setSymbol("pencil", size: 12)
        menu.addItem(rename)
        let remove = NSMenuItem(title: "Remove Space", action: #selector(removeSpaceFromStrip(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        remove.setSymbol("xmark", size: 12)
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
        if let id = sender.representedObject as? BlockID { renameSpace(id) }
    }

    @objc func removeSpaceFromStrip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? BlockID { removeFromDesk(id) }
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
        case "hoverhost": strip.debugHoverPill(w.dropFirst().first.flatMap(Int.init))
        case "pick": if let id = chip(w.dropFirst().first) { strip.onPick?(id) }
        case "swipe": switchSpace(by: w.dropFirst().first == "back" ? -1 : 1)
        case "needs": return sidebar.needsYou.debugRows
        case "pretend":
            // "spaces pretend <i> <j>": as if the squares from i were one
            // remote host's, and from j another's (until the strip's shown
            // again) — to see their underlines.
            let at = w.dropFirst().compactMap(Int.init)
            let hosts = [HostID("debug-far"), HostID("debug-near")]
            var chips = strip.chips
            for (k, start) in at.prefix(2).enumerated() where chips.indices.contains(start) {
                for i in start..<chips.count { chips[i].remote = hosts[k]; chips[i].hostBreak = i == start }
            }
            strip.show(chips, pending: strip.pending)
            return strip.hostRuns().map { "\($0.host) \(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))" }.joined(separator: "\n")
        case "numbers": strip.showsNumbers = w.dropFirst().first != "off"
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
        case "dropfile":
            // "dropfile <i> <path>": a file (this Mac's) dropped on square i,
            // as from the Finder: opened in that space.
            let a = arg.split(separator: " ", maxSplits: 2).map(String.init)
            guard a.count == 3, let i = Int(a[1]), strip.chips.indices.contains(i) else { return "usage: spaces dropfile <i> <path>" }
            let pb = NSPasteboard(name: NSPasteboard.Name("manifold.debug.drop"))
            pb.clearContents()
            pb.setString(URL(fileURLWithPath: a[2]).absoluteString, forType: .fileURL)
            return strip.onDrop?(pb, strip.chips[i].id, false, .zero) == true ? "opened" : "refused"
        case "spring":
            // "spring <i>": a drag held over square i, as long as the system
            // springs (then the flash, then its space): what's shown after.
            guard let i = w.dropFirst().first.flatMap(Int.init) else { return "usage: spaces spring <i>" }
            strip.debugSpring(i)
            return "springing"
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
    // Clickable: the pointing hand (not the window's arrow), as the rest are.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
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
        NSAttributedString(string: "Needs you", attributes: [.font: UIType.section, .foregroundColor: Status.attention])
            .draw(at: NSPoint(x: SidebarView.margin + 2, y: 5))
        if items.count > 1 {
            let n = NSAttributedString(string: "\(items.count)", attributes: [.font: UIType.count, .foregroundColor: Theme.secondaryText])
            n.draw(at: NSPoint(x: bounds.width - 18 - n.size().width, y: 6))
        }
        for (i, item) in items.prefix(shown).enumerated() {
            let r = rowRect(i)
            if hovered == i {
                Flat.ground(.hover).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            // Its space's square, small.
            let sq = NSRect(x: SidebarView.margin, y: r.midY - 8, width: 16, height: 16)
            SpaceSquare.fill(sq, color: item.spaceColor, alpha: 0.28)
            SpaceSquare.drawGlyph(in: sq, color: item.spaceColor, symbol: item.spaceSymbol, letter: item.spaceLetter)
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
final class HostPickerView: PopoverView {
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

    override func drawContent(_ dirtyRect: NSRect) {
        Flat.menuHeader("New space on", at: NSPoint(x: 12, y: 6))
        for (i, row) in rows.enumerated() {
            let r = rowRect(i)
            let lit = hovered == i
            if lit { Flat.menuBand(r) }
            let dot = NSRect(x: r.minX + 9, y: r.midY - 3.5, width: 7, height: 7)
            (row.connected ? Status.done : Theme.tertiaryText).withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: dot).fill()
            let count = NSAttributedString(string: row.spaces == 1 ? "1 space" : "\(row.spaces) spaces",
                                           attributes: [.font: UIType.detail, .foregroundColor: lit ? Flat.onBand(dim: true) : Theme.tertiaryText])
            let cz = count.size()
            count.draw(at: NSPoint(x: r.maxX - 10 - cz.width, y: r.midY - cz.height / 2))
            var x = dot.maxX + 9
            if row.here, let image = Theme.symbol("checkmark", size: 10, weight: .semibold, color: lit ? Flat.onBand() : Theme.accent) {
                let z = image.size
                image.draw(in: NSRect(x: x, y: (r.midY - z.height / 2).rounded(), width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += z.width + 6
            }
            NSAttributedString(string: row.label, attributes: [.font: UIType.row, .foregroundColor: lit ? Flat.onBand() : row.connected ? Theme.text : Theme.secondaryText])
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
        pickerHide.cancel()
        let rows = hostPickerRows()
        guard rows.count > 1 || always else { return }
        sidebar.showHostPicker(rows, over: rect)
    }

    /// Put away a moment after the pointer leaves the + and the list, if
    /// it hasn't come back to either.
    func hideHostPicker(now: Bool = false) {
        let hide = { [weak self] in
            guard let self, now || !self.sidebar.hostPicker.inside else { return }
            self.sidebar.hideHostPicker()
        }
        if now { pickerHide.runNow(hide) } else { pickerHide.schedule(after: Motion.lingerAfterExit, hide) }
    }
}
