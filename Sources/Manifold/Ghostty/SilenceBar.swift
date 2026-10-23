import AppKit

/// Over a terminal whose host has gone quiet (a ping unanswered, nothing
/// coming) or whose link is being made again: how long since it was last
/// heard from, as mosh says it — so a terminal that doesn't answer is
/// plainly the network, not the program. Top centre; clicks go through.
final class SilenceBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private var showing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.95, alpha: 1)
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    /// Seconds since the host was last heard from (nil: it's fine), and
    /// whether its link is up (else it's being made again).
    func set(silence: TimeInterval?, connected: Bool) {
        if let silence {
            let n = Int(silence.rounded(.down))
            let ago = n < 60 ? "\(n) s" : n < 3600 ? "\(n / 60) min" : "\(n / 3600) h"
            label.stringValue = "Last contact \(ago) ago" + (connected ? "" : " · reconnecting…")
            needsLayout = true
            superview?.needsLayout = true
        }
        let show = silence != nil
        guard show != showing else { return }
        showing = show
        if show { isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? 0.15 : 0.3
            animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.showing else { return }
            self.isHidden = true
        })
    }

    /// Its size, for its label.
    var fitting: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + 26, height: ceil(s.height) + 8)
    }

    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: 12, y: ((bounds.height - s.height) / 2).rounded(), width: ceil(s.width) + 2, height: ceil(s.height))
    }
}
