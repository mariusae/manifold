import AppKit
import ManifoldCore

/// The inspector (§3.5, ⌥⌘I): the focused block's properties in a window
/// of its own, as the Finder's Get Info is — a small panel floating over
/// every window (Manifold's and other apps'), staying up when Manifold
/// isn't in front, taking the keyboard only when a field in it needs it,
/// closed by its own button or ⌥⌘I again, its place and size kept. Compact
/// as Get Info: a row a line, its label at the right of a column and its
/// value after it; sections folded but for what it is and what its kind
/// has, as the reader leaves them.
final class InspectorPanel: NSPanel {
    let list = InspectorList()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let what = NSTextField(labelWithString: "")
    private let tags = NSTextField(labelWithString: "")
    private let tagIcon = NSImageView()
    private let header = NSView()
    private let rule = FlatDivider()
    /// Told when it's closed by its own button.
    var onClose: (() -> Void)?
    /// A row clicked: what it does, or where it goes.
    var onOpen: ((OrgNode) -> Void)? {
        get { list.onOpen }
        set { list.onOpen = newValue }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Inspector"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        minSize = NSSize(width: 240, height: 200)
        let content = NSView()
        content.wantsLayer = true
        content.themed { $0.layer?.backgroundColor = Theme.panel.cgColor }
        icon.imageScaling = .scaleProportionallyDown
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        what.font = UIType.detail
        what.textColor = Theme.secondaryText
        what.lineBreakMode = .byTruncatingTail
        tags.font = UIType.detail
        tags.textColor = Theme.text
        tags.lineBreakMode = .byTruncatingTail
        tagIcon.image = Theme.symbol("tag", size: 10, weight: .medium, color: Theme.secondaryText)
        for v in [icon, name, what, tags, tagIcon, rule] { header.addSubview(v) }
        content.addSubview(header)
        content.addSubview(list)
        contentView = content
        setFrameAutosaveName("Inspector")
        if frame.origin == .zero { center() }
    }

    /// What it shows: the block's name, what and where it is, its
    /// annotations as tags, its sections.
    func show(title: String, subtitle: String, symbol: String?, tags marks: [String], nodes: [OrgNode]) {
        name.stringValue = title
        what.stringValue = subtitle
        tags.stringValue = marks.joined(separator: "  ")
        tags.toolTip = marks.joined(separator: "\n")
        tags.isHidden = marks.isEmpty
        tagIcon.isHidden = marks.isEmpty
        icon.image = symbol.flatMap { Theme.symbol($0, size: 22, weight: .light, color: Theme.secondaryText) }
        list.show(nodes)
        layoutContent()
    }

    override func close() {
        super.close()
        onClose?()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutContent()
    }

    private func layoutContent() {
        guard let content = contentView else { return }
        let b = content.bounds
        let h: CGFloat = tags.isHidden ? 48 : 66
        header.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: h)
        icon.frame = NSRect(x: 10, y: h - 42, width: 32, height: 32)
        name.frame = NSRect(x: 48, y: h - 24, width: b.width - 58, height: 17)
        what.frame = NSRect(x: 48, y: h - 41, width: b.width - 58, height: 15)
        tagIcon.frame = NSRect(x: 48, y: 6, width: 12, height: 12)
        tags.frame = NSRect(x: 63, y: 4, width: b.width - 73, height: 15)
        rule.frame = NSRect(x: 0, y: 0, width: b.width, height: 1)
        list.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - h)
    }

    /// Debugging: the window as drawn, written to `path`.
    func debugPicture(to path: String) -> String {
        guard let v = contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return "nothing drawn" }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return "wrote \(path)"
    }

    var debugState: String {
        "\(isVisible ? "shown" : "hidden") \(Int(frame.width))×\(Int(frame.height)) level \(level.rawValue): \(name.stringValue) — \(what.stringValue)"
            + (tags.isHidden ? "" : " [\(tags.stringValue)]")
    }
}

