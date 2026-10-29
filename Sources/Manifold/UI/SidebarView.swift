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
    /// The bar's filter button, or the counts: narrowed to a filter, or
    /// not (nil).
    func sidebarFilter(_ filter: SidebarFilter?)
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
    // Set here, not passed on: under the title bar, a cursor update passed
    // on went to the title bar, which gave it back to the view under the
    // pointer, round until the stack ran out.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    weak var delegate: SidebarDelegate?
    /// Clear over the window's wash when pinned, as Kero's is; a pale sheet when floating over the cards.
    private let card = NSView()
    private let pinButton: IconButton
    private let newButton: IconButton
    private let moreButton: IconButton
    private let header = WindowDragView()
    private let resizeHandle = ResizeHandleView()
    var pinned = false { didSet { updateChrome() } }
    /// The tree; the bar at the bottom: by workspace or by file, the
    /// filter (⌘.), and the counts of what's doing something, which turn
    /// the filter on.
    let organizationView = OrganizationView()
    private(set) var organization: Organization = .desk
    private let byButton: IconButton
    private let filterButton: IconButton
    /// What the tree is narrowed to, if anything.
    private(set) var filter: SidebarFilter?
    private let counts = StatusCountsView()
    /// A quiet row above the bar (§4): what's closed and not yet
    /// collected; it opens its list in place of the tree, and again puts
    /// the tree back.
    private let closedRow = FootRowView(title: "Recently Closed", symbol: "clock.arrow.circlepath")
    /// Copies on their way (§8), above those rows.
    let transfers = TransfersView()
    static let footRowHeight: CGFloat = 22

    static let headerHeight: CGFloat = 40
    static let filterHeight: CGFloat = 34
    static let barHeight: CGFloat = 34
    /// A list pushed over the tree (Recently Closed, Search): the header
    /// grows to a back button, the list's name and what it holds.
    static let pushedHeight: CGFloat = 36
    private let backButton = IconButton(symbol: "chevron.left", size: 12, weight: .semibold, target: nil, action: nil)
    private let pushedTitle = NSTextField(labelWithString: "")
    private let pushedSubtitle = NSTextField(labelWithString: "")
    private var pushed: Bool { organization == .closed || organization == .inspector }

    override init(frame: NSRect) {
        pinButton = IconButton(symbol: "sidebar.left", size: 13, weight: .regular, target: nil, action: nil)
        newButton = IconButton(symbol: "plus", size: 13, weight: .medium, target: nil, action: nil)
        moreButton = IconButton(symbol: "ellipsis", size: 13, weight: .medium, target: nil, action: nil)
        byButton = IconButton(symbol: Organization.desk.symbol, size: 13, weight: .medium, target: nil, action: nil)
        filterButton = IconButton(symbol: "circle", size: 13, weight: .medium, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        if let layer { Elevation.float.apply(to: layer) }

        card.wantsLayer = true
        card.layer?.cornerRadius = Radius.surface
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        addSubview(card)

        card.addSubview(header)
        pinButton.target = self
        pinButton.action = #selector(togglePinned)
        pinButton.toolTip = "Keep Sidebar Shown (⌃⌘S)"
        card.addSubview(pinButton)
        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.toolTip = "New Space (⌥⌘T)"
        card.addSubview(newButton)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        card.addSubview(moreButton)
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.toolTip = "Back to Spaces"
        pushedTitle.font = .systemFont(ofSize: 15, weight: .bold)
        pushedTitle.textColor = Theme.text
        pushedTitle.lineBreakMode = .byTruncatingTail
        pushedSubtitle.font = UIType.detail
        pushedSubtitle.textColor = Theme.secondaryText
        for v in [backButton, pushedTitle, pushedSubtitle] { v.isHidden = true; card.addSubview(v) }

        byButton.target = self
        byButton.action = #selector(toggleBy)
        filterButton.target = self
        filterButton.action = #selector(filterClicked)
        counts.onClick = { [weak self] in self?.delegate?.sidebarFilter(.status) }
        for v in [byButton, filterButton, counts, closedRow, transfers] { card.addSubview(v) }
        setFilter(nil)
        closedRow.onClick = { [weak self] in self?.chooseOrganization(self?.organization == .closed ? .desk : .closed) }
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
        // The shadow's shape given, not found from what's drawn (offscreen,
        // every frame it slides).
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
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
        // The bar along the bottom: its buttons at the left, the counts at the right.
        let by: CGFloat = (Self.barHeight - 20) / 2
        var x: CGFloat = 12
        for b in [byButton, filterButton] {
            b.frame = NSRect(x: x, y: by, width: 20, height: 20)
            x += 28
        }
        let cw = counts.wantedWidth
        counts.frame = NSRect(x: bounds.width - 12 - cw, y: 0, width: cw, height: Self.barHeight)
        var bottom = Self.barHeight
        let th = transfers.wantedHeight
        transfers.frame = NSRect(x: 4, y: bottom, width: bounds.width - 8, height: th)
        // Their own place under the tree, a little apart from it.
        bottom += th > 0 ? th + 6 : 0
        if !closedRow.isHidden, !pushed {
            closedRow.frame = NSRect(x: 4, y: bottom, width: bounds.width - 8, height: Self.footRowHeight)
            bottom += Self.footRowHeight + 6
        } else {
            closedRow.frame = .zero
        }
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
        byButton.toolTip = org == .files ? "Spaces (⌥⌘1)" : "Files (⌥⌘2)"
        byButton.contentTintColor = org == .desk || org == .files ? Theme.text : Theme.secondaryText
        closedRow.current = org == .closed
        pushedTitle.stringValue = org.title
        needsLayout = true
    }

    @objc private func backClicked() { chooseOrganization(.desk) }

    /// The Inspector's header: the block's name, and what and where it is.
    func setInspected(title: String, subtitle: String) {
        guard organization == .inspector else { return }
        pushedTitle.stringValue = title
        pushedSubtitle.stringValue = subtitle
    }

    /// How many are closed awaiting collection: the foot row, hidden at zero.
    func setFoot(closed n: Int) {
        closedRow.count = n
        closedRow.isHidden = n == 0 && organization != .closed
        guard organization == .closed else { return needsLayout = true }
        pushedSubtitle.stringValue = n == 1 ? "1 closed, awaiting collection" : "\(n) closed, awaiting collection"
        needsLayout = true
    }

    /// What's doing something, for the bar's counts (§3.7).
    func setCounts(needsYou: Int, working: Int, done: Int) {
        counts.set(needsYou: needsYou, working: working, done: done)
        needsLayout = true
    }


    private func chooseOrganization(_ org: Organization) {
        setOrganization(org)
        delegate?.sidebarOrganizationChanged(org)
    }

    @objc private func toggleBy() { chooseOrganization(organization == .desk ? .files : .desk) }
    @objc private func filterClicked() { delegate?.sidebarFilter(filter == nil ? .status : nil) }

    /// Shows the filter on (its button filled, in the accent) or off.
    func setFilter(_ f: SidebarFilter?) {
        filter = f
        let shown = f ?? .status
        filterButton.image = shown.image(on: f != nil)
        filterButton.contentTintColor = f == nil ? Theme.secondaryText : Theme.accent
        filterButton.toolTip = f == nil ? "Show Only \(shown.title) (⌘.)" : "Showing Only \(shown.title) — Show All (⌘.)"
    }



    /// The card's ground, as pinned or not, in the appearance shown —
    /// themed once (each `themed` call adds a hook kept for good), then
    /// set again as the pin changes.
    private var chromeThemed = false
    private func applyCard(_ v: NSView) {
        v.layer?.backgroundColor = pinned ? NSColor.clear.cgColor : Theme.panel.withAlphaComponent(0.94).cgColor
        v.layer?.borderWidth = pinned ? 0 : 0.5
        v.layer?.borderColor = Theme.cardBorder.cgColor
    }

    private func updateChrome() {
        layer?.shadowOpacity = pinned ? 0 : Float(Elevation.floatOpacity)
        if chromeThemed {
            card.effectiveAppearance.performAsCurrentDrawingAppearance { applyCard(card) }
        } else {
            chromeThemed = true
            card.themed { [weak self] v in self?.applyCard(v) }
        }
        pinButton.contentTintColor = pinned ? Theme.text : Theme.secondaryText
        pinButton.toolTip = pinned ? "Let Sidebar Slide Out (⌃⌘S)" : "Keep Sidebar Shown (⌃⌘S)"
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
        pill.layer?.cornerRadius = Radius.hair
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
            ctx.duration = Motion.fast
            pill.animator().alphaValue = hovering || dragging ? 1 : 0
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

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

    /// As choosing the item (a row that offers it, the Inspector's).
    func perform() { handler() }

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
        label.font = UIType.label
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
        Flat.rowBand(bounds).fill()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}

/// The bar's counts of what's doing something (§3.7): needs you, working,
/// done and not yet read — each its glyph and a number, hidden at zero;
/// clicked, the sidebar narrowed to blocks with a status.
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
        toolTip = "Show Only Blocks with a Status (⌘.)"
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
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}

