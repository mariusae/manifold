import AppKit

/// A host's ping times over the last five minutes as a small line, by its
/// name in the sidebar: latency getting worse or better, at a glance. Time
/// runs left to right, now at the right; round trips up from nothing to
/// the most of the five minutes; a gap where pings went unanswered (the
/// link given up on), and a dot at the latest — amber when it's well above
/// the rest. Redrawn as they come.
final class Sparkline: NSView {
    typealias Pings = [(at: Date, rtt: TimeInterval?)]

    var pings: (() -> Pings)? {
        didSet {
            needsDisplay = true
            updateTimer()
        }
    }
    static let span: TimeInterval = 300
    static let width: CGFloat = 56, height: CGFloat = 14
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil, pings != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the host was out of touch: from the last ping answered before
    /// one went unanswered (the link given up on) to the next answered —
    /// or to now, if none has been since. Shaded, not drawn across.
    static func gaps(_ points: Pings, now: Date) -> [(from: Date, to: Date)] {
        var out: [(from: Date, to: Date)] = []
        var lastAnswered: Date?
        var open: Date?
        for p in points {
            if p.rtt == nil {
                if open == nil { open = lastAnswered ?? p.at }
            } else {
                if let o = open { out.append((o, p.at)) }
                open = nil
                lastAnswered = p.at
            }
        }
        if let o = open { out.append((o, now)) }
        return out
    }

    /// Two answered pings this far apart (none between: the Mac asleep, say)
    /// aren't joined by a line.
    static let breakAfter: TimeInterval = 6

    /// The top of the scale: what most round trips come to, not a spike's
    /// (a spike goes past it, drawn at the top) — the 90th percentile and
    /// some, or twice the median; never above the most there is.
    static func top(_ rtts: [TimeInterval]) -> TimeInterval {
        let sorted = rtts.sorted()
        guard let most = sorted.last else { return 0.005 }
        guard sorted.count >= 5 else { return max(most, 0.005) }
        let p90 = sorted[Int(0.9 * Double(sorted.count - 1))]
        return max(0.005, min(most, max(p90 * 1.4, sorted[sorted.count / 2] * 2)))
    }

    /// Whether the latest is well above the rest: more than twice the
    /// median, and by more than a little.
    static func worse(_ rtts: [TimeInterval]) -> Bool {
        guard let last = rtts.last, rtts.count >= 4 else { return false }
        let median = rtts.sorted()[rtts.count / 2]
        return last > 2 * median && last - median > 0.03
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let points = pings?(), !points.isEmpty else { return }
        let now = Date()
        let rtts = points.compactMap(\.rtt)
        let top = Self.top(rtts)
        let inset: CGFloat = 1.5
        func x(_ at: Date) -> CGFloat { inset + (bounds.width - 2 * inset) * CGFloat(1 - min(1, now.timeIntervalSince(at) / Self.span)) }
        func y(_ rtt: TimeInterval) -> CGFloat { inset + (bounds.height - 2 * inset) * CGFloat(min(rtt, top) / top) }
        let worse = Self.worse(rtts)
        let ink = worse ? StatusGlyph.amber : Theme.secondaryText.withAlphaComponent(0.85)
        // A faint baseline, so a calm link's flat line reads as one.
        Theme.secondaryText.withAlphaComponent(0.15).setFill()
        NSRect(x: inset, y: inset - 0.5, width: bounds.width - 2 * inset, height: 0.5).fill()
        let line = NSBezierPath()
        line.lineWidth = 1.1
        line.lineJoinStyle = .round
        // Out of touch: a band, faintly red.
        for g in Self.gaps(points, now: now) {
            Theme.statusError.withAlphaComponent(0.22).setFill()
            NSRect(x: x(g.from), y: 0, width: max(1.5, x(g.to) - x(g.from)), height: bounds.height).fill()
        }
        var previous: Date?
        for p in points {
            guard let rtt = p.rtt else {
                previous = nil
                continue
            }
            let pt = NSPoint(x: x(p.at), y: y(rtt))
            if let previous, p.at.timeIntervalSince(previous) <= Self.breakAfter { line.line(to: pt) } else { line.move(to: pt) }
            previous = p.at
        }
        ink.setStroke()
        line.stroke()
        if let last = points.last, let rtt = last.rtt {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(last.at) - 1.6, y: y(rtt) - 1.6, width: 3.2, height: 3.2)).fill()
        }
    }
}