/// The inspector's sections, as Get Info's: a heading with a disclosure
/// triangle, a click folding or unfolding it (kept, by the section, for
/// every block); under it a row a line — its label right-aligned in a
/// column, a colon after it, its value after that, middle-truncated, the
/// whole in its tip — a row that does something taking a click.
final class InspectorList: NSView {
    var onOpen: ((OrgNode) -> Void)?
    private let scroll = ClippingScrollView()
    private let stack = FlippedView()
    private var sections: [OrgNode] = []
    /// Folded or not by the reader, by section id; what isn't here is as
    /// it starts (only what it is and its kind's open).
    private var open: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "InspectorSections") as? [String: Bool]) ?? [:]
    static let openAtFirst: Set<String> = ["insp:About", "insp:kind", "insp:none", "insp:versions"]
    static let rowHeight: CGFloat = 18, headingHeight: CGFloat = 24, labelWidth: CGFloat = 92

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    func isOpen(_ id: String) -> Bool { open[id] ?? Self.openAtFirst.contains(id) }

    func show(_ nodes: [OrgNode]) {
        sections = nodes
        rebuild()
    }

    private func toggle(_ id: String) {
        open[id] = !isOpen(id)
        UserDefaults.standard.set(open, forKey: "InspectorSections")
        rebuild()
    }

    private func rebuild() {
        stack.subviews.forEach { $0.removeFromSuperview() }
        for s in sections {
            // A lone row (nothing to inspect) is shown as it is.
            guard s.isGroup else { stack.addSubview(InspectorRow(s, onOpen: onOpen)); continue }
            let open = isOpen(s.id)
            stack.addSubview(InspectorHeading(s.title, open: open, count: s.children.count) { [weak self] in self?.toggle(s.id) })
            if open { for r in s.children { stack.addSubview(InspectorRow(r, onOpen: onOpen)) } }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let w = scroll.contentSize.width
        var y: CGFloat = 4
        for v in stack.subviews {
            let h = v is InspectorHeading ? Self.headingHeight : Self.rowHeight
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        stack.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 8, scroll.contentSize.height))
    }

    // MARK: Debugging

    /// Each line as it reads: a heading's triangle, a row's label and value.
    var debugRows: String {
        stack.subviews.enumerated().map { i, v in
            "\(i) " + ((v as? InspectorHeading)?.debugState ?? (v as? InspectorRow)?.debugState ?? "?")
        }.joined(separator: "\n")
    }

    func debugClick(_ i: Int) -> String {
        guard stack.subviews.indices.contains(i) else { return "no row \(i)" }
        if let h = stack.subviews[i] as? InspectorHeading { h.onClick(); return "toggled" }
        if let r = stack.subviews[i] as? InspectorRow { return r.click() ? "clicked" : "nothing to do" }
        return "?"
    }

    /// "fold <section title>": as its heading clicked.
    func debugToggle(_ title: String) -> String {
        guard let s = sections.first(where: { $0.title == title }) else { return "no section \(title)" }
        toggle(s.id)
        return isOpen(s.id) ? "open" : "folded"
    }
}

/// A section's heading: its triangle, its name, how many rows it holds
/// when it's folded.
private final class InspectorHeading: NSView {
    let onClick: () -> Void
    private let title: String
    private let open: Bool
    private let count: Int

    init(_ title: String, open: Bool, count: Int, onClick: @escaping () -> Void) {
        self.title = title
        self.open = open
        self.count = count
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let chevron = Theme.symbol(open ? "chevron.down" : "chevron.right", size: 9, weight: .semibold, color: Theme.secondaryText) {
            chevron.draw(in: chevron.centered(in: NSRect(x: 8, y: 6, width: 12, height: 12)), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: true, hints: nil)
        }
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text]
        (title as NSString).draw(at: NSPoint(x: 24, y: 4), withAttributes: a)
        if !open {
            let n = NSAttributedString(string: "\(count)", attributes: [.font: UIType.detail, .foregroundColor: Theme.tertiaryText])
            n.draw(at: NSPoint(x: bounds.width - 14 - n.size().width, y: 5))
        }
        Theme.divider.setFill()
        NSRect(x: 8, y: 0, width: bounds.width - 16, height: 0.5).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    var debugState: String { (open ? "▾ " : "▸ ") + title + (open ? "" : " (\(count))") }
}

