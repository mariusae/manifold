import AppKit
import ManifoldCore

/// A view's outline beside its scroll bar (§3.1, §7.5), as claude.ai has
/// its conversation's: a column of ticks, one for each item that's shown,
/// evenly spaced, in the middle of the view's right edge, left of an
/// ordinary scroll bar the full height. A tick's height is how much its
/// item spans — four heights, against the rest of the view's, not any
/// other's — and the ticks of what shows are lit. Which items have ticks
/// doesn't change as you scroll: a page's headings down to the deepest
/// level whose every heading fits (the others dropped), a terminal's
/// commands all; when there are more than fit, the column scrolls, a
/// chevron at its top or bottom to go on. The pointer on it widens the
/// ticks around it, as the Dock does its icons, and brightens them; the
/// one under the pointer is previewed in a card beside it, and clicked,
/// gone to. The ticks show as an overlay scroll bar does: while the view
/// scrolls or the pointer's on the strip, and a moment after — so they
/// hide nothing under them the rest of the time.

/// An outline's item as the strip weighs it: its level, where it begins
/// in the view's scroll units and how much it spans.
struct StripItem: Equatable {
    var level = 0
    var start: Double
    var size: Double
    /// An agent's turn: what you asked (in the accent).
    var you = false
    var failed = false
    var running = false
}

/// Which items the strip shows: a page's headings, its deepest levels
/// dropped till they fit; or every one (a terminal's commands).
enum StripPolicy: Equatable {
    case document
    case recent
}

/// A tick placed: the item it stands for, its middle (from the view's
/// top), its height (0…3), and whether what it stands for shows.
struct StripTick: Equatable {
    var index: Int
    var y: CGFloat
    var height: Int
    var lit: Bool
}

enum StripLayout {
    /// From one tick's middle to the next's.
    static let pitch: CGFloat = 12
    /// Above and below the column, when it scrolls: a chevron's room.
    static let pad: CGFloat = 14
    /// A tick's width at rest, and its heights.
    static let tickWidth: CGFloat = 12
    static let heights: [CGFloat] = [1.5, 3, 4.5, 6]
    /// How much wider the tick under the pointer is, and how far that
    /// reaches (the Dock's).
    static let swell: CGFloat = 2.2
    static let reach: CGFloat = 2 * pitch

    /// Items from where each begins and its level: each a section, from
    /// its top to the next at its level or above (the last, to the end).
    static func sections(tops: [Double], levels: [Int], total: Double) -> [StripItem] {
        tops.indices.map { k in
            let next = ((k + 1)..<tops.count).first { levels[$0] <= levels[k] }
            let end = next.map { tops[$0] } ?? total
            return StripItem(level: levels[k], start: tops[k], size: max(end - tops[k], 1))
        }
    }

    /// How many ticks a span holds.
    static func fits(_ height: CGFloat) -> Int { max(1, Int(height / pitch)) }

    /// The items that have ticks: a page's headings down to the deepest
    /// level whose every one fits (`fit`) — one deeper, scrolled, if that
    /// leaves too few to say anything; every item of a terminal.
    static func chosen(_ items: [StripItem], policy: StripPolicy, fit: Int) -> [Int] {
        guard policy == .document, items.count > fit else { return Array(items.indices) }
        let deepest = items.map(\.level).max() ?? 0
        func upTo(_ l: Int) -> [Int] { items.indices.filter { items[$0].level <= l } }
        var level = 0
        for l in 0...deepest where upTo(l).count <= fit { level = l }
        var out = upTo(level)
        if out.count < min(fit, 3), level < deepest { out = upTo(level + 1) }
        return out
    }

