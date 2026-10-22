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
    /// A selected row in a list: a step in lightness, not a hue, so it
    /// reads the same to every eye and the row's own colors stay.
    static let selection = NSColor.dynamic(NSColor(white: 0, alpha: 0.09), NSColor(white: 1, alpha: 0.14))
    static let divider = NSColor.dynamic(NSColor(white: 0, alpha: 0.1), NSColor(white: 1, alpha: 0.1))
    static let accent = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1)
    /// A block that failed (§3.7).
    static let statusError = NSColor(srgbRed: 0.88, green: 0.3, blue: 0.28, alpha: 1)
    static let dropHighlight = NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 0.18)
    /// Floating panels: the palette, a stack's list.
    /// A text in view mode, as go.dev's docs (the Go spec) set code: on
    /// their grey (#F8F8F8; #2D2D2D in the dark), in their text color
    /// (#202224; #F0F1F2), its line numbers in theirs (#999).
    static let codePage = NSColor.dynamic(hex(0xF8F8F8), hex(0x2D2D2D))
    static let codeText = NSColor.dynamic(hex(0x202224), hex(0xF0F1F2))
    static let codeLineNumber = NSColor.dynamic(hex(0x999999), hex(0x848688))

    static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let panel = NSColor.dynamic(NSColor(white: 0.995, alpha: 1), NSColor(white: 0.17, alpha: 1))
    static let panelBorder = NSColor.dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.14))
    /// Over the window, behind the palette.
    static let scrim = NSColor.dynamic(NSColor(white: 0.9, alpha: 0.35), NSColor(white: 0, alpha: 0.3))
    /// Behind the ⌘E switcher's cards, top to bottom.
    static let switcherTop = NSColor.dynamic(NSColor(white: 0.87, alpha: 1), NSColor(white: 0.27, alpha: 1))
    static let switcherBottom = NSColor.dynamic(NSColor(srgbRed: 0.76, green: 0.79, blue: 0.84, alpha: 1),
                                                NSColor(srgbRed: 0.25, green: 0.29, blue: 0.35, alpha: 1))
    /// What the cards at the back fade into.
    static let switcherFog = NSColor.dynamic(NSColor(srgbRed: 0.84, green: 0.85, blue: 0.87, alpha: 1),
                                             NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
    /// A switcher card's title bar.
    static let switcherHeader = NSColor.dynamic(NSColor(white: 0.955, alpha: 1), NSColor(white: 0.2, alpha: 1))
    /// The sidebar card's edge.
    static let cardBorder = NSColor.dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.1))
    /// The sidebar's resize handle.
    static let handle = NSColor.dynamic(NSColor(white: 0, alpha: 0.22), NSColor(white: 1, alpha: 0.25))
    /// A scrubber's strip, its knob, and its quiet ticks (§3.1).
    static let scrubberTrack = NSColor.dynamic(NSColor(white: 0, alpha: 0.035), NSColor(white: 1, alpha: 0.04))
    static let scrubberKnob = NSColor.dynamic(NSColor(white: 0, alpha: 0.14), NSColor(white: 1, alpha: 0.18))
    static let scrubberTick = NSColor.dynamic(NSColor(white: 0, alpha: 0.55), NSColor(white: 1, alpha: 0.6))
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

    static func symbolName(for lens: Lens) -> String {
        switch lens {
        case .terminal: "apple.terminal"
        case .preview: "doc.richtext"
        case .editor: "doc.text"
        case .directory: "folder"
        case .web: "globe"
        case .image: "photo"
        case .pdf: "doc.richtext.fill"
        case .search: "magnifyingglass"
        case .diff: "arrow.left.arrow.right"
        case .git: "arrow.triangle.branch"
        case .process: "cpu"
        case .agent: "sparkles"
        case .card: "rectangle.3.group"
        case .output: "text.alignleft"
        case .notebook: "text.and.command.macwindow"
        case .outline: "list.bullet.rectangle"
        }
    }

    static func symbolName(for kind: BlockKind, path: String? = nil) -> String {
        kind == .text && path == nil ? noteSymbol : symbolName(for: Lens.default(for: kind, path: path), path: path)
    }

    /// A note's: a text not saved anywhere yet, unlike a file's page.
    static let noteSymbol = "note.text"

    /// A lens's symbol for a text at `path`: viewed, Markdown is rich
    /// text and anything else still a page of text.
    static func symbolName(for lens: Lens, path: String?) -> String {
        lens == .preview && Lens.viewRendering(for: path) != .markdown ? symbolName(for: .editor) : symbolName(for: lens)
    }

    /// Older names for symbols a macOS before this one's may not have,
    /// tried in turn; last, a dot, so nothing is ever blank.
    static let symbolFallbacks: [String: [String]] = [
        "eraser": ["eraser.fill", "xmark.circle"],
        "rectangle.expand.vertical": ["arrow.up.and.down.square", "arrow.up.and.down"],
        "point.3.connected.trianglepath.dotted": ["link", "circle.hexagongrid"],
        "tray.and.arrow.down": ["tray", "square.and.arrow.down"],
        "arrow.up.left.and.arrow.down.right": ["arrow.up.left.and.down.right.magnifyingglass", "arrow.up.and.down"],
        "arrow.down.right.and.arrow.up.left": ["arrow.down.right.and.arrow.up.left.circle", "arrow.up.and.down"],
        "cpu": ["cpu.fill", "memorychip"],
        "number": ["number.square", "textformat"],
        "apple.terminal": ["terminal"],
        "text.and.command.macwindow": ["apple.terminal.on.rectangle", "terminal"],
        "arrow.left.arrow.right": ["arrow.right.arrow.left", "arrow.left.and.right"],
    ]

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        for candidate in [name] + (symbolFallbacks[name] ?? []) + ["circle.fill"] {
            if let image = NSImage(systemSymbolName: candidate, accessibilityDescription: nil) {
                return image.withSymbolConfiguration(.init(pointSize: size, weight: weight))
            }
        }
        return nil
    }
}

