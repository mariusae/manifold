import AppKit
import ManifoldCore

/// How a block's status shows by its name (§3.7), wherever its name is —
/// a sidebar row, a tile's bar, an overview's card. Something extra shows
/// only when it needs you: a word in a pill — Permission, Question, Sign
/// in, Needs you; Done; Failed — exactly while it's in the inbox (⌘J
/// goes to it), gone once seen. Working, the name shimmers (and a
/// program that says how far has its percent beside it, in grey); with
/// Reduce motion, the name is still, a little dim, a dot beside it. An
/// inactive terminal's name is dim. Done and seen: nothing. A host's
/// states (connecting, offline, quiet, watching) keep their glyphs, and a
/// notebook's cells their own.
struct StatusMark: Equatable {
    /// The name shimmers: working.
    var shimmer = false
    /// The pill at the trailing edge: a word that needs you, or how far.
    var pill: StatusPill.Kind?
    /// A glyph instead: a host's state, or — Reduce motion — working's dot.
    var glyph: StatusGlyph.Look?
    /// The name dimmed: an inactive terminal.
    var dim = false

    init(_ look: StatusGlyph.Look?, kind: BlockedKind? = nil) {
        switch look {
        case nil: break
        case .working(let p)?:
            shimmer = true
            if let p { pill = .progress(p) }
            if Motion.reduced { glyph = .busy }
        case .needsYou?: pill = .needs(StatusPill.words(kind))
        case .done(read: false)?: pill = .done
        case .failed(read: false)?: pill = .failed
        case .done?, .failed?: break
        case .inactive?: dim = true
        case .busy?, .connecting?, .offline?, .quiet?, .watching?: glyph = look
        }
    }

    init(of block: Block?) {
        self.init(StatusGlyph.look(of: block), kind: block?.statusRecord?.kind)
    }
}

/// A status in a word, in a capsule (`StatusMark`): amber for what
/// needs you, red for failed, grey for done; a percent alone, no capsule.
enum StatusPill {
    enum Kind: Equatable {
        case needs(String)
        case done
        case failed
        case progress(Int)
        /// A word in grey, not a state that wants anything (Editing).
        case note(String)

        var text: String {
            switch self {
            case .note(let w): w
            case .needs(let w): w
            case .done: "Done"
            case .failed: "Failed"
            case .progress(let p): "\(p)%"
            }
        }
    }

    /// What a blocked program needs, in a word.
    static func words(_ kind: BlockedKind?) -> String {
        switch kind {
        case .permission?: "Permission"
        case .question?: "Question"
        case .auth?: "Sign in"
        case nil: "Needs you"
        }
    }

    static let height: CGFloat = 16
    static let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let figures = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private static func ink(_ kind: Kind) -> NSColor {
        switch kind {
        case .needs: Status.attention
        case .failed: Status.failed
        case .done, .progress, .note: Theme.secondaryText
        }
    }

    private static func ground(_ kind: Kind) -> NSColor? {
        switch kind {
        case .needs: Status.attention.withAlphaComponent(0.16)
        case .failed: Status.failed.withAlphaComponent(0.14)
        case .done, .note: Pill.ground
        case .progress: nil
        }
    }

    private static func attributed(_ kind: Kind) -> NSAttributedString {
        let f = if case .progress = kind { figures } else { font }
        return NSAttributedString(string: kind.text, attributes: [.font: f, .foregroundColor: ink(kind)])
    }

    /// Short of room: a dot in its color for the word (a percent stays).
    static func compactSize(_ kind: Kind) -> NSSize {
        if case .progress = kind { return size(kind) }
        return NSSize(width: 8, height: height)
    }

