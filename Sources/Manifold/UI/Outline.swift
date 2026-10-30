import AppKit
import ManifoldCore

/// A view's outline (§7.5): the places in what it shows — a text's
/// headings, a PDF's contents, an agent's turns, a diff's files and their
/// changes — which of them you're at, and what each does: chosen, the view
/// goes there; its menu, what else can be done with it (a link to it, an
/// agent turn's changes). One per view, kept as the view changes whether
/// or not anything shows it; the tile's ticks (`OutlineTicks`) and its
/// sidebar (`TileSidebar`) both show it.
final class Outline {
    struct Item: Equatable {
        var title: String
        var level = 0
        /// At the right, in grey: how a command ended, and when.
        var detail = ""
        var failed = false
        var running = false
        /// In the code font: a command, not a heading.
        var code = false
    }

    private(set) var items: [Item] = []
    /// The item you're at: the last that begins at or above the top of
    /// what shows (a terminal's, the last command whose output shows).
    var current: Int? {
        didSet { if current != oldValue { changed() } }
    }
    /// An item chosen (clicked, ⏎): the view goes there.
    var onPick: ((Int) -> Void)?
    /// What can be done with an item, as a menu.
    var menuFor: ((Int) -> NSMenu?)?
    /// What an item with no place of its own carries, dragged out (a diff's file).
    var writerFor: ((Int) -> NSPasteboardWriting?)?
    /// The block it's the outline of, and each item's place in it ("line=12",
    /// "page=3", "command=7"): what a link to an item says.
    var block: BlockID?
    var placeFor: ((Int) -> String?)?

    /// Counts up each time its items change (not the current one): what
    /// a space's index (`OutlineIndex`) goes by, with which outline it is
    /// (`serial`, never another's, as an address could be).
    private(set) var generation = 0
    let serial: Int = {
        Outline.made += 1
        return Outline.made
    }()
    private static var made = 0
    /// Its space's index watches it (once).
    var indexed = false

    func set(_ fresh: [Item]) {
        guard fresh != items else { return }
        items = fresh
        generation += 1
        if let c = current, c >= items.count { current = nil }
        changed()
    }

    func pick(_ i: Int) {
        guard items.indices.contains(i) else { return }
        onPick?(i)
    }

    /// What an item carries dragged (§3.11): the place in its block it is
    /// (a heading, a page, a command), with its words — a note links to
    /// it, a shell types it, an agent is given what's there; an item with
    /// no place of its own, what the view gives (a diff's file), else its block.
    func dragItem(_ i: Int) -> NSPasteboardWriting? {
        guard items.indices.contains(i) else { return nil }
        if let block, let place = Drags.place, let fragment = placeFor?(i) { return place(block, fragment, items[i].title) }
        if let w = writerFor?(i) { return w }
        if let block, let place = Drags.place { return place(block, nil, items[i].title) }
        return nil
    }

    /// Whether an item can be dragged at all.
    var draggable: Bool { block != nil || writerFor != nil }

    /// Headings as items, the shallowest at the left (a text whose
    /// headings all begin at ## isn't indented a step for nothing).
    static func headings(_ headings: [(title: String, level: Int)]) -> [Item] {
        let top = headings.map(\.level).min() ?? 0
        return headings.map { Item(title: $0.title, level: min(max($0.level - top, 0), 4)) }
    }

    /// Those showing it, told when its items or the current one change;
    /// each kept only as long as its owner is.
    private var watchers: [(owner: () -> AnyObject?, run: () -> Void)] = []

    func watch(_ owner: AnyObject, _ run: @escaping () -> Void) {
        watchers.append(({ [weak owner] in owner }, run))
    }

    private func changed() {
        watchers.removeAll { $0.owner() == nil }
        for w in watchers { w.run() }
    }
}

