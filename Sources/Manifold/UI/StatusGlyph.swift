import AppKit
import ManifoldCore

/// A block's status in one glyph (§3.7), the same wherever it's shown —
/// bars, sidebar rows and cards (`StatusMark`), a notebook's cells, a
/// block's pill in a note, a host's row: hollow while at work, filled
/// when there's something for you. Three dots for running, a light
/// going along them (a ring filling clockwise from the top instead when
/// the program says how far, as OSC 9;4 or 7501 progress does; still,
/// with Reduce motion), an amber ring
/// with a dot for a block that needs you, a filled disc with a check for
/// done and not yet read (red for failed), a filled dot for a thread with
/// something new, a plain grey check once read (where it's said at all),
/// and a moon for what's asleep — an agent not running, a terminal gone
/// inactive. A host's: being reached, offline, quiet, or watched — an
/// eye: another Manifold took it over.
final class StatusGlyph: NSView {
    enum Look: Equatable {
        case working(progress: Int?)
        /// Something new to read (a thread's comments not seen): a filled
        /// dot — filled, as done and not seen is.
        case unseen
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
            // What it means, unless it's been told more.
            if toolTip == nil || toolTip == oldValue.map(Self.words) { toolTip = look.map(Self.words) }
            updateTurning()
            settleIfJustFinished()
        }
    }

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
    /// Just finished — running, then done or failed (not a glyph made
    /// afresh as done): it lands a little larger and eases to its size, as a
    /// thing put down settles (it only fades in, with Reduce motion).
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
        big = CATransform3DScale(big, 1.2, 1.2, 1)
        big = CATransform3DTranslate(big, -c.x, -c.y, 0)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = big
        a.toValue = CATransform3DIdentity
        a.duration = Motion.spatial
        // Eased down, not past its size and back: settled, not sprung.
        a.timingFunction = Motion.travel
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
        // Edited, and the file changed on disk under the edits: which to
        // keep is yours to say — needs you, as the glyph says it (not a
        // second amber dot after the name).
        if block.text?.stale == true { return .needsYou }
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

    /// What a look means, said on its own — the tooltip of a glyph that
    /// isn't told more (its block's, `tooltip(_:)`, says more).
    static func words(_ look: Look) -> String {
        switch look {
        case .working(let p): p.map { "Working, \($0)% done" } ?? "Working"
        case .unseen: "Something new since you last looked"
        case .needsYou: "Needs you: waiting on an answer from you"
        case .done(let read): read ? "Done" : "Done, and not looked at since"
        case .failed(let read): read ? "Failed" : "Failed, and not looked at since"
        case .inactive: "Asleep: its shell ended after a while idle; a new one starts when it's shown"
        case .connecting: "Connecting to its host"
        case .offline: "Its host can't be reached: what's shown is as last seen"
        case .quiet: "Its host hasn't answered for a while"
        case .watching: "Another Manifold took over its host: this one only watches"
        }
    }

    /// What a block's glyph means for it: what it's waiting on, from what,
    /// and what to do — its status report's title and message after.
    static func tooltip(_ block: Block?) -> String? {
        guard let block, let look = look(of: block) else { return nil }
        let r = block.statusRecord
        var words = [Self.words(look)]
        if case .needsYou = look {
            switch r?.kind {
            case .permission?: words = ["Needs you: asking permission"]
            case .question?: words = ["Needs you: asking a question"]
            case .auth?: words = ["Needs you: asking you to sign in"]
            case nil where block.text?.stale == true:
                words = ["Needs you: the file changed on disk while you had unsaved edits",
                         "Choose Reload or Keep Mine from the tile's menu (its icon)"]
            case nil: break
            }
        }
        if let app = r?.app { words[0] += " · " + app }
        if let title = r?.title, !title.isEmpty { words.append(title) }
        if let msg = r?.msg, !msg.isEmpty { words.append(msg) }
        return words.joined(separator: "\n")
    }

    /// What the status says that its pill doesn't — the title, the
    /// message — for a row beside it: not "Done", "Permission", which the
    /// pill is (`StatusMark`).
    static func remark(_ block: Block?) -> String? {
        guard let block, look(of: block) != nil else { return nil }
        let r = block.statusRecord
        var words: [String] = []
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
        // Reduce motion: the dots still.
        if Motion.reduced { return false }
        if case .working(nil) = look { return true }
        if case .connecting = look { return true }
        return false
    }

    /// As terminals: MANIFOLD_NO_OCCLUSION (testing) has them turn all the same.
    private static let ignoresWindowOcclusion = ProcessInfo.processInfo.environment["MANIFOLD_NO_OCCLUSION"] != nil

    private func updateTurning() {
        // At work with no word of how far: three dots, a wave of light
        // going along them; a host being reached, the ring turning.
        let wantsDots = animates && look == .working(progress: nil)
        if !wantsDots, dots != nil {
            dots?.removeFromSuperlayer()
            dots = nil
            needsDisplay = true
        }
        if wantsDots {
            if spinner != nil {
                spinner?.removeFromSuperlayer()
                spinner = nil
            }
            if dots == nil { makeDots() }
            colorSpinner()
            return
        }
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
                // The dots: how lit each is now.
                if let dots = g.dots {
                    let lit = (dots.sublayers ?? []).map { $0.presentation()?.opacity ?? -1 }
                    line += " dots " + lit.map { String(format: "%.2f", $0) }.joined(separator: " ")
                }
                out.append(line)
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out.isEmpty ? "none" : out.joined(separator: "\n")
    }

    /// The dots, while it works: a layer each, lit and dimmed in turn —
    /// each a little after the one before, so the light goes along them,
    /// then a rest — by the clock, as every glyph's are.
    private var dots: CALayer?
    static let dotCount = 3
    static let dotPeriod: Double = 1.2
    /// How long after the one before each dot lights.
    static let dotStep: Double = 0.2
    static let dotDim: Float = 0.35

    private func makeDots() {
        wantsLayer = true
        let holder = CALayer()
        layer?.addSublayer(holder)
        dots = holder
        let now = CACurrentMediaTime(), into = phase.truncatingRemainder(dividingBy: Self.dotPeriod)
        for i in 0..<Self.dotCount {
            let dot = CALayer()
            dot.opacity = Self.dotDim
            holder.addSublayer(dot)
            // Up quickly, down more slowly, then dim till its turn comes again.
            let lit = CAKeyframeAnimation(keyPath: "opacity")
            lit.values = [Self.dotDim, 1, Self.dotDim, Self.dotDim]
            lit.keyTimes = [0, 0.17, 0.45, 1]
            lit.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            lit.duration = Self.dotPeriod
            lit.repeatCount = .infinity
            lit.isRemovedOnCompletion = false
            lit.beginTime = now - into + Self.dotStep * Double(i)
            dot.add(lit, forKey: "lit")
        }
        placeSpinner()
        needsDisplay = true
    }

    /// The dots in a glyph `s` wide: centred, across.
    static func dotRects(side s: CGFloat) -> [CGRect] {
        let d = (s * 0.215 * 2).rounded() / 2, gap = (s * 0.34 * 2).rounded() / 2
        let x0 = s / 2 - gap
        return (0..<dotCount).map { i in CGRect(x: x0 + gap * CGFloat(i) - d / 2, y: s / 2 - d / 2, width: d, height: d) }
    }

    /// How lit dot `i` is at `phase` (seconds, by the clock), as its layer would be.
    static func dotLight(_ i: Int, phase: Double) -> CGFloat {
        var t = (phase - dotStep * Double(i)).truncatingRemainder(dividingBy: dotPeriod) / dotPeriod
        if t < 0 { t += 1 }
        let dim = CGFloat(dotDim)
        if t < 0.17 { return dim + (1 - dim) * CGFloat(t / 0.17) }
        if t < 0.45 { return 1 - (1 - dim) * CGFloat((t - 0.17) / 0.28) }
        return dim
    }

    private func placeSpinner() {
        if let holder = dots {
            let s = Self.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            holder.frame = CGRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
            for (dot, r) in zip(holder.sublayers ?? [], Self.dotRects(side: s)) {
                dot.frame = r
                dot.cornerRadius = r.width / 2
            }
            CATransaction.commit()
        }
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
        let ink = look == .connecting ? Theme.secondaryText : Theme.text.withAlphaComponent(0.9)
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = ink.cgColor }
        if let holder = dots {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for dot in holder.sublayers ?? [] { dot.backgroundColor = color }
            CATransaction.commit()
        }
        guard let ring = spinner else { return }
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
        // The ring turning, the dots working, are their layers' to show.
        if spinner != nil || dots != nil { return }
        let s = Self.size
        Self.draw(look, in: NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s), phase: phase)
    }

    /// The glyph drawn anywhere (a pill in a note): in a square, at a
    /// phase of its turning.
    /// Drawn into a view of its own (a menu's row, flipped or not), as it
    /// stands — still, where a glyph view's ring would turn.
    static func drawUpright(_ look: Look, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current, ctx.isFlipped else {
            return draw(look, in: rect, phase: Date.timeIntervalSinceReferenceDate)
        }
        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 0, yBy: rect.midY * 2)
        t.scaleX(by: 1, yBy: -1)
        t.concat()
        draw(look, in: rect, phase: Date.timeIntervalSinceReferenceDate)
        ctx.restoreGraphicsState()
    }

    static func draw(_ look: Look, in rect: NSRect, phase: Double) {
        let s = rect.width
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = s / 2 - 1
        switch look {
        case .unseen, .needsYou, .done(read: false), .failed(read: false):
            // Something for you: a filled dot, its colour why — amber,
            // you're needed; the done colour, something new to read (done,
            // a thread's comments); red, it failed.
            let tone: NSColor = switch look {
            case .needsYou: amber
            case .failed: Theme.statusError
            default: Status.done
            }
            tone.setFill()
            let r = radius * 0.66
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        case .done(read: true):
            // Read: nothing more to say.
            break
        case .failed(read: true):
            // Read, but it failed: a trace of it, faint (a notebook's cell).
            Theme.statusError.withAlphaComponent(0.45).setFill()
            let r = radius * 0.5
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        case .working(let p?):
            // At work, saying how far: the dots lit as far as it's come,
            // left to right — still, as the light that goes along them
            // when it doesn't say.
            let lit = CGFloat(min(max(p, 0), 100)) / 100 * CGFloat(dotCount)
            for (i, d) in dotRects(side: rect.width).enumerated() {
                let f = min(max(lit - CGFloat(i), 0), 1)
                Theme.text.withAlphaComponent(0.9 * (CGFloat(dotDim) + (1 - CGFloat(dotDim)) * f)).setFill()
                NSBezierPath(ovalIn: d.offsetBy(dx: rect.minX, dy: rect.minY)).fill()
            }
        case .working(nil):
            // Working, still (a menu's row, Reduce motion): the dots as
            // they stand at this moment of their wave.
            for (i, d) in dotRects(side: rect.width).enumerated() {
                Theme.text.withAlphaComponent(0.9 * dotLight(i, phase: phase)).setFill()
                NSBezierPath(ovalIn: d.offsetBy(dx: rect.minX, dy: rect.minY)).fill()
            }
        case .connecting:
            // A host being reached: an open ring, turning.
            let start = 45 - (phase * 180).truncatingRemainder(dividingBy: 360)
            let arc = NSBezierPath()
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 270, clockwise: true)
            Theme.secondaryText.setStroke()
            arc.stroke()
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
            // A crescent, lit at the left (☾): the disc less a disc shifted
            // right and a little up, only the disc's part filled (filled
            // together, the bite's part outside it drew a second crescent).
            // Set so the crescent itself — the disc's left edge to its
            // further horn, where the circles cross — is in the middle.
            let shift = radius * 0.62, rise = radius * 0.22
            let d = (shift * shift + rise * rise).squareRoot()
            let horn = shift / 2 + (radius * radius - d * d / 4).squareRoot() * rise / d
            let c = NSPoint(x: center.x - (horn - radius) / 2, y: center.y)
            let disc = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
            let bite = NSBezierPath(ovalIn: NSRect(x: c.x - radius + shift, y: c.y - radius + rise, width: 2 * radius, height: 2 * radius))
            NSGraphicsContext.saveGraphicsState()
            disc.addClip()
            let lit = NSBezierPath(rect: disc.bounds.insetBy(dx: -1, dy: -1))
            lit.append(bite)
            lit.windingRule = .evenOdd
            Theme.secondaryText.withAlphaComponent(0.85).setFill()
            lit.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
