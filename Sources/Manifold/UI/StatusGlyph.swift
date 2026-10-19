import AppKit
import ManifoldCore

/// A block's status in one glyph (§3.7), as apex's handle says what a
/// window waits for: working is a ring, an arc turning while the program
/// doesn't say how far, filled clockwise from the top as far as it does;
/// blocked is the ring pulsing in the accent; done a filled dot in the
/// accent; error a filled dot in red; idle nothing. Drawn wherever a
/// block's name is: a pill, a sidebar row, a card.
final class StatusGlyph: NSView {
    var record: StatusRecord? {
        didSet {
            if record?.state != oldValue?.state || record?.progress != oldValue?.progress { needsDisplay = true }
            updateTimer()
            toolTip = Self.tooltip(record)
        }
    }

    static let size: CGFloat = 12
    private var timer: Timer?
    private var phase: Double = 0

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override var isHidden: Bool { didSet { updateTimer() } }

    static func tooltip(_ r: StatusRecord?) -> String? {
        guard let r else { return nil }
        var words: [String]
        switch r.state {
        case .idle: words = ["Idle"]
        case .working: words = [r.progress.map { "Working, \($0)%" } ?? "Working"]
        case .done: words = ["Done"]
        case .error: words = ["Failed"]
        case .blocked:
            switch r.kind {
            case .permission?: words = ["Waiting for permission"]
            case .question?: words = ["Waiting for an answer"]
            case .auth?: words = ["Waiting to sign in"]
            case nil: words = ["Waiting on you"]
            }
        }
        if let app = r.app { words[0] += " · " + app }
        if let title = r.title, !title.isEmpty { words.append(title) }
        if let msg = r.msg, !msg.isEmpty { words.append(msg) }
        return words.joined(separator: "\n")
    }

    /// Whether anything shows for a record at all.
    static func shows(_ r: StatusRecord?) -> Bool { r != nil && r?.state != .idle }

    private var animates: Bool {
        guard !isHidden, window != nil, let r = record else { return false }
        return (r.state == .working && r.progress == nil) || r.state == .blocked
    }

    private func updateTimer() {
        if animates {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase += 1 / 30
                self.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = record, r.state != .idle else { return }
        let rect = NSRect(x: (bounds.width - Self.size) / 2, y: (bounds.height - Self.size) / 2, width: Self.size, height: Self.size)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = Self.size / 2 - 1.25
        switch r.state {
        case .done, .error:
            (r.state == .done ? Theme.accent : Theme.statusError).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius + 1, y: center.y - radius + 1, width: 2 * radius - 2, height: 2 * radius - 2)).fill()
        case .working, .blocked:
            let faint = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            faint.lineWidth = 1.5
            (r.state == .blocked ? Theme.accent : Theme.secondaryText).withAlphaComponent(0.25).setStroke()
            faint.stroke()
            let arc = NSBezierPath()
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            if r.state == .blocked {
                // Pulsing: the ring breathes in the accent.
                let a = 0.55 + 0.45 * sin(phase * 2.6)
                Theme.accent.withAlphaComponent(a).setStroke()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 450)
            } else if let p = r.progress {
                // Filled clockwise from the top, as far as the program says.
                Theme.accent.setStroke()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * Double(p) / 100, clockwise: true)
            } else {
                // Turning, as long as it doesn't say.
                Theme.accent.setStroke()
                let start = 90 - (phase * 220).truncatingRemainder(dividingBy: 360)
                arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
            }
            arc.stroke()
        case .idle:
            break
        }
    }
}
