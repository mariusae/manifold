import AppKit
import ManifoldCore

/// A view's outline as its scroll bar (§3.1, §7.5): down the view's right
/// edge, a mark for each item that fits — the most telling of them, where
/// it is — its length how much it spans, its weight its level, its colour
/// what it is (failed, running, what you asked an agent). The part shown
/// is the knob, dragged as a scroll bar's. The pointer on it magnifies the
/// marks around it, as the Dock does its icons, and the room that opens is
/// given to the items there that didn't fit; the one under the pointer is
/// previewed in a card beside it, and clicked, gone to.

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

/// Where the strip looks from when it picks: the part shown (a page), or
/// the end (a terminal: its latest commands matter most).
enum StripPolicy: Equatable {
    case document
    case recent
}

/// A mark placed: the item it stands for, its middle (from the strip's
/// top), how magnified it is there, and whether it's one the pointer's
/// magnification made room for.
struct StripMark: Equatable {
    var index: Int
    var y: CGFloat
    var scale: CGFloat
    var extra: Bool
}

enum StripLayout {
    /// The room a mark takes at rest, and the least between two magnified.
    static let pitch: CGFloat = 12
    static let minPitch: CGFloat = 7
    /// Top and bottom, kept clear.
    static let pad: CGFloat = 8

    /// How many marks fit at rest.
    static func budget(height: CGFloat) -> Int { max(3, Int((height - 2 * pad) / pitch)) }

    /// How much an item matters, where you are: its level, its size, what
    /// it says (failed, running, asked), less how far it is from where the
    /// strip looks from (`focus`, a fraction of the whole).
    static func interest(_ item: StripItem, total: Double, largest: Double, focus: Double, sharpness: Double) -> Double {
        // A level outweighs nearness and size: a page's H2 far off before
        // a paragraph near.
        let level = [2.0, 1.2, 0.5, 0.2][min(max(item.level, 0), 3)]
        let size = log1p(max(item.size, 0)) / log1p(max(largest, 1)) * 0.5
        var api = level + size
        if item.failed { api += 1.5 }
        if item.running { api += 2 }
        if item.you { api += 0.2 }
        let middle = (item.start + item.size / 2) / max(total, 1)
        return api - abs(middle - focus) * sharpness
    }

    /// The marks at rest: the `budget` that matter most from `focus`, in
    /// order. Those shown before keep a little more, so the marks don't
    /// trade places at each scroll (`previous`).
    static func rest(_ items: [StripItem], total: Double, focus: Double, policy: StripPolicy, budget: Int, previous: Set<Int> = []) -> [Int] {
        guard items.count > budget else { return Array(items.indices) }
        let largest = items.map(\.size).max() ?? 1
        // A page's headings are its landmarks wherever they are; a
        // terminal's latest commands matter most.
        let sharpness = policy == .recent ? 1.6 : 0.6
        let ranked = items.indices.map { i -> (Double, Int) in
            (interest(items[i], total: total, largest: largest, focus: focus, sharpness: sharpness) + (previous.contains(i) ? 0.1 : 0), i)
        }.sorted { $0.0 > $1.0 }
        return ranked.prefix(budget).map(\.1).sorted()
    }

    /// The fisheye (Sarkar and Brown's): `x` (0…1) seen through a lens at
    /// `p` magnifying `m + 1` times there — the ends stay, and so does `p`.
    static func fisheye(_ x: Double, at p: Double, by m: Double) -> Double {
        guard m > 0 else { return x }
        if x >= p {
            guard p < 1 else { return x }
            let d = (x - p) / (1 - p)
            return p + (m + 1) * d / (m * d + 1) * (1 - p)
        }
        guard p > 0 else { return x }
        let d = (p - x) / p
        return p - (m + 1) * d / (m * d + 1) * p
    }

    /// Each in order at least `gap` from the one before, all within 0…`length`,
    /// moved as little as that takes.
    static func spread(_ ys: [CGFloat], gap: CGFloat, length: CGFloat) -> [CGFloat] {
        guard !ys.isEmpty else { return [] }
        var out = ys
        for k in out.indices.dropFirst() { out[k] = max(out[k], out[k - 1] + gap) }
        if let last = out.indices.last { out[last] = min(out[last], length) }
        for k in out.indices.reversed().dropFirst() { out[k] = min(out[k], out[k + 1] - gap) }
        if out[0] < 0 {
            out[0] = 0
            for k in out.indices.dropFirst() { out[k] = max(out[k], out[k - 1] + gap) }
        }
        return out
    }

