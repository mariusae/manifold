import AppKit
import ManifoldCore

/// A block's status in one glyph (§3.7), drawn wherever its name is: an
/// open ring turning for running (filling clockwise from the top when the
/// program says how far, as OSC 9;4 or 7501 progress does), an amber ring
/// with a dot for a block that needs you, a filled disc with a check for
/// done and not yet read (red for failed), a plain grey check once read,
/// and a moon for a terminal gone inactive.
final class StatusGlyph: NSView {
    enum Look: Equatable {
        case working(progress: Int?)
        case needsYou
        case done(read: Bool)
        case failed(read: Bool)
        case inactive
        /// A host being reached (§8).
        case connecting
        /// A host that can't be reached now: what's shown is as last seen.
        case offline
        /// Put away as it was (§3.7): an archive box.
        case archived
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
        if block.isArchived { return .archived }
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

    /// When the status shown came to be: the report's stamp; for an
    /// inactive terminal, when its shell went; nothing for the rest.
    static func at(of block: Block?) -> Stamp? {
        guard let block, let look = look(of: block) else { return nil }
        switch look {
        case .inactive: return block.terminal?.dormantSince
        case .archived: return nil
        default: return block.statusRecord?.at
        }
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
        case .archived: words = ["Archived: as it was" + (block.kind == .terminal ? "; no shell" : "")]
        case .connecting: words = ["Connecting to its host"]
        case .offline: words = ["Its host can't be reached: as last seen"]
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

    /// The status in a line: what the tooltip says, with " · " between.
    static func summary(_ block: Block?) -> String? {
        tooltip(block)?.split(separator: "\n").joined(separator: " · ")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override var isHidden: Bool { didSet { updateTimer() } }

    private var animates: Bool {
        guard !isHidden, window != nil, let look else { return false }
        if case .working(nil) = look { return true }
        if case .connecting = look { return true }
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
        Self.draw(look, in: NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s), phase: phase)
    }

    /// The glyph drawn anywhere (a pill in a note): in a square, at a
    /// phase of its turning.
    static func draw(_ look: Look, in rect: NSRect, phase: Double) {
        let s = rect.width
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = s / 2 - 1
        switch look {
        case .working, .connecting:
            // Running: an open ring. With no word of how far, three
            // quarters of it, turning; with progress, as much of it as is
            // done, clockwise from the top over a faint track.
            let p: Int? = if case .working(let p) = look { p } else { nil }
            let ink = look == .connecting ? Theme.secondaryText : Theme.text.withAlphaComponent(0.9)
            let arc = NSBezierPath()
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            if let p {
                let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                track.lineWidth = 2
                Theme.text.withAlphaComponent(0.15).setStroke()
                track.stroke()
                if p > 0 {
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * Double(min(p, 100)) / 100, clockwise: true)
                }
            } else {
                let start = 45 - (phase * 180).truncatingRemainder(dividingBy: 360)
                arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 270, clockwise: true)
            }
            ink.setStroke()
            arc.stroke()
        case .needsYou:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            ring.lineWidth = 1.6
            amber.setStroke()
            ring.stroke()
            amber.setFill()
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
            let failed = look == .failed(read: read)
            if read {
                (failed ? Theme.statusError.withAlphaComponent(0.6) : Theme.secondaryText.withAlphaComponent(0.8)).setStroke()
                check.stroke()
            } else {
                // Not yet read: a filled disc with the check cut in it.
                let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                (failed ? Theme.statusError : Theme.text.withAlphaComponent(0.88)).setFill()
                disc.fill()
                Theme.panel.setStroke()
                check.lineWidth = 1.6
                check.stroke()
            }
        case .offline:
            // A ring with a slash through it.
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            ring.lineWidth = 1.4
            Theme.statusError.withAlphaComponent(0.8).setStroke()
            ring.stroke()
            let slash = NSBezierPath()
            slash.lineWidth = 1.4
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: center.x - radius * 0.6, y: center.y - radius * 0.6))
            slash.line(to: NSPoint(x: center.x + radius * 0.6, y: center.y + radius * 0.6))
            slash.stroke()
        case .archived:
            // An archive box: a lid across the top, the box beneath with a
            // short handle on its front.
            let grey = Theme.secondaryText.withAlphaComponent(0.85)
            grey.setStroke()
            let lid = NSBezierPath(roundedRect: NSRect(x: center.x - radius, y: center.y + radius * 0.3, width: 2 * radius, height: radius * 0.55), xRadius: 1, yRadius: 1)
            lid.lineWidth = 1.3
            lid.stroke()
            let box = NSBezierPath()
            box.lineWidth = 1.3
            box.lineJoinStyle = .round
            box.move(to: NSPoint(x: center.x - radius * 0.8, y: center.y + radius * 0.3))
            box.line(to: NSPoint(x: center.x - radius * 0.8, y: center.y - radius))
            box.line(to: NSPoint(x: center.x + radius * 0.8, y: center.y - radius))
            box.line(to: NSPoint(x: center.x + radius * 0.8, y: center.y + radius * 0.3))
            box.stroke()
            let handle = NSBezierPath()
            handle.lineWidth = 1.3
            handle.lineCapStyle = .round
            handle.move(to: NSPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.25))
            handle.line(to: NSPoint(x: center.x + radius * 0.3, y: center.y - radius * 0.25))
            handle.stroke()
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
