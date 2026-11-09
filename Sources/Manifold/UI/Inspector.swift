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
    private let name = NSTextField.label(font: .systemFont(ofSize: 13, weight: .semibold), cut: .byTruncatingMiddle)
    private let what = NSTextField.label(font: UIType.detail, color: Theme.secondaryText)
    private let tags = NSTextField.label(font: UIType.detail)
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
    /// it starts: only what anything is at a glance open — its About, its
    /// kind's own (a space's), a host's versions; the detail (a kind's
    /// Details, a space's layout and tiles, a host's machine and server,
    /// ids, links, history…) folded.
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

    /// The sections shown. The same rows as before with only their values
    /// changed (a host's traffic, each second), they're changed in place —
    /// the pointer's row, its tip, the scroll left as they are.
    func show(_ nodes: [OrgNode]) {
        let same = Self.shape(nodes) == Self.shape(sections)
        sections = nodes
        if same, !editing, !pendingRebuild, updateInPlace() { return }
        rebuild()
    }

    /// What rows there are, apart from their values: each section and the
    /// label of each row, and what a row does.
    private static func shape(_ nodes: [OrgNode]) -> [String] {
        nodes.flatMap { s in
            ["§" + s.id + (s.isGroup ? "" : "/" + s.detail)] + s.children.map {
                "\($0.detail)|\($0.editable != nil)|\($0.adds != nil)|\($0.copies != nil)|\($0.block?.description ?? "")|\($0.action != nil)"
            }
        }
    }

    /// Each row given its new node, in the order they're shown; false if
    /// what's shown isn't what the sections say (rebuilt, then).
    private func updateInPlace() -> Bool {
        var views = stack.subviews.makeIterator()
        func next(_ node: OrgNode) -> Bool {
            switch views.next() {
            case let r as InspectorRow: r.update(node); return true
            case is InspectorEditRow: return node.editable != nil
            default: return false
            }
        }
        for s in sections {
            guard s.isGroup else { if !next(s) { return false }; continue }
            guard views.next() is InspectorHeading else { return false }
            if isOpen(s.id) { for r in s.children where !next(r) { return false } }
        }
        return views.next() == nil
    }

    private func toggle(_ id: String) {
        open[id] = !isOpen(id)
        UserDefaults.standard.set(open, forKey: "InspectorSections")
        rebuild()
    }

    /// Rows were being edited when new ones came: shown once they're not.
    private var pendingRebuild = false

    /// A row being edited, or a new one not yet said: the rows aren't
    /// replaced under it.
    private var editing: Bool { stack.subviews.contains { ($0 as? InspectorEditRow)?.holds == true } }

    private func rebuild() {
        if editing {
            pendingRebuild = true
            return
        }
        pendingRebuild = false
        stack.subviews.forEach { $0.removeFromSuperview() }
        for s in sections {
            // A lone row (nothing to inspect) is shown as it is.
            guard s.isGroup else { stack.addSubview(InspectorRow(s, onOpen: onOpen)); continue }
            let open = isOpen(s.id)
            stack.addSubview(InspectorHeading(s.title, open: open, count: s.children.count) { [weak self] in self?.toggle(s.id) })
            if open { for r in s.children { stack.addSubview(row(r)) } }
        }
        needsLayout = true
    }

    private func row(_ node: OrgNode) -> NSView {
        if let e = node.editable { return editRow(e, isNew: false) }
        if node.adds != nil { return InspectorRow(node) { [weak self] n in self?.add(n) } }
        return InspectorRow(node, onOpen: onOpen)
    }

    private func editRow(_ e: InspectorEditable, isNew: Bool) -> InspectorEditRow {
        let r = InspectorEditRow(e, isNew: isNew)
        r.onDone = { [weak self] row in
            guard let self else { return }
            if row.isNew { row.removeFromSuperview() }
            // What came while it was edited (its own change, as the host took it).
            if self.pendingRebuild { DispatchQueue.main.async { self.rebuild() } } else { self.needsLayout = true }
        }
        return r
    }

    /// An add row clicked: a new row before it, its name to type.
    private func add(_ node: OrgNode) {
        guard let template = node.adds, let at = stack.subviews.firstIndex(where: { ($0 as? InspectorRow)?.node === node }) else { return }
        // One new row at a time.
        if let open = stack.subviews.first(where: { ($0 as? InspectorEditRow)?.isNew == true }) as? InspectorEditRow { return open.focus() }
        let r = editRow(template, isNew: true)
        stack.addSubview(r, positioned: .below, relativeTo: stack.subviews[at])
        layout()
        r.focus()
    }

    /// A section opened (if it's folded) and its add row clicked: what a
    /// menu's "Add Environment Variable…" does.
    func startAdding(in sectionID: String) {
        if !isOpen(sectionID) { toggle(sectionID) }
        guard let node = sections.first(where: { $0.id == sectionID })?.children.first(where: { $0.adds != nil }) else { return }
        add(node)
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
            "\(i) " + ((v as? InspectorHeading)?.debugState ?? (v as? InspectorRow)?.debugState ?? (v as? InspectorEditRow)?.debugState ?? "?")
        }.joined(separator: "\n")
    }

    /// "set <row> name=… value=… scope=…": an edited row's fields as if
    /// typed, then left (said, as leaving it does); "set <row> escape".
    func debugSet(_ arg: String) -> String {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard let i = parts.first.flatMap(Int.init), stack.subviews.indices.contains(i),
              let r = stack.subviews[i] as? InspectorEditRow else { return "no edited row there" }
        return r.debugSet(parts.count > 1 ? parts[1] : "")
    }

    func debugClick(_ i: Int) -> String {
        guard stack.subviews.indices.contains(i) else { return "no row \(i)" }
        if let h = stack.subviews[i] as? InspectorHeading { h.clicked(); return "toggled" }
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
private final class InspectorHeading: ClickView {
    private let title: String
    private let open: Bool
    private let count: Int

    init(_ title: String, open: Bool, count: Int, onClick: @escaping () -> Void) {
        self.title = title
        self.open = open
        self.count = count
        super.init(frame: .zero)
        self.onClick = onClick
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

    var debugState: String { (open ? "▾ " : "▸ ") + title + (open ? "" : " (\(count))") }
}

/// A row: its label (what it is, the part before an em dash) right-aligned
/// in its column, a colon, its value; a row with no label its value across.
private final class InspectorRow: NSView {
    private(set) var node: OrgNode
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
        setTip()
    }

    private func setTip() {
        var tip = node.tooltip ?? (label.isEmpty ? node.title : "\(label): \(node.title)")
        if let copies = node.copies { tip += "\nClick to copy: \(copies)" }
        if toolTip != tip { toolTip = tip }
    }

    /// The same row, its value now (its label, and what it does, as they were).
    func update(_ new: OrgNode) {
        let changed = new.title != node.title
        node = new
        setTip()
        if changed { needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var acts: Bool { node.action != nil || node.block != nil || node.arrangement != nil || node.adds != nil }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, acts {
            Flat.hovered.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        // An add row: in the values' column, under them.
        var x: CGFloat = node.adds != nil ? 8 + InspectorList.labelWidth + 6 : 12
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
        NSPasteboard.copy(text)
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

/// A row the inspector edits in place (a host's variable, §8.6): what it
/// holds, the choices at its right (a scope), and what's done with it —
/// said by its owner, which hears it once the row's left (Return, Tab on,
/// a click elsewhere) or its choice changes.
final class InspectorEditable {
    var name: String
    var value: String
    var choice: String
    var choices: [String]
    var namePlaceholder: String
    var valuePlaceholder: String
    /// The value as shown while it isn't edited (a secret's hidden).
    var shown: (_ name: String, _ value: String) -> String = { $1 }
    var commit: (_ name: String, _ value: String, _ choice: String) -> Void
    var remove: (() -> Void)?
    var help: String?

    init(name: String = "", value: String = "", choice: String, choices: [String], namePlaceholder: String = "NAME",
         valuePlaceholder: String = "value", commit: @escaping (String, String, String) -> Void) {
        self.name = name
        self.value = value
        self.choice = choice
        self.choices = choices
        self.namePlaceholder = namePlaceholder
        self.valuePlaceholder = valuePlaceholder
        self.commit = commit
    }
}

/// A field of an edited row: no bezel, its row's face; its whole value
/// shown once it's being edited (a secret's hidden till then).
private final class InspectorField: NSTextField {
    var onFocus: (() -> Void)?

    init(alignment: NSTextAlignment, secondary: Bool) {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = UIType.detail
        textColor = secondary ? Theme.secondaryText : Theme.text
        self.alignment = alignment
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    var isEditing: Bool { (window?.firstResponder as? NSTextView)?.delegate === self }
}

/// An edited row: its name in the label column, its value, both fields;
/// its choice at the right, a menu (and Remove).
private final class InspectorEditRow: NSView, NSTextFieldDelegate {
    let spec: InspectorEditable
    let isNew: Bool
    var onDone: ((InspectorEditRow) -> Void)?
    private let nameField = InspectorField(alignment: .right, secondary: true)
    private let valueField = InspectorField(alignment: .left, secondary: false)
    private var value: String
    private var choice: String
    private var cancelled = false
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private static let choiceWidth: CGFloat = 58

    init(_ spec: InspectorEditable, isNew: Bool) {
        self.spec = spec
        self.isNew = isNew
        value = spec.value
        choice = spec.choice
        super.init(frame: .zero)
        nameField.stringValue = spec.name
        nameField.placeholderString = spec.namePlaceholder
        valueField.placeholderString = spec.valuePlaceholder
        showValue(editing: false)
        for f in [nameField, valueField] {
            f.delegate = self
            addSubview(f)
        }
        nameField.nextKeyView = valueField
        valueField.onFocus = { [weak self] in self?.showValue(editing: true) }
        toolTip = spec.help
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Being edited, or new and not yet said.
    var holds: Bool { isNew || nameField.isEditing || valueField.isEditing }

    /// Its field to type in — only while Manifold is the app in front: the
    /// panel doesn't activate it, so made key from behind (a menu of the
    /// Dock's, a script) it would take what's typed into another app.
    func focus() {
        guard NSApp.isActive else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(isNew && nameField.stringValue.isEmpty ? nameField : valueField)
    }

    private func showValue(editing: Bool) {
        valueField.stringValue = editing ? value : spec.shown(nameField.stringValue, value)
    }

    private var choiceRect: NSRect { NSRect(x: bounds.width - 8 - Self.choiceWidth, y: 1, width: Self.choiceWidth, height: bounds.height - 2) }

    override func layout() {
        super.layout()
        nameField.frame = NSRect(x: 8, y: 1, width: InspectorList.labelWidth, height: 16)
        let x = 8 + InspectorList.labelWidth + 6
        valueField.frame = NSRect(x: x, y: 1, width: max(0, choiceRect.minX - 4 - x), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The fields' ground: faint under the pointer, plain while edited.
        if hovering || holds {
            Flat.hovered.setFill()
            NSBezierPath(roundedRect: nameField.frame.insetBy(dx: -3, dy: 0), xRadius: 3, yRadius: 3).fill()
            NSBezierPath(roundedRect: valueField.frame.insetBy(dx: -3, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let a: [NSAttributedString.Key: Any] = [.font: UIType.detail, .foregroundColor: hovering ? Theme.text : Theme.secondaryText, .paragraphStyle: para]
        let r = choiceRect
        (choice as NSString).draw(in: NSRect(x: r.minX, y: 2, width: r.width - 13, height: 15), withAttributes: a)
        if let chevron = Theme.symbol("chevron.up.chevron.down", size: 8, weight: .medium, color: Theme.secondaryText) {
            chevron.draw(in: chevron.centered(in: NSRect(x: r.maxX - 11, y: 2, width: 10, height: 14)), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if choiceRect.contains(p) { return showChoices() }
        super.mouseDown(with: event)
    }

    private func showChoices() {
        let menu = NSMenu()
        for c in spec.choices {
            let item = ClosureMenuItem(c) { [weak self] in self?.choose(c) }
            item.state = c == choice ? .on : .off
            menu.addItem(item)
        }
        if !isNew, let remove = spec.remove {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove", symbol: "trash") { remove() })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: choiceRect.minX, y: choiceRect.maxY + 2), in: self)
    }

    private func choose(_ c: String) {
        choice = c
        needsDisplay = true
        // A row there already: said at once; a new one, with the rest.
        if !isNew { spec.commit(spec.name, spec.value, c) }
    }

    // MARK: Editing

    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === valueField { value = valueField.stringValue }
        // Tabbed to its other field: still being edited.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.nameField.isEditing, !self.valueField.isEditing else { return }
            self.finish()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if control === nameField, isNew { window?.makeFirstResponder(valueField) } else { window?.makeFirstResponder(nil) }
            return true
        default:
            return false
        }
    }

    /// A new row said or given up: it goes, and isn't said again.
    private var over = false

    private func finish() {
        guard !over else { return }
        defer {
            cancelled = false
            needsDisplay = true
            if isNew {
                over = true
                // Its field let go before it goes (no editor left on a row gone).
                if nameField.isEditing || valueField.isEditing { window?.makeFirstResponder(nil) }
            }
            onDone?(self)
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if cancelled || (isNew && name.isEmpty) || (!isNew && name.isEmpty) {
            nameField.stringValue = spec.name
            value = spec.value
            showValue(editing: false)
            return
        }
        showValue(editing: false)
        guard isNew || name != spec.name || value != spec.value else { return }
        spec.commit(name, value, choice)
    }

    // MARK: Debugging

    var debugState: String {
        (isNew ? "+ " : "✎ ") + (nameField.stringValue.isEmpty ? "(name)" : nameField.stringValue) + " = " + valueField.stringValue + " [\(choice)]"
    }

    func debugSet(_ arg: String) -> String {
        if arg == "escape" {
            cancelled = true
            finish()
            return "cancelled"
        }
        for pair in arg.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "name": nameField.stringValue = kv[1]
            case "value": value = kv[1]
            case "scope":
                if isNew { choice = kv[1] } else { choose(kv[1]); return "chose" }
            case "remove":
                spec.remove?()
                return "removed"
            default: break
            }
        }
        finish()
        return "said"
    }
}
