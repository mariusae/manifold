import AppKit

/// A word at the foot of the window about something just done that can
/// be undone (§4): a block deleted, or closed with unsaved edits or a job
/// running, which collection will end. A line of text and one action,
/// gone after a while or when the action is taken. With a countdown, the
/// time left runs down as a bar along its foot — held while the pointer
/// is on it, so there's time to take its action — and what waits on it
/// (a deletion, `then`) is done when it runs out, or at once if the toast
/// is put away or another takes its place.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = FlatButton("Restore")
    private var hideWork: DispatchWorkItem?
    private var action: (() -> Void)?
    /// Done once its time is up and its action wasn't taken.
    private var then: (() -> Void)?
    /// The time left, along its foot.
    private let bar = CALayer()
    private var counting = false
    private var total: Double = 0
    private var remaining: Double = 0
    private var runningSince: Date?
    private var pointerOn = false
    /// Gone (its time up, its action taken, put away): for a stack of them to let it go.
    var onGone: (() -> Void)?
    /// In the sidebar's foot (§4): as wide as the sidebar, its words
    /// wrapped (three lines at most), its action under them at the right.
    var compact = false {
        didSet {
            label.lineBreakMode = compact ? .byWordWrapping : .byTruncatingMiddle
            label.maximumNumberOfLines = compact ? 3 : 1
            label.usesSingleLineMode = !compact
            label.cell?.wraps = compact
            label.cell?.truncatesLastVisibleLine = compact
            label.font = .systemFont(ofSize: compact ? 12 : 12.5)
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Flat.float(self)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingMiddle
        button.target = self
        button.action = #selector(act)
        addSubview(label)
        addSubview(button)
        bar.anchorPoint = NSPoint(x: 0, y: 0.5)
        bar.cornerRadius = 1
        bar.isHidden = true
        layer?.addSublayer(bar)
        themed { $0.bar.backgroundColor = Theme.secondaryText.withAlphaComponent(0.45).cgColor }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Says something, offering an action, for a few seconds (an empty
    /// name: no action, only the word — something under way). `countdown`:
    /// the time left shown running down; `then`: done when it's up, unless
    /// the action was taken.
    func show(_ text: String, action name: String = "Restore", for seconds: Double = 8, countdown: Bool = false,
              then: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        // One waiting on its time: done now, as this takes its place.
        finishPending()
        let arriving = isHidden
        label.stringValue = text
        button.title = name
        button.isHidden = name.isEmpty
        self.action = action
        self.then = then
        hideWork?.cancel()
        isHidden = false
        alphaValue = 1
        needsLayout = true
        superview?.needsLayout = true
        if arriving { rise() }
        counting = countdown
        bar.isHidden = !countdown
        total = seconds
        remaining = seconds
        layoutSubtreeIfNeeded()
        if !pointerOn { run() } else { freeze() }
    }

    /// The time left running down from here: its end to come, the bar
    /// shrinking to nothing by then.
    private func run() {
        hideWork?.cancel()
        runningSince = Date()
        let work = DispatchWorkItem { [weak self] in self?.expire() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        guard counting else { return }
        // As a share of the foot (laid out at whatever width the toast
        // takes), from what's left to none.
        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = remaining / max(total, 0.01)
        shrink.toValue = 0
        shrink.duration = remaining
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.setAffineTransform(CGAffineTransform(scaleX: 0.0001, y: 1))
        CATransaction.commit()
        bar.add(shrink, forKey: "countdown")
    }

    /// Held where it is (the pointer on the toast).
    private func freeze() {
        hideWork?.cancel()
        hideWork = nil
        if let since = runningSince { remaining = max(0.5, remaining - Date().timeIntervalSince(since)) }
        runningSince = nil
        guard counting else { return }
        bar.removeAnimation(forKey: "countdown")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.setAffineTransform(CGAffineTransform(scaleX: remaining / max(total, 0.01), y: 1))
        CATransaction.commit()
    }

    private var barWidth: CGFloat { max(0, bounds.width - 2 * Radius.surface) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerOn = true
        if !isHidden { freeze() }
    }

    override func mouseExited(with event: NSEvent) {
        pointerOn = false
        if !isHidden, hideWork == nil { run() }
    }

    /// Its time up: what waits on it done, and away.
    private func expire() {
        hide()
    }

    /// What waits on its time, done now (the app quitting, say).
    func finishPending() {
        guard let t = then else { return }
        then = nil
        t()
    }

    /// Coming up from the window's foot as it fades in, as a stack's tabs
    /// rise (only fading, with less motion asked for).
    private func rise() {
        guard let l = layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let up = CABasicAnimation(keyPath: "transform.translation.y")
        up.fromValue = Motion.distance(superview?.isFlipped == true ? 8 : -8)
        up.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [fade, up]
        g.duration = Motion.base
        g.timingFunction = Motion.appear
        l.add(g, forKey: "rise")
    }

    /// Said again while it's up — what you did didn't take: a shake, as a
    /// refused password's field gives (a blink, with less motion asked for).
    func nudge() {
        guard !isHidden, let l = layer else { return }
        let a = CAKeyframeAnimation(keyPath: Motion.reduced ? "opacity" : "transform.translation.x")
        a.values = Motion.reduced ? [1, 0.5, 1] : [0, -7, 7, -5, 5, -2, 0]
        a.duration = 0.32 * Motion.slowdown
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(a, forKey: "nudge")
    }

    /// Put away: what waits on its time done now.
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        runningSince = nil
        bar.removeAnimation(forKey: "countdown")
        finishPending()
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.alphaValue = 1
            self?.onGone?()
        })
    }

    /// Its action taken (Undo): what waited on its time isn't done.
    @objc private func act() {
        let a = action
        then = nil
        hide()
        a?()
    }

    var wantedSize: NSSize {
        // The text measured as drawn, and the field's own inset: its
        // intrinsic size can lag what it was just given.
        let text = NSAttributedString(string: label.stringValue, attributes: [.font: label.font ?? .systemFont(ofSize: 12.5)])
        let lw = min(ceil(text.size().width) + 6, 560)
        let bw = button.isHidden ? -12 : ceil(button.intrinsicContentSize.width)
        return NSSize(width: 14 + lw + 12 + bw + 10, height: 36)
    }

    /// Its height, compact, at a width: its words wrapped, its action under them.
    func compactHeight(width: CGFloat) -> CGFloat {
        let w = max(40, width - 24)
        let text = NSAttributedString(string: label.stringValue, attributes: [.font: label.font ?? .systemFont(ofSize: 12)])
        let lineH = ceil((label.font ?? .systemFont(ofSize: 12)).boundingRectForFont.height)
        let h = min(ceil(text.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height), lineH * 3)
        return 10 + h + (button.isHidden ? 10 : 6 + Flat.buttonHeight + 8)
    }

    override func layout() {
        super.layout()
        if compact {
            let bw = button.isHidden ? 0 : ceil(button.intrinsicContentSize.width)
            button.frame = NSRect(x: bounds.width - 10 - bw, y: 8, width: bw, height: Flat.buttonHeight)
            let top: CGFloat = button.isHidden ? 10 : 8 + Flat.buttonHeight + 6
            label.frame = NSRect(x: 12, y: top, width: bounds.width - 24, height: max(0, bounds.height - top - 10))
            label.toolTip = label.stringValue
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.position = NSPoint(x: Radius.surface, y: 2.5)
            bar.bounds.size = NSSize(width: barWidth, height: 2)
            CATransaction.commit()
            return
        }
        let h = bounds.height
        let bw = button.isHidden ? 0 : ceil(button.intrinsicContentSize.width)
        button.frame = NSRect(x: bounds.width - 10 - bw, y: (h - Flat.buttonHeight) / 2, width: bw, height: Flat.buttonHeight)
        label.frame = NSRect(x: 14, y: (h - 17) / 2, width: max(0, (button.isHidden ? bounds.width - 10 : button.frame.minX - 12) - 14), height: 17)
        // Along its foot, in from the rounded corners.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.position = NSPoint(x: Radius.surface, y: isFlipped ? h - 2.5 : 2.5)
        bar.bounds.size = NSSize(width: barWidth, height: 2)
        CATransaction.commit()
    }

    var text: String { label.stringValue }

    /// Debugging: what it says, if shown, and the time left of its countdown.
    var debugText: String? {
        guard !isHidden else { return nil }
        guard counting else { return label.stringValue }
        let left = runningSince.map { remaining - Date().timeIntervalSince($0) } ?? remaining
        let shown = (bar.presentation() ?? bar).affineTransform().a
        return label.stringValue + String(format: " [%.1f s of %.0f left, bar %.0f%% of %.0f%@]", max(0, left), total,
                                          shown * 100, barWidth, then == nil ? "" : ", waiting")
    }

    /// Debugging: the toast as Core Animation shows it now (its countdown
    /// where it is), written as a PNG.
    func debugPicture(to path: String) -> String {
        guard !isHidden, let l = layer, let shown = l.presentation() else { return "no toast" }
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        ctx.scaleBy(x: scale, y: scale)
        shown.render(in: ctx)
        guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "no image" }
        try? png.write(to: URL(fileURLWithPath: path))
        return "wrote \(path)"
    }

    /// Debugging: its button pressed, if it's up.
    func debugAct() -> String {
        guard !isHidden, !button.isHidden else { return "no toast" }
        act()
        return "acted"
    }
}


