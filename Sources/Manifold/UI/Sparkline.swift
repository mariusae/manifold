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
        var drawing = false
        for p in points {
            guard let rtt = p.rtt else {
                // Unanswered: a break, and a mark at the bottom.
                drawing = false
                Theme.statusError.withAlphaComponent(0.8).setFill()
                NSRect(x: x(p.at) - 0.75, y: inset - 0.5, width: 1.5, height: 3).fill()
                continue
            }
            let pt = NSPoint(x: x(p.at), y: y(rtt))
            if drawing { line.line(to: pt) } else { line.move(to: pt) }
            drawing = true
        }
        ink.setStroke()
        line.stroke()
        if let last = points.last, let rtt = last.rtt {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(last.at) - 1.6, y: y(rtt) - 1.6, width: 3.2, height: 3.2)).fill()
        }
    }
}