/// A tile's outline at its upper right (§7.5): a few short ticks — five at
/// most, however long the outline — the one nearest where you are longer
/// and darker. The pointer on them opens the whole outline over them
/// (`FloatingList`): an item clicked goes there; its actions are its ⋯.
/// It takes no room of its own: it sits over the content's corner, in
/// from the scroll bar.
final class OutlineTicks: NSView {
    static let maxTicks = 5
    static let size = NSSize(width: 22, height: 28)
    private static let spacing: CGFloat = 5
    private static let thickness: CGFloat = 2

    let outline: Outline
    /// Whether the grid shows its tile (not collapsed, stashed, or held).
    var available = true { didSet { if available != oldValue { refresh() } } }
    private var hovering = false

    init(outline: Outline) {
        self.outline = outline
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.zPosition = 5
        outline.watch(self) { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        isHidden = !available || outline.items.isEmpty
        needsDisplay = true
        if isHidden { FloatingList.shared.hide(for: self) } else { FloatingList.shared.update(rows(), for: self) }
    }

    /// Which tick stands for the item you're at: the item itself among
    /// five or fewer; its share of the way down a longer outline.
    var currentTick: Int? {
        guard let c = outline.current, !outline.items.isEmpty else { return nil }
        let n = min(outline.items.count, Self.maxTicks)
        guard outline.items.count > n else { return c }
        return Int((Double(c) / Double(outline.items.count - 1) * Double(n - 1)).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = min(outline.items.count, Self.maxTicks)
        let span = CGFloat(n - 1) * Self.spacing + Self.thickness
        var y = ((bounds.height - span) / 2).rounded()
        let right = bounds.width - 4
        for i in 0..<n {
            let here = i == currentTick
            let length: CGFloat = here ? 14 : 10
            (here || hovering ? Theme.text : Theme.secondaryText.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: NSRect(x: right - length, y: y, width: length, height: Self.thickness),
                         xRadius: Self.thickness / 2, yRadius: Self.thickness / 2).fill()
            y += Self.spacing
        }
    }

    /// The outline's items as the list's rows.
    private func rows() -> [FloatingList.Row] {
        outline.items.enumerated().map { i, item in
            FloatingList.Row(title: item.title, detail: item.detail, level: item.level, code: item.code,
                             failed: item.failed, running: item.running, current: i == outline.current,
                             action: { [weak outline] in
                                 FloatingList.shared.hideNow()
                                 outline?.pick(i)
                             },
                             menu: outline.menuFor == nil ? nil : { [weak outline] in outline?.menuFor?(i) },
                             drag: !outline.draggable ? nil : { [weak outline] _ in outline?.dragItem(i) })
        }
    }

    /// The whole outline, over the ticks.
    func open() {
        guard !isHidden, let window else { return }
        let r = convert(bounds, to: nil)
        FloatingList.shared.show(rows(), for: self, in: window, place: .overTopRight(r), scrollToCurrent: true)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        open()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        FloatingList.shared.openerLeft(self)
    }

    override func mouseDown(with event: NSEvent) { open() }

    /// Debugging: the ticks as drawn, and the items.
    var debugState: String {
        let n = min(outline.items.count, Self.maxTicks)
        return "ticks \(n) current tick \(currentTick.map(String.init) ?? "-") hidden \(isHidden)\n"
            + outline.items.enumerated().map { "\($0.offset == outline.current ? "*" : " ")\(String(repeating: "  ", count: $0.element.level))\($0.element.title)\($0.element.detail.isEmpty ? "" : " · " + $0.element.detail)" }.joined(separator: "\n")
    }
}

/// A list floating over the window — an outline opened from its ticks, a
/// command's actions from its dot — in a little window of its own over it,
/// as a menu is: the views under it don't see the pointer while it's on
/// the list (a terminal's caret cursor, a page's), and it has a window's
/// shadow. A row clicked does what it does; one with a menu has a ⋯ while the
/// pointer is on it (and the menu on a right-click). It stays while the
/// pointer is on it or on what opened it, and goes a moment after it's on
/// neither.
final class FloatingList: NSView {
    static let shared = FloatingList()

    struct Row {
        var title: String
        var detail = ""
        var level = 0
        var code = false
        var failed = false
        var running = false
        /// The item you're at: its dash longer and darker.
        var current = false
        /// A symbol in place of the dash: an action's.
        var symbol: String?
        /// Not clickable: what the rows below are about (a command's line).
        var header = false
        var action: (() -> Void)?
        var menu: (() -> NSMenu?)?
        /// What it carries dragged, with the modifiers held.
        var drag: ((NSEvent.ModifierFlags) -> NSPasteboardWriting?)?
        /// The part of the title in bold (what was typed, in a completion).
        var bold: NSRange?
    }

    enum Place {
        /// Over a rectangle (in the window), its top right corner on the rectangle's.
        case overTopRight(NSRect)
        /// To the right of a rectangle (in the window), its first row level with it.
        case rightOf(NSRect)
        /// Under a rectangle (in the window), as wide as it: a field's completions.
        case below(NSRect)
    }

    private let scroll = ClippingScrollView()
    private let stack = FlippedView()
    private var rowViews: [FloatingListRow] = []
    private(set) var rows: [Row] = []
    /// What opened it (ticks, a dot), which keeps it while the pointer is there.
    private weak var opener: AnyObject?
    private var hideWork: DispatchWorkItem?
    private var place: Place = .overTopRight(.zero)
    /// The window it's over, and its own.
    private weak var host: NSWindow?
    private let panel: NSPanel = ListPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

    /// Never key: the keyboard stays where it was.
    private final class ListPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static let rowHeight: CGFloat = 28
    private static let pad: CGFloat = 6

    private init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        applyColors()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        addSubview(scroll)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its layer's colors, as its appearance is now: set as it shows and as
    /// its appearance changes (its window, closed, may hear of light and dark
    /// switching before it has taken the new one on).
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.panel.cgColor
            layer?.borderColor = Theme.panelBorder.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    var isShown: Bool { panel.isVisible && panel.parent != nil }
    func isShown(for owner: AnyObject) -> Bool { isShown && opener === owner }

    /// `sticky`: kept while its owner wants it (a field's completions, while
    /// it's edited), not gone as the pointer leaves.
    func show(_ rows: [Row], for owner: AnyObject, in window: NSWindow, place: Place, scrollToCurrent: Bool = false, sticky: Bool = false) {
        hideWork?.cancel()
        let same = opener === owner && isShown && host === window
        opener = owner
        self.place = place
        self.sticky = sticky
        if !same { chosen = nil }
        host = window
        // (Its appearance the app's, as the window's is — not pinned to the
        // one it had when it last showed: light and dark switch under it.)
        fill(rows)
        position(in: window)
        applyColors()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        updateHover()
        if scrollToCurrent || !same, let i = rows.firstIndex(where: \.current) {
            stack.scrollToVisible(rowViews[i].frame.insetBy(dx: 0, dy: -Self.rowHeight))
        }
    }

    /// The rows afresh, if it shows for this owner (an outline that changed).
    func update(_ rows: [Row], for owner: AnyObject) {
        guard isShown(for: owner), let host else { return }
        fill(rows)
        position(in: host)
    }

    func hide(for owner: AnyObject) {
        if opener === owner { hideNow() }
    }

    func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        // Its rows are used again for the next list: none left marked.
        for r in rowViews { r.hovering = false }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        opener = nil
    }

    /// The pointer left what opened it: gone in a moment, unless it came here.
    func openerLeft(_ owner: AnyObject) {
        guard opener === owner else { return }
        scheduleHide()
    }

    /// The pointer back on what opened it.
    func openerEntered(_ owner: AnyObject) {
        if opener === owner { hideWork?.cancel() }
    }

    /// Gone in a moment — unless by then the pointer is on it, or back on
    /// what opened it, when it's looked at again a moment later. (It opens
    /// under the pointer, over the ticks: the pointer is on it without
    /// ever having come onto it, so its own tracking can't be relied on.)
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.pointerOnIt { self.scheduleHide() } else { self.hideNow() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Where the pointer is, on the screen.
    private var pointer: NSPoint {
        if let p = debugPointer, let host { return host.convertPoint(toScreen: p) }
        return NSEvent.mouseLocation
    }

    /// Whether the pointer is on the list, or on what opened it.
    private var pointerOnIt: Bool {
        guard isShown, let host else { return false }
        let p = pointer
        let opener: NSRect = switch place {
        case let .overTopRight(r), let .rightOf(r), let .below(r): r
        }
        return panel.frame.insetBy(dx: -2, dy: -2).contains(p) || host.convertToScreen(opener).insetBy(dx: -2, dy: -2).contains(p)
    }

    private func fill(_ fresh: [Row]) {
        rows = fresh
        while rowViews.count < fresh.count {
            let r = FloatingListRow()
            stack.addSubview(r)
            rowViews.append(r)
        }
        while rowViews.count > fresh.count { rowViews.removeLast().removeFromSuperview() }
        for (i, row) in fresh.enumerated() { rowViews[i].show(row) }
        updateHover()
    }

    private func position(in window: NSWindow) {
        var width = min(380, max(200, rowViews.map(\.wantedWidth).max() ?? 200)) + 2 * Self.pad
        if case let .below(r) = place { width = r.width }
        let content = CGFloat(rows.count) * Self.rowHeight
        // Within the window's content, in its coordinates.
        let root = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let room = root.insetBy(dx: 8, dy: 8)
        let height = min(content + 2 * Self.pad, min(room.height, 480))
        var frame: NSRect
        switch place {
        case let .overTopRight(r):
            frame = NSRect(x: r.maxX + 6 - width, y: r.maxY + 6 - height, width: width, height: height)
        case let .rightOf(r):
            frame = NSRect(x: r.maxX + 4, y: r.midY + Self.rowHeight / 2 + Self.pad - height, width: width, height: height)
        case let .below(r):
            frame = NSRect(x: r.minX, y: r.minY - 4 - height, width: width, height: height)
        }
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - width)
        frame.origin.y = min(max(frame.minY, room.minY), room.maxY - height)
        panel.setFrame(window.convertToScreen(frame.integral), display: false)
        scroll.frame = bounds.insetBy(dx: 0, dy: Self.pad)
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: content)
        for (i, v) in rowViews.enumerated() {
            v.frame = NSRect(x: Self.pad, y: CGFloat(i) * Self.rowHeight, width: bounds.width - 2 * Self.pad, height: Self.rowHeight)
        }
        panel.invalidateShadow()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hideWork?.cancel()
        updateHover()
    }
    override func mouseExited(with event: NSEvent) {
        if !sticky { scheduleHide() }
        updateHover()
    }
    override func mouseMoved(with event: NSEvent) {
        hideWork?.cancel()
        updateHover()
    }
    // The pointer on it is its own: nothing under it hears of it.
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {
        scroll.scrollWheel(with: event)
        updateHover()
    }

