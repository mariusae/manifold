import AppKit
import ManifoldCore

/// A block's card, shown while the pointer rests on its row: what it is,
/// where, when it was last seen, and a little of its text.
final class HoverCard: NSObject {
    static let shared = HoverCard()
    private let panel: NSPanel
    private let box = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var pendingShow: DispatchWorkItem?

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 0.5
        box.themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        body.font = .systemFont(ofSize: 12)
        body.textColor = Theme.text
        body.maximumNumberOfLines = 8
        for v in [title, detail, body] { box.addSubview(v) }
        panel.contentView = box
    }

    /// Shows the card beside a rect (in window coordinates) after a moment.
    func show(title: String, detail: String, body: String, font: NSFont?, beside rect: NSRect, in window: NSWindow) {
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.title.stringValue = title
            self.detail.stringValue = detail
            self.body.stringValue = body
            self.body.font = font ?? .systemFont(ofSize: 12)
            self.body.isHidden = body.isEmpty
            let width: CGFloat = 320, pad: CGFloat = 12
            self.body.preferredMaxLayoutWidth = width - 2 * pad
            let bodyHeight = body.isEmpty ? 0 : ceil(self.body.sizeThatFits(NSSize(width: width - 2 * pad, height: 200)).height)
            let height = pad + 17 + 2 + (detail.isEmpty ? 0 : 16) + (body.isEmpty ? 0 : 8 + bodyHeight) + pad
            self.title.frame = NSRect(x: pad, y: height - pad - 17, width: width - 2 * pad, height: 17)
            self.detail.frame = NSRect(x: pad, y: height - pad - 17 - 2 - 16, width: width - 2 * pad, height: 16)
            self.detail.isHidden = detail.isEmpty
            self.body.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: bodyHeight)
            var origin = window.convertToScreen(NSRect(origin: NSPoint(x: rect.maxX + 8, y: rect.midY), size: .zero)).origin
            origin.y -= height / 2
            if let screen = window.screen {
                origin.y = max(screen.visibleFrame.minY + 8, min(origin.y, screen.visibleFrame.maxY - height - 8))
                if origin.x + width > screen.visibleFrame.maxX { origin.x = window.convertToScreen(NSRect(origin: NSPoint(x: rect.minX, y: 0), size: .zero)).origin.x - width - 8 }
            }
            self.panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            self.panel.orderFront(nil)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        panel.orderOut(nil)
    }
}
