import AppKit
import ManifoldCore

/// What the sidebar asks of its window.
protocol SidebarDelegate: AnyObject {
    func sidebarTogglePinned()
    /// The resize handle was dragged to make the sidebar this wide.
    func sidebarResize(to width: CGFloat)
    func sidebarResizeEnded()
    /// Another organization was chosen.
    func sidebarOrganizationChanged(_ organization: Organization)
    /// Threads' filter: which (all, open, unread) and where (the space,
    /// its project), as a menu.
    func sidebarThreadsFilterMenu() -> NSMenu
    /// Every thread shown, read.
    func sidebarMarkThreadsRead()
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
    private let header = WindowDragView()
    private let resizeHandle = ResizeHandleView()
    var pinned = false { didSet { updateChrome() } }
    /// The tree; the tabs at the top: what it lists — spaces, files or
    /// threads, an icon each.
    let organizationView = OrganizationView()
    private(set) var organization: Organization = .desk
    private let tabs: [SidebarTab] = [.desk, .files, .threads].map { SidebarTab($0) }
    /// The space's threads (§3.12): the timeline, in place of the tree; at
    /// the right of their header, the filter (which, and where) and Mark
    /// All Read.
    let timeline = ThreadTimelineView()
    private let threadsFilter = IconButton("line.3.horizontal.decrease.circle", size: 13, weight: .medium, tip: "Filter Threads")
    private let threadsRead = IconButton("checkmark.circle", size: 13, weight: .medium)
    /// The timeline's buttons in the header.
    private var threadsControls: [NSView] { [threadsFilter, threadsRead] }
    /// The threads' filter narrows them (not all, or not only the space's): its button filled, in the accent.
    func setThreadsFilter(narrowed: Bool, unseen: Int) {
        threadsFilter.image = Theme.symbol(narrowed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", size: 13, weight: .medium)
        threadsFilter.contentTintColor = narrowed ? Theme.accent : Theme.secondaryText
        threadsRead.isEnabled = unseen > 0
        threadsRead.toolTip = unseen > 0 ? "Mark All Read (\(unseen))" : "All Read"
    }
    /// Every space (§3.6), a square each, above the bar: the sidebar shows
    /// one at a time, and these are the rest.
    let spaces = SpaceStripView()
    /// What needs you, in every space, over the strip: always there.
    let needsYou = NeedsYouView()
    /// The hosts to make a space on, over the strip's +.
    let hostPicker = HostPickerView()
    /// Threads and the tiles' menu, always at the very bottom.
    let footer = SidebarFooter()
    /// Copies on their way (§8), above those rows.
    let transfers = TransfersView()
    /// Toasts (§4), while it's out: above the copies, as many as are up.
    let toasts = ToastStackView()

    static let headerHeight: CGFloat = 40
    /// Where everything down the sidebar starts: the space's name, the
    /// rows' icons and their sections' names, what needs you, the strip.
    static let margin: CGFloat = 20
    /// A list pushed over the tree (Recently Closed, Search): the header
    /// grows to a back button, the list's name and what it holds.
    static let pushedHeight: CGFloat = 36
    private let backButton = IconButton("chevron.left", size: 12, tip: "Back to Spaces")
    private let pushedTitle = NSTextField(labelWithString: "")
    private let pushedSubtitle = NSTextField.label(font: UIType.detail, color: Theme.secondaryText)
    /// Under a space's name: the host it's on, a remote's ping times by it.
    let spaceHost = SpaceHostLine()
    private var pushed: Bool { organization == .closed }
    /// A header of its own under the window's buttons: a pushed list's, the
    /// space's (its name, over its tiles), or the threads'.
    private var titled: Bool { pushed || organization == .threads || organization == .desk }

    override init(frame: NSRect) {
        pinButton = IconButton("sidebar.left", size: 13, weight: .regular, tip: "Keep Sidebar Shown (⇧⌘/)")
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
        card.addSubview(pinButton)
        backButton.target = self
        backButton.action = #selector(backClicked)
        pushedTitle.font = .systemFont(ofSize: 15, weight: .bold)
        pushedTitle.textColor = Theme.text
        pushedTitle.lineBreakMode = .byTruncatingTail
        for v in [backButton, pushedTitle, pushedSubtitle, spaceHost] { v.isHidden = true; card.addSubview(v) }

        for t in tabs {
            t.onClick = { [weak self, weak t] in
                guard let self, let t else { return }
                self.chooseOrganization(t.organization)
            }
            card.addSubview(t)
        }
        for v in [spaces, needsYou, transfers, toasts, footer] { card.addSubview(v) }
        hostPicker.isHidden = true
        toasts.onChange = { [weak self] in self?.needsLayout = true }
        threadsFilter.target = self
        threadsFilter.action = #selector(threadsFilterClicked)
        threadsRead.target = self
        threadsRead.action = #selector(threadsReadClicked)
        setThreadsFilter(narrowed: false, unseen: 0)
        timeline.compact = true
        timeline.isHidden = true
        for v in threadsControls + [timeline] { v.isHidden = true; card.addSubview(v) }
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
        // What it lists, an icon each, along the top beside the pin.
        var tx = pinButton.frame.minX - 6 - CGFloat(tabs.count) * (SidebarTab.size + 2) + 2
        for t in tabs {
            t.frame = NSRect(x: tx, y: pinButton.frame.midY - SidebarTab.size / 2, width: SidebarTab.size, height: SidebarTab.size)
            tx += SidebarTab.size + 2
        }
        var top = bounds.height - Self.headerHeight
        // The spaces at the top, under the window's buttons, as Dia's
        // favourites: whichever list shows under them.
        let sh = spaces.wantedHeight(width: bounds.width)
        spaces.frame = NSRect(x: 0, y: top - sh, width: bounds.width, height: sh)
        // Some room between them and the space's name.
        top -= sh + 12
        backButton.isHidden = !pushed
        pushedTitle.isHidden = !titled
        pushedSubtitle.isHidden = !titled || organization == .desk
        spaceHost.isHidden = !titled || organization != .desk
        for v in threadsControls { v.isHidden = organization != .threads }
        if titled {
            // The back button (a list pushed over the tree) and the list's
            // name, under the header's buttons; the threads' own buttons
            // at its right.
            backButton.frame = NSRect(x: 12, y: top - Self.pushedHeight + 6, width: 24, height: 24)
            var right = bounds.width - 10
            if organization == .threads {
                for b in threadsControls.reversed() {
                    right -= 22
                    b.frame = NSRect(x: right, y: top - Self.pushedHeight + 8, width: 22, height: 22)
                    right -= 2
                }
                right -= 6
            }
            // The sidebar's one margin (its rows' icons'), past a back button.
            let left: CGFloat = pushed ? 44 : Self.margin
            if organization == .desk {
                // A space's name and its host, the same size, apart: the
                // name strong, the host quiet.
                pushedTitle.font = .systemFont(ofSize: 13, weight: .semibold)
                pushedTitle.frame = NSRect(x: left, y: top - 20, width: max(0, right - left), height: 18)
                spaceHost.frame = NSRect(x: left, y: top - 42, width: max(0, right - left), height: 18)
                top -= 48
            } else {
                pushedTitle.font = .systemFont(ofSize: 15, weight: .bold)
                pushedTitle.frame = NSRect(x: left, y: top - Self.pushedHeight + 17, width: max(0, right - left), height: 18)
                pushedSubtitle.frame = NSRect(x: left, y: top - Self.pushedHeight + 2, width: max(0, right - left), height: 14)
                top -= Self.pushedHeight + 6
            }
        }
        // The footer along the very bottom; over it what needs you, the
        // transfers and the toasts, each only when there's something.
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: SidebarFooter.height)
        var bottom = SidebarFooter.height
        let nh = needsYou.wantedHeight
        needsYou.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: nh)
        needsYou.isHidden = nh == 0
        bottom += nh > 0 ? nh + 4 : 0
        let th = transfers.wantedHeight
        transfers.frame = NSRect(x: 4, y: bottom, width: bounds.width - 8, height: th)
        // Their own place under the tree, a little apart from it.
        bottom += th > 0 ? th + 6 : 0
        toasts.frame.size.width = bounds.width - 16
        let toastH = toasts.wantedHeight
        toasts.frame = NSRect(x: 8, y: bottom, width: bounds.width - 16, height: toastH)
        bottom += toastH > 0 ? toastH + 8 : 0
        let timelineShown = organization == .threads
        timeline.isHidden = !timelineShown
        organizationView.isHidden = timelineShown
        timeline.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: max(0, top - bottom))
        organizationView.frame = NSRect(x: 4, y: bottom, width: bounds.width - 8, height: max(0, top - bottom))
        resizeHandle.frame = NSRect(x: bounds.width - 7, y: 0, width: 7, height: bounds.height - Self.headerHeight)
    }

    /// The hosts' list over the + (`rect`, in the window), on top of all.
    func showHostPicker(_ rows: [HostPickerView.Row], over rect: NSRect) {
        hostPicker.show(rows)
        let r = card.convert(rect, from: nil)
        let h = hostPicker.wantedHeight, w = min(HostPickerView.width, card.bounds.width - 16)
        let x = min(max(8, r.midX - w / 2), card.bounds.width - 8 - w)
        // Under the + (the strip at the top), else over it where there's no room.
        let below = r.minY - 6 - h
        hostPicker.frame = NSRect(x: x.rounded(), y: (below >= 8 ? below : r.maxY + 6).rounded(), width: w, height: h)
        if hostPicker.superview == nil || card.subviews.last !== hostPicker { card.addSubview(hostPicker) }
        hostPicker.isHidden = false
    }

    func hideHostPicker() { hostPicker.isHidden = true }

    /// Shows an organization's tree.
    func setOrganization(_ org: Organization) {
        organization = org
        for t in tabs { t.chosen = t.organization == org }
        pushedTitle.stringValue = org.title
        if org != .threads { pushedSubtitle.stringValue = "" }
        needsLayout = true
    }

    @objc private func backClicked() { chooseOrganization(.desk) }

    /// Another space shown (§3.6): its name and its tiles slide in from
    /// `dir`'s side (1, the right: the next in the strip), as the grid's
    /// do, over a picture of the last sliding out. With less motion, only
    /// changed.
    func slideSpace(_ dir: CGFloat, change: () -> Void) {
        let moving: [NSView] = [organizationView, pushedTitle, pushedSubtitle, spaceHost]
        let region = moving.filter { !$0.isHidden }.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        guard !Motion.reduced, window != nil, !isHiddenOrHasHiddenAncestor, !region.isEmpty, let host = card.layer,
              let rep = card.bitmapImageRepForCachingDisplay(in: region) else { return change() }
        card.cacheDisplay(in: region, to: rep)
        change()
        layoutSubtreeIfNeeded()
        let old = CALayer()
        old.contents = rep.cgImage
        old.frame = region
        old.zPosition = 5
        host.addSublayer(old)
        let shift = bounds.width * 0.5
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
        func move(_ l: CALayer, from: CGFloat, to: CGFloat, fade: (Float, Float)) {
            let t = CABasicAnimation(keyPath: "transform.translation.x")
            t.fromValue = from
            t.toValue = to
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = fade.0
            o.toValue = fade.1
            let g = CAAnimationGroup()
            g.animations = [t, o]
            g.duration = Motion.spatial
            g.timingFunction = Motion.travel
            l.add(g, forKey: "space.slide")
        }
        old.opacity = 0
        move(old, from: 0, to: -dir * shift, fade: (1, 0))
        for v in moving { if let l = v.layer { move(l, from: dir * shift, to: 0, fade: (0, 1)) } }
        CATransaction.commit()
    }

    /// A two-finger swipe across the sidebar, sideways: the next space (-1,
    /// the fingers going left, as Arc's) or the one before — once a swipe.
    var onSwipe: ((Int) -> Void)?
    private var swipeMonitor: Any?
    private var swiped: CGFloat = 0
    private var swipeDone = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = swipeMonitor { NSEvent.removeMonitor(m); swipeMonitor = nil }
        guard window != nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.swipe(e)
            return e
        }
    }

    private func swipe(_ e: NSEvent) {
        guard e.window === window, e.hasPreciseScrollingDeltas, e.momentumPhase == [],
              bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        if e.phase.contains(.began) { swiped = 0; swipeDone = false }
        guard e.phase.contains(.changed) || e.phase.contains(.began) else { return }
        // Sideways, not a scroll up or down that drifts.
        guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5 else { return }
        // As the fingers go, whichever way scrolling is set to go.
        swiped += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        guard !swipeDone, abs(swiped) > 70 else { return }
        swipeDone = true
        onSwipe?(swiped < 0 ? 1 : -1)
    }

    /// The space shown (§3.6): its name over its tiles, and how many.
    func setSpace(title: String, host: String, standing: String?, pings: (() -> Sparkline.Pings)?, remote: Bool = false) {
        guard organization == .desk else { return }
        pushedTitle.stringValue = title
        spaceHost.show(host: host, standing: standing, pings: pings, remote: remote)
    }

    /// How many are closed awaiting collection, under Recently Closed's
    /// title while it's shown (⇧⌘A's menu has them otherwise).
    func setFoot(closed n: Int) {
        guard organization == .closed else { return }
        pushedSubtitle.stringValue = n == 1 ? "1 closed" : "\(n) closed"
        needsLayout = true
    }

    /// The space's threads: how many, how many open, and how many with
    /// something not seen (the count on their tab).
    func setFoot(threads n: Int, open: Int, unseen: Int) {
        tabs.first { $0.organization == .threads }?.count = unseen
        if organization == .threads {
            var words = [open == 1 ? "1 open" : "\(open) open"]
            if n > open { words.append("\(n - open) resolved") }
            if unseen > 0 { words.append("\(unseen) new") }
            pushedSubtitle.stringValue = n == 0 ? "None in this space yet" : words.joined(separator: " · ")
        }
        needsLayout = true
    }

    @objc private func threadsFilterClicked() {
        guard let menu = delegate?.sidebarThreadsFilterMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: threadsFilter.bounds.height + 4), in: threadsFilter)
    }

    @objc private func threadsReadClicked() { delegate?.sidebarMarkThreadsRead() }



    private func chooseOrganization(_ org: Organization) {
        setOrganization(org)
        delegate?.sidebarOrganizationChanged(org)
    }




    /// The card's ground, as pinned or not, in the appearance shown —
    /// themed once (each `themed` call adds a hook kept for good), then
    /// set again as the pin changes.
    private var chromeThemed = false
    private func applyCard(_ v: NSView) {
        // Pinned, on the backdrop: the theme's veil over it, if it has one.
        let veil = Palette.current.backdrop.sidebarVeil.map { $0.color(dark: v.effectiveAppearance.isDark).cgColor } ?? NSColor.clear.cgColor
        v.layer?.backgroundColor = pinned ? veil : Theme.panel.withAlphaComponent(0.94).cgColor
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
        pinButton.toolTip = pinned ? "Let Sidebar Slide Out (⇧⌘/)" : "Keep Sidebar Shown (⇧⌘/)"
    }

    @objc private func togglePinned() { delegate?.sidebarTogglePinned() }

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
    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        onDrag?(event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onEnd?()
    }
}

