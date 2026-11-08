import AppKit
import ManifoldCore

/// The sidebar's footer (§3.6), as Dia's: Threads at its left — the
/// space's, by time, searched and filtered in a menu over it — and at its
/// right a chevron: the space's tiles, by when they were last seen, and
/// what was closed, in a menu (⇧⌘A from anywhere).
final class SidebarFooter: NSView {
    let threads = FooterButton(symbol: "bubble.left.and.bubble.right", title: "Threads")
    let tiles = FooterButton(symbol: "chevron.down", title: nil)
    static let height: CGFloat = 38

    override init(frame: NSRect) {
        super.init(frame: frame)
        threads.toolTip = "The Space's Threads"
        tiles.toolTip = "Tiles and Recently Closed (⇧⌘A)"
        addSubview(threads)
        addSubview(tiles)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        let tw = threads.wantedWidth
        threads.frame = NSRect(x: SidebarView.margin - 8, y: (h - 28) / 2, width: tw, height: 28)
        tiles.frame = NSRect(x: bounds.width - 12 - 30, y: (h - 28) / 2, width: 30, height: 28)
    }
}

/// A button of the footer: a symbol, maybe a word, maybe a count; a band
/// under the pointer, and while its menu's open.
final class FooterButton: NSView {
    var onClick: (() -> Void)?
    var open = false { didSet { needsDisplay = true } }
    var count: Int = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    private let symbol: String
    private let title: String?
    private var hovering = false { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    init(symbol: String, title: String?) {
        self.symbol = symbol
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var wantedWidth: CGFloat {
        var w: CGFloat = 8 + 16
        if let title { w += 6 + ceil((title as NSString).size(withAttributes: [.font: font]).width) }
        if count > 0 { w += 6 + Pill.size("\(count)").width }
        return w + 10
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || open {
            Theme.text.withAlphaComponent(open ? 0.1 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        var x: CGFloat = title == nil ? (bounds.width - 16) / 2 : 8
        if let image = Theme.symbol(symbol, size: title == nil ? 11 : 12, weight: title == nil ? .semibold : .regular, color: Theme.secondaryText) {
            let z = image.size
            image.draw(in: NSRect(x: x + (16 - z.width) / 2, y: (bounds.height - z.height) / 2, width: z.width, height: z.height))
        }
        x += 16 + 6
        if let title {
            let s = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: Theme.secondaryText])
            let z = s.size()
            s.draw(at: NSPoint(x: x, y: (bounds.height - z.height) / 2))
            x += z.width + 6
        }
        if count > 0 {
            let r = NSRect(x: x, y: (bounds.height - Pill.height) / 2, width: Pill.size("\(count)").width, height: Pill.height)
            Pill.draw("\(count)", in: r)
        }
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

extension MainWindowController {
    enum FooterMenu { case threads, tiles }

    /// The footer's menu, over its button; again, put away.
    func showFooterMenu(_ which: FooterMenu) {
        if let m = footerMenu.view, m.superview != nil {
            let same = footerMenu.which == which
            closeFooterMenu()
            if same { return }
        }
        if !sidebarShown && !pinned { showSidebar(animated: true) }
        let m = PopMenu()
        footerMenu = (m, which)
        m.onClose = { [weak self] in self?.closeFooterMenu() }
        switch which {
        case .threads:
            m.placeholder = "Search threads"
            m.empty = "No threads"
            m.chips = [.init(id: "open", title: "Open"), .init(id: "unread", title: "Unread"),
                       .init(id: "resolved", title: "Resolved"), .init(id: "everywhere", title: "Every Space")]
            m.provider = { [weak self] q, on in self?.threadsMenu(q, on) ?? [] }
            sidebar.footer.threads.open = true
        case .tiles:
            m.placeholder = "Search"
            m.hint = "⇧⌘A"
            m.empty = "No tiles"
            tilesShowAll = false
            m.provider = { [weak self] q, _ in self?.tilesMenu(q) ?? [] }
            sidebar.footer.tiles.open = true
        }
        m.refresh()
        root.addSubview(m)
        layoutFooterMenu()
        m.focus()
        // A click anywhere else puts it away.
        footerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, let m = self.footerMenu.view, e.window === self.window else { return e }
            let p = m.convert(e.locationInWindow, from: nil)
            let onButton = [self.sidebar.footer.threads, self.sidebar.footer.tiles].contains { b in b.bounds.contains(b.convert(e.locationInWindow, from: nil)) }
            if !m.bounds.contains(p), !onButton { self.closeFooterMenu() }
            return e
        }
    }

    func closeFooterMenu() {
        footerMenu.view?.removeFromSuperview()
        footerMenu = (nil, .threads)
        sidebar.footer.threads.open = false
        sidebar.footer.tiles.open = false
        if let mon = footerMonitor { NSEvent.removeMonitor(mon) }
        footerMonitor = nil
        if let f = arrangement?.focused, let v = views[f] { window?.makeFirstResponder(v.focusView) }
    }

    /// Over the footer, from the sidebar's left, as tall as it needs.
    func layoutFooterMenu() {
        guard let m = footerMenu.view else { return }
        let foot = root.convert(sidebar.footer.bounds, from: sidebar.footer)
        let w = PopMenu.width
        let x = max(8, foot.minX + 6)
        let bottom = foot.maxY + 4
        let h = m.wantedHeight(most: min(560, root.bounds.height - bottom - 20))
        m.frame = NSRect(x: x, y: bottom, width: w, height: h)
    }

    /// ⇧⌘A: the space's tiles and what was closed.
    @objc func showTilesMenu(_ sender: Any?) { showFooterMenu(.tiles) }

    // MARK: Threads

    func threadsMenu(_ query: String, _ on: Set<String>) -> [PopMenu.Section] {
        guard let space = selected else { return [] }
        var all = on.contains("everywhere") ? hosts.threads : hosts.threads(inSpace: space)
        if on.contains("open"), !on.contains("resolved") { all = all.filter { $0.thread?.resolved != true } }
        if on.contains("resolved"), !on.contains("open") { all = all.filter { $0.thread?.resolved == true } }
        if on.contains("unread") { all = all.filter { !hosts.unseen($0).isEmpty } }
        let q = query.lowercased()
        func place(_ t: Block) -> String { t.thread?.about.map { describe($0).title } ?? "" }
        if !q.isEmpty {
            all = all.filter { t in
                ([t.thread?.title ?? "", place(t)] + (t.thread?.comments.compactMap(\.comment) ?? [])).contains { $0.lowercased().contains(q) }
            }
        }
        let far = Date.distantPast
        all.sort { ($0.thread?.lastActivity?.date ?? far) > ($1.thread?.lastActivity?.date ?? far) }
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        func item(_ t: Block) -> PopMenu.Item {
            let th = t.thread
            let about = th?.about.flatMap { hosts.block($0.block) }
            let when = th?.lastActivity?.date
            // When first, as Dia's: the place after it, cut if it must be.
            var sub: [String] = []
            if let when { sub.append(Self.dayWord(when) + " at " + time.string(from: when)) }
            sub.append(place(t))
            let unseen = hosts.unseen(t).count
            return PopMenu.Item(symbol: th?.resolved == true ? "checkmark.bubble" : "text.bubble",
                                image: about?.web.flatMap { Favicons.image(forPage: $0.url) },
                                title: th?.title ?? "Thread", subtitle: sub.filter { !$0.isEmpty }.joined(separator: " · "),
                                trailing: unseen > 0 ? "\(unseen) new" : "", dimmed: th?.resolved == true,
                                run: { [weak self] in self?.showThreadOverlay(nil, thread: t.id) })
        }
        if !q.isEmpty { return [PopMenu.Section(title: "Search Results", items: all.map(item))] }
        // By day, as Dia's: Today, Yesterday, the week, then by month.
        var sections: [PopMenu.Section] = []
        for t in all {
            let key = th(t)
            if sections.last?.title != key { sections.append(PopMenu.Section(title: key, items: [])) }
            sections[sections.count - 1].items.append(item(t))
        }
        func th(_ t: Block) -> String { t.thread?.lastActivity.map { Self.dayGroup($0.date) } ?? "Earlier" }
        sections.append(PopMenu.Section(title: nil, items: [
            PopMenu.Item(symbol: "plus.bubble", title: "New Thread About This Space…", dimmed: true, run: { [weak self] in self?.newThreadAboutSpace() }),
        ], divided: true))
        return sections
    }

    static func dayWord(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMMd" : "yMMMd")
        return f.string(from: d)
    }

    static func dayGroup(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -7, to: Date()), d > week { return "Previous 7 Days" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMMM" : "MMMM y")
        return f.string(from: d)
    }

    // MARK: Tiles

    func tilesMenu(_ query: String) -> [PopMenu.Section] {
        guard let space = selected, let a = hosts.arrangement(space) else { return [] }
        let q = query.lowercased()
        func matchesQuery(_ b: Block?) -> Bool {
            guard !q.isEmpty else { return true }
            return [b.map(Self.linkTitle) ?? "", b?.path ?? "", b?.web?.url ?? ""].contains { $0.lowercased().contains(q) }
        }
        // The space's tiles, the last seen first.
        let far = Date.distantPast
        func seen(_ id: BlockID) -> Date { hosts.client(of: id)?.node.graph.seen(id)?.date ?? far }
        let placed = (a.columns.flatMap { $0 } + a.docked.map(\.placement))
            .filter { !stacked.contains($0.id) && matchesQuery(hosts.block($0.block)) }
            .sorted { $0.id == a.focused || ($1.id != a.focused && seen($0.block) > seen($1.block)) }
        var tiles = placed.map { p -> PopMenu.Item in
            let b = hosts.block(p.block)
            return PopMenu.Item(symbol: b.map { Theme.symbolName(for: $0) } ?? "square.dashed", image: b?.web.flatMap { Favicons.image(forPage: $0.url) },
                                title: b.map(Self.linkTitle) ?? "Untitled", trailing: a.isDocked(p.id) ? "Docked" : "",
                                run: { [weak self] in self?.arrive(atTile: p.id) })
        }
        let most = 8
        if q.isEmpty, !tilesShowAll, tiles.count > most {
            let more = tiles.count - most
            tiles = Array(tiles.prefix(most))
            tiles.append(PopMenu.Item(symbol: "ellipsis", title: "Show All", trailing: "\(more) more", chevron: true, keepsOpen: true,
                                      run: { [weak self] in
                self?.tilesShowAll = true
                self?.footerMenu.view?.refresh()
                self?.layoutFooterMenu()
            }))
        }
        // What was closed and not yet collected, the last seen first.
        let reachable = hosts.reachable()
        let closed = hosts.all.flatMap { closedItems(on: $0, reachable: reachable) }
            .filter { $0.kind != .arrangement && matchesQuery($0) }
            .sorted { seen($0.id) > seen($1.id) }
        let closedItems = closed.prefix(q.isEmpty ? 5 : 20).map { b in
            PopMenu.Item(symbol: Theme.symbolName(for: b), image: b.web.flatMap { Favicons.image(forPage: $0.url) }, title: Self.linkTitle(b),
                         run: { [weak self] in self?.follow(b.id, from: self?.arrangement?.focused, .goTo, context: "recently closed") })
        }
        var sections = [PopMenu.Section(title: q.isEmpty ? "Tiles" : "Search Results", items: tiles),
                        PopMenu.Section(title: "Recently Closed", items: Array(closedItems))]
        if q.isEmpty {
            sections.append(PopMenu.Section(title: nil, items: [
                PopMenu.Item(symbol: "clock.arrow.circlepath", title: "All Recently Closed", trailing: closed.count > 0 ? "\(closed.count)" : "", chevron: true,
                             run: { [weak self] in self?.setOrganization(.closed) }),
                PopMenu.Item(symbol: "folder", title: "Files", chevron: true, run: { [weak self] in self?.setOrganization(.files) }),
            ], divided: true))
        }
        return sections
    }

    /// Debugging: "footer threads|tiles [type <q>|chip <id>|close]" and what it shows.
    func debugFooter(_ arg: String) -> String {
        let w = arg.split(separator: " ", maxSplits: 2).map(String.init)
        switch w.first {
        case "threads": if footerMenu.view == nil || footerMenu.which != .threads { showFooterMenu(.threads) }
        case "tiles": if footerMenu.view == nil || footerMenu.which != .tiles { showFooterMenu(.tiles) }
        case "close": closeFooterMenu(); return "closed"
        default: break
        }
        guard let m = footerMenu.view else { return "no menu" }
        if w.count > 1, w[1] == "type" { m.debugType(w.count > 2 ? w[2] : ""); layoutFooterMenu() }
        if w.count > 2, w[1] == "chip" { m.debugChip(w[2]); layoutFooterMenu() }
        return "menu \(m.frame.integral)\n" + m.debugRows
    }
}
