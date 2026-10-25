import AppKit
import ManifoldCore

/// A remote host's link at a glance, in its card while the pointer rests on
/// it in the sidebar: its ping times over the last five minutes, plotted
/// with their numbers (now, the median, the 95th percentile, the best),
/// where pings went unanswered and links were given up on; how it stands
/// (connected since when, reconnecting, unreachable and why), the links
/// that went in the last hour, and how the link is used (its rate, round
/// trip, queue, what compression saves). Redrawn each second while shown.
final class HostDashboard: NSView {
    private weak var client: HostClient?
    private var timer: Timer?
    static let size = NSSize(width: 480, height: 300)

    init(client: HostClient) {
        self.client = client
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    // MARK: Words

    static func ms(_ t: TimeInterval) -> String {
        let v = t * 1000
        return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
    }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// How it stands, in a line: for the card's detail too.
    static func standing(_ c: HostClient) -> String {
        switch c.link {
        case .connected:
            if let s = c.silenceDescription, c.silence != nil { return "Quiet: " + s }
            let since = c.connectedSince.map { "Connected \(duration(Date().timeIntervalSince($0))) (since \(clock.string(from: $0)))" } ?? "Connected"
            let last = c.pings.last?.rtt.map { " · \(ms($0))" } ?? ""
            return since + last
        case .connecting:
            return "Connecting" + (c.silenceDescription.map { " · " + $0 } ?? "")
        case .unreachable(let why):
            let when = c.nextTry.map { " · trying again in \(max(Int($0.timeIntervalSinceNow.rounded()), 0)) s" } ?? ""
            return "Unreachable" + (why.map { ": \($0)" } ?? "") + when
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let c = client else { return }
        let pad: CGFloat = 14
        let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let text = UIType.detail
        let grey = Theme.secondaryText
        func say(_ s: String, at p: NSPoint, font: NSFont = text, color: NSColor = Theme.text, right: Bool = false) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let w = a.size().width
            a.draw(at: NSPoint(x: right ? p.x - w : p.x, y: p.y))
        }

        // The plot: round trips over five minutes, an axis in ms at the left.
        let now = Date()
        let points = c.pings
        let rtts = points.compactMap(\.rtt)
        let axis: CGFloat = 46
        let plot = NSRect(x: pad + axis, y: pad, width: bounds.width - 2 * pad - axis, height: 130)
        let top = Self.niceTop(rtts.isEmpty ? 0.1 : Sparkline.top(rtts))
        // Grid: four lines, labelled.
        for i in 0...4 {
            let v = top * Double(i) / 4
            let y = plot.maxY - plot.height * CGFloat(i) / 4
            (i == 0 ? grey.withAlphaComponent(0.4) : grey.withAlphaComponent(0.13)).setFill()
            NSRect(x: plot.minX, y: y, width: plot.width, height: 0.5).fill()
            say(Self.ms(v), at: NSPoint(x: plot.minX - 6, y: y - 6), font: small, color: grey, right: true)
        }
        say("5 min ago", at: NSPoint(x: plot.minX, y: plot.maxY + 3), font: small, color: grey)
        say("now", at: NSPoint(x: plot.maxX, y: plot.maxY + 3), font: small, color: grey, right: true)
        func x(_ at: Date) -> CGFloat { plot.minX + plot.width * CGFloat(1 - min(1, now.timeIntervalSince(at) / Sparkline.span)) }
        func y(_ rtt: TimeInterval) -> CGFloat { plot.maxY - plot.height * CGFloat(min(rtt, top) / top) }
        // Out of touch: a band, faintly red, from the last ping answered to
        // the next.
        for g in Sparkline.gaps(points, now: now) {
            Theme.statusError.withAlphaComponent(0.1).setFill()
            NSRect(x: x(g.from), y: plot.minY, width: max(2, x(g.to) - x(g.from)), height: plot.height).fill()
        }
        // Links given up on: a red line where each went.
        for d in c.drops where now.timeIntervalSince(d.at) <= Sparkline.span {
            Theme.statusError.withAlphaComponent(0.5).setFill()
            NSRect(x: x(d.at) - 0.5, y: plot.minY, width: 1, height: plot.height).fill()
        }
        let worse = Sparkline.worse(rtts)
        let ink = worse ? StatusGlyph.amber : Theme.accent
        // The area under the line, faintly; then the line.
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        var run: [NSPoint] = []
        func endRun() {
            guard let first = run.first, let last = run.last else { return }
            let area = NSBezierPath()
            area.move(to: NSPoint(x: first.x, y: plot.maxY))
            for p in run { area.line(to: p) }
            area.line(to: NSPoint(x: last.x, y: plot.maxY))
            area.close()
            ink.withAlphaComponent(0.12).setFill()
            area.fill()
            line.move(to: first)
            for p in run.dropFirst() { line.line(to: p) }
            run = []
        }
        // Runs of answered pings, each drawn alone: none across a gap.
        var previous: Date?
        for p in points {
            guard let rtt = p.rtt else {
                endRun()
                previous = nil
                continue
            }
            if let previous, p.at.timeIntervalSince(previous) > Sparkline.breakAfter { endRun() }
            run.append(NSPoint(x: x(p.at), y: y(rtt)))
            previous = p.at
        }
        endRun()
        ink.setStroke()
        line.stroke()
        // Past the top (a spike): a tick there, at its time.
        for p in points {
            guard let rtt = p.rtt, rtt > top else { continue }
            ink.setFill()
            NSRect(x: x(p.at) - 1, y: plot.minY - 4, width: 2, height: 4).fill()
        }
        if let last = points.last, let rtt = last.rtt {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(last.at) - 2.5, y: y(rtt) - 2.5, width: 5, height: 5)).fill()
        }
        if rtts.isEmpty {
            say(c.isConnected ? "No pings answered yet" : "No pings while it's away", at: NSPoint(x: plot.midX - 60, y: plot.midY - 7), color: grey)
        }