/// The top of the sidebar, beside the window buttons, moves the window, as
/// a title bar would.
final class WindowDragView: NSView {
    /// The window buttons sit on this row, partly below the title bar they
    /// belong to, where they'd get no clicks; pass those clicks on — only
    /// clicks: the title bar asks what's under it for the next responder
    /// of a cursor update, and a button given back sends it to the title
    /// bar again, around until the stack runs out (a crash on macOS 27).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), let window, let superview else { return nil }
        guard let type = NSApp.currentEvent?.type,
              [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type) else { return hit }
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
        showImage()
    }

    /// Its image shown, which macOS 27 hides unless asked.
    func showImage() {
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

}

/// One of the bar's tabs: what the sidebar lists (spaces, files,
/// threads), its icon — strong and on a band when it's the one shown — and
/// a count of what's new in it, in a dot at its corner.
final class SidebarTab: ClickView {
    static let size: CGFloat = 26
    let organization: Organization
    var chosen = false { didSet { if chosen != oldValue { update() } } }
    var count = 0 { didSet { if count != oldValue { update() } } }
    private let icon = NSImageView()
    /// A grey count, as the pills are.
    private let badge = NSTextField.label(font: UIType.badge, align: .center)

    init(_ organization: Organization) {
        self.organization = organization
        super.init(frame: .zero)
        icon.image = Theme.symbol(organization.symbol, size: 13, weight: .medium)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.drawsBackground = false
        badge.themed { $0.layer?.backgroundColor = Theme.text.withAlphaComponent(0.14).cgColor }
        for v in [icon, badge] { addSubview(v) }
        let keys: [Organization: String] = [.desk: "⌥⌘1", .files: "⌥⌘2", .threads: "⌥⌘3"]
        toolTip = organization.title + (keys[organization].map { " (\($0))" } ?? "")
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        icon.contentTintColor = chosen ? Theme.text : Theme.secondaryText
        badge.stringValue = count > 99 ? "99+" : "\(count)"
        badge.isHidden = count == 0
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 4, dy: 4)
        let w = max(12, ceil(badge.intrinsicContentSize.width) + 4)
        badge.frame = NSRect(x: bounds.width - w + 3, y: bounds.height - 10, width: w, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard chosen || hovering else { return }
        (chosen ? Theme.selectionInactive : Theme.hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Radius.control, yRadius: Radius.control).fill()
    }
}

