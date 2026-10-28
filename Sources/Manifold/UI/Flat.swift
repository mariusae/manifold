import AppKit

/// The flat style, one set of parts every view makes its controls of, so
/// they're the same everywhere: no bezels, no gradients; a hairline on a
/// faint fill where a control needs an edge, the accent only for what has
/// the keyboard, is on, is chosen (a thin band of it), or is the thing to
/// do; a faint grey band under the pointer; the system font throughout.
enum Flat {
    // Radii, type and shadows are Design.swift's measures (Radius.control
    // for fields and buttons, Radius.surface for floating panels,
    // UIType.body, Elevation.float).
    static let fieldHeight: CGFloat = 28
    static let buttonHeight: CGFloat = 24
    /// A control's edge, and its fill.
    static var line: NSColor { Theme.text.withAlphaComponent(0.14) }
    static var fill: NSColor { Theme.text.withAlphaComponent(0.025) }
    /// A band: chosen (stronger with the keyboard), under the pointer, pressed.
    static func chosen(emphasized: Bool = true) -> NSColor { emphasized ? Theme.selection : Theme.selectionInactive }
    static var hovered: NSColor { Theme.hover }
    /// Pressed: the hover's grey, deeper — not the tint, which is for
    /// what's chosen (a grey button pressed doesn't flash blue).
    static let pressed = NSColor.dynamic(NSColor(white: 0, alpha: 0.11), NSColor(white: 1, alpha: 0.14))

    /// A panel floating over the window: rounded, a hairline round it, and
    /// one soft shadow — the same for every one (but one in a window of its
    /// own, whose window casts the shadow).
    static func float(_ v: NSView, background: NSColor = Theme.panel, shadow: Bool = true) {
        v.wantsLayer = true
        guard let l = v.layer else { return }
        l.cornerRadius = Radius.surface
        l.cornerCurve = .continuous
        l.borderWidth = 0.5
        if shadow { Elevation.float.apply(to: l) }
        v.themed {
            $0.layer?.backgroundColor = background.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
    }

    /// The mark at a row's left edge saying it's the one — a marked row,
    /// a notebook's focused cell: the tint, a little light, this wide,
    /// rounded as a hairline.
    static var mark: NSColor { Theme.accent.withAlphaComponent(0.85) }
    static let markWidth: CGFloat = 3

    /// A thin progress bar in `track`: a faint groove, the tint filled as
    /// far as `fraction` — or, not knowing how far, a quarter of it moving
    /// along (`phase`, 0…1) — a summary card's, a transfer's.
    static func progress(in track: NSRect, fraction: Double?, phase: Double = 0) {
        Theme.divider.setFill()
        NSBezierPath(roundedRect: track, xRadius: Radius.hair, yRadius: Radius.hair).fill()
        Theme.accent.setFill()
        var bar = track
        if let f = fraction {
            bar.size.width = max(track.height, track.width * CGFloat(max(0, min(1, f))))
        } else {
            bar = NSRect(x: track.minX + track.width * 0.75 * CGFloat(phase), y: track.minY, width: track.width * 0.25, height: track.height)
        }
        NSBezierPath(roundedRect: bar, xRadius: Radius.hair, yRadius: Radius.hair).fill()
    }

    /// A list row's band — hovered, or chosen — as every list draws it: in
    /// from the row's sides and a hair from its top and bottom, rounded as
    /// a control is.
    static func rowBand(_ r: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 1), xRadius: Radius.control, yRadius: Radius.control)
    }

    /// A list set in a window (a settings table): a hairline round it,
    /// rounded as a field is, not the system's sunken bezel.
    static func outline(_ scroll: NSScrollView) {
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Radius.control + 1
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.borderWidth = 1
        scroll.layer?.masksToBounds = true
        scroll.themed { $0.layer?.borderColor = Flat.line.cgColor }
    }
}

// MARK: Fields

