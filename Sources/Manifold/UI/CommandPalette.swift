import AppKit

struct PaletteItem {
    var symbol: String
    var title: String
    var subtitle: String
    var run: () -> Void
}

/// The ⌘T palette: open something new, or go to an existing tab.
final class CommandPaletteView: NSView, NSTextFieldDelegate {
    var onDismiss: (() -> Void)?
    /// Whether Escape and clicking outside close it (not when there's
    /// nothing behind it to go back to).
    var dismissable = true

    private let panel = NSView()
    private let field = NSTextField()
    private let searchIcon = NSImageView()
    private let list = FlippedView()
    private var rows: [PaletteRowView] = []
    private var items: [PaletteItem] = []
    private var filtered: [PaletteItem] = []
    private var selection = 0

    private static let width: CGFloat = 560
    private static let maxRows = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.9, alpha: 0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.995, alpha: 1).cgColor
        panel.layer?.cornerRadius = 12
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        panel.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.2)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -6)
            return s
        }()
        addSubview(panel)

        searchIcon.image = Theme.symbol("magnifyingglass", size: 13)
        searchIcon.contentTintColor = Theme.secondaryText
        panel.addSubview(searchIcon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.text
        field.placeholderString = "Search tabs or type a command"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        panel.addSubview(field)
        panel.addSubview(list)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(items: [PaletteItem], in window: NSWindow?) {
        self.items = items
        field.stringValue = ""
        refilter()
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        let rowH: CGFloat = 34
        let listH = CGFloat(min(filtered.count, Self.maxRows)) * rowH
        let h = 48 + (listH > 0 ? listH + 12 : 0)
        let w = min(Self.width, bounds.width - 40)
        // The search field stays put as results come and go.
        panel.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.height * 0.7 - h, width: w, height: h).integral
        searchIcon.frame = NSRect(x: 16, y: h - 32, width: 16, height: 16)
        field.frame = NSRect(x: 40, y: h - 35, width: w - 56, height: 22)
        list.frame = NSRect(x: 6, y: 6, width: w - 12, height: listH)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * rowH, width: list.bounds.width, height: rowH)
        }
    }

    private func refilter() {
        let words = field.stringValue.lowercased().split(separator: " ").map(String.init)
        filtered = items.filter { item in
            let hay = (item.title + " " + item.subtitle).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        selection = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = filtered.prefix(Self.maxRows).enumerated().map { i, item in
            let row = PaletteRowView(item: item)
            row.onHover = { [weak self] in self?.select(i) }
            row.onClick = { [weak self] in self?.run(i) }
            list.addSubview(row)
            return row
        }
        select(0)
        needsLayout = true
    }

    private func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(i, 0), rows.count - 1)
        for (j, row) in rows.enumerated() { row.highlighted = j == selection }
    }

    private func run(_ i: Int) {
        guard i < filtered.count else { return }
        let item = filtered[i]
        onDismiss?()
        item.run()
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveUp(_:)):
            select(selection - 1)
        case #selector(moveDown(_:)):
            select(selection + 1)
        case #selector(insertNewline(_:)):
            run(selection)
        case #selector(cancelOperation(_:)):
            if dismissable { onDismiss?() }
        default:
            return false
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)), dismissable { onDismiss?() }
    }

    // Swallow the rest, so nothing behind the palette gets them.
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v ?? (frame.contains(point) ? self : nil)
    }
}

final class PaletteRowView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    /// Set, a drag from the row starts one of these rather than clicking.
    var onDragStart: ((NSEvent) -> Void)?
    private var downAt: NSPoint?
    var highlighted = false { didSet { update() } }
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(item: PaletteItem) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        icon.image = Theme.symbol(item.symbol, size: 13)
        title.stringValue = item.title
        title.font = .systemFont(ofSize: 13.5)
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = item.subtitle
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.lineBreakMode = .byTruncatingMiddle
        for v in [icon, title, subtitle] { addSubview(v) }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The width that shows the whole title (and subtitle, if any).
    var fittingWidth: CGFloat {
        let t = (title.stringValue as NSString).size(withAttributes: [.font: title.font!]).width
        let s = subtitle.stringValue.isEmpty ? 0 : (subtitle.stringValue as NSString).size(withAttributes: [.font: subtitle.font!]).width + 10
        return ceil(38 + t + 6 + s + 12)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        let natural = (title.stringValue as NSString).size(withAttributes: [.font: title.font!]).width
        // With a subtitle, the title leaves it room.
        let cap = subtitle.stringValue.isEmpty ? bounds.width - 50 : bounds.width * 0.6
        let tw = min(ceil(natural) + 6, cap)
        title.frame = NSRect(x: 38, y: (h - 18) / 2, width: tw, height: 18)
        subtitle.frame = NSRect(x: 38 + tw + 10, y: (h - 16) / 2, width: max(0, bounds.width - tw - 60), height: 16)
    }

    private func update() {
        layer?.backgroundColor = highlighted ? Theme.accent.cgColor : NSColor.clear.cgColor
        title.textColor = highlighted ? .white : Theme.text
        subtitle.textColor = highlighted ? NSColor(white: 1, alpha: 0.8) : Theme.secondaryText
        icon.contentTintColor = highlighted ? .white : Theme.secondaryText
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { if !highlighted { onHover?() } }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let onDragStart else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downAt = nil
        onDragStart(event)
    }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil { onClick?() }
        downAt = nil
    }
}