extension NSMutableAttributedString {
    /// One line, cut with an ellipsis: attributed strings in labels don't
    /// take the label's line breaking.
    func truncatingTail() -> NSMutableAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: length))
        return self
    }
}

extension NSPasteboard.PasteboardType {
    /// An arrangement being dragged, by id.
    static let manifoldArrangement = NSPasteboard.PasteboardType("com.manifold.arrangement")
    /// A placement (a column's block) being dragged, by id.
    static let manifoldPlacement = NSPasteboard.PasteboardType("com.manifold.placement")
    /// A block being dragged from the sidebar, by id.
    static let manifoldBlock = NSPasteboard.PasteboardType("com.manifold.block")
    /// A ⇧-dragged block as a Markdown link to it, for a note to take.
    static let manifoldBlockLink = NSPasteboard.PasteboardType("com.manifold.blocklink")
    /// With a block's link, ⌥⇧-dragged: the link alone — the tile it's
    /// dropped on linked to it, nothing typed or put in.
    static let manifoldLinkOnly = NSPasteboard.PasteboardType("com.manifold.linkonly")
    /// A folder's entry dragged out: "host<TAB>path<TAB>d|f" — on any
    /// host, where a file URL is only for this Mac's.
    static let manifoldPath = NSPasteboard.PasteboardType("com.manifold.path")
    /// A host's row in the sidebar being dragged, by session id.
    static let manifoldHost = NSPasteboard.PasteboardType("com.manifold.host")
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}


/// A list's selected row drawn as a lightness change with a bar at the
/// left, instead of the system's hue — colorblind-safe, and the row's
/// text and highlights keep their colors (`interiorBackgroundStyle`
/// stays normal). Every table and outline makes its rows from this.
/// A scroll view whose content ends at its edges. Without this, the
/// content ran on past the frame — a list's rows drawn over the header
/// above it and the rows below — since nothing here is meant to show
/// through under bars the way the system's own lists do.
final class ClippingScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }
}

final class SelectionRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    /// Marked: a bar in the accent at the left edge (the current workspace's row).
    var marked = false { didSet { needsDisplay = true } }
    override var isFloating: Bool { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // A section's header kept at the top as its rows scroll under it:
        // a background of its own, so they don't show through it.
        if isGroupRowStyle, isFloating {
            Theme.windowBackground.setFill()
            bounds.fill()
        }
        guard marked else { return }
        Theme.accent.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: 3, height: bounds.height - 10), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let style = (superview as? NSTableView)?.effectiveStyle ?? .plain
        let inset: CGFloat = style == .plain || style == .fullWidth ? 0 : 6
        let r = bounds.insetBy(dx: inset, dy: 0)
        Theme.selection.setFill()
        NSBezierPath(roundedRect: r, xRadius: inset == 0 ? 0 : 5, yRadius: inset == 0 ? 0 : 5).fill()
        let bar = NSRect(x: r.minX, y: r.minY + 3, width: 3, height: r.height - 6)
        Theme.accent.withAlphaComponent(isEmphasized ? 1 : 0.5).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