    /// The marks placed in a strip `height` high: those at rest where
    /// their items are (spread to `pitch` apart where they crowd); with the
    /// pointer at `pointer` (a fraction of the strip), magnified around it
    /// by `magnification`, and the items between them there that the room
    /// opened takes — the most telling first.
    static func place(_ items: [StripItem], rest: [Int], total: Double, height: CGFloat,
                      pointer: Double? = nil, magnification: Double = 2.5) -> [StripMark] {
        guard !rest.isEmpty else { return [] }
        let length = max(height - 2 * pad, 1)
        let total = max(total, 1)
        func fraction(_ i: Int) -> Double { min(max(items[i].start / total, 0), 1) }
        // At rest: where each is, kept a pitch apart.
        let atRest = spread(rest.map { CGFloat(fraction($0)) * length }, gap: pitch, length: length).map { Double($0 / length) }
        guard let p = pointer, magnification > 1 else {
            return zip(rest, atRest).map { StripMark(index: $0, y: pad + CGFloat($1) * length, scale: 1, extra: false) }
        }
        let m = magnification - 1
        func lens(_ x: Double) -> Double { fisheye(x, at: p, by: m) }
        func scale(_ x: Double) -> CGFloat {
            let e = 0.004
            let d = (lens(min(x + e, 1)) - lens(max(x - e, 0))) / (min(x + e, 1) - max(x - e, 0))
            return CGFloat(min(max(d, 1), magnification))
        }
        var marks = zip(rest, atRest).map { StripMark(index: $0, y: pad + CGFloat(lens($1)) * length, scale: scale($1), extra: false) }
        // Between each two (and before the first, after the last): the
        // items there, where they are between them, as many as the room
        // the lens opens within reach of the pointer holds.
        let largest = items.map(\.size).max() ?? 1
        let bounds = [(-1, 0.0, 0.0)] + zip(rest, atRest).map { ($0, $1, fraction($0)) } + [(items.count, 1.0, 1.0)]
        let py = CGFloat(p) * length, reach = pitch * 6
        for g in 0..<(bounds.count - 1) {
            let (a, xa, fa) = bounds[g], (b, xb, fb) = bounds[g + 1]
            guard b - a > 1 else { continue }
            let top = max(CGFloat(lens(xa)) * length, py - reach), bottom = min(CGFloat(lens(xb)) * length, py + reach)
            let fits = Int((bottom - top) / minPitch) - 1
            guard fits > 0, bottom - top > pitch * 1.4 else { continue }
            // Each where it is between the two, through the lens.
            let candidates = ((a + 1)..<b).compactMap { i -> (Int, Double)? in
                let x = fb > fa ? xa + (xb - xa) * (fraction(i) - fa) / (fb - fa) : (xa + xb) / 2
                let y = CGFloat(lens(x)) * length
                return y > top && y < bottom ? (i, x) : nil
            }
            let chosen = candidates.map { c in (interest(items[c.0], total: total, largest: largest, focus: p, sharpness: 1), c) }
                .sorted { $0.0 > $1.0 }.prefix(fits).map(\.1)
            for (i, x) in chosen {
                marks.append(StripMark(index: i, y: pad + CGFloat(lens(x)) * length, scale: scale(x), extra: true))
            }
        }
        marks.sort { $0.index < $1.index }
        let ys = spread(marks.map { $0.y - pad }, gap: minPitch, length: length)
        for k in marks.indices { marks[k].y = pad + ys[k] }
        return marks
    }
}

/// The strip itself: the marks, the knob, the card.
final class OutlineStripView: NSView {
    static let width: CGFloat = ScrubberView.width

    /// Scrolled to a fraction of the content, the knob dragged or the track clicked.
    var onScroll: ((Double) -> Void)?
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
    /// Whether the knob means anything (an agent's turns have no rows).
    var scrolls = true { didSet { needsLayout = true } }

    private(set) var rest: [Int] = []
    private(set) var marks: [StripMark] = []
    private(set) var pointer: Double?
    private var hovered: Int?
    private var markLayers: [Int: CALayer] = [:]
    private let knob = CALayer()
    private let card = StripCard()
    private var dragging: (grab: CGFloat, start: Double)?
    private var dragged = false
    private var fade: Timer?
    static var magnification = 2.6

