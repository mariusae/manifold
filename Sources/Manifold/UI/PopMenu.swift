import AppKit

/// A menu of rows from the sidebar's foot (§3.6), as Dia's: frosted, over
/// the window; a search field at its top, a key's hint at its right (or ×
/// once something's typed), and — for one that has them — a filter
/// button showing a row of chips; then its rows, in sections under small
/// headers, a hairline between groups. ↑↓ choose, ↩ goes, ⎋ or a click
/// outside closes it.
final class PopMenu: NSView, NSTextFieldDelegate {
    struct Item {
        var symbol: String
        var image: NSImage? = nil
        var title: String
        var subtitle: String = ""
        /// At its right: a count, a word.
        var trailing: String = ""
        /// A row that leads somewhere else (Show All, Recently Closed): a › at its right.
        var chevron = false
        var dimmed = false
        /// The menu stays (Show All: more of it).
        var keepsOpen = false
        var run: () -> Void
    }

    struct Section {
        var title: String?
        var items: [Item]
        /// A hairline over it, apart from what's above.
        var divided = false
    }

    struct Chip: Equatable {
        var id: String
        var title: String
    }

    /// What it shows for what's typed and the chips on.
    var provider: (String, Set<String>) -> [Section] = { _, _ in [] }
    var chips: [Chip] = [] { didSet { filterButton.isHidden = chips.isEmpty; buildChips() } }
    private(set) var on: Set<String> = []
    var onClose: (() -> Void)?
    var hint = "" { didSet { hintLabel.stringValue = hint } }
    var placeholder = "Search" { didSet { field.placeholderString = placeholder } }
    /// What it says with nothing to show.
    var empty = "Nothing here"

    private let ground = NSVisualEffectView()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let clear = IconButton(symbol: "xmark.circle.fill", size: 12, weight: .regular, target: nil, action: nil)
    private let filterButton = IconButton(symbol: "line.3.horizontal.decrease", size: 12, weight: .medium, target: nil, action: nil)
    private var chipButtons: [ChipButton] = []
    private var chipsShown = false
    private let scroll = NSScrollView()
    private let list = PopMenuList()

    static let width: CGFloat = 330
    static let searchHeight: CGFloat = 44
    static let chipsHeight: CGFloat = 34

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 20
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        ground.material = .popover
        ground.blendingMode = .withinWindow
        ground.state = .active
        ground.wantsLayer = true
        ground.layer?.cornerRadius = 12
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        ground.layer?.borderWidth = 0.5
        addSubview(ground)
        glass.image = Theme.symbol("magnifyingglass", size: 13, weight: .regular)
        glass.contentTintColor = Theme.secondaryText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.delegate = self
        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = Theme.tertiaryText
        clear.contentTintColor = Theme.tertiaryText
        clear.onClick = { [weak self] in
            guard let self else { return }
            self.field.stringValue = ""
            self.refresh()
            self.window?.makeFirstResponder(self.field)
        }
        filterButton.toolTip = "Filters"
        filterButton.onClick = { [weak self] in
            guard let self else { return }
            self.chipsShown.toggle()
            self.updateFilterLook()
            self.needsLayout = true
        }
        filterButton.isHidden = true
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        list.onRun = { [weak self] item in
            if !item.keepsOpen { self?.onClose?() }
            item.run()
        }
        for v in [glass, field, hintLabel, clear, filterButton, scroll] as [NSView] { ground.addSubview(v) }
        themed { v in v.ground.layer?.borderColor = Flat.line.cgColor }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildChips() {
        chipButtons.forEach { $0.removeFromSuperview() }
        chipButtons = chips.map { c in
            let b = ChipButton(c.title)
            b.onClick = { [weak self, weak b] in
                guard let self, let b else { return }
                if self.on.contains(c.id) { self.on.remove(c.id) } else { self.on.insert(c.id) }
                b.isOn = self.on.contains(c.id)
                self.updateFilterLook()
                self.refresh()
            }
            ground.addSubview(b)
            return b
        }
    }

    /// Filters on: its button in the accent, the chips kept showing.
    private func updateFilterLook() {
        filterButton.contentTintColor = on.isEmpty ? Theme.secondaryText : Theme.accent
        filterButton.layer?.backgroundColor = chipsShown ? Theme.text.withAlphaComponent(0.08).cgColor : nil
    }

    func setOn(_ ids: Set<String>) {
        on = ids
        for (b, c) in zip(chipButtons, chips) { b.isOn = on.contains(c.id) }
        if !on.isEmpty { chipsShown = true }
        updateFilterLook()
    }