    /// Each tick's height (0…3): its item's size against the others'
    /// (logarithmically, from about the smallest to about the largest, so
    /// a stray one doesn't flatten the rest) — what's big here, not
    /// anywhere.
    static func heights(_ sizes: [Double]) -> [Int] {
        let logs = sizes.map { log(max($0, 1)) }
        let sorted = logs.sorted()
        guard sorted.count > 1 else { return sizes.map { _ in 1 } }
        let cut = sorted.count >= 10 ? sorted.count / 10 : 0
        let lo = sorted[cut], hi = sorted[sorted.count - 1 - cut]
        guard hi - lo > 1e-6 else { return sizes.map { _ in 1 } }
        return logs.map { min(3, max(0, Int((($0 - lo) / (hi - lo)) * 4))) }
    }

    /// The ticks (positions in `ticks`) whose stretch shows: from their
    /// item's start to the next tick's (its children with it, when theirs
    /// were dropped).
    static func lit(_ items: [StripItem], ticks: [Int], offset: Double, shown: Double, total: Double) -> Set<Int> {
        var out: Set<Int> = []
        for (k, i) in ticks.enumerated() {
            let start = items[i].start
            let end = max(k + 1 < ticks.count ? items[ticks[k + 1]].start : total, start + 1)
            if start < offset + shown, end > offset { out.insert(k) }
        }
        return out
    }

    /// The column: how many ticks it shows, and whether it scrolls (there
    /// being more than fit in `track`, the chevrons' room kept).
    static func column(count: Int, track: CGFloat) -> (shows: Int, scrolls: Bool) {
        if CGFloat(count) * pitch <= track { return (count, false) }
        return (max(1, Int((track - 2 * pad) / pitch)), true)
    }

    /// The first tick shown, moved as little as it takes to show `keep`
    /// (its start, if not all of it fits).
    static func follow(first: Int, keep: ClosedRange<Int>?, shows: Int, count: Int) -> Int {
        var f = first
        if let k = keep {
            if k.upperBound >= f + shows { f = k.upperBound - shows + 1 }
            if k.lowerBound < f { f = k.lowerBound }
        }
        return min(max(f, 0), max(count - shows, 0))
    }

    /// How much wider a tick is `d` from the pointer.
    static func swollen(_ d: CGFloat) -> CGFloat { 1 + (swell - 1) * exp(-(d * d) / (2 * reach * reach)) }
}

/// The strip itself: the ticks, the scroll bar, the card.
final class OutlineStripView: NSView {
    /// The room it takes of its view's width: the scroll bar's.
    static let width: CGFloat = ScrubberView.width
    /// The ticks' lane, over the view's content left of that.
    static let lane: CGFloat = 16

