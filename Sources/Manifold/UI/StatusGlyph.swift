import AppKit
import ManifoldCore

/// A block's status in one glyph (§3.7), drawn wherever its name is: a
/// thin arc turning for working (filling clockwise from the top when the
/// program says how far), an amber ring with a dot for a block that needs
/// you, a filled check for done and not yet read (red for failed), a
/// plain grey check once read, and a moon for a terminal gone inactive.
final class StatusGlyph: NSView {
    enum Look: Equatable {
        case working(progress: Int?)
        case needsYou
        case done(read: Bool)
        case failed(read: Bool)
        case inactive
    }

    var look: Look? {
        didSet {
            if look != oldValue { needsDisplay = true }
            updateTimer()
        }
    }

    static let size: CGFloat = 13
    private var timer: Timer?
    private var phase: Double = 0

    /// What a block shows: its status; else, for a terminal whose shell
    /// ended for idleness, inactive; else nothing.
    static func look(of block: Block?) -> Look? {
        guard let block else { return nil }
        if let r = block.statusRecord {
            switch r.state {
            case .idle: break
            case .working: return .working(progress: r.progress)
            case .blocked: return .needsYou
            case .done: return .done(read: r.read == true)
            case .error: return .failed(read: r.read == true)
            }
        }
        if let t = block.terminal, t.dormantSince != nil, t.pid == nil { return .inactive }
        return nil
    }

    static func tooltip(_ block: Block?) -> String? {
        guard let block, let look = look(of: block) else { return nil }
        let r = block.statusRecord
        var words: [String]
        switch look {
        case .working(let p): words = [p.map { "Working, \($0)%" } ?? "Working"]
        case .done(let read): words = [read ? "Done" : "Done, not read yet"]
        case .failed(let read): words = [read ? "Failed" : "Failed, not read yet"]
        case .inactive: words = ["Inactive: the shell ended while idle"]
        case .needsYou:
            switch r?.kind {
            case .permission?: words = ["Needs you: permission"]
            case .question?: words = ["Needs you: a question"]
            case .auth?: words = ["Needs you: a sign-in"]
            case nil: words = ["Needs you"]
            }
        }
        if let app = r?.app { words[0] += " · " + app }
        if let title = r?.title, !title.isEmpty { words.append(title) }
        if let msg = r?.msg, !msg.isEmpty { words.append(msg) }
        return words.joined(separator: "\n")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override var isHidden: Bool { didSet { updateTimer() } }

    private var animates: Bool {
        guard !isHidden, window != nil, let look else { return false }
        if case .working(nil) = look { return true }
        return false
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

    static let amber = NSColor(srgbRed: 0.93, green: 0.68, blue: 0.3, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let look else { return }
        let s = Self.size
        let rect = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = s / 2 - 1
        switch look {
        case .working(let p):
            let arc = NSBezierPath()
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            Theme.text.withAlphaComponent(0.85).setStroke()
            if let p {
                let faint = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                faint.lineWidth = 1.6
                Theme.text.withAlphaComponent(0.18).setStroke()
                faint.stroke()
                Theme.text.withAlphaComponent(0.85).setStroke()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * Double(p) / 100, clockwise: true)
            } else {
                let start = 90 - (phase * 240).truncatingRemainder(dividingBy: 360)
                arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 280, clockwise: true)
            }
            arc.stroke()
        case .needsYou:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            ring.lineWidth = 1.6
            Self.amber.setStroke()
            ring.stroke()
            Self.amber.setFill()
            let r = radius * 0.42
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        case .done(let read), .failed(let read):
            let check = NSBezierPath()
            check.lineWidth = read ? 1.6 : 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            let k = s * 0.16
            check.move(to: NSPoint(x: center.x - 1.9 * k, y: center.y - 0.1 * k))
            check.line(to: NSPoint(x: center.x - 0.6 * k, y: center.y - 1.4 * k))
            check.line(to: NSPoint(x: center.x + 2.0 * k, y: center.y + 1.3 * k))
            if read {
                (look == .done(read: true) ? Theme.secondaryText : Theme.statusError.withAlphaComponent(0.7)).setStroke()
                check.stroke()
            } else {
                let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 0.5, y: center.y - radius - 0.5, width: 2 * radius + 1, height: 2 * radius + 1))
                (look == .done(read: false) ? Theme.text : Theme.statusError).setFill()
                disc.fill()
                Theme.windowBackground.setStroke()
                check.stroke()
            }
        case .inactive:
            // A crescent: the disc less a disc shifted up and right.
            let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            let bite = NSBezierPath(ovalIn: NSRect(x: center.x - radius + 3.2, y: center.y - radius + 2.6, width: 2 * radius, height: 2 * radius))
            disc.append(bite.reversed)
            disc.windingRule = .nonZero
            Theme.secondaryText.withAlphaComponent(0.75).setFill()
            disc.fill()
        }
    }
}
