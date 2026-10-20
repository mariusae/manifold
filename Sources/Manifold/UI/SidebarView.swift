import AppKit
import ManifoldCore

protocol SidebarDelegate: AnyObject {
    /// Takes an arrangement off the desk (it stays, to be found again).
    func sidebarRemove(_ arrangement: BlockID)
    func sidebarRename(_ arrangement: BlockID)
    func sidebarMove(_ arrangement: BlockID, to index: Int)
    func sidebarNewTab()
    func sidebarTogglePinned()
    func sidebarMoreMenu() -> NSMenu
    func sidebarDragChanged(_ dragging: Bool)
    /// The resize handle was dragged to make the sidebar this wide.
    func sidebarResize(to width: CGFloat)
    func sidebarResizeEnded()
    /// Another organization was chosen, or the filter typed in.
    func sidebarOrganizationChanged(_ organization: Organization)
    func sidebarFilterChanged(_ text: String)
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The spine of the window (DESIGN.md §3.6): one browser over the graph,
/// organized four ways, beside the surface (or sliding out over it when
/// not pinned). Its top row carries the window buttons, New, and ⋯.
final class SidebarView: NSView {
    weak var delegate: SidebarDelegate?
    private let card = NSVisualEffectView()
    private let pinButton: IconButton
    private let newButton: IconButton
    private let moreButton: IconButton
    private let header = WindowDragView()
    private let resizeHandle = ResizeHandleView()
    var pinned = false { didSet { updateChrome() } }
    /// The tree; the filter over it, shown by the bar's search; the bar
    /// at the bottom: search, by workspace or by file, the inbox, and the
    /// counts of what's doing something, which go to Status.
    private let filter = NSSearchField()
    let organizationView = OrganizationView()
    private(set) var organization: Organization = .desk
    private let searchButton: IconButton
    private let byButton: IconButton
    private let inboxButton: IconButton
    private let counts = StatusCountsView()
    private var filterShown = false

    static let headerHeight: CGFloat = 40
    static let filterHeight: CGFloat = 30
    static let barHeight: CGFloat = 34

    override init(frame: NSRect) {
        pinButton = IconButton(symbol: "sidebar.left", size: 13, weight: .regular, target: nil, action: nil)
        newButton = IconButton(symbol: "plus", size: 13, weight: .medium, target: nil, action: nil)
        moreButton = IconButton(symbol: "ellipsis", size: 13, weight: .medium, target: nil, action: nil)
        searchButton = IconButton(symbol: "magnifyingglass", size: 13, weight: .medium, target: nil, action: nil)
        byButton = IconButton(symbol: Organization.desk.symbol, size: 13, weight: .medium, target: nil, action: nil)
        inboxButton = IconButton(symbol: Organization.inbox.symbol, size: 13, weight: .medium, target: nil, action: nil)
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
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.toolTip = "New… (⌘T)"
        card.addSubview(newButton)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        card.addSubview(moreButton)

        searchButton.target = self
        searchButton.action = #selector(toggleFilter)
        searchButton.toolTip = "Filter"
        byButton.target = self
        byButton.action = #selector(toggleBy)
        inboxButton.target = self
        inboxButton.action = #selector(inboxClicked)
        inboxButton.toolTip = "Inbox (⌥⌘6)"
        counts.onClick = { [weak self] in self?.chooseOrganization(.status) }
        for v in [searchButton, byButton, inboxButton, counts] { card.addSubview(v) }
        filter.isHidden = true
        filter.placeholderString = "Filter"
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: 11.5)
        filter.focusRingType = .none
        filter.target = self
        filter.action = #selector(filterTyped)
        filter.sendsSearchStringImmediately = true
        filter.sendsWholeSearchString = false
        card.addSubview(filter)
        card.addSubview(organizationView)

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
        moreButton.frame = NSRect(x: bounds.width - 54, y: bounds.height - 30, width: 20, height: 20)
        newButton.frame = NSRect(x: bounds.width - 78, y: bounds.height - 30, width: 20, height: 20)
        var top = bounds.height - Self.headerHeight
        if filterShown {
            filter.frame = NSRect(x: 10, y: top - Self.filterHeight + 5, width: bounds.width - 20, height: 22)
            top -= Self.filterHeight
        }
        // The bar along the bottom: its buttons at the left, the counts at the right.
        let by: CGFloat = (Self.barHeight - 20) / 2
        var x: CGFloat = 12
        for b in [searchButton, byButton, inboxButton] {
            b.frame = NSRect(x: x, y: by, width: 20, height: 20)
            x += 28
        }
        let cw = counts.wantedWidth
        counts.frame = NSRect(x: bounds.width - 12 - cw, y: 0, width: cw, height: Self.barHeight)
        organizationView.frame = NSRect(x: 4, y: Self.barHeight, width: bounds.width - 8, height: max(0, top - Self.barHeight))
        resizeHandle.frame = NSRect(x: bounds.width - 7, y: 0, width: 7, height: bounds.height - Self.headerHeight)
    }