    static func drawCompact(_ kind: Kind, in r: NSRect) {
        if case .progress = kind { return draw(kind, in: r) }
        ink(kind).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.midX - 3.5, y: r.midY - 3.5, width: 7, height: 7)).fill()
    }

    static func size(_ kind: Kind) -> NSSize {
        let w = ceil(attributed(kind).size().width)
        if case .progress = kind { return NSSize(width: w + 2, height: height) }
        return NSSize(width: w + 12, height: height)
    }

    static func draw(_ kind: Kind, in r: NSRect) {
        if let g = ground(kind) {
            g.setFill()
            NSBezierPath(roundedRect: r, xRadius: Radius.capsule(r.height), yRadius: Radius.capsule(r.height)).fill()
        }
        let s = attributed(kind)
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font
        let w = s.size().width
        // By the letters' cap height, so they sit in the middle.
        let baseline = r.minY + (r.height - f.capHeight) / 2
        let x = if case .progress = kind { r.maxX - w - 1 } else { (r.midX - w / 2).rounded() }
        s.draw(at: NSPoint(x: x, y: baseline + f.descender))
    }
}

/// A `StatusPill` as a view, for a row laid out by views.
final class StatusPillView: NSView {
    var kind: StatusPill.Kind? { didSet { if kind != oldValue { needsDisplay = true; isHidden = kind == nil } } }
    /// Short of room: a dot for the word.
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    var wanted: NSSize { kind.map { compact ? StatusPill.compactSize($0) : StatusPill.size($0) } ?? .zero }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let kind else { return }
        if compact { StatusPill.drawCompact(kind, in: bounds) } else { StatusPill.draw(kind, in: bounds) }
    }
}

/// A name shimmering while its block works (`StatusMark`): its layer
/// masked so a wide band, faded to 30%, sweeps across it every 3 s, the
/// name at full strength between — every name in step, by the clock, so
/// many working read as one rhythm. With Reduce motion it holds still at
/// 75%.
final class Shimmer {
    private weak var view: NSView?
    private var mask: CAGradientLayer?
    /// Whether the mask was made for Reduce motion (made again if that changes).
    private var madeReduced = false
    static let period: Double = 3
    /// How faded the band is at its middle.
    static let faded: CGFloat = 0.3
    /// How faded the name is, still (Reduce motion).
    static let still: CGFloat = 0.75

    /// The band across a name `w` wide, in a mask three times as wide (the
    /// band in its middle): each stop's alpha and place.
    static func stops(width w: CGFloat) -> [(alpha: CGFloat, at: CGFloat)] {
        // About 40% of the name, 60 points at least and 160 at most (no
        // wider than the name, so the mask always covers it); its middle
        // third at its faintest, its edges soft.
        let w = max(w, 1), half = min(min(max(0.42 * w, 60), 160) / 2, 0.45 * w) / (3 * w)
        return [(1, 0), (1, 0.5 - half), (faded, 0.5 - half / 3), (faded, 0.5 + half / 3), (1, 0.5 + half), (1, 1)]
    }

    init(_ view: NSView) { self.view = view }

    /// Every shimmer made, for debugging (`debugStrip`).
    private static let made = NSHashTable<Shimmer>.weakObjects()
    /// The first one sweeping now, if any.
    static var shown: [Shimmer] { made.allObjects.filter { $0.on && $0.view?.window != nil && $0.view?.isHiddenOrHasHiddenAncestor == false } }

    var on = false {
        didSet {
            guard on != oldValue else { return }
            if on { start() } else { stop() }
        }
    }

    /// Debugging: whether it's sweeping, still, or off.
    var debugState: String { mask == nil ? "off" : mask?.animation(forKey: "sweep") == nil ? "still" : "sweeping" }

    private func start() {
        guard let view else { return }
        view.wantsLayer = true
        let m = CAGradientLayer()
        m.startPoint = CGPoint(x: 0, y: 0.5)
        m.endPoint = CGPoint(x: 1, y: 0.5)
        madeReduced = Motion.reduced
        let still = NSColor(white: 0, alpha: Self.still).cgColor
        m.colors = madeReduced ? [still, still] : Self.stops(width: 1).map { NSColor(white: 0, alpha: $0.alpha).cgColor }
        mask = m
        view.layer?.mask = m
        Self.made.add(self)
        layout()
    }

