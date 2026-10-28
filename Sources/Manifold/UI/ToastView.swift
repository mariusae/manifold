import AppKit

/// A word at the foot of the window about something just done that can
/// be undone (§4): a block closed with unsaved edits, or with a job
/// running, which collection will end. A line of text and one action,
/// gone after a while or when the action is taken.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = FlatButton("Restore")
    private var hideWork: DispatchWorkItem?
    private var action: (() -> Void)?

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
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Says something, offering an action, for a few seconds (an empty
    /// name: no action, only the word — something under way).
    func show(_ text: String, action name: String = "Restore", for seconds: Double = 8, _ action: @escaping () -> Void) {
        let arriving = isHidden
        label.stringValue = text
        button.title = name
        button.isHidden = name.isEmpty
        self.action = action
        hideWork?.cancel()
        isHidden = false
        alphaValue = 1
        needsLayout = true
        superview?.needsLayout = true
        if arriving { rise() }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.alphaValue = 1
        })
    }

    @objc private func act() {
        let a = action
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

    override func layout() {
        super.layout()
        let h = bounds.height
        let bw = button.isHidden ? 0 : ceil(button.intrinsicContentSize.width)
        button.frame = NSRect(x: bounds.width - 10 - bw, y: (h - Flat.buttonHeight) / 2, width: bw, height: Flat.buttonHeight)
        label.frame = NSRect(x: 14, y: (h - 17) / 2, width: max(0, (button.isHidden ? bounds.width - 10 : button.frame.minX - 12) - 14), height: 17)
    }

    /// Debugging: what it says, if shown.
    var debugText: String? { isHidden ? nil : label.stringValue }

    /// Debugging: its button pressed, if it's up.
    func debugAct() -> String {
        guard !isHidden, !button.isHidden else { return "no toast" }
        act()
        return "acted"
    }
}