/// A field that says when it takes the keyboard (its box shows it). ⎋
/// empties it, as a search field's does (its delegate may take ⎋ first);
/// empty, ⎋ goes on as usual.
final class FlatField: NSTextField {
    var focused: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focused() }
        return ok
    }

    override func cancelOperation(_ sender: Any?) {
        guard !stringValue.isEmpty, let box = superview as? FlatFieldBox, box.clears else { return super.cancelOperation(sender) }
        box.clearField()
    }
}

/// A field's box: a hairline round it on a faint fill, in the accent while
/// it has the keyboard. A symbol at the left (a filter's magnifier), the
/// field, and a cross at the right to clear it once there's something in
/// it. (Made of these rather than a search field, which without its bezel
/// lets the text it's editing run under its magnifier.) Every text field
/// that isn't part of something larger — the palette's, a pill's — is one.
final class FlatFieldBox: NSView {
    let field = FlatField()
    private let glass = NSImageView()
    private let clear = NSButton()
    let clears: Bool
    /// What's in it changed: typed, or emptied by its cross.
    var onChange: () -> Void = {}

    init(symbol: String? = "magnifyingglass", clears: Bool = true, fontSize: CGFloat = 13) {
        self.clears = clears
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: Flat.fieldHeight))
        if let symbol {
            glass.image = Theme.symbol(symbol, size: fontSize - 1, weight: .regular)
            glass.contentTintColor = Theme.secondaryText
        } else {
            glass.isHidden = true
        }
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = Theme.text
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.focused = { [weak self] in self?.needsDisplay = true }
        clear.isBordered = false
        clear.image = Theme.symbol("xmark", size: 10, weight: .semibold)
        clear.contentTintColor = Theme.secondaryText
        clear.toolTip = "Clear"
        clear.target = self
        clear.action = #selector(clearField)
        clear.isHidden = true
        for v in [glass, field, clear] as [NSView] { addSubview(v) }
        NotificationCenter.default.addObserver(self, selector: #selector(typed), name: NSControl.textDidChangeNotification, object: field)
        NotificationCenter.default.addObserver(self, selector: #selector(edited), name: NSControl.textDidEndEditingNotification, object: field)
    }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue; update() }
    }

    /// The cross shown once there's something to clear.
    func update() {
        let shown = clears && !field.stringValue.isEmpty
        if clear.isHidden == shown {
            clear.isHidden = !shown
            needsLayout = true
        }
    }

    @objc private func edited() {
        update()
        needsDisplay = true
    }

    @objc private func typed() {
        edited()
        onChange()
    }

    @objc func clearField() {
        field.stringValue = ""
        update()
        onChange()
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        let h = bounds.height, button: CGFloat = 20
        glass.frame = NSRect(x: 7, y: 0, width: 16, height: h)
        clear.frame = NSRect(x: bounds.width - button - 4, y: (h - button) / 2, width: button, height: button)
        let left = glass.isHidden ? 8 : glass.frame.maxX + 4
        let right = clear.isHidden ? bounds.width - 8 : clear.frame.minX - 2
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: left, y: ((h - fh) / 2).rounded(), width: max(0, right - left), height: fh)
    }

    /// Whether the window's field editor is editing its field now.
    var hasKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return false }
        return field.isDescendant(of: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.control + 1, yRadius: Radius.control + 1)
        Flat.fill.setFill()
        path.fill()
        path.lineWidth = 1
        (hasKeyboard ? EdgeColor.accentStrong : Flat.line).setStroke()
        path.stroke()
    }

    /// A click anywhere in it is the field's.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

// MARK: Buttons