    /// The one row under the pointer, from where the pointer is: rows
    /// scrolled or filled afresh under a pointer that didn't move are told
    /// so (each row's own tracking would leave the ones it left marked).
    private func updateHover() {
        guard isShown else { return }
        let p = panel.convertPoint(fromScreen: pointer)
        let inClip = scroll.contentView.convert(p, from: nil)
        let inStack = stack.convert(p, from: nil)
        let row = scroll.contentView.bounds.contains(inClip) ? rowViews.firstIndex { $0.frame.contains(inStack) } : nil
        pointerRow = row
        for (i, r) in rowViews.enumerated() { r.hovering = i == row || i == chosen }
        // Its own cursor, all over it (a window that's never key has no
        // cursor rectangles): a hand on a row that does something, else
        // the arrow — between rows too.
        if bounds.contains(p) {
            (row.map { !rows[$0].header && rows[$0].action != nil } == true ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    /// Kept while its owner wants it, not gone as the pointer leaves.
    private var sticky = false
    /// The row under the pointer, and the one chosen from the keyboard (a
    /// field's completion): both marked.
    private var pointerRow: Int?
    private(set) var chosen: Int?

    /// A row chosen from the keyboard (nil: none), kept in sight.
    func choose(_ i: Int?) {
        chosen = i.flatMap { rows.indices.contains($0) ? $0 : nil }
        for (j, r) in rowViews.enumerated() { r.hovering = j == pointerRow || j == chosen }
        if let c = chosen { stack.scrollToVisible(rowViews[c].frame) }
    }

    /// Debugging: where the pointer is taken to be (in the window), in place
    /// of where it is.
    var debugPointer: NSPoint?

    /// Debugging: "pointer x y" (in the window, from the bottom left; "pointer"
    /// alone, the real one again), "leave" (the pointer off what opened it).
    func debugPointer(_ arg: String) -> String {
        let words = arg.split(separator: " ")
        if words.first == "leave" {
            if let o = opener { openerLeft(o) }
            return "left"
        }
        let xy = words.dropFirst().compactMap { Double($0) }
        debugPointer = xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
        updateHover()
        let inHost = host?.convertFromScreen(panel.frame) ?? .zero
        return "pointer \(debugPointer.map { NSStringFromPoint($0) } ?? "real") panel \(NSStringFromRect(inHost))"
    }

    /// Debugging: the rows, the current one starred.
    var debugRows: String {
        guard isShown else { return "not shown" }
        let bg = layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { String(format: "%.2f", $0.brightnessComponent) } ?? "-"
        return "frame \(NSStringFromRect(host?.convertFromScreen(panel.frame) ?? .zero)) \(effectiveAppearance.isDark ? "dark" : "light") background \(bg)\n" + rows.enumerated().map { i, r in
            (rowViews[i].hovering ? "h" : " ") + (r.current ? "*" : " ") + (r.header ? "# " : "") + String(repeating: "  ", count: r.level)
                + (r.symbol.map { "[\($0)] " } ?? "") + r.title + (r.menu == nil ? "" : " ⋯")
        }.joined(separator: "\n")
    }

    /// Debugging: as a click on a row; "menu N", its menu's items.
    func debugClick(_ arg: String) -> String {
        let words = arg.split(separator: " ")
        if words.first == "drag", words.count > 1, let i = Int(words[1]), rows.indices.contains(i) {
            // "drag N [shift|optshift]": what the row would carry.
            let mods: NSEvent.ModifierFlags = words.count > 2 ? (words[2] == "optshift" ? [.shift, .option] : [.shift]) : []
            guard let item = rows[i].drag?(mods) as? NSPasteboardItem else { return "nothing" }
            return item.types.map { "\($0.rawValue): \(item.string(forType: $0) ?? "-")" }.joined(separator: "\n")
        }
        if words.first == "menu", words.count > 1, let i = Int(words[1]), rows.indices.contains(i) {
            guard let menu = rows[i].menu?() else { return "no menu" }
            return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: "\n")
        }
        guard let i = words.first.flatMap({ Int($0) }), rows.indices.contains(i), !rows[i].header, let a = rows[i].action else { return "no row \(arg)" }
        a()
        return "clicked \(rows[i].title)"
    }
}

/// A row of a floating list: a dash (or an action's symbol), indented by
/// its level, its title, its detail at the right; on hover, a background
/// and its ⋯.
final class FloatingListRow: NSView, NSDraggingSource {
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let more = IconButton(symbol: "ellipsis", size: 11, weight: .semibold, target: nil, action: nil)
    private var row = FloatingList.Row(title: "")
    /// The pointer is on it (the list says, for one row at a time).
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true; more.isHidden = !hovering || row.menu == nil } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        detail.font = UIType.detail
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        icon.imageScaling = .scaleProportionallyDown
        more.isHidden = true
        more.target = self
        more.action = #selector(moreClicked)
        more.toolTip = "Actions"
        for v in [label, detail, icon, more] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ r: FloatingList.Row) {
        row = r
        label.font = r.code ? FontTheme.code(12.5) : .systemFont(ofSize: 13, weight: r.header ? .medium : .regular)
        label.textColor = r.header ? Theme.secondaryText : r.failed ? Theme.statusError : Theme.text
        if let bold = r.bold, let font = label.font, NSMaxRange(bold) <= (r.title as NSString).length {
            let a = NSMutableAttributedString(string: r.title, attributes: [.font: font, .foregroundColor: label.textColor ?? Theme.text])
            a.addAttribute(.font, value: font.emphasized(bold: true), range: bold)
            label.attributedStringValue = a
        } else {
            label.stringValue = r.title
        }
        detail.stringValue = r.detail
        detail.isHidden = r.detail.isEmpty
        icon.isHidden = r.symbol == nil
        icon.image = r.symbol.flatMap { Theme.symbol($0, size: 12, weight: .regular) }
        icon.contentTintColor = Theme.secondaryText
        more.isHidden = !hovering || r.menu == nil
        needsLayout = true
        needsDisplay = true
    }

