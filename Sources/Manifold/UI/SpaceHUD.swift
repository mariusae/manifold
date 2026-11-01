import AppKit

/// The space a ⌘` walk has come to, named over the window while ⌘ is held
/// and the sidebar (which would show it) is away: a clue to where you are,
/// as the walk slides one space in after another.
final class SpaceHUD: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        Flat.float(self)
        icon.image = Theme.symbol(Theme.spaceSymbol, size: 15, weight: .medium)
        icon.contentTintColor = Theme.secondaryText
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingMiddle
        detail.font = UIType.detail
        detail.textColor = Theme.secondaryText
        for v in [icon, label, detail] { addSubview(v) }
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Says `name` (and where it is in the walk), at the top middle of `area`.
    func show(_ name: String, position: String, in area: NSRect) {
        label.stringValue = name
        detail.stringValue = position
        label.sizeToFit()
        detail.sizeToFit()
        let w = min(max(label.frame.width, detail.frame.width) + 40 + 18, area.width - 40), h: CGFloat = 54
        frame = NSRect(x: (area.midX - w / 2).rounded(), y: (area.maxY - h - 64).rounded(), width: w, height: h)
        icon.frame = NSRect(x: 14, y: h - 14 - 20, width: 20, height: 20)
        label.frame = NSRect(x: 40, y: h - 10 - 22, width: w - 40 - 14, height: 22)
        detail.frame = NSRect(x: 40, y: 9, width: w - 40 - 14, height: 15)
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Motion.reduced ? 0 : 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Motion.reduced ? 0 : 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        })
    }
}