/// The window's toasts (§4): while the sidebar's out, at its foot with
/// what's under way (copies), as many as are up at once — each its own
/// time, gone when it's up; else one at the window's foot, a new one
/// taking its place as ever. Putting one away, or shaking it, is the
/// newest's.
final class Toasts {
    /// The one at the window's foot.
    let window = ToastView()
    /// The sidebar's stack, and whether it's what shows them now.
    weak var stack: ToastStackView?
    var inSidebar: () -> Bool = { false }

    private var sidebarToasts: [ToastView] { stack?.toasts.filter { !$0.isHidden } ?? [] }
    /// The newest up.
    private var latest: ToastView? { sidebarToasts.last ?? (window.isHidden ? nil : window) }

    func show(_ text: String, action name: String = "Restore", for seconds: Double = 8, countdown: Bool = false,
              then: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        guard inSidebar(), let stack else {
            return window.show(text, action: name, for: seconds, countdown: countdown, then: then, action)
        }
        // The same words again, up already: that one's, not another.
        if let same = sidebarToasts.first(where: { $0.text == text }) { same.hide() }
        let t = ToastView()
        t.compact = true
        stack.add(t)
        t.show(text, action: name, for: seconds, countdown: countdown, then: then, action)
    }

    var isHidden: Bool { latest == nil }
    func hide() { latest?.hide() }
    func nudge() { latest?.nudge() }
    func finishPending() {
        window.finishPending()
        for t in stack?.toasts ?? [] { t.finishPending() }
    }
    var debugText: String? {
        let all = (window.isHidden ? [] : [window]) + sidebarToasts
        let texts = all.compactMap(\.debugText)
        return texts.isEmpty ? nil : (sidebarToasts.isEmpty ? "" : "[sidebar] ") + texts.joined(separator: " | ")
    }
    func debugAct() -> String { latest?.debugAct() ?? "no toast" }
    func debugPicture(to path: String) -> String { latest?.debugPicture(to: path) ?? "no toast" }
}

/// The sidebar's toasts, at its foot, oldest at the top: each as wide as
/// the sidebar, gone from the stack as it goes.
final class ToastStackView: NSView {
    private(set) var toasts: [ToastView] = []
    /// Its height changed: for the sidebar to lay its foot out again.
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }

    func add(_ t: ToastView) {
        toasts.append(t)
        addSubview(t)
        t.onGone = { [weak self, weak t] in
            guard let self, let t else { return }
            t.removeFromSuperview()
            self.toasts.removeAll { $0 === t }
            self.onChange?()
        }
        onChange?()
    }

    var wantedHeight: CGFloat {
        let shown = toasts.filter { !$0.isHidden }
        guard !shown.isEmpty else { return 0 }
        return shown.reduce(0) { $0 + $1.compactHeight(width: bounds.width > 0 ? bounds.width : 220) } + CGFloat(shown.count - 1) * 6
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for t in toasts where !t.isHidden {
            let h = t.compactHeight(width: bounds.width)
            t.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 6
        }
    }
}