/// A space's host, under its name (§3.6): its name — This Mac, or the
/// remote's — what's wrong with its link if anything, and a remote's ping
/// times lately (`Sparkline`). The pointer on it, the host's card: its
/// machine and link, live.
final class SpaceHostLine: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let sparkline = Sparkline()
    /// The pointer on it (its rect in the window), or gone.
    var onHover: ((NSRect?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = Theme.symbol(Theme.hostSymbol(remote: false), size: 11, weight: .regular)
        icon.contentTintColor = Theme.secondaryText
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        for v in [icon, label, sparkline] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(host: String, standing: String?, pings: (() -> Sparkline.Pings)?, remote: Bool = false) {
        icon.image = Theme.symbol(Theme.hostSymbol(remote: remote), size: 11, weight: .regular)
        label.stringValue = host + (standing.map { " · " + $0 } ?? "")
        label.textColor = standing == nil ? Theme.secondaryText : Status.attention
        sparkline.pings = pings
        sparkline.isHidden = pings == nil
        needsLayout = true
    }

    var debugText: String { label.stringValue + (sparkline.isHidden ? "" : " ~sparkline") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 0, y: (h - 14) / 2, width: 16, height: 14)
        let room = bounds.width - 20 - (sparkline.isHidden ? 0 : Sparkline.width + 8)
        label.sizeToFit()
        let lw = min(ceil(label.frame.width), max(0, room))
        label.frame = NSRect(x: 20, y: ((h - label.frame.height) / 2).rounded(), width: lw, height: label.frame.height)
        sparkline.frame = NSRect(x: label.frame.maxX + 8, y: (h - Sparkline.height) / 2, width: Sparkline.width, height: Sparkline.height)
    }

    /// Its parts, for the pointer: the name and the line by it.
    private var hot: NSRect { NSRect(x: 0, y: 0, width: sparkline.isHidden ? label.frame.maxX : sparkline.frame.maxX, height: bounds.height) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private var over = false
    private func track(_ event: NSEvent) {
        let now = hot.contains(convert(event.locationInWindow, from: nil))
        guard now != over else { return }
        over = now
        onHover?(now ? convert(hot, to: nil) : nil)
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { over = false; onHover?(nil) }
}
