import AppKit
import ManifoldCore

/// A space's square — in the strip, beside what needs you, on ⌘`'s
/// cards — at any size alike: rounded a quarter of its height; its mark
/// (a letter or two, or a symbol) in its colour, a little darker; its
/// badge, if it has one (a simple shape, what kind of space it is), bare
/// at its lower right, ringed in the panel's ground.
enum SpaceSquare {
    static func radius(_ r: NSRect) -> CGFloat { r.height / 4 }

    /// Its ground: the colour, as strong as `alpha`.
    static func fill(_ r: NSRect, color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius(r), yRadius: radius(r)).fill()
    }

    /// Its mark, centred; its badge, if one, at its lower right.
    static func drawGlyph(in r: NSRect, color: NSColor, mark: SpaceMark, badge: String?) {
        let ink = color.blended(withFraction: 0.25, of: Theme.text) ?? color
        switch mark {
        case .letters(let letters):
            // One letter about half its height; two a little smaller, to fit.
            var size = max(8.5, (r.height * (letters.count > 1 ? 0.4 : 0.48) * 2).rounded() / 2)
            func text(_ size: CGFloat) -> NSAttributedString {
                NSAttributedString(string: letters, attributes: [.font: NSFont.systemFont(ofSize: size, weight: r.height >= 24 ? .semibold : .bold), .foregroundColor: ink])
            }
            var t = text(size)
            while t.size().width > r.width - 4, size > 6 { size -= 0.5; t = text(size) }
            let z = t.size()
            t.draw(at: NSPoint(x: (r.midX - z.width / 2).rounded(), y: (r.midY - z.height / 2).rounded()))
        case .symbol(let name):
            Theme.symbol(name, size: max(7, (r.height * 0.46).rounded()), weight: r.height >= 24 ? .semibold : .bold, color: ink)?
                .draw(centeredAt: NSPoint(x: r.midX, y: r.midY))
        }
        if let badge { drawBadge(badge, on: r) }
    }

    /// A badge: its shape, bare — no disc, which took half its room —
    /// in the text's ink, ringed in the panel's ground, over the square's
    /// lower right corner. Shape alone says what kind; its colour is the
    /// space's square's.
    static func drawBadge(_ name: String, on r: NSRect) {
        guard let symbol = SpaceLook.badgeSymbol(name) else { return }
        let size = max(7, (r.height * 0.42).rounded())
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let inset = size * 0.18
        let at = NSPoint(x: r.maxX - inset, y: flipped ? r.maxY - inset : r.minY + inset)
        // The ring: the shape in the panel's ground, drawn round it.
        if let halo = Theme.symbol(symbol, size: size, weight: .heavy, color: Theme.panel) {
            let o: CGFloat = 1.5
            for (dx, dy) in [(-o, 0), (o, 0), (0, -o), (0, o), (-o * 0.7, -o * 0.7), (o * 0.7, -o * 0.7), (-o * 0.7, o * 0.7), (o * 0.7, o * 0.7)] {
                halo.draw(centeredAt: NSPoint(x: at.x + dx, y: at.y + dy))
            }
        }
        Theme.symbol(symbol, size: size, weight: .bold, color: Theme.text.withAlphaComponent(0.92))?.draw(centeredAt: at)
    }
}