    private var indent: CGFloat { CGFloat(min(row.level, 4)) * 12 }
    private var textLeft: CGFloat { 10 + indent + (row.header ? 0 : 20) }

    /// The width a label's text takes, set as it is.
    private static func width(_ f: NSTextField) -> CGFloat { ceil(f.attributedStringValue.size().width) + 4 }

    /// As wide as its title and detail want.
    var wantedWidth: CGFloat {
        textLeft + Self.width(label) + (row.detail.isEmpty ? 0 : 12 + min(Self.width(detail), 140)) + 34
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lh = label.intrinsicContentSize.height
        let right = bounds.width - (row.menu == nil ? 10 : 30)
        let dw = row.detail.isEmpty ? 0 : min(Self.width(detail), 140)
        detail.frame = NSRect(x: right - dw, y: ((h - lh) / 2).rounded(), width: dw, height: lh)
        label.frame = NSRect(x: textLeft, y: ((h - lh) / 2).rounded(), width: max(0, right - (dw > 0 ? dw + 12 : 0) - textLeft), height: lh)
        icon.frame = NSRect(x: 10 + indent, y: (h - 14) / 2, width: 14, height: 14)
        more.frame = NSRect(x: bounds.width - 26, y: (h - 20) / 2, width: 20, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, !row.header {
            Theme.hover.setFill()
            Flat.rowBand(bounds).fill()
        }
        guard row.symbol == nil, !row.header else { return }
        // The dash: the item you're at, longer and darker; a running one
        // in the accent; a failed one in red.
        let length: CGFloat = row.current ? 12 : 9
        let color: NSColor = row.failed ? Theme.statusError : row.running ? Theme.accent
            : row.current ? Theme.text : Theme.secondaryText.withAlphaComponent(0.5)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 10 + indent, y: (bounds.height - 2) / 2, width: length, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where a press began, and whether it became a drag.
    private var pressedAt: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        dragged = false
    }

    /// Dragged out (⇧ for its link, as a pill is): what it carries, its
    /// picture under the pointer; the list goes, out of the way of where it
    /// will be dropped.
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = pressedAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4,
              let writer = row.drag?(event.modifierFlags) else { return }
        dragged = true
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = bitmapImageRepForCachingDisplay(in: bounds).map { rep -> NSImage in
            cacheDisplay(in: bounds, to: rep)
            let i = NSImage(size: bounds.size)
            i.addRepresentation(rep)
            return i
        }
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
        FloatingList.shared.hideNow()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        let p = convert(event.locationInWindow, from: nil)
        guard !dragged, bounds.contains(p), !row.header, more.isHidden || !more.frame.contains(p) else { return }
        row.action?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = row.menu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func moreClicked() {
        guard let menu = row.menu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY + 2), in: self)
    }
}