        // The numbers.
        var lineY = plot.maxY + 22
        if !rtts.isEmpty {
            let sorted = rtts.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let unanswered = points.count - rtts.count
            var s = "now \(Self.ms(rtts.last!)) · median \(Self.ms(median)) · 95% \(Self.ms(p95)) · best \(Self.ms(sorted[0]))"
            s += " · \(rtts.count) pings" + (unanswered > 0 ? ", \(unanswered) unanswered" : "")
            say(s, at: NSPoint(x: pad, y: lineY), font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: worse ? StatusGlyph.amber : Theme.text)
            lineY += 20
        }

        // How it stands, what went, how the link is used.
        var rows: [(String, String)] = [("Link", Self.standing(c))]
        let hour = c.drops.filter { now.timeIntervalSince($0.at) <= 3600 }
        if !hour.isEmpty {
            let list = hour.suffix(3).reversed().map { "\(Self.clock.string(from: $0.at)) \($0.why)" }.joined(separator: "; ")
            rows.append(("Dropped", "\(hour.count) in the last hour — " + list))
        }
        if let st = c.mux?.stats {
            // As this end sees it (what it sends): once it's measured any.
            if let rt = st.roundTrip {
                rows.append(("Pacing", "round trip \(Self.ms(rt)) · queue \(Self.ms(st.queueDelay)) · budget \(Self.bytes(st.budget))"))
            }
            if st.sent.raw > 0 || st.received.raw > 0 {
                var z: [String] = []
                if st.received.raw > 0 { z.append("received \(Self.bytes(st.received.raw)) as \(Self.bytes(st.received.wire))") }
                if st.sent.raw > 0 { z.append("sent \(Self.bytes(st.sent.raw)) as \(Self.bytes(st.sent.wire))") }
                rows.append(("Compressed", z.joined(separator: " · ")))
            }
        }
        if let d = c.destination { rows.append(("Through", d.description)) }
        for (label, value) in rows {
            say(label, at: NSPoint(x: pad, y: lineY), color: grey)
            let a = NSAttributedString(string: value, attributes: [.font: text, .foregroundColor: Theme.text])
            a.draw(with: NSRect(x: pad + 78, y: lineY, width: bounds.width - 2 * pad - 78, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            lineY += 18
        }
    }

    /// A round number above the most: the plot's top.
    static func niceTop(_ v: TimeInterval) -> TimeInterval {
        let ms = max(v * 1000 * 1.15, 4)
        let steps: [Double] = [4, 8, 10, 20, 40, 50, 80, 100, 200, 400, 500, 800, 1000, 2000, 4000, 5000, 8000, 10000]
        return (steps.first { $0 >= ms } ?? ms) / 1000
    }
}