    private func stop() {
        mask?.removeAllAnimations()
        if view?.layer?.mask === mask { view?.layer?.mask = nil }
        mask = nil
    }

    /// Debugging: the view's row (its superview) at `count` points along
    /// the sweep, one under another, at 2× — the mask applied by hand, as
    /// a picture of the window doesn't show it.
    func debugStrip(count: Int) -> NSImage? {
        guard let view, let row = view.superview, count > 0 else { return nil }
        let scale: CGFloat = 2
        func picture(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        view.isHidden = true
        let ground = picture(row)
        view.isHidden = false
        guard let ground, let label = picture(view) else { return nil }
        let w = row.bounds.width, h = row.bounds.height, lw = view.bounds.width
        let lr = view.convert(view.bounds, to: row)
        let out = NSImage(size: NSSize(width: w * scale, height: h * scale * CGFloat(count)))
        out.lockFocus()
        let stops = Self.stops(width: lw)
        let band = (0.5 - stops[1].at) * 3 * lw
        for i in 0..<count {
            let y = CGFloat(count - 1 - i) * h * scale
            // On the window's ground: a sidebar's row is clear.
            row.effectiveAppearance.performAsCurrentDrawingAppearance { Theme.windowBackground.setFill() }
            NSRect(x: 0, y: y, width: w * scale, height: h * scale).fill()
            ground.draw(in: NSRect(x: 0, y: y, width: w * scale, height: h * scale))
            // The label masked: drawn into its own image, then kept by the
            // gradient's alpha (full, the band faded).
            let mid = -band - 2 + (lw + 2 * band + 4) * CGFloat(i) / CGFloat(max(count - 1, 1))
            let masked = NSImage(size: NSSize(width: lw * scale, height: lr.height * scale))
            masked.lockFocus()
            label.draw(in: NSRect(x: 0, y: 0, width: lw * scale, height: lr.height * scale))
            let g = NSGradient(colors: stops.map { NSColor(white: 0, alpha: $0.alpha) }, atLocations: stops.map(\.at), colorSpace: .deviceGray)
            NSGraphicsContext.current?.compositingOperation = .destinationIn
            g?.draw(in: NSRect(x: (mid - 1.5 * lw) * scale, y: 0, width: 3 * lw * scale, height: lr.height * scale), angle: 0)
            masked.unlockFocus()
            let ly = row.isFlipped ? h - lr.maxY : lr.minY
            masked.draw(in: NSRect(x: lr.minX * scale, y: y + ly * scale, width: lw * scale, height: lr.height * scale))
        }
        out.unlockFocus()
        return out
    }

    /// The mask fitted to the view as it's now: called as it lays out.
    func layout() {
        if mask != nil, madeReduced != Motion.reduced { stop(); start(); return }
        guard let view, let m = mask else { return }
        let b = view.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if Motion.reduced {
            m.frame = b
            CATransaction.commit()
            return
        }
        // Three widths, the band in the middle of them (its middle the
        // mask's): it moves from just before the name to just past it,
        // then rests a beat before it again.
        let w = max(b.width, 1)
        let stops = Self.stops(width: w), half = (0.5 - stops[1].at) * 3 * w
        let from = -half - 2, to = w + half + 2
        m.bounds = CGRect(x: 0, y: 0, width: 3 * w, height: b.height)
        m.position = CGPoint(x: from, y: b.midY)
        m.locations = stops.map { NSNumber(value: Double($0.at)) }
        CATransaction.commit()
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = from
        sweep.toValue = to
        sweep.duration = Self.period * 0.65
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let group = CAAnimationGroup()
        group.animations = [sweep]
        group.duration = Self.period
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        // By the clock: every name in step, one made afresh not jumping.
        let t = m.convertTime(CACurrentMediaTime(), from: nil)
        group.beginTime = t - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        m.add(group, forKey: "sweep")
    }
}
