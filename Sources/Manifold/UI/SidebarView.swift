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
    /// Over the sidebar the pointer is the arrow, whatever is beneath it
    /// when it floats out.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    weak var delegate: SidebarDelegate?
    /// Clear over the window's wash when pinned, as Kero's is; a pale sheet when floating over the cards.
    private let card = NSView()
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
    /// Two quiet rows above the bar (§4): what's kept off the desk, and
    /// what's closed and not yet collected; each opens its list in place
    /// of the tree, and again puts the tree back.
    private let keptRow = FootRowView(title: "Kept", symbol: "pin")
    private let closedRow = FootRowView(title: "Recently Closed", symbol: "clock.arrow.circlepath")
    static let footRowHeight: CGFloat = 22
    private var filterShown = false

    static let headerHeight: CGFloat = 40
    static let filterHeight: CGFloat = 30
    static let barHeight: CGFloat = 34
    /// A list pushed over the tree (Kept, Recently Closed): the header
    /// grows to a back button, the list's name and what it holds.
    static let pushedHeight: CGFloat = 36
    private let backButton = IconButton(symbol: "chevron.left", size: 12, weight: .semibold, target: nil, action: nil)
    private let pushedTitle = NSTextField(labelWithString: "")
    private let pushedSubtitle = NSTextField(labelWithString: "")
    private var pushed: Bool { organization == .kept || organization == .closed || organization == .search }

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

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
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
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.toolTip = "Back to Workspaces"
        backButton.wantsLayer = true
        backButton.layer?.cornerRadius = 12
        backButton.themed { $0.layer?.backgroundColor = Theme.hover.cgColor }
        pushedTitle.font = .systemFont(ofSize: 15, weight: .bold)
        pushedTitle.textColor = Theme.text
        pushedTitle.lineBreakMode = .byTruncatingTail
        pushedSubtitle.font = .systemFont(ofSize: 11.5)
        pushedSubtitle.textColor = Theme.secondaryText
        for v in [backButton, pushedTitle, pushedSubtitle] { v.isHidden = true; card.addSubview(v) }

        searchButton.target = self
        searchButton.action = #selector(toggleFilter)
        searchButton.toolTip = "Search every block (⌥⌘4)"
        byButton.target = self
        byButton.action = #selector(toggleBy)
        inboxButton.target = self
        inboxButton.action = #selector(inboxClicked)
        inboxButton.toolTip = "Inbox (⌥⌘6)"
        counts.onClick = { [weak self] in self?.chooseOrganization(.inbox) }
        for v in [searchButton, byButton, inboxButton, counts, keptRow, closedRow] { card.addSubview(v) }
        keptRow.onClick = { [weak self] in self?.chooseOrganization(self?.organization == .kept ? .desk : .kept) }
        closedRow.onClick = { [weak self] in self?.chooseOrganization(self?.organization == .closed ? .desk : .closed) }
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
        backButton.isHidden = !pushed
        pushedTitle.isHidden = !pushed
        pushedSubtitle.isHidden = !pushed
        if pushed {
            // The back button and the list's name, under the header's buttons.
            backButton.frame = NSRect(x: 12, y: top - Self.pushedHeight + 6, width: 24, height: 24)
            pushedTitle.frame = NSRect(x: 44, y: top - Self.pushedHeight + 17, width: bounds.width - 56, height: 18)
            pushedSubtitle.frame = NSRect(x: 44, y: top - Self.pushedHeight + 2, width: bounds.width - 56, height: 14)
            top -= Self.pushedHeight + 6
        }
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
        var bottom = Self.barHeight
        for row in [closedRow, keptRow] where !row.isHidden && !pushed {
            row.frame = NSRect(x: 4, y: bottom, width: bounds.width - 8, height: Self.footRowHeight)
            bottom += Self.footRowHeight
        }
        if !pushed, !keptRow.isHidden || !closedRow.isHidden { bottom += 6 }
        for row in [closedRow, keptRow] where pushed { row.frame = .zero }
        organizationView.frame = NSRect(x: 4, y: bottom, width: bounds.width - 8, height: max(0, top - bottom))
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
        keptRow.current = org == .kept
        closedRow.current = org == .closed
        pushedTitle.stringValue = org.title
        searchButton.contentTintColor = org == .search ? Theme.text : Theme.secondaryText
        // Search is its own place (pushed, as Kept is): the field under its
        // name, taking the keyboard; left, the field goes, emptied.
        let searching = org == .search
        if searching != filterShown {
            filterShown = searching
            filter.isHidden = !searching
            if !searching { filter.stringValue = "" }
        }
        filter.placeholderString = "Search every block"
        if searching { DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.filter) } }
        needsLayout = true
    }

    /// What a pushed list says under its name (Search: how much was found).
    func setPushedSubtitle(_ text: String) {
        guard organization == .search else { return }
        pushedSubtitle.stringValue = text
    }

    @objc private func backClicked() { chooseOrganization(.desk) }

    /// How many are kept off the desk, and closed awaiting collection:
    /// the foot rows, each hidden at zero.
    func setFoot(kept: Int, closed: Int) {
        keptRow.count = kept
        closedRow.count = closed
        keptRow.isHidden = kept == 0 && organization != .kept
        closedRow.isHidden = closed == 0 && organization != .closed
        guard organization == .kept || organization == .closed else { return needsLayout = true }
        let n = organization == .kept ? kept : closed
        pushedSubtitle.stringValue = organization == .kept
            ? (n == 1 ? "1 kept off the desk" : "\(n) kept off the desk")
            : (n == 1 ? "1 closed, awaiting collection" : "\(n) closed, awaiting collection")
        needsLayout = true
    }

    /// What's doing something, for the bar's counts (§3.7).
    func setCounts(needsYou: Int, working: Int, done: Int) {
        counts.set(needsYou: needsYou, working: working, done: done)
        needsLayout = true
    }

    var filterText: String { filter.isHidden ? "" : filter.stringValue }

    /// Debugging: as if typed into the field; and whether it has the keyboard.
    func debugTypeFilter(_ text: String) -> String {
        filter.stringValue = text
        filterTyped()
        return window?.firstResponder === filter.currentEditor() ? "typed (field has the keyboard)" : "typed"
    }

    private func chooseOrganization(_ org: Organization) {
        setOrganization(org)
        delegate?.sidebarOrganizationChanged(org)
    }

    @objc private func toggleBy() { chooseOrganization(organization == .desk ? .files : .desk) }
    @objc private func inboxClicked() { chooseOrganization(organization == .inbox ? .desk : .inbox) }

    /// The filter field shown (and taking the keyboard), or put away.
    /// The search button: Search, pushed over the tree; again, back.
    @objc func toggleFilter() {
        if organization == .search {
            chooseOrganization(.desk)
            delegate?.sidebarFilterChanged("")
        } else {
            chooseOrganization(.search)
        }
    }

    @objc private func filterTyped() { delegate?.sidebarFilterChanged(filter.stringValue) }

    private func updateChrome() {
        layer?.shadowOpacity = pinned ? 0 : 0.16
        card.themed { [weak self] v in
            guard let self else { return }
            v.layer?.backgroundColor = self.pinned ? NSColor.clear.cgColor : Theme.panel.withAlphaComponent(0.94).cgColor
            v.layer?.borderWidth = self.pinned ? 0 : 0.5
            v.layer?.borderColor = Theme.cardBorder.cgColor
        }
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
extension NSMenuItem {
    /// A symbol before the title. macOS 27 hides a menu item's symbol
    /// image unless the item asks for it: `preferredImageVisibility`, not
    /// in the SDK we build with (1 is visible; 0, the default, hides it).
    func setSymbol(_ name: String, size: CGFloat) {
        image = Theme.symbol(name, size: size)
        if responds(to: Selector(("setPreferredImageVisibility:"))) { setValue(1, forKey: "preferredImageVisibility") }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if let symbol { setSymbol(symbol, size: 12) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    /// Debugging: as choosing the item.
    func debugRun() { handler() }
}

/// A row at the sidebar's foot: a symbol, a name, a count at the right;
/// clicked, its list.
final class FootRowView: NSView {
    var onClick: (() -> Void)?
    var count = 0 { didSet { countLabel.stringValue = count == 0 ? "" : "\(count)"; countLabel.isHidden = count == 0; needsLayout = true } }
    var current = false { didSet { label.textColor = current ? Theme.text : Theme.secondaryText; icon.contentTintColor = label.textColor } }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// The count in the same capsule as the tree's, its right edge on
    /// theirs (the row sits in the sidebar as the tree's rows do, less
    /// the room the tree keeps at its right).
    private let countLabel = CountPill()
    static let countRightInset: CGFloat = 18
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        icon.image = Theme.symbol(symbol, size: 11)
        icon.contentTintColor = Theme.secondaryText
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.secondaryText
        for v in [icon, label, countLabel] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 12) / 2, width: 14, height: 12)
        let cw = countLabel.wantedWidth
        countLabel.frame = NSRect(x: bounds.width - Self.countRightInset - cw, y: ((h - CountPill.height) / 2).rounded(), width: cw, height: CountPill.height)
        label.frame = NSRect(x: 32, y: (h - 16) / 2, width: max(0, countLabel.frame.minX - 40), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}

/// The bar's counts of what's doing something (§3.7): needs you, working,
/// done and not yet read — each its glyph and a number, hidden at zero;
/// clicked, Status.
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
        values.enumerated().reduce(0) { w, e in e.element == 0 ? w : w + StatusGlyph.size + 5 + ceil(labels[e.offset].intrinsicContentSize.width) + 14 }
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
            x += StatusGlyph.size + 5
            let lw = ceil(labels[i].intrinsicContentSize.width)
            labels[i].frame = NSRect(x: x, y: (h - 15) / 2, width: lw, height: 15)
            x += lw + 14
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
