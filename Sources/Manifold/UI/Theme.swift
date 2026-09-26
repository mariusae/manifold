import AppKit
import ManifoldCore

enum Theme {
    static let windowBackground = GhosttyRuntime.background
    static let sidebarWidth: CGFloat = 232
    static let sidebarWidthRange: ClosedRange<CGFloat> = 180...480
    static let sidebarInset: CGFloat = 6
    static let rowHeight: CGFloat = 30
    static let text = NSColor(white: 0.13, alpha: 1)
    static let secondaryText = NSColor(white: 0.45, alpha: 1)
    static let hover = NSColor(white: 0, alpha: 0.055)
    static let selected = NSColor.white
    static let divider = NSColor(white: 0, alpha: 0.1)
    static let accent = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1)
    static let dropHighlight = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 0.18)

    static func symbolName(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "apple.terminal"
        case .markdown: "doc.richtext"
        case .editor: "doc.text"
        }
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

extension NSPasteboard.PasteboardType {
    /// A tab being dragged, by id.
    static let manifoldTab = NSPasteboard.PasteboardType("com.manifold.tab")
    /// A pane (a sheet) being dragged, by id.
    static let manifoldPane = NSPasteboard.PasteboardType("com.manifold.pane")
}

/// A small borderless button showing a symbol, with a hover background.
final class IconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, size: CGFloat = 11, weight: NSFont.Weight = .semibold, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        image = Theme.symbol(symbol, size: size, weight: weight)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Theme.secondaryText
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
