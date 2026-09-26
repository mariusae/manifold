import AppKit
import ManifoldCore

protocol SidebarDelegate: AnyObject {
    func sidebarSelect(_ tab: UUID)
    func sidebarClose(_ tab: UUID)
    func sidebarUnsplit(_ tab: UUID)
    func sidebarRename(_ tab: UUID)
    func sidebarMove(_ tab: UUID, to index: Int)
    func sidebarNewTab()
    func sidebarTogglePinned()
    func sidebarMoreMenu() -> NSMenu
    func sidebarDragChanged(_ dragging: Bool)
    /// A pane (a sheet) was dropped on the sidebar.
    func sidebarMovePane(_ pane: UUID, to destination: PaneDestination)
    /// The resize handle was dragged to make the sidebar this wide.
    func sidebarResize(to width: CGFloat)
    func sidebarResizeEnded()
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The floating list of tabs on the left.
final class SidebarView: NSView {
    weak var delegate: SidebarDelegate?
    private let card = NSVisualEffectView()
    private let pinButton: IconButton
    private let header = WindowDragView()
    private let resizeHandle = ResizeHandleView()
    private let scroll = NSScrollView()
    private let list = TabListView()
    private let newTabRow = NewTabRowView()
    private var rows: [UUID: TabRowView] = [:]
    private var order: [UUID] = []
    var pinned = false { didSet { updateChrome() } }

    static let headerHeight: CGFloat = 40

    override init(frame: NSRect) {
        pinButton = IconButton(symbol: "sidebar.left", size: 13, weight: .regular, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        card.material = .sidebar
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.themed { $0.layer?.borderColor = Theme.cardBorder.cgColor }
        addSubview(card)

        card.addSubview(header)
        pinButton.target = self
        pinButton.action = #selector(togglePinned)
        pinButton.toolTip = "Show Sidebar (⌃⌘S)"
        card.addSubview(pinButton)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.contentView.drawsBackground = false
        card.addSubview(scroll)

        list.sidebar = self
        list.registerForDraggedTypes([.manifoldTab, .manifoldPane])
        newTabRow.onClick = { [weak self] in self?.delegate?.sidebarNewTab() }
        newTabRow.onMore = { [weak self] button in
            guard let self, let menu = self.delegate?.sidebarMoreMenu() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        list.addSubview(newTabRow)

        resizeHandle.onDrag = { [weak self] x in
            guard let self, let superview = self.superview else { return }
            self.delegate?.sidebarResize(to: superview.convert(NSPoint(x: x, y: 0), from: nil).x - self.frame.minX)
        }
        resizeHandle.onEnd = { [weak self] in self?.delegate?.sidebarResizeEnded() }
        addSubview(resizeHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        card.frame = bounds
        header.frame = NSRect(x: 0, y: bounds.height - Self.headerHeight, width: bounds.width, height: Self.headerHeight)
        pinButton.frame = NSRect(x: bounds.width - 30, y: bounds.height - 30, width: 20, height: 20)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
        resizeHandle.frame = NSRect(x: bounds.width - 7, y: 0, width: 7, height: bounds.height - Self.headerHeight)
        layoutRows()
    }

    private func updateChrome() {
        layer?.shadowOpacity = pinned ? 0 : 0.16
        pinButton.contentTintColor = pinned ? Theme.text : Theme.secondaryText
        pinButton.toolTip = pinned ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)"
    }

    func update(tabs: [Tab], selected: UUID?, edited: Set<UUID> = []) {
        let ids = tabs.map(\.id)
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows.removeValue(forKey: id)
        }
        for tab in tabs {
            let row = rows[tab.id] ?? {
                let r = TabRowView(tab: tab.id)
                r.sidebar = self
                list.addSubview(r)
                rows[tab.id] = r
                return r
            }()
            row.configure(title: tab.title, paneCount: tab.columns.count, selected: tab.id == selected,
                          symbol: Theme.symbolName(for: tab.focused?.kind ?? .terminal), edited: edited.contains(tab.id))
        }
        order = ids
        layoutRows()
    }

    private func layoutRows() {
        let width = scroll.contentSize.width
        let pad: CGFloat = 8
        var y: CGFloat = 2
        for id in order {
            rows[id]?.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: Theme.rowHeight)
            y += Theme.rowHeight + 2
        }
        newTabRow.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: Theme.rowHeight)
        y += Theme.rowHeight + 8
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    @objc private func togglePinned() { delegate?.sidebarTogglePinned() }

    // MARK: From rows and the list

    func rowClicked(_ id: UUID) { delegate?.sidebarSelect(id) }
    func rowDoubleClicked(_ id: UUID) { delegate?.sidebarRename(id) }
    func rowClose(_ id: UUID) { delegate?.sidebarClose(id) }
    func rowUnsplit(_ id: UUID) { delegate?.sidebarUnsplit(id) }
    func dragChanged(_ dragging: Bool) { delegate?.sidebarDragChanged(dragging) }