    /// Its frame for a view whose right edge is at `right`: the scroll
    /// bar there, the ticks' lane left of it.
    static func frame(right: CGFloat, y: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: right - width - lane, y: y, width: width + lane, height: height)
    }

    /// Scrolled to a fraction of the content, the knob dragged or the track clicked.
    var onScroll: ((Double) -> Void)? {
        get { scrubber.onScroll }
        set { scrubber.onScroll = newValue }
    }
    /// What the card says of an item: a line or a few under its title.
    var preview: ((Int) -> [String])?
    /// Lines set in the code font in the card (a terminal's output).
    var previewIsCode = false

    let outline: Outline
    private(set) var items: [StripItem] = []
    private(set) var policy: StripPolicy
    private var total: Double = 1
    private var offset: Double = 0
    private var shown: Double = 1
    /// Whether what it shows scrolls (an agent's turns have no rows).
    var scrolls = true { didSet { if scrolls != oldValue { needsLayout = true } } }
    /// Whether the scroll bar is the strip's, or the view's own (a page's,
    /// a scroll view's), right of the ticks as the strip's would be.
    var hasScrollBar = true { didSet { if hasScrollBar != oldValue { needsLayout = true } } }

    private let scrubber = ScrubberView(frame: .zero)
    /// The items with ticks (all of them, not only those the column shows
    /// now), their heights, and the first the column shows.
    private(set) var chosen: [Int] = []
    private var chosenHeights: [Int] = []
    private var first = 0
    private var litSeen: ClosedRange<Int>?
    private(set) var ticks: [StripTick] = []
    private var more = (above: false, below: false)
    /// The ticks and chevrons, shown or faded together.
    private let column = CALayer()
    private var fade: Timer?
    private var pointerIn = false
    private var pointer: CGFloat?
    private var hovered: Int?
    private var layers: [Int: CALayer] = [:]
    private let up = CAShapeLayer(), down = CAShapeLayer()
    private var onChevron: Chevron?
    enum Chevron { case up, down }
    private let card = StripCard()

    init(outline: Outline, policy: StripPolicy) {
        self.outline = outline
        self.policy = policy
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width + Self.lane, height: 100))
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(scrubber)
        layer?.addSublayer(column)
        // Faded till the view scrolls or the pointer comes, unless scroll
        // bars stay.
        column.opacity = NSScroller.preferredScrollerStyle == .overlay ? 0 : 1
        for c in [up, down] {
            c.fillColor = nil
            c.lineWidth = 1.5
            c.lineCap = .round
            c.lineJoin = .round
            column.addSublayer(c)
        }
        outline.watch(self) { [weak self] in self?.relayout() }
        themed { $0.draw(animated: false) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: What it shows

    func update(total: Double, offset: Double, shown: Double) {
        let moved = total != self.total || offset != self.offset || shown != self.shown
        self.total = max(total, 1)
        self.offset = offset
        self.shown = max(shown, 1)
        scrubber.update(total: self.total, offset: offset, shown: self.shown)
        if moved { reveal(); relayout() }
    }

    /// The outline's items as the strip weighs them, one for each of its items.
    func set(_ fresh: [StripItem], policy: StripPolicy? = nil) {
        if let policy { self.policy = policy }
        guard fresh != items else { return }
        items = fresh
        relayout()
    }

    override func layout() {
        super.layout()
        scrubber.frame = NSRect(x: Self.lane, y: 0, width: Self.width, height: bounds.height)
        relayout()
    }

    /// The span the column may take: two thirds of the view's height, in
    /// its middle (a short view's 120 points, or all of one shorter).
    var track: (top: CGFloat, height: CGFloat) {
        let h = min(bounds.height, max(bounds.height * 2 / 3, 120))
        return (((bounds.height - h) / 2).rounded(), h)
    }

    /// The column's ticks' span, from the first's top to the last's bottom.
    private var block: (top: CGFloat, bottom: CGFloat) {
        let n = CGFloat(ticks.count)
        let top = ((bounds.height - n * StripLayout.pitch) / 2).rounded()
        return (top, top + n * StripLayout.pitch)
    }

    private func relayout() {
        scrubber.isHidden = !scrolls || !hasScrollBar
        let usable = items.count == outline.items.count ? items : []
        let admitted = Set(outline.shown)
        let pool = usable.indices.filter { admitted.contains($0) }
        let t = track
        let picked = StripLayout.chosen(pool.map { usable[$0] }, policy: policy, fit: StripLayout.fits(t.height)).map { pool[$0] }
        if picked != chosen {
            chosen = picked
            litSeen = nil
        }
        chosenHeights = StripLayout.heights(picked.map { usable[$0].size })
        let (shows, scrollsTicks) = StripLayout.column(count: picked.count, track: t.height)
        let lit: Set<Int> = scrolls
            ? StripLayout.lit(usable, ticks: picked, offset: offset, shown: shown, total: total)
            : Set(outline.current.flatMap { picked.firstIndex(of: $0) }.map { [$0] } ?? [])
        // The column follows what shows, when that changes; scrolled by
        // its chevrons, it stays till then.
        let range = lit.min().flatMap { lo in lit.max().map { lo...$0 } }
        if range != litSeen {
            first = StripLayout.follow(first: first, keep: range, shows: shows, count: picked.count)
            litSeen = range
        }
        first = min(max(first, 0), max(picked.count - shows, 0))
        let n = min(shows, picked.count)
        let top = ((bounds.height - CGFloat(n) * StripLayout.pitch) / 2).rounded()
        ticks = (0..<n).map { k in
            StripTick(index: picked[first + k], y: top + (CGFloat(k) + 0.5) * StripLayout.pitch,
                      height: chosenHeights[first + k], lit: lit.contains(first + k))
        }
        more = (scrollsTicks && first > 0, scrollsTicks && first + n < picked.count)
        draw(animated: pointer != nil)
    }

    // MARK: Drawing

    /// The right end of the ticks, a little left of the scroll bar.
    private var tickRight: CGFloat { Self.lane - 2 }

    /// The ticks shown, and faded a moment after unless the pointer's on
    /// the strip — always shown where the system's scroll bars are the
    /// kind that stay.
    private func reveal() {
        fade?.invalidate()
        fade = nil
        if column.opacity != 1 {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.15)
            column.opacity = 1
            CATransaction.commit()
        }
        guard NSScroller.preferredScrollerStyle == .overlay, !pointerIn else { return }
        fade = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.unchecked {
                guard let self, !self.pointerIn else { return }
                self.fade = nil
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                self.column.opacity = 0
                CATransaction.commit()
                self.card.hide()
            }
        }
    }

    private func color(_ item: StripItem, _ tick: StripTick) -> NSColor {
        if item.running { return Theme.accent }
        if item.failed { return Status.failed }
        if item.you { return Theme.accent }
        return tick.lit ? Theme.text : Theme.tertiaryText
    }

    private func draw(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !Motion.reduced ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if !animated { CATransaction.setDisableActions(true) }
        let keep = Set(ticks.map(\.index))
        for (i, l) in layers where !keep.contains(i) {
            l.removeFromSuperlayer()
            layers.removeValue(forKey: i)
        }
        for t in ticks where items.indices.contains(t.index) {
            let item = items[t.index]
            let l = layers[t.index] ?? {
                let l = CALayer()
                column.insertSublayer(l, below: up)
                layers[t.index] = l
                return l
            }()
            // Wider and brighter near the pointer.
            let swell = pointer.map { StripLayout.swollen(abs($0 - t.y)) } ?? 1
            let near = (swell - 1) / (StripLayout.swell - 1)
            let w = StripLayout.tickWidth * swell
            let h = StripLayout.heights[t.height]
            l.frame = NSRect(x: tickRight - w, y: t.y - h / 2, width: w, height: h)
            l.cornerRadius = min(min(h, w) / 2, 1.5)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let base = hovered == t.index ? Theme.text : color(item, t)
                l.backgroundColor = (base.blended(withFraction: near * 0.7, of: Theme.text) ?? base).cgColor
            }
        }
        drawChevrons()
        CATransaction.commit()
    }

    private func drawChevrons() {
        let x = tickRight - StripLayout.tickWidth / 2
        func path(_ y: CGFloat, pointingUp: Bool) -> CGPath {
            let p = CGMutablePath()
            let h: CGFloat = 3.5
            p.move(to: CGPoint(x: x - h, y: pointingUp ? y + h / 2 : y - h / 2))
            p.addLine(to: CGPoint(x: x, y: pointingUp ? y - h / 2 : y + h / 2))
            p.addLine(to: CGPoint(x: x + h, y: pointingUp ? y + h / 2 : y - h / 2))
            return p
        }
        let b = block
        up.path = path(b.top - StripLayout.pad / 2, pointingUp: true)
        down.path = path(b.bottom + StripLayout.pad / 2, pointingUp: false)
        up.isHidden = !more.above
        down.isHidden = !more.below
        effectiveAppearance.performAsCurrentDrawingAppearance {
            up.strokeColor = (onChevron == .up ? Theme.text : Theme.tertiaryText).cgColor
            down.strokeColor = (onChevron == .down ? Theme.text : Theme.tertiaryText).cgColor
        }
    }

    /// Which chevron a height is on, if one's shown there.
    private func chevron(at y: CGFloat) -> Chevron? {
        let b = block
        if more.above, y >= b.top - StripLayout.pad - 2, y < b.top { return .up }
        if more.below, y > b.bottom, y <= b.bottom + StripLayout.pad + 2 { return .down }
        return nil
    }

    /// A chevron clicked: the column scrolled by most of itself.
    func go(_ c: Chevron) {
        let step = max(1, ticks.count - 2)
        first += c == .up ? -step : step
        first = min(max(first, 0), max(chosen.count - ticks.count, 0))
        card.hide()
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        draw(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { card.hide(); fade?.invalidate() } else { draw(animated: false) }
    }

    // MARK: The pointer

    /// The column's span and the chevrons', in the ticks' lane.
    private func onColumn(_ p: NSPoint) -> Bool {
        guard !ticks.isEmpty, p.x >= 0, p.x < Self.lane else { return false }
        let b = block
        return p.y >= b.top - (more.above ? StripLayout.pad : 2) && p.y <= b.bottom + (more.below ? StripLayout.pad : 2)
    }

    /// The scroll bar where it is; the ticks' lane only on the column:
    /// elsewhere it's the content's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p), !isHidden else { return nil }
        if p.x >= Self.lane { return scrubber.isHidden ? nil : scrubber.hitTest(p) }
        // Faded, the ticks take nothing from what's under them.
        return onColumn(p) && column.opacity > 0 ? self : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        let b = block
        addCursorRect(NSRect(x: 0, y: b.top - StripLayout.pad, width: Self.lane, height: b.bottom - b.top + 2 * StripLayout.pad), cursor: .arrow)
    }

    /// The tick at a height, if there's one there.
    private func tick(near y: CGFloat) -> StripTick? {
        ticks.min { abs($0.y - y) < abs($1.y - y) }.flatMap { abs($0.y - y) <= StripLayout.pitch / 2 + 1 ? $0 : nil }
    }

    /// The pointer at a height on the column: the ticks around it widened,
    /// the one there previewed; nil, off it.
    func hover(at y: CGFloat?) {
        if let y, let c = chevron(at: y) {
            onChevron = c
            pointer = nil
            hovered = nil
            card.hide()
            draw(animated: true)
            return
        }
        onChevron = nil
        let was = pointer
        pointer = y
        hovered = y.flatMap { tick(near: $0)?.index }
        if was == nil, y == nil { return }
        draw(animated: true)
        guard let y, let i = hovered, outline.items.indices.contains(i), let t = ticks.first(where: { $0.index == i }) else {
            return card.hide()
        }
        let item = outline.items[i]
        card.show(title: item.title, detail: item.detail, lines: preview?(i) ?? [], code: previewIsCode || item.code,
                  beside: self, at: t.y, pointerAt: y)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !pointerIn { pointerIn = true; reveal() }
        hover(at: onColumn(p) ? p.y : nil)
    }
    override func mouseExited(with event: NSEvent) {
        pointerIn = false
        reveal()
        hover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard onColumn(p) else { return }
        if let c = chevron(at: p.y) { return go(c) }
        if let t = tick(near: p.y) {
            card.hide()
            outline.pick(t.index)
        }
    }

    // MARK: Debugging

    var debugState: String {
        let lines = ticks.map { t -> String in
            let title = outline.items.indices.contains(t.index) ? outline.items[t.index].title : "?"
            let at = items.indices.contains(t.index) ? " @\(Int(items[t.index].start))+\(Int(items[t.index].size))" : ""
            return "\(t.index) y \(Int(t.y)) h\(t.height)\(at)\(t.lit ? " lit" : "")\(hovered == t.index ? " *" : "") \(title.prefix(40))"
        }
        return "total \(Int(total)) offset \(Int(offset)) shown \(Int(shown)) up \(more.above ? "+" : "-") down \(more.below ? "+" : "-") items \(items.count) chosen \(chosen.count) first \(first) shows \(ticks.count) track \(Int(track.top))+\(Int(track.height)) block \(Int(block.top))…\(Int(block.bottom)) scrollbar \(scrubber.isHidden ? "-" : "+") ticks \(column.opacity > 0 ? "shown" : "faded") card \(card.isShown ? card.debugTitle : "-")\n" + lines.joined(separator: "\n")
    }

    /// The strip drawn, wider (the ticks widened left of it), larger.
    private func image(to path: String, scale: Double) -> String {
        guard let root = layer else { return "no layer" }
        let extra: CGFloat = 40, w = bounds.width + extra, h = bounds.height
        let s = CGFloat(scale)
        guard let ctx = CGContext(data: nil, width: Int(w * s), height: Int(h * s), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(Theme.windowBackground.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: w * s, height: h * s))
        // Flipped, as the view is.
        ctx.translateBy(x: 0, y: h * s)
        ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: extra, y: 0)
        root.render(in: ctx)
        guard let img = ctx.makeImage() else { return "no image" }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return "wrote \(path)"
    }

    /// "hover <f>" (the pointer that far down the column), "off", "pick <i>", "up", "down".
    func debug(_ arg: String) -> String {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first {
        case "hover":
            if let f = a.dropFirst().first.flatMap(Double.init) {
                let b = block
                hover(at: b.top + CGFloat(f) * (b.bottom - b.top))
            }
        case "off": hover(at: nil)
        case "pick": if let i = a.dropFirst().first.flatMap(Int.init) { outline.pick(i) }
        case "up": go(.up)
        case "down": go(.down)
        case "image":
            // "image <path> [scale]": the strip's layers drawn, on its view's ground.
            if a.count > 1 { return image(to: a[1], scale: a.count > 2 ? Double(a[2]) ?? 4 : 4) }
        default: break
        }
        return debugState
    }
}