    /// Made again from the provider, the first row chosen.
    func refresh() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        list.sections = provider(q, on)
        list.empty = empty
        list.chosen = list.items.isEmpty ? nil : 0
        clear.isHidden = field.stringValue.isEmpty
        hintLabel.isHidden = !field.stringValue.isEmpty
        needsLayout = true
    }

    /// Its height for what it shows, at most `most`.
    func wantedHeight(most: CGFloat) -> CGFloat {
        min(most, Self.searchHeight + (chipsShown && !chips.isEmpty ? Self.chipsHeight : 0) + list.wantedHeight + 8)
    }

    func focus() { window?.makeFirstResponder(field) }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let w = bounds.width, top = bounds.height
        let sy = top - Self.searchHeight
        glass.frame = NSRect(x: 14, y: sy + (Self.searchHeight - 16) / 2, width: 16, height: 16)
        var right = w - 12
        if !filterButton.isHidden {
            filterButton.frame = NSRect(x: right - 26, y: sy + (Self.searchHeight - 26) / 2, width: 26, height: 26)
            filterButton.wantsLayer = true
            filterButton.layer?.cornerRadius = 7
            right -= 30
        }
        hintLabel.sizeToFit()
        hintLabel.frame.origin = NSPoint(x: right - hintLabel.frame.width - 2, y: sy + (Self.searchHeight - hintLabel.frame.height) / 2)
        clear.frame = NSRect(x: right - 20, y: sy + (Self.searchHeight - 20) / 2, width: 20, height: 20)
        let fieldRight = (hintLabel.isHidden ? clear.frame.minX : hintLabel.frame.minX) - 6
        field.frame = NSRect(x: 38, y: sy + (Self.searchHeight - 22) / 2, width: max(0, fieldRight - 38), height: 22)
        var y = sy
        let showChips = chipsShown && !chips.isEmpty
        var x: CGFloat = 12
        for b in chipButtons {
            b.isHidden = !showChips
            let bw = b.wantedWidth
            b.frame = NSRect(x: x, y: y - Self.chipsHeight + 5, width: bw, height: 24)
            x += bw + 6
        }
        if showChips { y -= Self.chipsHeight }
        scroll.frame = NSRect(x: 0, y: 4, width: w, height: max(0, y - 4))
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(list.wantedHeight, scroll.contentSize.height))
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): list.move(1); scrollToChosen(); return true
        case #selector(NSResponder.moveUp(_:)): list.move(-1); scrollToChosen(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let item = list.chosenItem { if !item.keepsOpen { onClose?() }; item.run() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    private func scrollToChosen() {
        guard let r = list.chosenRect else { return }
        list.scrollToVisible(r.insetBy(dx: 0, dy: -6))
    }

    // Clicks stop here, not on what's beneath.
    override func mouseDown(with event: NSEvent) {}

    var debugRows: String { list.debugRows }
    func debugType(_ s: String) { field.stringValue = s; refresh() }
    func debugChip(_ id: String) { if let i = chips.firstIndex(where: { $0.id == id }) { chipsShown = true; chipButtons[i].onClick?() } }
}

/// A chip, as Dia's: a small grey capsule, its word in grey — on, a
/// little deeper and its word in the text's colour; never loud.
final class ChipButton: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    var title: String { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let height: CGFloat = 24

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var wantedWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 20 }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: (bounds.height - Self.height) / 2 + 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Theme.text.withAlphaComponent(isOn ? 0.15 : hovering ? 0.09 : 0.055).setFill()
        path.fill()
        let s = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: isOn ? Theme.text : Theme.secondaryText])
        let z = s.size()
        s.draw(at: NSPoint(x: (bounds.width - z.width) / 2, y: (bounds.height - z.height) / 2))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}

/// One of a few, as chips (in place of a segmented control): the one
/// chosen on; chosen, its action sent.
final class ChipGroup: NSControl {
    private var chips: [ChipButton] = []
    var labels: [String] = [] {
        didSet {
            chips.forEach { $0.removeFromSuperview() }
            chips = labels.enumerated().map { i, l in
                let c = ChipButton(l)
                c.onClick = { [weak self] in
                    guard let self else { return }
                    self.selectedSegment = i
                    self.sendAction(self.action, to: self.target)
                }
                addSubview(c)
                return c
            }
            selectedSegment = min(selectedSegment, max(0, labels.count - 1))
            needsLayout = true
        }
    }
    var selectedSegment = 0 { didSet { for (i, c) in chips.enumerated() { c.isOn = i == selectedSegment } } }
    var segmentCount: Int { labels.count }

    convenience init(labels: [String]) {
        self.init(frame: .zero)
        self.labels = labels
        self.selectedSegment = 0
    }

    var wantedWidth: CGFloat { chips.reduce(0) { $0 + $1.wantedWidth } + CGFloat(max(0, chips.count - 1)) * 6 }
    override func sizeToFit() { setFrameSize(NSSize(width: wantedWidth, height: ChipButton.height)) }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for c in chips {
            c.frame = NSRect(x: x, y: 0, width: c.wantedWidth, height: bounds.height)
            x += c.wantedWidth + 6
        }
    }
}