    /// Shows an organization's tree.
    func setOrganization(_ org: Organization) {
        organization = org
        // The by-button shows which of workspaces and files is on (the
        // other a click away); the inbox its own.
        let by: Organization = org == .files ? .files : .desk
        byButton.image = Theme.symbol(by.symbol, size: 13, weight: .medium)
        byButton.toolTip = org == .files ? "By Workspace (⌥⌘1)" : "By File (⌥⌘2)"
        byButton.contentTintColor = org == .desk || org == .files ? Theme.text : Theme.secondaryText
        inboxButton.contentTintColor = org == .inbox ? Theme.text : Theme.secondaryText
        counts.emphasized = org == .status
        needsLayout = true
    }

    /// What's doing something, for the bar's counts (§3.7).
    func setCounts(needsYou: Int, working: Int, done: Int) {
        counts.set(needsYou: needsYou, working: working, done: done)
        needsLayout = true
    }

    var filterText: String { filter.isHidden ? "" : filter.stringValue }

    private func chooseOrganization(_ org: Organization) {
        setOrganization(org)
        delegate?.sidebarOrganizationChanged(org)
    }

    @objc private func toggleBy() { chooseOrganization(organization == .desk ? .files : .desk) }
    @objc private func inboxClicked() { chooseOrganization(organization == .inbox ? .desk : .inbox) }

    /// The filter field shown (and taking the keyboard), or put away.
    @objc func toggleFilter() {
        filterShown.toggle()
        filter.isHidden = !filterShown
        searchButton.contentTintColor = filterShown ? Theme.text : Theme.secondaryText
        needsLayout = true
        if filterShown {
            window?.makeFirstResponder(filter)
        } else {
            filter.stringValue = ""
            delegate?.sidebarFilterChanged("")
        }
    }

    @objc private func filterTyped() { delegate?.sidebarFilterChanged(filter.stringValue) }

    private func updateChrome() {
        layer?.shadowOpacity = pinned ? 0 : 0.16
        pinButton.contentTintColor = pinned ? Theme.text : Theme.secondaryText
        pinButton.toolTip = pinned ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)"
    }

    @objc private func togglePinned() { delegate?.sidebarTogglePinned() }
    @objc private func newClicked() { delegate?.sidebarNewTab() }

    @objc private func moreClicked() {
        guard let menu = delegate?.sidebarMoreMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
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

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if let symbol { image = Theme.symbol(symbol, size: 12) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    /// Debugging: as choosing the item.
    func debugRun() { handler() }
}

/// The bar's counts of what's doing something (§3.7): needs you, working,
/// done — each its glyph and a number, hidden at zero; clicked, Status.
final class StatusCountsView: NSView {
    var onClick: (() -> Void)?
    var emphasized = false { didSet { for l in labels { l.textColor = emphasized ? Theme.text : Theme.secondaryText } } }
    private let glyphs = [StatusGlyph(), StatusGlyph(), StatusGlyph()]
    private let labels = (0..<3).map { _ in NSTextField(labelWithString: "") }
    private var values = [0, 0, 0]

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (g, look) in zip(glyphs, [StatusGlyph.Look.needsYou, .working(progress: nil), .done(read: false)]) {
            g.look = look
            addSubview(g)
        }
        for l in labels {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            l.textColor = Theme.secondaryText
            addSubview(l)
        }
        toolTip = "Status (⌥⌘5)"
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(needsYou: Int, working: Int, done: Int) {
        values = [needsYou, working, done]
        for (l, v) in zip(labels, values) { l.stringValue = "\(v)" }
        needsLayout = true
    }

    var wantedWidth: CGFloat {
        values.enumerated().reduce(0) { w, e in e.element == 0 ? w : w + StatusGlyph.size + 3 + ceil(labels[e.offset].intrinsicContentSize.width) + 10 }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let h = bounds.height
        for i in 0..<3 {
            let shown = values[i] > 0
            glyphs[i].isHidden = !shown
            labels[i].isHidden = !shown
            guard shown else { continue }
            glyphs[i].frame = NSRect(x: x, y: (h - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
            x += StatusGlyph.size + 3
            let lw = ceil(labels[i].intrinsicContentSize.width)
            labels[i].frame = NSRect(x: x, y: (h - 15) / 2, width: lw, height: 15)
            x += lw + 10
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