/// A shell's commands as a dot beside each one's prompt (§3.8), over the
/// terminal's left padding: grey, red for one that failed, the accent for
/// one still running. The pointer on a dot offers what can be done with
/// the command (its output copied, or as a block of its own); anywhere
/// else, the pointer and clicks are the terminal's.
final class CommandDots: NSView {
    struct Dot: Equatable {
        var id: Int
        /// Its middle, from the bottom.
        var y: CGFloat
        var failed = false
        var running = false
    }

    /// The pointer came to a dot: its command, and where it is.
    var onHover: ((Int, NSRect) -> Void)?
    /// The pointer left the dots.
    var onLeave: (() -> Void)?
    private var dots: [Dot] = []
    private var hovered: Int?
    private static let diameter: CGFloat = 5
    /// How near the pointer must be to a dot to be on it.
    private static let reach: CGFloat = 7

    func set(_ fresh: [Dot]) {
        guard fresh != dots else { return }
        dots = fresh
        if let h = hovered, !dots.contains(where: { $0.id == h }) { hovered = nil }
        needsDisplay = true
    }

    func dot(_ id: Int) -> Dot? { dots.first { $0.id == id } }

    func rect(of d: Dot) -> NSRect {
        NSRect(x: bounds.midX - Self.reach, y: d.y - Self.reach, width: 2 * Self.reach, height: 2 * Self.reach)
    }