/// A button with words (and a symbol, perhaps): a hairline on a faint
/// fill, darker under the pointer and pressed; `.primary`, the thing to
/// do, filled in the accent. One that toggles is on in the accent.
final class FlatButton: NSButton {
    enum Style { case normal, primary }
    var style: Style { didSet { needsDisplay = true } }
    private let toggles: Bool
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    /// The symbol before the words (or alone, with none).
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    init(_ title: String, symbol: String? = nil, style: Style = .normal, toggles: Bool = false, font: NSFont = UIType.body,
         target: AnyObject? = nil, action: Selector? = nil) {
        self.style = style
        self.toggles = toggles
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: Flat.buttonHeight))
        setButtonType(toggles ? .pushOnPushOff : .momentaryPushIn)
        isBordered = false
        self.title = title
        self.font = font
        symbolName = symbol
        self.target = target
        self.action = action
        setFrameSize(intrinsicContentSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    private var on: Bool { toggles && state == .on }
    private var ink: NSColor {
        style == .primary ? .white : on ? Tints.accentText : Theme.text
    }
    private var symbol: NSImage? { symbolName.flatMap { Theme.symbol($0, size: (font?.pointSize ?? 12) - 1, weight: .medium) } }
    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: font ?? UIType.body, .foregroundColor: ink])
    }

    override var intrinsicContentSize: NSSize {
        var w = ceil(label.size().width)
        if let s = symbol { w += s.size.width + (title.isEmpty ? 0 : 5) }
        return NSSize(width: w + (title.isEmpty ? 12 : 20), height: Flat.buttonHeight)
    }

    override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        defer { ctx?.restoreGState() }
        if !isEnabled { ctx?.setAlpha(0.4) }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.control, yRadius: Radius.control)
        let pressed = isHighlighted && isEnabled, over = hovering && isEnabled
        switch style {
        case .primary:
            Tints.accentFill.blended(withFraction: pressed ? 0.2 : over ? 0.1 : 0, of: .black)?.setFill()
            path.fill()
        case .normal:
            (on ? Theme.accent.withAlphaComponent(pressed ? 0.22 : 0.14)
                : pressed ? Flat.pressed : over ? Flat.hovered : Flat.fill).setFill()
            path.fill()
            path.lineWidth = 1
            (on ? EdgeColor.accentSoft : Flat.line).setStroke()
            path.stroke()
        }
        // The symbol and the words, centered together.
        let text = label
        let ts = text.size()
        let image = symbol?.tinted(ink)
        let iw = image.map { $0.size.width + (title.isEmpty ? 0 : 5) } ?? 0
        var x = ((bounds.width - ceil(ts.width) - iw) / 2).rounded()
        if let image {
            let ir = NSRect(x: x, y: ((bounds.height - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
            image.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iw
        }
        text.draw(at: NSPoint(x: x, y: ((bounds.height - ts.height) / 2).rounded()))
    }
}

// MARK: Segments

/// A choice of a few (a mode, a scope): its words or symbols in a row, the
/// one chosen on a grey band, a fainter one under the pointer; no frame
/// round them.
final class FlatSegments: NSView, NSViewToolTipOwner {
    enum Item {
        case title(String)
        case symbol(String)
    }
    private let items: [Item]
    private var tips: [Int: String] = [:]
    private let font: NSFont
    var selectedSegment = 0 {
        didSet {
            guard selectedSegment != oldValue else { return }
            if window != nil, !Motion.reduced, items.indices.contains(oldValue) { glide(from: band(to: oldValue)) }
            needsDisplay = true
        }
    }
    /// The chosen band on its way from where it was, as a slider's knob goes.
    private var gliding: (from: NSRect, start: CFTimeInterval)?
    private var glideTimer: Timer?
    private func glide(from r: NSRect) {
        gliding = (r, CACurrentMediaTime())
        glideTimer?.invalidate()
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, let g = self.gliding else { return t.invalidate() }
            if CACurrentMediaTime() - g.start >= Motion.base { self.gliding = nil; t.invalidate() }
            self.needsDisplay = true
        }
    }
    /// Where the chosen band is drawn: its segment's, or on its way there.
    private func band(to i: Int) -> NSRect {
        let to = rect(i)
        guard let g = gliding else { return to }
        let t = min(1, (CACurrentMediaTime() - g.start) / max(Motion.base, 0.001))
        let e = 1 - pow(1 - t, 3)
        return NSRect(x: g.from.minX + (to.minX - g.from.minX) * e, y: to.minY,
                      width: g.from.width + (to.width - g.from.width) * e, height: to.height)
    }
    /// Chosen by a click (not when set).
    var onChange: ((Int) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ items: [Item], font: NSFont = UIType.body) {
        self.items = items
        self.font = font
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
    }

    convenience init(titles: [String], font: NSFont = UIType.body) { self.init(titles.map { .title($0) }, font: font) }
    convenience init(symbols: [String]) { self.init(symbols.map { .symbol($0) }) }

    required init?(coder: NSCoder) { fatalError() }

    var segmentCount: Int { items.count }

    func setToolTip(_ tip: String, forSegment i: Int) {
        tips[i] = tip
        updateTips()
    }

    private func width(of item: Item) -> CGFloat {
        switch item {
        case .title(let t): ceil((t as NSString).size(withAttributes: [.font: font]).width) + 18
        case .symbol: 28
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: items.map(width).reduce(0, +) + CGFloat(max(items.count - 1, 0)) * 2, height: Flat.buttonHeight)
    }

    func sizeToFit() { setFrameSize(intrinsicContentSize) }

    private func rect(_ i: Int) -> NSRect {
        var x: CGFloat = 0
        for j in 0..<i { x += width(of: items[j]) + 2 }
        return NSRect(x: x, y: (bounds.height - Flat.buttonHeight) / 2, width: width(of: items[i]), height: Flat.buttonHeight)
    }

    private func index(at p: NSPoint) -> Int? { items.indices.first { rect($0).contains(p) } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTips()
    }

    private func updateTips() {
        removeAllToolTips()
        for i in items.indices where tips[i] != nil { addToolTip(rect(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).flatMap { tips[$0] } ?? ""
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), i != selectedSegment else { return }
        selectedSegment = i
        onChange?(i)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let h = hovered, h != selectedSegment, items.indices.contains(h) {
            Flat.hovered.setFill()
            NSBezierPath(roundedRect: rect(h), xRadius: Radius.control, yRadius: Radius.control).fill()
        }
        if items.indices.contains(selectedSegment) {
            Flat.chosen().setFill()
            NSBezierPath(roundedRect: band(to: selectedSegment), xRadius: Radius.control, yRadius: Radius.control).fill()
        }
        for (i, item) in items.enumerated() {
            let r = rect(i)
            let chosen = i == selectedSegment
            let ink = chosen ? Theme.text : Theme.secondaryText
            switch item {
            case .title(let t):
                let a = NSAttributedString(string: t, attributes: [.font: chosen ? NSFont.systemFont(ofSize: font.pointSize, weight: .medium) : font, .foregroundColor: ink])
                let s = a.size()
                a.draw(at: NSPoint(x: (r.midX - s.width / 2).rounded(), y: (r.midY - s.height / 2).rounded()))
            case .symbol(let name):
                guard let image = Theme.symbol(name, size: 12, weight: .regular)?.tinted(ink) else { continue }
                image.draw(in: NSRect(x: (r.midX - image.size.width / 2).rounded(), y: (r.midY - image.size.height / 2).rounded(),
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

// MARK: Slider

/// A slider's: a thin track, filled in the accent up to a small round knob.
final class FlatSliderCell: NSSliderCell {
    private static let knob: CGFloat = 13

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // From the knob's center at one end to its center at the other, less
        // what the system's wider knob leaves beyond this one.
        let knob = knobRect(flipped: flipped)
        let inset = max(0, (knob.width - Self.knob) / 2)
        let bar = NSRect(x: rect.minX + inset, y: rect.midY - 1.5, width: rect.width - 2 * inset, height: 3)
        Theme.text.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: Radius.hair, yRadius: Radius.hair).fill()
        Theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(0, knob.midX - bar.minX), height: bar.height), xRadius: Radius.hair, yRadius: Radius.hair).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d = Self.knob
        let r = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        Theme.panel.setFill()
        path.fill()
        path.lineWidth = 1
        EdgeColor.control.setStroke()
        path.stroke()
    }
}

// MARK: Checkboxes

/// A checkbox in a table's cells: a small rounded square, a hairline on a
/// faint fill; checked, filled in the accent with a white tick.
final class FlatCheckboxCell: NSButtonCell {
    private static let box: CGFloat = 14, gap: CGFloat = 7

    override init(textCell string: String) {
        super.init(textCell: string)
        setButtonType(.switch)
        title = string
        font = UIType.row
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    override var cellSize: NSSize {
        guard !title.isEmpty else { return NSSize(width: Self.box + 2, height: Self.box + 2) }
        let t = (title as NSString).size(withAttributes: [.font: font ?? UIType.row])
        return NSSize(width: Self.box + Self.gap + ceil(t.width) + 2, height: max(Self.box + 2, ceil(t.height)))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let d = Self.box
        // Alone (a table's cell): the box in the middle; titled, at the
        // left, its title after it.
        let x = title.isEmpty ? (cellFrame.midX - d / 2).rounded() : cellFrame.minX + 1
        let r = NSRect(x: x, y: (cellFrame.midY - d / 2).rounded(), width: d, height: d)
        if !title.isEmpty {
            let a = NSAttributedString(string: title, attributes: [.font: font ?? UIType.row, .foregroundColor: isEnabled ? Theme.text : Theme.tertiaryText])
            let size = a.size()
            a.draw(at: NSPoint(x: r.maxX + Self.gap, y: cellFrame.midY - size.height / 2))
        }
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.inline, yRadius: Radius.inline)
        let on = state == .on
        (on ? Tints.accentFill : Flat.fill).setFill()
        path.fill()
        if !on {
            path.lineWidth = 1
            EdgeColor.control.setStroke()
            path.stroke()
        } else if let tick = Theme.symbol("checkmark", size: 9, weight: .bold)?.tinted(.white) {
            tick.draw(in: NSRect(x: r.midX - tick.size.width / 2, y: r.midY - tick.size.height / 2, width: tick.size.width, height: tick.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

extension Flat {
    /// A checkbox, flat: the box and its title.
    static func checkbox(_ title: String) -> NSButton {
        let b = NSButton(frame: .zero)
        b.cell = FlatCheckboxCell(textCell: title)
        return b
    }

    /// A slider, flat: a thin bar, a round knob.
    static func slider(value: Double, min: Double, max: Double) -> NSSlider {
        let s = NSSlider(frame: .zero)
        s.cell = FlatSliderCell()
        s.minValue = min
        s.maxValue = max
        s.doubleValue = value
        return s
    }
}

// MARK: Table headers

/// A column's header: its title small and grey on nothing, a hairline
/// under the row of them and between columns — not the system's bar.
final class FlatHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.windowBackground.setFill()
        cellFrame.fill()
        Theme.divider.setFill()
        NSRect(x: cellFrame.minX, y: controlView.isFlipped ? cellFrame.maxY - 1 : cellFrame.minY, width: cellFrame.width, height: 1).fill()
        if cellFrame.minX > 0 {
            NSRect(x: cellFrame.minX, y: cellFrame.minY + 5, width: 1, height: cellFrame.height - 10).fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let a = NSAttributedString(string: stringValue, attributes: [.font: UIType.caption, .foregroundColor: Theme.secondaryText])
        let s = a.size()
        let x = alignment == .right ? cellFrame.maxX - 6 - s.width : cellFrame.minX + 6
        a.draw(in: NSRect(x: x, y: cellFrame.midY - s.height / 2, width: min(s.width, cellFrame.width - 12), height: s.height))
    }
}

extension Flat {
    /// A table's column headers made flat.
    static func headers(_ table: NSTableView) {
        for c in table.tableColumns {
            let cell = FlatHeaderCell(textCell: c.title)
            cell.alignment = c.headerCell.alignment
            c.headerCell = cell
        }
    }
}

// MARK: Backgrounds

/// A panel's own window's background, drawn (so it's in the window's
/// appearance whenever it's drawn, as the glass it replaces was; a layer's
/// color is only as current as the last switch it heard of).
final class FlatBackground: NSView {
    var color: NSColor = Theme.panel { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

// MARK: Dividers

/// A hairline between two parts of a view, in the dividers' grey.
final class FlatDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        bounds.fill()
    }
}