    func rowMenu(_ id: UUID, split: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename Tab…") { [weak self] in self?.delegate?.sidebarRename(id) })
        if split {
            menu.addItem(ClosureMenuItem("Separate Columns") { [weak self] in self?.delegate?.sidebarUnsplit(id) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab") { [weak self] in self?.delegate?.sidebarClose(id) })
        return menu
    }

    /// Where a drop at `y` (in the list's coordinates) would put a tab.
    func insertionIndex(at y: CGFloat) -> Int {
        var index = 0
        for id in order {
            guard let row = rows[id] else { continue }
            if y > row.frame.midY { index += 1 }
        }
        return index
    }

    func insertionY(for index: Int) -> CGFloat {
        if index < order.count, let row = rows[order[index]] { return row.frame.minY - 1 }
        if let last = order.last, let row = rows[last] { return row.frame.maxY + 1 }
        return 2
    }

    /// The row whose middle is at `y`, for dropping a sheet onto its tab.
    func row(at y: CGFloat) -> TabRowView? {
        rows.values.first { $0.frame.insetBy(dx: 0, dy: $0.frame.height * 0.2).contains(NSPoint(x: $0.frame.midX, y: y)) }
    }

    func movePane(_ pane: UUID, to destination: PaneDestination) {
        delegate?.sidebarMovePane(pane, to: destination)
    }

    func moveTab(_ id: UUID, toInsertionIndex index: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        let to = from < index ? index - 1 : index
        if to != from { delegate?.sidebarMove(id, to: to) }
    }
}

/// The sidebar's right edge, which resizes it: a pill shows on hover.
final class ResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private let pill = NSView()
    private var hovering = false { didSet { updatePill() } }
    private var dragging = false { didSet { updatePill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pill.wantsLayer = true
        pill.themed { $0.layer?.backgroundColor = Theme.handle.cgColor }
        pill.layer?.cornerRadius = 1.5
        pill.alphaValue = 0
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        pill.frame = NSRect(x: bounds.width - 5, y: (bounds.height - 36) / 2, width: 3, height: 36)
    }

    private func updatePill() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            pill.animator().alphaValue = hovering || dragging ? 1 : 0
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { dragging = true }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x) }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onEnd?()
    }
}

/// The top of the sidebar, beside the window buttons, moves the window, as
/// a title bar would.
final class WindowDragView: NSView {
    /// The window buttons sit on this row, partly below the title bar they
    /// belong to, where they'd get no clicks; pass those clicks on.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), let window, let superview else { return nil }
        let p = superview.convert(point, to: nil)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(type), let bs = b.superview,
                  b.isEnabled, b.alphaValue > 0 else { continue }
            if b.frame.contains(bs.convert(p, from: nil)) { return b }
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// The scrolling list of rows, which takes tab drops to reorder, and sheet
/// drops: between rows, as a new tab there; on a row, onto that tab's stack.
final class TabListView: FlippedView {
    weak var sidebar: SidebarView?
    private let indicator = NSView()
    private var dropIndex: Int?
    private var dropRow: TabRowView? {
        didSet {
            if oldValue !== dropRow { oldValue?.dropTarget = false }
            dropRow?.dropTarget = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = Theme.accent.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        addSubview(indicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        guard let sidebar, pb.string(forType: .manifoldTab) != nil || pb.string(forType: .manifoldPane) != nil else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        if pb.string(forType: .manifoldPane) != nil, let row = sidebar.row(at: p.y) {
            dropRow = row
            dropIndex = nil
            indicator.isHidden = true
            return .move
        }
        dropRow = nil
        let index = sidebar.insertionIndex(at: p.y)
        dropIndex = index
        indicator.frame = NSRect(x: 12, y: sidebar.insertionY(for: index) - 1, width: bounds.width - 24, height: 2)
        indicator.isHidden = false
        addSubview(indicator, positioned: .above, relativeTo: nil)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        indicator.isHidden = true
        dropIndex = nil
        dropRow = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        defer { dropRow = nil }
        guard let sidebar else { return false }
        let pb = sender.draggingPasteboard
        if let pane = pb.string(forType: .manifoldPane).flatMap(UUID.init(uuidString:)) {
            if let row = dropRow {
                sidebar.movePane(pane, to: .tabStack(tab: row.tab))
            } else if let index = dropIndex {
                sidebar.movePane(pane, to: .newTab(tab: UUID(), index: index))
            } else {
                return false
            }
            return true
        }
        guard let index = dropIndex, let id = pb.string(forType: .manifoldTab).flatMap(UUID.init(uuidString:)) else { return false }
        sidebar.moveTab(id, toInsertionIndex: index)
        return true
    }
}

/// A tab in the sidebar.
final class TabRowView: NSView, NSDraggingSource {
    let tab: UUID
    weak var sidebar: SidebarView?
    private let icon = NSImageView()
    private let badge = BadgeView()
    private let title = NSTextField(labelWithString: "")
    private lazy var closeButton = IconButton(symbol: "xmark", target: self, action: #selector(closeClicked))
    private lazy var unsplitButton = IconButton(symbol: "arrow.trianglehead.branch", size: 11, weight: .medium,
                                                target: self, action: #selector(unsplitClicked))
    private var selected = false
    private var paneCount = 1
    private var symbol = "apple.terminal"
    /// Whether an editor in it has unsaved changes: a dot where the close
    /// button goes, as a Mac window's is.
    private var edited = false
    private let editedDot = NSView()
    private var hovering = false { didSet { updateAppearance() } }
    /// Whether a sheet dragged over it would go onto this tab's stack.
    var dropTarget = false { didSet { updateAppearance() } }
    private var mouseDownPoint: NSPoint?

    init(tab: UUID) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        icon.image = Theme.symbol("apple.terminal", size: 13)
        icon.contentTintColor = Theme.secondaryText
        title.font = .systemFont(ofSize: 13)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        closeButton.toolTip = "Close Tab"
        unsplitButton.toolTip = "Separate Columns"
        editedDot.wantsLayer = true
        editedDot.themed { $0.layer?.backgroundColor = Theme.secondaryText.cgColor }
        editedDot.layer?.cornerRadius = 3.5
        for v in [icon, badge, title, unsplitButton, closeButton, editedDot] { addSubview(v) }
        themed { $0.updateAppearance() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, paneCount: Int, selected: Bool, symbol: String, edited: Bool = false) {
        self.edited = edited
        if symbol != self.symbol {
            self.symbol = symbol
            icon.image = Theme.symbol(symbol, size: 13)
        }
        title.stringValue = text
        self.paneCount = paneCount
        self.selected = selected
        badge.count = paneCount
        toolTip = text
        updateAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        badge.frame = icon.frame
        var right = bounds.width - 6
        closeButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
        editedDot.frame = NSRect(x: right - 13.5, y: (h - 7) / 2, width: 7, height: 7)
        if !editedDot.isHidden { right -= 22 }
        if !closeButton.isHidden { right -= 22 }
        unsplitButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
        if !unsplitButton.isHidden { right -= 22 }
        title.frame = NSRect(x: 32, y: (h - 17) / 2, width: max(0, right - 34), height: 17)
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance { updateColors() }
    }

    private func updateColors() {
        let split = paneCount > 1
        icon.isHidden = split
        badge.isHidden = !split
        closeButton.isHidden = !hovering
        editedDot.isHidden = hovering || !edited
        unsplitButton.isHidden = !(hovering && split)
        title.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        if selected {
            layer?.backgroundColor = Theme.selected.cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.1
            layer?.shadowRadius = 2
            layer?.shadowOffset = NSSize(width: 0, height: -1)
            layer?.masksToBounds = false
        } else {
            layer?.backgroundColor = hovering ? Theme.hover.cgColor : NSColor.clear.cgColor
            layer?.shadowOpacity = 0
        }
        if dropTarget {
            layer?.backgroundColor = Theme.dropHighlight.cgColor
            layer?.borderColor = Theme.accent.withAlphaComponent(0.5).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.borderWidth = 0
        }
        needsLayout = true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 {
            mouseDownPoint = nil
            sidebar?.rowDoubleClicked(tab)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let item = NSPasteboardItem()
        item.setString(tab.uuidString, forType: .manifoldTab)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        sidebar?.dragChanged(true)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownPoint != nil { sidebar?.rowClicked(tab) }
        mouseDownPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        sidebar?.rowMenu(tab, split: paneCount > 1)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hovering = false
        sidebar?.dragChanged(false)
    }

    private func snapshot() -> NSImage {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    @objc private func closeClicked() { sidebar?.rowClose(tab) }
    @objc private func unsplitClicked() { sidebar?.rowUnsplit(tab) }
}

/// The number of panes in a split tab, in a blue dot.
final class BadgeView: NSView {
    var count = 2 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 15
        let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        Theme.accent.setFill()
        NSBezierPath(ovalIn: r).fill()
        let s = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let size = s.size()
        s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }
}

/// "+ New Tab", and the "…" menu.
final class NewTabRowView: NSView {
    var onClick: (() -> Void)?
    var onMore: ((NSView) -> Void)?
    private let label = NSTextField(labelWithString: "New Tab")
    private let plus = NSImageView()
    private lazy var more = IconButton(symbol: "ellipsis", size: 12, weight: .medium, target: self, action: #selector(moreClicked))
    private var hovering = false {
        didSet {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = hovering ? Theme.hover.cgColor : NSColor.clear.cgColor
            }
        }
    }
    // Only ever hovered briefly; not hovered after a switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hovering = false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        plus.image = Theme.symbol("plus", size: 12, weight: .medium)
        plus.contentTintColor = Theme.secondaryText
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.secondaryText
        more.toolTip = "More"
        for v in [plus, label, more] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        plus.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 32, y: (h - 17) / 2, width: bounds.width - 64, height: 17)
        more.frame = NSRect(x: bounds.width - 26, y: (h - 20) / 2, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {}

    @objc private func moreClicked() { onMore?(more) }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