/// The spaces, at the sidebar's top (§3.6): the sidebar shows one at
/// a time, and here are all of them, as Arc's spaces — each a small
/// square in its colour, its letter in it and its badge, if any, at its
/// corner; the one shown
/// outlined; a dot at a corner for what most wants you in it (needs you,
/// failed, done and not read); a hairline between one host's and the
/// next's. Clicked, a space is gone to; the pointer on one peeks at it;
/// right-clicked, its menu (its colour, its badge, its name). After
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
        /// Its letter or two, or a symbol.
        var mark: SpaceMark
        /// Its badge, a shape's name.
        var badge: String?
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
    /// A square dragged to another place among its host's: its space, and
    /// the one it now comes before (nil: after its host's last).
    var onReorder: ((BlockID, _ before: BlockID?) -> Void)?
    /// The square a press began on, and where.
    private var pressed: (index: Int, at: NSPoint)?
    /// A square being dragged among its host's: which, where in it the
    /// pointer took it, where the pointer is; the squares as they were.
    private var reordering: (id: BlockID, grab: NSSize, at: NSPoint, was: [Chip])?
    /// Squares shown meanwhile, kept till the drag's done.
    private var shownLater: (chips: [Chip], pending: [Pending])?
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
        if reordering != nil { return shownLater = (new, newPending) }
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
    /// row's start: there, its underline says another host's begun). A
    /// host's that would be cut by a row's end begins the next row
    /// instead, if that takes no more rows — so rows end where hosts do
    /// when they can; the + goes where it fits.
    private func place(width: CGFloat) -> (frames: [NSRect], pills: [NSRect]) {
        // In order: each square (the + last) and pill — its width, the room
        // before it, and whether another host's begin with it.
        var items: [(w: CGFloat, lead: CGFloat, starts: Bool, pill: Bool)] = []
        var p = 0
        for i in 0...chips.count {
            while p < pending.count, pending[p].at <= i {
                items.append((Self.pillWidth, pending[p].hostBreak ? 7 : 0, pending[p].hostBreak, true))
                p += 1
            }
            let starts = i < chips.count && chips[i].hostBreak
            items.append((Self.side, i == chips.count ? 2 : starts ? 7 : 0, starts, false))
        }
        let rowStep = Self.side + Self.gap + (hostColors.isEmpty ? 0 : Self.underlineRoom)
        func lay(breaking: Set<Int>) -> [NSRect] {
            var x = Self.inset, y = (Self.height - Self.side) / 2
            return items.enumerated().map { k, item in
                var lead = item.lead
                if x > Self.inset, breaking.contains(k) || x + lead + item.w > width - 8 {
                    x = Self.inset
                    y += rowStep
                    lead = 0
                }
                x += lead
                let r = NSRect(x: x, y: y.rounded(), width: item.w, height: Self.side)
                x += item.w + Self.gap
                return r
            }
        }
        // Each host's run of items (the + not among them).
        let hosts = items.indices.dropLast().filter { $0 == 0 || items[$0].starts }
        var breaking = Set<Int>()
        var rects = lay(breaking: breaking)
        let rows = rects.last?.minY
        for (n, first) in hosts.enumerated() where first > 0 {
            let last = (n + 1 < hosts.count ? hosts[n + 1] : items.count - 1) - 1
            // Cut by a row's end, and not at a row's start already.
            guard rects[first].minY != rects[last].minY, rects[first].minX > Self.inset else { continue }
            let tried = lay(breaking: breaking.union([first]))
            if let r = tried.last?.minY, let rows, r <= rows { breaking.insert(first); rects = tried }
        }
        var frames: [NSRect] = [], pills: [NSRect] = []
        for (k, item) in items.enumerated() { if item.pill { pills.append(rects[k]) } else { frames.append(rects[k]) } }
        return (frames, pills)
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
            if let m = reordering, m.id == c.id {
                // Where it will go: a hollow its size.
                let hollow = NSBezierPath(roundedRect: rect(i).insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                Theme.text.withAlphaComponent(0.06).setFill()
                hollow.fill()
                continue
            }
            drawSquare(i, c, in: rect(i))
        }
        // The square dragged, over the rest, under the pointer, lifted.
        if let m = reordering, let i = chips.firstIndex(where: { $0.id == m.id }) {
            let r = NSRect(x: m.at.x - m.grab.width, y: m.at.y - m.grab.height, width: Self.side, height: Self.side)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            Theme.panel.setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawSquare(i, chips[i], in: r)
        }
    }

    /// A space's square: its colour (stronger shown, under the pointer, or
    /// with something held over it), its ring if it's shown, its glyph, its
    /// number with ⌘ held, what wants you there.
    private func drawSquare(_ i: Int, _ c: Chip, in r: NSRect) {
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
            // In the text's ink, not the space's colour: a light one's (yellow,
            // mint) ring was lost against its own ground and the wash.
            Theme.text.withAlphaComponent(0.7).setStroke()
            ring.stroke()
        }
        // ⌘ held, its number takes the badge's corner.
        SpaceSquare.drawGlyph(in: r, color: c.color, mark: c.mark, badge: showsNumbers ? nil : c.badge)
        // ⌘ held: its number, over its bottom right, as a key's badge.
        if showsNumbers, let n = number(i) {
            let t = NSAttributedString(string: "\(n)", attributes: [.font: UIType.badge, .foregroundColor: Theme.panel])
            let z = t.size()
            let b = NSRect(x: r.maxX - 9, y: r.maxY - 9, width: max(13, z.width + 6), height: 13)
            Theme.text.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: b, xRadius: 6.5, yRadius: 6.5).fill()
            t.draw(at: NSPoint(x: b.midX - z.width / 2, y: b.midY - z.height / 2))
        }
        // What most wants you there, at its top right: a dot; something
        // at work there (wanting nothing of you yet), an open ring — not
        // to be taken for something to attend to.
        if let tone = Self.tone(c.status) {
            let d = NSRect(x: r.maxX - 5, y: r.minY - 2, width: 7, height: 7)
            Theme.panel.setFill()
            NSBezierPath(ovalIn: d.insetBy(dx: -1.5, dy: -1.5)).fill()
            if case .working = c.status {
                let ring = NSBezierPath(ovalIn: d.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                tone.setStroke()
                ring.stroke()
            } else {
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

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: event).flatMap { $0 == plus ? nil : ($0, convert(event.locationInWindow, from: nil)) }
    }

    /// A square dragged: among its host's, the others moving aside for it.
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if reordering == nil {
            guard let (i, at) = pressed, chips.indices.contains(i), hypot(p.x - at.x, p.y - at.y) > 4 else { return }
            beginReorder(i, grab: at)
        }
        reorder(to: p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if reordering != nil { return endReorder() }
        guard let i = index(at: event) else { return }
        onHover?(nil, .zero)
        if i == plus { return onNew?() ?? () }
        onPick?(chips[i].id)
    }

    /// Square `i` taken up, the pointer at `grab` on it.
    private func beginReorder(_ i: Int, grab: NSPoint) {
        let r = rect(i)
        reordering = (chips[i].id, NSSize(width: grab.x - r.minX, height: grab.y - r.minY), grab, chips)
        hovered = nil
        onHover?(nil, .zero)
    }

    /// The square dragged to `p`: put where it's nearest among its host's
    /// squares (its section; no further), the others moving aside.
    private func reorder(to p: NSPoint) {
        guard var m = reordering, let from = chips.firstIndex(where: { $0.id == m.id }) else { return }
        m.at = p
        reordering = m
        needsDisplay = true
        let section = chips.indices.filter { chips[$0].id.host == m.id.host }
        let middle = NSPoint(x: p.x - m.grab.width + Self.side / 2, y: p.y - m.grab.height + Self.side / 2)
        func distance(_ i: Int) -> CGFloat { hypot(rect(i).midX - middle.x, rect(i).midY - middle.y) }
        guard let to = section.min(by: { distance($0) < distance($1) }), to != from, let first = section.first else { return }
        var c = chips
        c.insert(c.remove(at: from), at: to)
        // The host's first still set apart from the host before.
        let breaks = chips[first].hostBreak
        for i in section { c[i].hostBreak = i == first && breaks }
        chips = c
        (frames, pills) = place(width: bounds.width)
    }

    /// The square let go: its space where it now is among its host's, if
    /// that's somewhere else.
    private func endReorder() {
        guard let m = reordering else { return }
        reordering = nil
        needsDisplay = true
        let now = chips.filter { $0.id.host == m.id.host }.map(\.id)
        let later = shownLater
        shownLater = nil
        if now != m.was.filter({ $0.id.host == m.id.host }).map(\.id), let k = now.firstIndex(of: m.id) {
            // The desk's order changed: the strip's shown again from it.
            onReorder?(m.id, k + 1 < now.count ? now[k + 1] : nil)
        } else if let later {
            show(later.chips, pending: later.pending)
        }
    }

    /// Debugging: square `i` dragged onto square `j`'s place (a little
    /// short of it) and let go, or held there; a drag held, let go.
    func debugReorder(_ i: Int, to j: Int, hold: Bool = false) -> String {
        guard chips.indices.contains(i), chips.indices.contains(j) else { return "no such square" }
        let a = rect(i), b = rect(j)
        beginReorder(i, grab: NSPoint(x: a.midX, y: a.midY))
        reorder(to: NSPoint(x: b.midX - 5, y: b.midY + 3))
        if !hold { endReorder() }
        return debugChips
    }

    func debugDrop() -> String {
        endReorder()
        return debugChips
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = index(at: event), i != plus, let menu = onMenu?(chips[i].id) else { return }
        onHover?(nil, .zero)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Debugging: each, in order — the one shown starred, its status after it.
    var debugChips: String {
        var words = chips.map { c in (c.current ? "*" : "") + (c.hostBreak ? "| " : "") + c.title + " [\(c.mark.words)\(c.badge.map { " " + $0 } ?? "")]" + (c.status.map { " (\($0))" } ?? "") }
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

/// What's in a space's square: a letter or two (its name's, else
/// chosen), or a symbol.
enum SpaceMark: Equatable {
    case letters(String)
    case symbol(String)

    /// As `mani` and the debug readouts say it: the letters, or `symbol:<name>`.
    var words: String {
        switch self {
        case .letters(let l): l
        case .symbol(let s): "symbol:\(s)"
        }
    }
}

/// A space's look (§3.6): its colour; its mark (which space: a letter or
/// two, its name's unless chosen, or a symbol); its badge (what kind of
/// space: a simple shape). Kept on it as annotations (`space.color`,
/// `space.mark`, `space.badge`), so `mani annotate` sets them too.
enum SpaceLook {
    static let colorKey = "space.color"
    static let markKey = "space.mark"
    static let badgeKey = "space.badge"
    /// Where a badge was kept before badges were shapes: read, if it's one.
    static let oldBadgeKey = "space.symbol"

    static let colors: [(name: String, color: NSColor)] = [
        ("red", .systemRed), ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen),
        ("mint", .systemMint), ("teal", .systemTeal), ("blue", .systemBlue), ("indigo", .systemIndigo),
        ("purple", .systemPurple), ("pink", .systemPink), ("brown", .systemBrown), ("gray", .systemGray),
    ]

    /// The badges: shapes that read at a square's corner (nine points or
    /// so), filled. Only these — a symbol with any detail (a terminal, a
    /// wrench) was a smudge that small.
    static let badges: [(name: String, symbol: String)] = [
        ("circle", "circle.fill"), ("square", "square.fill"), ("triangle", "triangle.fill"), ("diamond", "diamond.fill"),
        ("star", "star.fill"), ("heart", "heart.fill"), ("bolt", "bolt.fill"), ("flame", "flame.fill"),
        ("flag", "flag.fill"), ("bookmark", "bookmark.fill"), ("leaf", "leaf.fill"), ("drop", "drop.fill"),
        ("moon", "moon.fill"), ("eye", "eye.fill"), ("checkmark", "checkmark"),
    ]

    static func badgeSymbol(_ name: String) -> String? { badges.first { $0.name == name }?.symbol }

    /// Symbols the menu offers for a mark, in place of its letters
    /// (`mani space --symbol` takes any of the system's).
    static let markSymbols: [(symbol: String, name: String)] = [
        ("folder", "Folder"), ("terminal", "Terminal"), ("hammer", "Hammer"), ("wrench.and.screwdriver", "Tools"),
        ("book", "Book"), ("doc.text", "Document"), ("flask", "Flask"), ("globe", "Globe"),
        ("server.rack", "Server"), ("cpu", "Chip"), ("chart.bar", "Chart"), ("bubble.left.and.bubble.right", "Conversation"),
        ("eye", "Eye"), ("checklist", "Checklist"), ("ladybug", "Bug"), ("paintbrush", "Brush"),
        ("music.note", "Music"), ("gamecontroller", "Game"), ("house", "House"), ("person", "Person"),
    ]

    /// Its colour: chosen, else one of the twelve by its name's hash, steady.
    static func color(of block: Block?) -> NSColor {
        if let name = block?.annotations?[colorKey], let c = colors.first(where: { $0.name == name }) { return c.color }
        var h: UInt32 = 2166136261
        for b in (block?.id.description ?? "").utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return colors[Int(h % UInt32(colors.count))].color
    }

    /// Its badge (a shape's name), if one's chosen. One kept as a symbol,
    /// before, that's one of the shapes (star, bolt…) still is.
    static func badge(of block: Block?) -> String? {
        let a = block?.annotations
        guard let raw = a?[badgeKey] ?? a?[oldBadgeKey], !raw.isEmpty else { return nil }
        let name = raw.hasSuffix(".fill") ? String(raw.dropLast(5)) : raw
        return badgeSymbol(name) != nil ? name : nil
    }

    /// Its mark, if one's chosen: letters, or `symbol:<name>`.
    static func chosenMark(of block: Block?) -> SpaceMark? {
        guard let raw = block?.annotations?[markKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("symbol:") {
            let name = String(raw.dropFirst(7))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? .symbol(name) : nil
        }
        return isLetters(raw) ? .letters(raw) : .letters(String(raw.prefix(2)))
    }

    /// Letters a mark can be: one or two, no spaces.
    static func isLetters(_ s: String) -> Bool {
        (1...2).contains(s.count) && !s.contains { $0.isWhitespace || $0.isNewline }
    }

    /// Each space's mark: its chosen one; else letters from its name —
    /// one if there's one no other space has (its first, its words'
    /// initials, its other letters), else two — the space made first
    /// keeping the one they'd both have, so a new space doesn't take
    /// another's.
    static func marks(_ spaces: [(id: BlockID, name: String, chosen: SpaceMark?)]) -> [BlockID: SpaceMark] {
        var out: [BlockID: SpaceMark] = [:]
        var taken = Set<String>()
        for s in spaces {
            guard let c = s.chosen else { continue }
            out[s.id] = c
            if case .letters(let l) = c { taken.insert(l.uppercased()) }
        }
        for s in spaces.filter({ $0.chosen == nil }).sorted(by: { $0.id.ulid < $1.id.ulid }) {
            let candidates = letterCandidates(s.name)
            let pick = candidates.first { !taken.contains($0.uppercased()) } ?? candidates[0]
            taken.insert(pick.uppercased())
            out[s.id] = .letters(pick)
        }
        return out
    }

    /// The letters a name could go by, the likeliest first: its first
    /// letter; its other words' initials; its other consonants, then
    /// vowels; then two: its first two words' initials, its first letter
    /// with each other.
    static func letterCandidates(_ title: String) -> [String] {
        let last = title.split(separator: "/").last.map(String.init) ?? title
        let words = last.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let letters = Array(words.joined())
        // No letters in it ("~"): its first mark, as it is.
        guard let first = letters.first else { return [last.first { !$0.isWhitespace }.map(String.init) ?? "·"] }
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        add(String(first).uppercased())
        for w in words.dropFirst() { if let c = w.first { add(String(c).uppercased()) } }
        let vowels = Set("aeiouyAEIOUY")
        for c in letters.dropFirst() where !vowels.contains(c) { add(String(c).uppercased()) }
        for c in letters.dropFirst() where vowels.contains(c) { add(String(c).uppercased()) }
        if words.count > 1, let a = words[0].first, let b = words[1].first { add((String(a) + String(b)).uppercased()) }
        for c in letters.dropFirst() { add(String(first).uppercased() + String(c).lowercased()) }
        return out
    }

    /// Its letter, as it'd be with no other space: its name's first.
    static func letter(of title: String) -> String { letterCandidates(title)[0] }
}

extension MainWindowController {
    /// The strip's chips: each host's spaces, in its desk's order, a host's
    /// first set apart from the one before.
    /// The strip's squares, host by host; and a pill for each remote host
    /// that hasn't yet said what it has (its first connection), where its
    /// spaces will be.
    func spaceChips() -> (chips: [SpaceStripView.Chip], pending: [SpaceStripView.Pending]) {
        var out: [SpaceStripView.Chip] = [], pending: [SpaceStripView.Pending] = []
        let marks = spaceMarks()
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
                out.append(.init(id: id, title: name, mark: marks[id] ?? .letters(SpaceLook.letter(of: name)), badge: SpaceLook.badge(of: b),
                                 color: SpaceLook.color(of: b), current: id == selected, status: spaceStatus(a),
                                 hostBreak: first && before, remote: c.isRemote ? c.host : nil))
                first = false
            }
        }
        return (out, pending)
    }

    /// Every space's mark: chosen, else letters its name's that no other
    /// space's are (as can be).
    func spaceMarks() -> [BlockID: SpaceMark] {
        SpaceLook.marks(allWorkspaces.compactMap { id in
            guard let b = hosts.block(id), let a = hosts.arrangement(id) else { return nil }
            return (id, title(of: a), SpaceLook.chosenMark(of: b))
        })
    }

    /// The mark a space would have unless one's chosen for it.
    func automaticSpaceMark(_ id: BlockID) -> SpaceMark? {
        SpaceLook.marks(allWorkspaces.compactMap { w in
            guard let b = hosts.block(w), let a = hosts.arrangement(w) else { return nil }
            return (w, title(of: a), w == id ? nil : SpaceLook.chosenMark(of: b))
        })[id]
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
            strip.onReorder = { [weak self] id, before in self?.moveSpace(id, before: before) }
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
    /// badge, its name; taken off the desk.
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

        // Its mark: which space it is — letters, its name's or chosen, or a symbol.
        let marks = NSMenu()
        let chosenMark = SpaceLook.chosenMark(of: b)
        let automatic = automaticSpaceMark(id)?.words ?? ""
        let autoMark = NSMenuItem(title: "Automatic (\(automatic))", action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
        autoMark.target = self
        autoMark.representedObject = (id, SpaceLook.markKey, "")
        autoMark.state = chosenMark == nil ? .on : .off
        marks.addItem(autoMark)
        var chosenLetters: String?
        if case .letters(let l) = chosenMark { chosenLetters = l }
        let letters = NSMenuItem(title: chosenLetters.map { "Letters (\($0))…" } ?? "Letters…", action: #selector(askSpaceMark(_:)), keyEquivalent: "")
        letters.target = self
        letters.representedObject = (id, false)
        letters.state = chosenLetters != nil ? .on : .off
        letters.setSymbol("character", size: 12)
        marks.addItem(letters)
        marks.addItem(.separator())
        var chosenSymbol: String?
        if case .symbol(let n) = chosenMark { chosenSymbol = n }
        for (sym, name) in SpaceLook.markSymbols {
            let item = NSMenuItem(title: name, action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (id, SpaceLook.markKey, "symbol:" + sym)
            item.setSymbol(sym, size: 13)
            item.state = chosenSymbol == sym ? .on : .off
            marks.addItem(item)
        }
        let other = NSMenuItem(title: "Other Symbol…", action: #selector(askSpaceMark(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = (id, true)
        if let n = chosenSymbol, !SpaceLook.markSymbols.contains(where: { $0.symbol == n }) {
            other.title = "Other Symbol (\(n))…"
            other.state = .on
        }
        marks.addItem(other)
        let markItem = NSMenuItem(title: "Mark", action: nil, keyEquivalent: "")
        markItem.submenu = marks
        markItem.setSymbol("textformat", size: 12)
        menu.addItem(markItem)

        // Its badge: what kind of space it is — a shape.
        let badges = NSMenu()
        let chosenBadge = SpaceLook.badge(of: b)
        let none = NSMenuItem(title: "None", action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = (id, SpaceLook.badgeKey, "")
        none.state = chosenBadge == nil ? .on : .off
        badges.addItem(none)
        badges.addItem(.separator())
        for (name, sym) in SpaceLook.badges {
            let item = NSMenuItem(title: name.capitalized, action: #selector(chooseSpaceLook(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (id, SpaceLook.badgeKey, name)
            item.setSymbol(sym, size: 12)
            item.state = chosenBadge == name ? .on : .off
            badges.addItem(item)
        }
        let badgeItem = NSMenuItem(title: "Badge", action: nil, keyEquivalent: "")
        badgeItem.submenu = badges
        badgeItem.setSymbol("star.square", size: 12)
        menu.addItem(badgeItem)
        menu.addItem(.separator())
        let after = NSMenuItem(title: "New Space After “\(b.arrangement.map(title(of:)) ?? "This One")”", action: #selector(newSpaceAfterFromStrip(_:)), keyEquivalent: "")
        after.target = self
        after.representedObject = id
        after.setSymbol("plus.square", size: 12)
        menu.addItem(after)
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

    /// Its mark chosen in words: letters (one or two), or a symbol by its name.
    @objc func askSpaceMark(_ sender: NSMenuItem) {
        guard let (id, symbol) = sender.representedObject as? (BlockID, Bool), let window else { return }
        let alert = NSAlert()
        alert.messageText = symbol ? "A Symbol for This Space" : "Letters for This Space"
        alert.informativeText = symbol
            ? "A system symbol's name, as SF Symbols names it (hammer, ladybug, chart.pie)."
            : "One or two, shown in its square in place of its name's."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        if let m = hosts.block(id).flatMap(SpaceLook.chosenMark(of:)) {
            switch m {
            case .letters(let l) where !symbol: field.stringValue = l
            case .symbol(let n) where symbol: field.stringValue = n
            default: break
            }
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Choose")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return self.setSpaceLook(id, SpaceLook.markKey, "") }
            if symbol {
                guard NSImage(systemSymbolName: v, accessibilityDescription: nil) != nil else { return NSSound.beep() }
                self.setSpaceLook(id, SpaceLook.markKey, "symbol:" + v)
            } else {
                guard SpaceLook.isLetters(v) else { return NSSound.beep() }
                self.setSpaceLook(id, SpaceLook.markKey, v)
            }
        }
    }

    @objc func chooseSpaceLook(_ sender: NSMenuItem) {
        guard let (id, key, value) = sender.representedObject as? (BlockID, String, String) else { return }
        setSpaceLook(id, key, value)
    }

    func setSpaceLook(_ id: BlockID, _ key: String, _ value: String) {
        hosts.append(.annotate([key: value]), to: .block(id))
    }

    /// A new space, with a terminal in it, right after this one on its
    /// host, and gone to.
    @objc func newSpaceAfterFromStrip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? BlockID { newWorkspace(on: id.host, cwd: nil, after: id) }
    }

    @objc func renameSpaceFromStrip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? BlockID { renameSpace(id) }
    }

    @objc func removeSpaceFromStrip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? BlockID { removeFromDesk(id) }
    }

    /// Debugging the strip: `spaces` its squares; `spaces hover <i>|off`;
    /// `spaces pick <i>`; `spaces drag <i> <j>`; `spaces menu <i> [title]`; `spaces color|mark|badge <i> [value]`.
    func debugSpaces(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        let strip = sidebar.spaces
        refreshSpaceStrip()
        func chip(_ s: String?) -> BlockID? { s.flatMap(Int.init).flatMap { strip.chips.indices.contains($0) ? strip.chips[$0].id : nil } }
        switch w.first {
        case "hover": strip.debugHover(w.dropFirst().first.flatMap(Int.init))
        case "hoverhost": strip.debugHoverPill(w.dropFirst().first.flatMap(Int.init))
        case "pick": if let id = chip(w.dropFirst().first) { strip.onPick?(id) }
        case "drag":
            // "spaces drag <i> <j>": square i dragged onto j's place, let go.
            let n = w.dropFirst().compactMap(Int.init)
            guard n.count == 2 else { return "usage: spaces drag <i> <j> [hold]" }
            return strip.debugReorder(n[0], to: n[1], hold: w.last == "hold")
        case "drop": return strip.debugDrop()
        case "menu":
            // "spaces menu <i> [title]": square i's menu, or that item chosen.
            guard let id = chip(w.dropFirst().first), let menu = spaceMenu(id) else { return "no such square" }
            let title = w.dropFirst(2).joined(separator: " ")
            if title.isEmpty { return menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n") }
            guard let item = menu.items.first(where: { $0.title.hasPrefix(title) }), let action = item.action else { return "no such item" }
            NSApp.sendAction(action, to: item.target, from: item)
            return "chose \(item.title)"
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
            // "spaces host [hover|menu]": the heading's host line; with hover, its card; with menu, its right-click menu.
            if w.dropFirst().first == "menu" {
                guard let m = sidebar.spaceHost.onMenu?() else { return "no menu" }
                return m.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
            }
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
        case "color", "mark", "badge":
            // "spaces color|mark|badge <i> [value]": as the menu sets it (a mark's symbol as symbol:<name>).
            let key = w[0] == "color" ? SpaceLook.colorKey : w[0] == "mark" ? SpaceLook.markKey : SpaceLook.badgeKey
            if let id = chip(w.dropFirst().first) { setSpaceLook(id, key, w.count > 2 ? w[2] : "") }
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
        var spaceMark: SpaceMark
        var spaceBadge: String?
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
            SpaceSquare.drawGlyph(in: sq, color: item.spaceColor, mark: item.spaceMark, badge: item.spaceBadge)
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
        items.isEmpty ? "nothing needs you" : items.map { "\($0.spaceMark.words) \($0.title) [\($0.need)]" }.joined(separator: " | ")
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
                                 spaceMark: chip.mark, spaceBadge: chip.badge, spaceColor: chip.color,
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