/// The menu's rows, drawn: section headers, hairlines, rows with their
/// icon, title, subtitle and what's at their right; the one chosen (the
/// pointer's, or the keys') on a band.
final class PopMenuList: NSView {
    var sections: [PopMenu.Section] = [] { didSet { lay() } }
    var empty = ""
    var chosen: Int? { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onRun: ((PopMenu.Item) -> Void)?

    private enum Line { case header(String), rule, item(Int) }
    private var lines: [(Line, NSRect)] = []
    private(set) var items: [PopMenu.Item] = []

    static let header: CGFloat = 26
    static let row: CGFloat = 32
    static let twoLines: CGFloat = 44

    override var isFlipped: Bool { true }

    private func lay() {
        lines = []
        items = []
        var y: CGFloat = 2
        for s in sections where !s.items.isEmpty {
            if s.divided, y > 2 {
                lines.append((.rule, NSRect(x: 0, y: y + 4, width: 0, height: 1)))
                y += 9
            }
            if let t = s.title {
                lines.append((.header(t), NSRect(x: 0, y: y, width: 0, height: Self.header)))
                y += Self.header
            }
            for item in s.items {
                let h = item.subtitle.isEmpty ? Self.row : Self.twoLines
                lines.append((.item(items.count), NSRect(x: 0, y: y, width: 0, height: h)))
                items.append(item)
                y += h
            }
        }
        wantedHeight = items.isEmpty ? 60 : y + 2
        needsDisplay = true
    }

    private(set) var wantedHeight: CGFloat = 60

    var chosenItem: PopMenu.Item? { chosen.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    var chosenRect: NSRect? {
        guard let c = chosen else { return nil }
        for (l, r) in lines { if case .item(let i) = l, i == c { return NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height) } }
        return nil
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        chosen = max(0, min(items.count - 1, (chosen ?? -1) + by))
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        if items.isEmpty {
            let s = NSAttributedString(string: empty, attributes: [.font: UIType.body, .foregroundColor: Theme.secondaryText])
            s.draw(at: NSPoint(x: (w - s.size().width) / 2, y: 20))
            return
        }
        for (l, r0) in lines {
            let r = NSRect(x: 0, y: r0.minY, width: w, height: r0.height)
            switch l {
            case .header(let t):
                NSAttributedString(string: t, attributes: [.font: UIType.section, .foregroundColor: Theme.secondaryText])
                    .draw(at: NSPoint(x: 16, y: r.minY + 8))
            case .rule:
                Theme.divider.setFill()
                NSRect(x: 12, y: r.minY, width: w - 24, height: 1).fill()
            case .item(let i):
                let item = items[i]
                let band = r.insetBy(dx: 6, dy: 1)
                if chosen == i {
                    Theme.text.withAlphaComponent(0.09).setFill()
                    NSBezierPath(roundedRect: band, xRadius: 7, yRadius: 7).fill()
                }
                let ink = item.dimmed ? Theme.secondaryText : Theme.text
                let iconRect = NSRect(x: 16, y: r.minY + (Self.row - 16) / 2, width: 16, height: 16)
                if let image = item.image {
                    image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else if let image = Theme.symbol(item.symbol, size: 12.5, weight: .regular, color: Theme.secondaryText) {
                    let z = image.size
                    image.draw(in: NSRect(x: iconRect.midX - z.width / 2, y: iconRect.midY - z.height / 2, width: z.width, height: z.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                var right = w - 16
                if item.chevron, let c = Theme.symbol("chevron.right", size: 10, weight: .semibold, color: Theme.tertiaryText) {
                    let z = c.size
                    c.draw(in: NSRect(x: right - z.width, y: r.minY + (Self.row - z.height) / 2, width: z.width, height: z.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    right -= z.width + 8
                }
                if !item.trailing.isEmpty {
                    let t = NSAttributedString(string: item.trailing, attributes: [.font: UIType.detail, .foregroundColor: Theme.tertiaryText])
                    let z = t.size()
                    t.draw(at: NSPoint(x: right - z.width, y: r.minY + (Self.row - z.height) / 2))
                    right -= z.width + 8
                }
                let x = iconRect.maxX + 10
                NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink])
                    .draw(with: NSRect(x: x, y: r.minY + (Self.row - 17) / 2 + 0.5, width: max(0, right - x), height: 17),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                if !item.subtitle.isEmpty {
                    NSAttributedString(string: item.subtitle, attributes: [.font: UIType.detail, .foregroundColor: Theme.secondaryText])
                        .draw(with: NSRect(x: x, y: r.minY + Self.row - 8, width: max(0, w - 16 - x), height: 15),
                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        for (l, r) in lines { if case .item(let i) = l, p.y >= r.minY, p.y < r.maxY { return i } }
        return nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { if let i = index(at: event) { chosen = i } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event), items.indices.contains(i) else { return }
        onRun?(items[i])
    }

    var debugRows: String {
        lines.map { l, _ -> String in
            switch l {
            case .header(let t): return "## " + t
            case .rule: return "--"
            case .item(let i): return (chosen == i ? "> " : "  ") + items[i].title + (items[i].subtitle.isEmpty ? "" : " — " + items[i].subtitle) + (items[i].trailing.isEmpty ? "" : " [\(items[i].trailing)]") + (items[i].chevron ? " ›" : "")
            }
        }.joined(separator: "\n")
    }
}
