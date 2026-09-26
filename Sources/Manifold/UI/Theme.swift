import AppKit
import ManifoldCore

enum Theme {
    static let windowBackground = GhosttyRuntime.background
    static let sidebarWidth: CGFloat = 232
    static let sidebarWidthRange: ClosedRange<CGFloat> = 180...480
    static let sidebarInset: CGFloat = 6
    static let rowHeight: CGFloat = 30
    static let text = NSColor.dynamic(NSColor(white: 0.13, alpha: 1), NSColor(white: 0.89, alpha: 1))
    static let secondaryText = NSColor.dynamic(NSColor(white: 0.45, alpha: 1), NSColor(white: 0.6, alpha: 1))
    static let hover = NSColor.dynamic(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.07))
    static let selected = NSColor.dynamic(.white, NSColor(white: 1, alpha: 0.13))
    static let divider = NSColor.dynamic(NSColor(white: 0, alpha: 0.1), NSColor(white: 1, alpha: 0.1))
    static let accent = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1)
    static let dropHighlight = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 0.18)
    /// Floating panels: the palette, a stack's list.
    static let panel = NSColor.dynamic(NSColor(white: 0.995, alpha: 1), NSColor(white: 0.17, alpha: 1))
    static let panelBorder = NSColor.dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.14))
    /// Over the window, behind the palette.
    static let scrim = NSColor.dynamic(NSColor(white: 0.9, alpha: 0.35), NSColor(white: 0, alpha: 0.3))
    /// Behind the ⌘E switcher's cards.
    static let switcherBackground = NSColor.dynamic(NSColor(white: 0.93, alpha: 1), NSColor(white: 0.08, alpha: 1))
    /// The sidebar card's edge.
    static let cardBorder = NSColor.dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.1))
    /// The sidebar's resize handle.
    static let handle = NSColor.dynamic(NSColor(white: 0, alpha: 0.22), NSColor(white: 1, alpha: 0.25))
    /// The hairline around sheets.
    static func sheetEdge(hovered: Bool) -> NSColor {
        hovered ? .dynamic(NSColor(white: 0, alpha: 0.34), NSColor(white: 1, alpha: 0.34))
            : .dynamic(NSColor(white: 0, alpha: 0.2), NSColor(white: 1, alpha: 0.16))
    }
    /// A sheet beneath a stack's top, `level` deep: darker further down in
    /// light, lighter nearer the top in dark (as things nearer are lit).
    static func sheet(level: Int) -> NSColor {
        .dynamic(NSColor(white: 0.935 - CGFloat(level) * 0.015, alpha: 1),
                 NSColor(white: 0.19 - CGFloat(level) * 0.025, alpha: 1))
    }

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