    private func dot(at p: NSPoint) -> Dot? {
        dots.filter { abs($0.y - p.y) <= Self.reach && p.x >= bounds.minX - 2 && p.x <= bounds.maxX + 4 }
            .min { abs($0.y - p.y) < abs($1.y - p.y) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for d in dots {
            let hot = d.id == hovered
            let color: NSColor = d.failed ? Theme.statusError : d.running ? Theme.accent
                : hot ? Theme.text : Theme.secondaryText.withAlphaComponent(0.45)
            color.setFill()
            let r = hot ? Self.diameter + 2 : Self.diameter
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - r / 2, y: d.y - r / 2, width: r, height: r)).fill()
        }
    }

    /// Only a dot is its own: the rest of the strip is the terminal's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let parent = superview else { return nil }
        return dot(at: convert(point, from: parent)) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: -4, dy: 0), options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointer(at: nil) }

    private func pointer(at p: NSPoint?) {
        let d = p.flatMap { dot(at: $0) }
        guard d?.id != hovered else { return }
        hovered = d?.id
        needsDisplay = true
        if let d { onHover?(d.id, rect(of: d)) } else { onLeave?() }
    }

    override func mouseDown(with event: NSEvent) {
        if let d = dot(at: convert(event.locationInWindow, from: nil)) { onHover?(d.id, rect(of: d)) }
    }

    override func resetCursorRects() {
        for d in dots { addCursorRect(rect(of: d), cursor: .pointingHand) }
    }

    /// Debugging: each dot, from the bottom.
    var debugDots: String {
        "dots \(dots.count) hidden \(isHidden)\n" + dots.map { "\($0.id) y\(Int($0.y))\($0.failed ? " failed" : "")\($0.running ? " running" : "")" }.joined(separator: "\n")
    }
}

extension Outline.Item {
    /// A note's outline entry (a heading, or a top-level item, checked or
    /// not), as an item.
    init(_ item: NoteOutlineItem) {
        self.init(title: item.title, level: item.level, detail: item.task.map { $0.isDone ? "done" : "to do" } ?? "")
    }
}