/// The filter's mark (§3.6): a lighthouse — there being none among the
/// system's symbols — drawn as a template at a symbol's size, in its
/// weight: its tower, lamp room and roof; on, filled, its light shining
/// both ways.
enum Lighthouse {
    private static var made: [Bool: NSImage] = [:]

    static func image(on: Bool) -> NSImage {
        if let i = made[on] { return i }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let line: CGFloat = 1.3
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: 5.4, y: 12.0)); roof.line(to: NSPoint(x: 8, y: 14.9)); roof.line(to: NSPoint(x: 10.6, y: 12.0)); roof.close()
            roof.fill()
            // The gallery under the lamp room.
            NSBezierPath(roundedRect: NSRect(x: 4.6, y: 8.7, width: 6.8, height: 1.3), xRadius: 0.4, yRadius: 0.4).fill()
            let lamp = NSRect(x: 6.3, y: 10.0, width: 3.4, height: 2.0)
            if on {
                NSBezierPath(rect: lamp).fill()
            } else {
                let p = NSBezierPath(rect: lamp.insetBy(dx: 0.45, dy: -0.2))
                p.lineWidth = 0.9
                p.stroke()
            }
            // The tower, narrowing up to the gallery, on its base.
            let tower = NSBezierPath()
            tower.move(to: NSPoint(x: 4.7, y: 1.6)); tower.line(to: NSPoint(x: 11.3, y: 1.6))
            tower.line(to: NSPoint(x: 10.1, y: 8.7)); tower.line(to: NSPoint(x: 5.9, y: 8.7)); tower.close()
            tower.lineJoinStyle = .round
            if on {
                tower.fill()
            } else {
                tower.lineWidth = line
                tower.stroke()
                let band = NSBezierPath()
                band.move(to: NSPoint(x: 5.3, y: 5.0)); band.line(to: NSPoint(x: 10.7, y: 5.0))
                band.lineWidth = line
                band.stroke()
            }
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 2.8, y: 1.0)); base.line(to: NSPoint(x: 13.2, y: 1.0))
            base.lineWidth = line
            base.lineCapStyle = .round
            base.stroke()
            if on {
                for (a, b) in [(NSPoint(x: 4.6, y: 11.5), NSPoint(x: 1.4, y: 12.6)), (NSPoint(x: 11.4, y: 11.5), NSPoint(x: 14.6, y: 12.6)),
                               (NSPoint(x: 4.6, y: 10.5), NSPoint(x: 1.8, y: 9.7)), (NSPoint(x: 11.4, y: 10.5), NSPoint(x: 14.2, y: 9.7))] {
                    let ray = NSBezierPath()
                    ray.move(to: a); ray.line(to: b)
                    ray.lineWidth = 0.95
                    ray.lineCapStyle = .round
                    ray.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        made[on] = image
        return image
    }
}
