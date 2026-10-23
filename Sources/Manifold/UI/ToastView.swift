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
        label.stringValue = text
        button.title = name
        button.isHidden = name.isEmpty
        self.action = action
        hideWork?.cancel()
        isHidden = false
        alphaValue = 1
        needsLayout = true
        superview?.needsLayout = true
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
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
        let lw = min(ceil(label.intrinsicContentSize.width), 520)
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
}