    init(outline: Outline, policy: StripPolicy) {
        self.outline = outline
        self.policy = policy
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        layer?.masksToBounds = false
        knob.cornerRadius = Radius.inline
        knob.opacity = 0
        layer?.addSublayer(knob)
        outline.watch(self) { [weak self] in self?.relayout() }
        themed { $0.recolor() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: What it shows

    func update(total: Double, offset: Double, shown: Double) {
        let moved = total != self.total || offset != self.offset || shown != self.shown
        self.total = max(total, 1)
        self.offset = offset
        self.shown = max(shown, 1)
        if moved { reveal(); relayout() }
    }

    /// The outline's items as the strip weighs them, one for each of its items.
    func set(_ fresh: [StripItem], policy: StripPolicy? = nil) {
        if let policy { self.policy = policy }
        guard fresh != items else { return }
        items = fresh
        relayout()
    }

    /// Where the strip looks from at rest: the middle of what shows, or the end.
    private var focus: Double {
        switch policy {
        case .recent: 1
        case .document: min(max((offset + shown / 2) / max(total, 1), 0), 1)
        }
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        let usable = items.count == outline.items.count ? items : []
        let shownIndices = Set(outline.shown)
        // Narrowed by the sidebar's filter: those it admits.
        let admitted = usable.indices.filter { shownIndices.contains($0) }
        let sub = admitted.map { usable[$0] }
        let picked = StripLayout.rest(sub, total: total, focus: focus, policy: policy,
                                      budget: StripLayout.budget(height: bounds.height),
                                      previous: Set(rest.compactMap { admitted.firstIndex(of: $0) }))
        let placed = StripLayout.place(sub, rest: picked, total: total, height: bounds.height,
                                       pointer: pointer, magnification: Self.magnification)
        rest = picked.map { admitted[$0] }
        marks = placed.map { StripMark(index: admitted[$0.index], y: $0.y, scale: $0.scale, extra: $0.extra) }
        draw(animated: pointer != nil)
    }

    // MARK: Drawing

    private func color(_ item: StripItem, _ i: Int) -> NSColor {
        if item.running { return Theme.accent }
        if item.failed { return Status.failed }
        if item.you { return Theme.accent }
        if i == outline.current { return Theme.text }
        return [Theme.text, Theme.secondaryText, Theme.tertiaryText, Theme.tertiaryText][min(item.level, 3)]
    }

    private func draw(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !Motion.reduced ? 0.14 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if !animated { CATransaction.setDisableActions(true) }
        let largest = items.map(\.size).max() ?? 1
        let keep = Set(marks.map(\.index))
        for (i, l) in markLayers where !keep.contains(i) {
            l.removeFromSuperlayer()
            markLayers.removeValue(forKey: i)
        }
        let right = bounds.width - 2
        for m in marks where items.indices.contains(m.index) {
            let item = items[m.index]
            let l = markLayers[m.index] ?? {
                let l = CALayer()
                l.opacity = 0
                layer?.addSublayer(l)
                markLayers[m.index] = l
                return l
            }()
            // Its length: how much it spans (a log, so one long section
            // doesn't flatten the rest); its weight, its level.
            let span = log1p(max(item.size, 0)) / log1p(max(largest, 1))
            let length = (3 + 8 * CGFloat(span)) * (1 + (m.scale - 1) * 0.9)
            let thick = [3.0, 2.0, 1.5, 1.5][min(item.level, 3)] * (1 + (m.scale - 1) * 0.25)
            l.frame = NSRect(x: right - length, y: (m.y - thick / 2).rounded(.down), width: length, height: thick)
            l.cornerRadius = thick / 2
            effectiveAppearance.performAsCurrentDrawingAppearance { l.backgroundColor = color(item, m.index).cgColor }
            let lit = hovered == m.index
            l.opacity = lit || pointer != nil || dragging != nil ? 1 : (item.level == 0 || item.failed || item.running || item.you ? 0.85 : 0.6)
            l.borderWidth = lit ? 1.5 : 0
            effectiveAppearance.performAsCurrentDrawingAppearance { l.borderColor = Theme.accent.cgColor }
        }
        // The knob: what shows, where it is in the whole.
        if scrolls, total > shown {
            let length = max(bounds.height - 2 * StripLayout.pad, 1)
            let top = StripLayout.pad + CGFloat(offset / total) * length
            let height = max(CGFloat(shown / total) * length, 12)
            knob.frame = NSRect(x: 1, y: top, width: bounds.width - 2, height: height)
            knob.isHidden = false
        } else {
            knob.isHidden = true
        }
        CATransaction.commit()
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            knob.backgroundColor = (dragging != nil ? Theme.handle : Theme.scrubberKnob).withAlphaComponent(0.55).cgColor
        }
        draw(animated: false)
    }

    /// The knob shown while the content moves, the pointer's on it, and a
    /// moment after; the marks stay.
    private func reveal() {
        fade?.invalidate()
        knob.opacity = 1
        guard pointer == nil, dragging == nil else { return }
        fade = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.unchecked {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                self.knob.opacity = 0
                CATransaction.commit()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { card.hide(); fade?.invalidate() } else { recolor() }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func fraction(at y: CGFloat) -> Double {
        let length = max(bounds.height - 2 * StripLayout.pad, 1)
        return Double(min(max((y - StripLayout.pad) / length, 0), 1))
    }

    /// The mark nearest a height in the strip, if one's within reach.
    private func mark(near y: CGFloat) -> StripMark? {
        marks.min { abs($0.y - y) < abs($1.y - y) }.flatMap { abs($0.y - y) <= StripLayout.pitch ? $0 : nil }
    }

    /// The pointer at a height: the marks magnified around it, the one
    /// there lit and its card shown; nil, off it.
    func hover(at y: CGFloat?) {
        pointer = y.map(fraction)
        relayout()
        hovered = y.flatMap { mark(near: $0)?.index }
        draw(animated: true)
        reveal()
        guard let y, let i = hovered, outline.items.indices.contains(i), let m = marks.first(where: { $0.index == i }) else {
            return card.hide()
        }
        let item = outline.items[i]
        card.show(title: item.title, detail: item.detail, lines: preview?(i) ?? [], code: previewIsCode || item.code,
                  beside: self, at: m.y, pointerAt: y)
    }

    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil).y) }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil).y) }
    override func mouseExited(with event: NSEvent) {
        guard dragging == nil else { return }
        hover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragged = false
        if scrolls, knob.frame.insetBy(dx: 0, dy: -2).contains(p), mark(near: p.y) == nil {
            dragging = (p.y, offset)
            recolor()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard scrolls else { return }
        let p = convert(event.locationInWindow, from: nil)
        if dragging == nil, !dragged { dragging = (p.y, offset); card.hide() }
        guard let d = dragging else { return }
        dragged = true
        let rows = Double(p.y - d.grab) / Double(max(1, bounds.height - 2 * StripLayout.pad)) * total
        let target = min(max(d.start + rows, 0), max(total - shown, 0))
        onScroll?(target / max(total - shown, 1))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let wasDragging = dragging != nil
        dragging = nil
        recolor()
        if dragged || wasDragging { return }
        // On a mark: its item gone to; else, the page there.
        if let m = mark(near: p.y) {
            card.hide()
            outline.pick(m.index)
            return
        }
        if scrolls { onScroll?(fraction(at: p.y)) }
    }

    // MARK: Debugging

    var debugState: String {
        let lines = marks.map { m -> String in
            let t = outline.items.indices.contains(m.index) ? outline.items[m.index].title : "?"
            return "\(m.index) y \(Int(m.y)) x\(String(format: "%.2f", m.scale))\(m.extra ? " +" : "")\(hovered == m.index ? " *" : "") \(t.prefix(40))"
        }
        return "items \(items.count) rest \(rest.count) budget \(StripLayout.budget(height: bounds.height)) pointer \(pointer.map { String(format: "%.2f", $0) } ?? "-") card \(card.isShown ? card.debugTitle : "-")\n" + lines.joined(separator: "\n")
    }

    func debug(_ arg: String) -> String {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first {
        case "hover": if let f = a.dropFirst().first.flatMap(Double.init) { hover(at: StripLayout.pad + CGFloat(f) * max(bounds.height - 2 * StripLayout.pad, 1)) }
        case "off": hover(at: nil)
        case "pick": if let i = a.dropFirst().first.flatMap(Int.init) { outline.pick(i) }
        default: break
        }
        return debugState
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
        // Left of the strip, level with the mark, kept on the window.
        let inWindow = strip.convert(NSPoint(x: 0, y: y), to: nil)
        let screen = window.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
        let frame = window.frame
        var x = screen.x - Self.width - 10
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
