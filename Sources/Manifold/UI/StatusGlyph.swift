import AppKit
import ManifoldCore

/// A block's status in one glyph (§3.7), drawn wherever its name is: an
/// open ring turning for running (filling clockwise from the top when the
/// program says how far, as OSC 9;4 or 7501 progress does), an amber ring
/// with a dot for a block that needs you, a filled disc with a check for
/// done and not yet read (red for failed), a plain grey check once read,
/// and a moon for a terminal gone inactive. A host's: being reached,
/// offline, quiet, or watched — an eye: another Manifold took it over.
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
        /// A host whose link is up but hasn't been heard from for a while
        /// (a ping unanswered): a broken ring.
        case quiet
        /// A host another Manifold took over (§8.2): this one watches,
        /// what's done here not taking until Take Over. An eye.
        case watching

        var isFinished: Bool { switch self { case .done, .failed: true; default: false } }
    }

    var look: Look? {
        didSet {
            if look != oldValue { needsDisplay = true }
            updateTurning()
            settleIfJustFinished()
        }
    }

    /// Just finished — running, then done or failed (not a glyph made
    /// afresh as done): it lands, a little larger, then its size, as a
    /// thing put down settles (it only fades in, with Reduce motion).
    /// The block it shows, where it's one's: a glyph is made afresh as
    /// often as it's kept (a row reloaded), so what just finished is
    /// known by the block, not by the glyph's last look.
    var block: BlockID? { didSet { if block != oldValue { settleIfJustFinished() } } }
    /// When each block was last seen to finish: running, then done or failed.
    private static var finishedAt: [BlockID: Date] = [:]
    private static var lastLook: [BlockID: Look] = [:]
    private var settledFor: Date?
    private func settleIfJustFinished() {
        guard look?.isFinished == true, let b = block, let at = Self.finishedAt[b], Date().timeIntervalSince(at) < 1.5, settledFor != at else { return }
        settledFor = at
        settle()
    }
    /// A block's look, seen: noted if it's just finished.
    private static func seen(_ look: Look?, of b: BlockID) -> Look? {
        if look?.isFinished == true, case .working = lastLook[b] { finishedAt[b] = Date() }
        lastLook[b] = look
        return look
    }

    /// Debugging: how many have settled.
    static var settled = 0
    private func settle() {
        Self.settled += 1
        wantsLayer = true
        guard let l = layer, window != nil else { return }
        if Motion.reduced {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.2
            a.toValue = 1
            a.duration = Motion.base
            l.add(a, forKey: "settle")
            return
        }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var big = CATransform3DMakeTranslation(c.x, c.y, 0)
        big = CATransform3DScale(big, 1.45, 1.45, 1)
        big = CATransform3DTranslate(big, -c.x, -c.y, 0)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = big
        a.toValue = CATransform3DIdentity
        a.duration = Motion.spatial * 1.5
        a.timingFunction = Motion.settle
        l.add(a, forKey: "settle")
    }

    static let size: CGFloat = 13
    /// The turning ring, while it turns: a layer the render server spins
    /// (it was drawn afresh on the main thread 30 times a second).
    private var spinner: CAShapeLayer?
    /// Where in its turning: by the clock, so every glyph turns together
    /// and one made afresh (a row reloaded, a cell reused) doesn't jump.
    private var phase: Double { Date.timeIntervalSinceReferenceDate }

    /// What a block shows: its status; else, for a terminal whose shell
    /// ended for idleness, inactive; else nothing.
    static func look(of block: Block?) -> Look? {
        guard let block else { return nil }
        return seen(plainLook(of: block), of: block.id)
    }
    private static func plainLook(of block: Block) -> Look? {
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
        case .connecting: words = ["Connecting to its host"]
        case .offline: words = ["Its host can't be reached: as last seen"]
        case .quiet: words = ["Its host has been quiet a while"]
        case .watching: words = ["Another Manifold took over its host: watching"]
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

    /// What the status says that the glyph doesn't — a question's kind,
    /// the title, the message — for a row beside the glyph: not "Done",
    /// "Working", which the glyph is.
    static func remark(_ block: Block?) -> String? {
        guard let block, let look = look(of: block) else { return nil }
        let r = block.statusRecord
        var words: [String] = []
        if look == .needsYou {
            switch r?.kind {
            case .permission?: words.append("permission")
            case .question?: words.append("a question")
            case .auth?: words.append("a sign-in")
            case nil: break
            }
        }
        if let title = r?.title, !title.isEmpty { words.append(title) }
        if let msg = r?.msg, !msg.isEmpty { words.append(msg) }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// The status in a line: what the tooltip says, with " · " between.
    static func summary(_ block: Block?) -> String? {
        tooltip(block)?.split(separator: "\n").joined(separator: " · ")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override var isHidden: Bool { didSet { updateTurning() } }

    /// Turning only where it can be seen: not hidden (itself or by a view
    /// it's in — a stashed tile's pill, the sidebar put away), in a window
    /// that's on screen.
    private var animates: Bool {
        guard !isHiddenOrHasHiddenAncestor, let window, window.occlusionState.contains(.visible) || Self.ignoresWindowOcclusion, let look else { return false }
        if case .working(nil) = look { return true }
        if case .connecting = look { return true }
        return false
    }

    /// As terminals: MANIFOLD_NO_OCCLUSION (testing) has them turn all the same.
    private static let ignoresWindowOcclusion = ProcessInfo.processInfo.environment["MANIFOLD_NO_OCCLUSION"] != nil

    private func updateTurning() {
        guard animates else {
            if spinner != nil {
                spinner?.removeFromSuperlayer()
                spinner = nil
                needsDisplay = true
            }
            return
        }
        if spinner == nil {
            wantsLayer = true
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.lineWidth = 2
            ring.lineCap = .round
            layer?.addSublayer(ring)
            spinner = ring
            placeSpinner()
            // Turning by the clock, as the drawn ring did: every glyph
            // together, one made afresh not jumping.
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 2
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            turn.beginTime = CACurrentMediaTime() - phase.truncatingRemainder(dividingBy: 2)
            ring.add(turn, forKey: "turn")
            needsDisplay = true
        }
        colorSpinner()
    }

    /// Debugging: the glyphs under `root` that turn, and the angle each
    /// is at on screen now (two looks apart differ if it turns).
    static func debugSpinners(in root: NSView, force: Bool = false) -> String {
        var out: [String] = []
        var forced = !force
        func walk(_ v: NSView) {
            // "force": the first shown glyph made to turn (as running would).
            if !forced, let g = v as? StatusGlyph, g.look != nil, !g.isHiddenOrHasHiddenAncestor { g.look = .working(progress: nil); forced = true }
            if let g = v as? StatusGlyph, let look = g.look {
                var line = "\(look) \(g.isHiddenOrHasHiddenAncestor ? "hidden" : "shown")"
                if let ring = g.spinner {
                    let angle = (ring.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? .nan
                    line += String(format: " %.0f° %@", angle * 180 / .pi, ring.animation(forKey: "turn") == nil ? "still" : "turning")
                }
                out.append(line)
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out.isEmpty ? "none" : out.joined(separator: "\n")
    }

    private func placeSpinner() {
        guard let ring = spinner else { return }
        let s = Self.size, radius = s / 2 - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        let start = 45.0 * Double.pi / 180
        path.addArc(center: CGPoint(x: s / 2, y: s / 2), radius: radius, startAngle: start, endAngle: start - 1.5 * Double.pi, clockwise: true)
        ring.path = path
        CATransaction.commit()
    }

    private func colorSpinner() {
        guard let ring = spinner else { return }
        let ink = look == .connecting ? Theme.secondaryText : Theme.text.withAlphaComponent(0.9)
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = ink.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        placeSpinner()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorSpinner()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = window.map { w in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in self?.updateTurning() }
        }
        updateTurning()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTurning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTurning()
    }

    private var occlusion: NSObjectProtocol?

    deinit {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    static let amber = Status.attention

    override func draw(_ dirtyRect: NSRect) {
        guard let look else { return }
        // The ring turning is the spinner's to show.
        if spinner != nil { return }
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
        case .watching:
            // An eye, in the tint: looking on, not leading.
            let w = radius * 1.05, h = radius * 0.72
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: center.x - w, y: center.y))
            eye.curve(to: NSPoint(x: center.x + w, y: center.y), controlPoint1: NSPoint(x: center.x - w * 0.45, y: center.y + h * 1.35), controlPoint2: NSPoint(x: center.x + w * 0.45, y: center.y + h * 1.35))
            eye.curve(to: NSPoint(x: center.x - w, y: center.y), controlPoint1: NSPoint(x: center.x + w * 0.45, y: center.y - h * 1.35), controlPoint2: NSPoint(x: center.x - w * 0.45, y: center.y - h * 1.35))
            eye.close()
            eye.lineWidth = 1.4
            eye.lineJoinStyle = .round
            Theme.accent.setStroke()
            eye.stroke()
            Theme.accent.setFill()
            let r = radius * 0.36
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        case .quiet:
            // A broken ring, in amber: the signal faltering, not yet gone.
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            ring.lineWidth = 1.6
            ring.lineCapStyle = .round
            let dash = 2 * .pi * radius / 6
            ring.setLineDash([dash * 0.55, dash * 0.45], count: 2, phase: 0)
            amber.setStroke()
            ring.stroke()
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