/// A strip for a scroll view's document: kept up with its scrolling and
/// its size, its items' tops asked for again as the document or the
/// outline changes; its scroll bar the strip's (the scroll view's own
/// hidden) or the scroll view's.
@MainActor
final class ScrollStrip {
    let strip: OutlineStripView
    private weak var scroll: NSScrollView?
    /// Each item's top in the document (its own coordinates) and level,
    /// one for each of the outline's items.
    var tops: () -> [(y: CGFloat, level: Int)] = { [] }
    private var filled: (size: NSSize, generation: Int)?
    private var observer: NSObjectProtocol?

    init(outline: Outline, scroll: NSScrollView, ownsScrollBar: Bool) {
        strip = OutlineStripView(outline: outline, policy: .document)
        self.scroll = scroll
        strip.hasScrollBar = ownsScrollBar
        if ownsScrollBar {
            scroll.hasVerticalScroller = false
            strip.onScroll = { [weak self] f in self?.scroll(to: f) }
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.unchecked { self?.update() }
        }
        outline.watch(strip) { [weak self] in
            MainActor.unchecked { self?.update() }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Down the right of `rect` (in the strip's superview).
    func place(_ rect: NSRect) {
        strip.frame = OutlineStripView.frame(right: rect.maxX, y: rect.minY, height: rect.height)
        update()
    }

    /// The document's height, the part shown and where — from its top.
    private var extent: (total: Double, offset: Double, shown: Double)? {
        guard let scroll, let doc = scroll.documentView else { return nil }
        let h = doc.frame.height, clip = scroll.contentView.bounds
        return (Double(h), Double(doc.isFlipped ? clip.minY : h - clip.maxY), Double(clip.height))
    }

    /// The tops asked for again, the next time it's brought up to date.
    func refill() { filled = nil; update() }

    func update() {
        guard let scroll, let doc = scroll.documentView, let e = extent else { return }
        let key = (doc.frame.size, strip.outline.generation)
        if filled.map({ $0.size != key.0 || $0.generation != key.1 }) ?? true {
            filled = key
            let t = tops()
            if t.count == strip.outline.items.count {
                let ys = t.map { Double(doc.isFlipped ? $0.y : doc.frame.height - $0.y) }
                strip.set(StripLayout.sections(tops: ys, levels: t.map(\.level), total: e.total))
            }
        }
        strip.update(total: e.total, offset: e.offset, shown: e.shown)
    }

    private func scroll(to f: Double) {
        guard let scroll, let doc = scroll.documentView, let e = extent else { return }
        let top = CGFloat(f * max(e.total - e.shown, 0))
        let y = doc.isFlipped ? top : doc.frame.height - CGFloat(e.shown) - top
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// The card beside the strip: the item under the pointer, its title and
/// a few lines of it — in a little window of its own over the window, so
/// nothing clips it and it never takes the pointer.
private final class StripCard {
    private let panel = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let box = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private(set) var isShown = false
    var debugTitle: String { title.stringValue }

    private final class CardPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        box.wantsLayer = true
        box.layer?.cornerRadius = Radius.surface
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 0.5
        title.font = UIType.title
        title.lineBreakMode = .byTruncatingTail
        detail.font = UIType.footnote
        detail.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = 5
        body.lineBreakMode = .byTruncatingTail
        for v in [title, detail, body] { box.addSubview(v) }
        panel.contentView = box
    }

    static let width: CGFloat = 280

    func show(title t: String, detail d: String, lines: [String], code: Bool, beside strip: NSView, at y: CGFloat, pointerAt: CGFloat) {
        guard let window = strip.window else { return hide() }
        let appearance = strip.effectiveAppearance
        panel.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = Theme.panel.cgColor
            box.layer?.borderColor = Theme.panelBorder.cgColor
        }
        title.stringValue = t
        title.textColor = Theme.text
        detail.stringValue = d
        detail.textColor = Theme.secondaryText
        detail.isHidden = d.isEmpty
        // Prose wraps, as a paragraph does; output keeps its lines.
        body.stringValue = code ? lines.joined(separator: "\n") : lines.joined(separator: " ")
        body.lineBreakMode = code ? .byTruncatingTail : .byWordWrapping
        body.maximumNumberOfLines = code ? 5 : 6
        body.cell?.truncatesLastVisibleLine = true
        body.font = code ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 13)
        body.textColor = Theme.secondaryText
        body.isHidden = lines.isEmpty
        let inner = Self.width - 24
        var h: CGFloat = 10
        let tH = ceil(title.sizeThatFits(NSSize(width: inner, height: 40)).height)
        let dH = d.isEmpty ? 0 : ceil(detail.sizeThatFits(NSSize(width: inner, height: 40)).height)
        body.preferredMaxLayoutWidth = inner
        let bH = lines.isEmpty ? 0 : min(ceil(body.sizeThatFits(NSSize(width: inner, height: 400)).height), 112)
        h += tH + (dH > 0 ? dH + 2 : 0) + (bH > 0 ? bH + 6 : 0) + 10
        // Flipped by hand: the box isn't.
        var top = h - 10
        title.frame = NSRect(x: 12, y: top - tH, width: inner, height: tH); top -= tH
        if dH > 0 { detail.frame = NSRect(x: 12, y: top - dH - 2, width: inner, height: dH); top -= dH + 2 }
        if bH > 0 { body.frame = NSRect(x: 12, y: top - bH - 6, width: inner, height: bH) }
        // Left of the ticks (widened as they are under the pointer), level
        // with the one it says, kept on the window.
        let inWindow = strip.convert(NSPoint(x: 0, y: y), to: nil)
        let screen = window.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
        let frame = window.frame
        var x = screen.x - Self.width - 18
        x = max(frame.minX + 4, x)
        var yTop = min(screen.y + 16, frame.maxY - 30)
        yTop = max(yTop, frame.minY + h + 4)
        panel.setFrame(NSRect(x: x, y: yTop - h, width: Self.width, height: h), display: true)
        if !isShown || panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            isShown = true
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
