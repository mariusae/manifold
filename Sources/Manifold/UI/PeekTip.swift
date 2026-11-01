import AppKit

/// What a name in code is, shown under it while the pointer rests there
/// (peek): its definition's signature and documentation, as its language
/// server or its project's index says them. One at a time, never taking
/// the keyboard; gone as the pointer leaves the name, a key goes down or
/// the text scrolls.
final class PeekTip {
    static let shared = PeekTip()

    private let panel: NSPanel
    private let text = NSTextField(wrappingLabelWithString: "")
    private(set) var isShown = false
    /// What it says, as last shown (debugging).
    var shownText: String { isShown ? text.stringValue : "" }

    private final class TipPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private init() {
        panel = TipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        let box = NSView()
        Flat.float(box)
        text.isSelectable = false
        text.drawsBackground = false
        box.addSubview(text)
        panel.contentView = box
    }

    static let maxWidth: CGFloat = 520

    /// Shows `content` under `rect` (in `window`'s coordinates), within the screen.
    func show(_ content: NSAttributedString, under rect: NSRect, in window: NSWindow) {
        text.attributedStringValue = content
        text.preferredMaxLayoutWidth = Self.maxWidth
        let fit = text.sizeThatFits(NSSize(width: Self.maxWidth, height: 360))
        let size = NSSize(width: min(ceil(fit.width), Self.maxWidth) + 20, height: min(ceil(fit.height), 360) + 14)
        text.frame = NSRect(x: 10, y: 7, width: size.width - 20, height: size.height - 14)
        let anchor = window.convertToScreen(rect)
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - size.height - 4)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            // No room under it: over it.
            if origin.y < screen.minY + 4 { origin.y = anchor.maxY + 4 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        isShown = true
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