/// A row: its label (what it is, the part before an em dash) right-aligned
/// in its column, a colon, its value; a row with no label its value across.
private final class InspectorRow: NSView {
    private let node: OrgNode
    private let onOpen: ((OrgNode) -> Void)?
    private let label: String
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    /// Copied a moment ago: its button a checkmark.
    private var copied = false { didSet { needsDisplay = true } }
    private static let button: CGFloat = 20

    /// The copy button's place, at the right, for a row that copies.
    private var buttonRect: NSRect? {
        node.copies == nil ? nil : NSRect(x: bounds.width - 8 - Self.button, y: (bounds.height - 16) / 2, width: Self.button, height: 16)
    }

    init(_ node: OrgNode, onOpen: ((OrgNode) -> Void)?) {
        self.node = node
        self.onOpen = onOpen
        // As Get Info's: capitalized ("Kind:", "Size:").
        let words = node.detail.components(separatedBy: " — ").first ?? node.detail
        label = words.prefix(1).uppercased() + words.dropFirst()
        super.init(frame: .zero)
        toolTip = node.tooltip ?? (label.isEmpty ? node.title : "\(label): \(node.title)")
        if let copies = node.copies { toolTip = (toolTip ?? "") + "\nClick to copy: \(copies)" }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var acts: Bool { node.action != nil || node.block != nil || node.arrangement != nil }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, acts {
            Flat.hovered.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        var x: CGFloat = 12
        if !label.isEmpty {
            let right = NSMutableParagraphStyle()
            right.alignment = .right
            right.lineBreakMode = .byTruncatingHead
            let la: [NSAttributedString.Key: Any] = [.font: UIType.detail, .foregroundColor: Theme.secondaryText, .paragraphStyle: right]
            (label + ":" as NSString).draw(in: NSRect(x: 8, y: 2, width: InspectorList.labelWidth, height: 15), withAttributes: la)
            x = 8 + InspectorList.labelWidth + 6
        }
        let va: [NSAttributedString.Key: Any] = [.font: UIType.detail, .foregroundColor: acts && hovering ? Tints.accentText : Theme.text, .paragraphStyle: para]
        let end = buttonRect.map { $0.minX - 4 } ?? bounds.width - 10
        (node.title as NSString).draw(in: NSRect(x: x, y: 2, width: end - x, height: 15), withAttributes: va)
        // Its copy button: always there, darker under the pointer, a check once it's copied.
        if let r = buttonRect {
            let color = copied ? Status.done : hovering ? Theme.text : Theme.tertiaryText
            if let image = Theme.symbol(copied ? "checkmark" : "doc.on.doc", size: 11, weight: .medium, color: color) {
                image.draw(in: image.centered(in: r), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// The row's text on the clipboard, its button saying so a moment.
    func copyText() {
        guard let text = node.copies else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copied = false }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { if acts || node.copies != nil { addCursorRect(bounds, cursor: .pointingHand) } }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        // The copy button, or a row that copies: copied here, said by its check.
        if node.copies != nil { return copyText() }
        _ = click()
    }

    @discardableResult func click() -> Bool {
        if node.copies != nil { copyText(); return true }
        guard acts else { return false }
        onOpen?(node)
        return true
    }

    var debugState: String { (label.isEmpty ? "" : label + ": ") + node.title + (node.copies == nil ? "" : " [copy]") }
}
