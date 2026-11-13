import AppKit
import ManifoldCore

/// What a project's homepage (§2.6) asks its tile to do.
enum ProjectAction {
    /// Its changes and commits, in a git tile of their own.
    case openGit
    case openCommit(GitCommit, repo: String)
    case openChange(GitStatusEntry, repo: String)
    /// Its index made again.
    case reindex
    /// Its settings: its indexer, and when it's indexed.
    case settings
    /// A block at work in it (a terminal, an agent, a note), gone to.
    case go(BlockID)
}

/// How a project stands, as its homepage shows it: its repository's
/// state scoped to it, and its index's.
struct ProjectFacts: Equatable {
    var project: Project
    /// The repository's root (its git block's path), if it's in one.
    var repo: String?
    var git: GitState?
    /// How its index stands; nil until the host has said.
    var index: SCIPStatus?
    /// Why it has none to speak of (no indexer for its language).
    var indexMissing: String?
    /// Its git block asked for, and not come yet.
    var gitPending = false
    /// Its code's languages, by their share of its code's bytes, most first.
    var languages: [LanguageShare] = []
    /// What's at work in it: terminals and agents there, notes about its files.
    var presence: [Presence] = []
}

/// A language's share of a project's code (§2.6).
struct LanguageShare: Equatable {
    var name: String
    var share: Double

    /// A project's languages as its host counted them (as GitHub does,
    /// `Linguist`): each one's share of the bytes, most first; the
    /// smallest folded into Other.
    static func of(_ counts: [Linguist.Count]) -> [LanguageShare] {
        let total = Double(counts.reduce(0) { $0 + $1.bytes })
        guard total > 0 else { return [] }
        var out = counts.map { LanguageShare(name: $0.name, share: Double($0.bytes) / total) }.sorted { $0.share > $1.share }
        if out.count > 6 {
            let other = out[5...].reduce(0) { $0 + $1.share }
            out = Array(out.prefix(5)) + [LanguageShare(name: "Other", share: other)]
        }
        return out
    }

    /// Its colour in the bar: the language's own, as code hosts colour
    /// them, else one of a few by its name.
    var color: NSColor {
        let known: [String: UInt32] = [
            "Swift": 0xF05138, "Rust": 0xDEA584, "Go": 0x00ADD8, "Python": 0x3572A5, "TypeScript": 0x3178C6,
            "JavaScript": 0xF1E05A, "C": 0x555555, "C++": 0xF34B7D, "Objective-C": 0x438EFF, "Java": 0xB07219,
            "Kotlin": 0xA97BFF, "Ruby": 0x701516, "Shell": 0x89E051, "Zig": 0xEC915C, "Haskell": 0x5E5086,
            "OCaml": 0xEF7A08, "Lua": 0x000080, "Scala": 0xC22D40, "C#": 0x178600, "PHP": 0x4F5D95, "Elixir": 0x6E4A7E,
        ]
        if let rgb = known[name] {
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        if name == "Other" { return Theme.secondaryText.withAlphaComponent(0.5) }
        let palette: [NSColor] = [.systemTeal, .systemIndigo, .systemPink, .systemMint, .systemBrown, .systemCyan]
        return palette[Int(name.unicodeScalars.reduce(0) { $0 &+ $1.value }) % palette.count]
    }
}

/// Something at work in a project, for its homepage's Here Now.
struct Presence: Equatable {
    var block: BlockID
    var title: String
    var symbol: String
    var detail: String
    /// Placed in the workspace shown: listed first.
    var here = false
    /// Its card, as a tile has it in a stack.
    var card: SummaryCardContent?

    static func == (a: Presence, b: Presence) -> Bool {
        a.block == b.block && a.title == b.title && a.symbol == b.symbol && a.detail == b.detail && a.here == b.here
            && a.card?.summary == b.card?.summary && a.card?.mark == b.card?.mark && a.card?.symbol == b.card?.symbol
    }
}

/// The line under a project's header (§2.6): its branch, how far from
/// upstream, its changes, how its index stands — each a flat button
/// doing the obvious thing (the branch and changes open its git tile;
/// the index's makes it again).
final class ProjectStrip: NSView {
    var onAction: ((ProjectAction) -> Void)?
    private let branch = FlatButton("", symbol: "arrow.triangle.branch", font: UIType.detail)
    private let changes = FlatButton("", symbol: "plusminus", font: UIType.detail)
    private let index = FlatButton("", symbol: "circle.dashed", font: UIType.detail)
    private var reindexes = false
    static let height: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [branch, changes, index] {
            b.target = self
            addSubview(b)
        }
        branch.action = #selector(openGit)
        changes.action = #selector(openGit)
        index.action = #selector(reindex)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openGit() { onAction?(.openGit) }
    @objc private func reindex() { if reindexes { onAction?(.reindex) } }

    func show(_ f: ProjectFacts) {
        if let g = f.git, f.repo != nil, g.error == nil || g.refreshedAt == nil {
            var words = g.branch ?? (g.refreshedAt == nil ? "Reading…" : "detached")
            if g.ahead > 0 { words += " ↑\(g.ahead)" }
            if g.behind > 0 { words += " ↓\(g.behind)" }
            branch.title = words
            branch.toolTip = (g.vcs == .sapling ? "Sapling" : "Git") + " repository at \(f.repo?.abbreviatingHome ?? "")"
                + (g.scope.map { " — this project is \($0) in it" } ?? "")
            changes.title = g.refreshedAt == nil ? "" : g.status.isEmpty ? "No changes" : g.status.count == 1 ? "1 change" : "\(g.status.count) changes"
            changes.isHidden = changes.title.isEmpty
        } else {
            branch.title = f.gitPending ? "Reading…" : "Not in a repository"
            branch.toolTip = f.git?.error
            changes.isHidden = true
        }
        let (symbol, words, tip, again) = Self.indexWords(f)
        index.symbolName = symbol
        index.spins = f.indexMissing == nil && f.index?.state == .indexing
        index.title = words
        index.toolTip = tip
        reindexes = again
        needsLayout = true
    }

    /// The index's chip: its symbol, words, tip, and whether a click
    /// indexes it again. The tip says all of how it stands — state, by
    /// what, when, where, why it failed — whatever the chip had room for.
    static func indexWords(_ f: ProjectFacts) -> (String, String, String?, Bool) {
        if let missing = f.indexMissing {
            return ("minus.circle", "No index", "No index: " + missing.prefix(1).lowercased() + missing.dropFirst(), false)
        }
        guard let s = f.index else { return ("circle.dashed", "Index…", "Asking the host how its index stands…", false) }
        let by = s.indexer.map { " · \($0)" } ?? ""
        let with = s.indexer.map { " with the \($0) indexer" } ?? ""
        let whenMade = s.at.map { $0.formatted(date: .abbreviated, time: .shortened) }
        let place = s.root.map { "\n" + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        switch s.state {
        case .none:
            return ("circle.dashed", "Not indexed — Index", "Not indexed\(place)\n\nClick to make its index (SCIP)\(with)", true)
        case .indexing:
            return ("arrow.triangle.2.circlepath", "Indexing…" + by, "Indexing\(with)…\(place)" + (whenMade.map { "\n\nThe last index was made \($0)" } ?? ""), false)
        case .current:
            let indexed = "Indexed" + (s.at.map { " " + BlockSummary.since($0, now: Date()) } ?? "") + by
            let made = "Indexed\(with)" + (whenMade.map { ", \($0)" } ?? "") + place
            // Behind its code: said, and a click makes it again.
            if let n = s.changed, n > 0 {
                return ("exclamationmark.arrow.circlepath", indexed + " · \(n) file\(n == 1 ? "" : "s") changed since",
                        made + "\n\n\(n) code file\(n == 1 ? " has" : "s have") changed since: what it finds may be out of date.\n\nClick to index again", true)
            }
            return ("checkmark.circle", indexed, made + "\n\nClick to index again", true)
        case .failed:
            // Why, in the chip; all it said, in its tip.
            let why = s.reason.map { ": " + ($0.count > 70 ? String($0.prefix(68)) + "…" : $0) } ?? ""
            let said = (s.message?.isEmpty == false ? s.message! : s.reason) ?? "The indexer said nothing."
            return ("exclamationmark.triangle", "Indexing failed" + by + why,
                    "Indexing failed\(with)" + place + "\n\n" + said + (whenMade.map { "\n\nThe last index was made \($0)" } ?? "") + "\n\nClick to index again", true)
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for b in [branch, changes, index] where !b.isHidden {
            b.sizeToFit()
            let w = min(b.frame.width, max(0, bounds.width - 8 - x))
            b.frame = NSRect(x: x, y: ((bounds.height - Flat.buttonHeight) / 2).rounded(), width: w, height: Flat.buttonHeight)
            x += w + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    var debugState: String {
        [branch, changes, index].filter { !$0.isHidden }.map { $0.title + ($0.spins ? " (turning)" : "") }.joined(separator: " | ")
    }
}

/// A project's sidebar (§2.6), at its homepage's right, as GitHub has
/// one: its changes and its recent commits — the project's alone, where
/// it's a folder in a bigger repository — each opened as a diff beside.
final class ProjectSidebar: NSView {
    var onAction: ((ProjectAction) -> Void)?
    /// The host its project is on: whose files and commits its rows drag.
    var host = Drags.localHost
    /// The tile it's in: what its rows open beside.
    var placement: PlacementID?
    private let scroll = ClippingScrollView()
    private let stack = FlippedView()
    private var shown: ProjectFacts?
    static let width: CGFloat = 280

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        // Its rows' bands follow the pointer as they scroll under it.
        scroll.watchScrolling { [weak self] _, _ in
            self?.stack.subviews.forEach { ($0 as? HomeRow)?.recheckHover() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ f: ProjectFacts) {
        guard f.git != shown?.git || f.repo != shown?.repo || f.languages != shown?.languages || f.presence != shown?.presence else { return }
        shown = f
        stack.subviews.forEach { $0.removeFromSuperview() }
        // Its languages, as a bar and its first few named.
        if !f.languages.isEmpty {
            add(SectionLabel("Languages"))
            add(LanguageBar(f.languages))
        }
        // What's at work in it now, each as its card: in the workspace
        // shown first, then those in others under their own heading.
        let here = f.presence.filter(\.here), elsewhere = f.presence.filter { !$0.here }
        for (title, list) in [("Here now", here), ("Other spaces", elsewhere)] where !list.isEmpty {
            add(SectionLabel(title))
            for p in list.prefix(8) {
                let row = p.card.map { HomeRow(card: $0) } ?? HomeRow(mark: nil, markColor: nil, title: p.title, detail: p.detail, symbol: p.symbol)
                row.onClick = { [weak self] in self?.onAction?(.go(p.block)) }
                // The block at work, dragged: itself, as a tile's bar ⇧-dragged is.
                row.drag = { Drags.block?(p.block, [.shift]) }
                add(row)
            }
        }
        guard let g = f.git, g.refreshedAt != nil, f.repo != nil, g.error == nil else { return relayout() }
        let repo = f.repo ?? "", host = host
        // Where a path of the repository's is, from the project's root.
        let scope = g.scope.map { $0 + "/" } ?? ""
        func inProject(_ path: String) -> String { path.hasPrefix(scope) ? String(path.dropFirst(scope.count)) : path }

        if !g.status.isEmpty {
            add(SectionLabel(g.status.count == 1 ? "1 change" : "\(g.status.count) changes"))
            for s in g.status.prefix(8) {
                let letter = s.isUntracked ? "?" : (s.workTree != " " ? s.workTree : s.index)
                let row = HomeRow(mark: letter, markColor: s.isUntracked ? Theme.secondaryText : (s.index != " " ? TextView.addedColor : TextView.modifiedColor),
                                  title: inProject(s.path), detail: nil)
                row.toolTip = repo.appendingPathComponent(s.path).abbreviatingHome
                row.onClick = { [weak self] in self?.onAction?(.openChange(s, repo: repo)) }
                row.drag = { Drags.file(repo.appendingPathComponent(s.path), isDirectory: false, on: host) }
                row.link = (repo.appendingPathComponent(s.path), placement, host)
                add(row)
            }
            if g.status.count > 8 { add(more("and \(g.status.count - 8) more")) }
        }
        add(SectionLabel(g.log.isEmpty ? "No commits" : "Recent commits"))
        for c in g.log.prefix(10) {
            let when = Age.since(Stamp(wall: Int64(c.date * 1000)))
            let row = HomeRow(mark: nil, markColor: nil, title: c.summary, detail: "\(c.short) · \(c.author) · \(when)")
            row.toolTip = c.summary
            row.onClick = { [weak self] in self?.onAction?(.openCommit(c, repo: repo)) }
            row.drag = { Drags.commit(c.sha, summary: c.summary, in: repo, on: host) }
            add(row)
        }
        if !g.log.isEmpty { add(more(g.scope == nil ? "All commits" : "All commits here")) }
        relayout()
    }

    private func more(_ words: String) -> HomeRow {
        let row = HomeRow(mark: nil, markColor: nil, title: words + " →", detail: nil, quiet: true)
        row.onClick = { [weak self] in self?.onAction?(.openGit) }
        return row
    }

    private func add(_ v: NSView) {
        if let row = v as? HomeRow, row.drag != nil {
            row.onChoose = { [weak self] row, mods in self?.choose(row, mods) }
            row.dragItems = { [weak self] row in self?.dragItems(from: row) ?? [] }
        }
        stack.addSubview(v)
    }

    /// The rows that can be dragged, in order.
    private var draggable: [HomeRow] { stack.subviews.compactMap { $0 as? HomeRow }.filter { $0.drag != nil } }
    /// The row ⌘- or ⇧-clicked last: where ⇧ chooses from.
    private weak var anchor: HomeRow?

    /// ⌘-click: a row chosen or let go, among others; ⇧-click: every row
    /// from the last so chosen to it. Chosen rows are dragged together.
    private func choose(_ row: HomeRow, _ mods: NSEvent.ModifierFlags) {
        let rows = draggable
        if mods.contains(.shift), let a = anchor, let i = rows.firstIndex(of: a), let j = rows.firstIndex(of: row) {
            for (k, r) in rows.enumerated() { r.chosen = (min(i, j)...max(i, j)).contains(k) }
            return
        }
        if mods.contains(.shift), anchor == nil { rows.forEach { $0.chosen = $0 === row } } else { row.chosen.toggle() }
        anchor = row
    }

    /// Clicked plainly: what was chosen let go.
    func unchoose() {
        draggable.forEach { $0.chosen = false }
        anchor = nil
    }

    /// What dragging `row` carries: every row chosen, if it's one of them;
    /// else it alone.
    private func dragItems(from row: HomeRow) -> [NSPasteboardWriting] {
        let rows = row.chosen ? draggable.filter(\.chosen) : [row]
        return rows.compactMap { $0.drag?() }
    }

    /// Debugging: rows chosen as ⌘-clicks (`i` of the draggable rows; a
    /// negative one, as ⇧-click), and what dragging the first would carry.
    func debugChoose(_ picks: [Int]) -> String {
        unchoose()
        let rows = draggable
        for i in picks where rows.indices.contains(abs(i)) { choose(rows[abs(i)], i < 0 ? .shift : .command) }
        return draggable.enumerated().map { ($1.chosen ? "*" : " ") + "\($0) " + $1.debugState }.joined(separator: "\n")
    }

    var debugDragItems: [NSPasteboardWriting] {
        guard let first = draggable.first(where: \.chosen) ?? draggable.first else { return [] }
        return dragItems(from: first)
    }

    private func relayout() {
        var y: CGFloat = 8
        let w = max(0, scroll.contentSize.width)
        for v in stack.subviews {
            let h = (v as? HomeRow)?.height ?? (v as? SectionLabel)?.height ?? (v as? LanguageBar)?.height ?? 20
            if v is SectionLabel, y > 8 { y += 8 }
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        stack.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 8, scroll.contentSize.height))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 0)
        relayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    var debugState: String {
        stack.subviews.map { ($0 as? HomeRow)?.debugState ?? ($0 as? SectionLabel)?.stringValue.uppercased() ?? ($0 as? LanguageBar)?.debugState ?? "?" }.joined(separator: "\n")
    }
}

/// A heading in a homepage's sidebar.
private final class SectionLabel: NSTextField {
    let height: CGFloat = 24
    init(_ words: String) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        stringValue = words
        font = UIType.section
        textColor = Theme.secondaryText
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 14, y: 6, width: bounds.width - 28, height: 14)
        (stringValue as NSString).draw(with: r, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                       attributes: [.font: UIType.caption, .foregroundColor: Theme.secondaryText])
    }
}

/// A row of a homepage's sidebar: a mark (a change's letter), its words
/// and a detail under them, a faint band under the pointer; clicked, it
/// does its thing.
final class HomeRow: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    /// What it is dragged out as (a change's file, a commit); nil, it isn't.
    var drag: (() -> NSPasteboardWriting?)?
    /// What it goes to, as a link names it (a change's file), with where
    /// it's shown and whose: right-clicked, the link menu (`LinkMenus`).
    var link: (target: String, from: PlacementID?, on: HostID?)?
    /// ⌘- or ⇧-clicked: chosen among others, not opened.
    var onChoose: ((HomeRow, NSEvent.ModifierFlags) -> Void)?
    /// What dragging it carries: it, with the others chosen.
    var dragItems: ((HomeRow) -> [NSPasteboardWriting])?
    /// Chosen, to be dragged with others.
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true; card?.chosen = chosen } } }
    private let mark: String?
    private let markColor: NSColor?
    private let symbol: String?
    private let title: String
    private let detail: String?
    private let quiet: Bool
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var height: CGFloat { card.map { SummaryCard.height(for: $0.content) + 8 } ?? (detail == nil ? 24 : 40) }
    /// Shown as a card (what's at work in the project): the card drawn,
    /// the row still what's clicked, chosen and dragged.
    private var card: SummaryCard?

    /// Two of its lines, not a stack's three: the page lists several, and
    /// two say what's at work.
    static let cardLines = 2

    convenience init(card content: SummaryCardContent) {
        self.init(mark: nil, markColor: nil, title: content.summary.title, detail: nil, symbol: content.symbol)
        var shown = content
        shown.summary.lines = Array(content.summary.lines.prefix(Self.cardLines))
        let c = SummaryCard(shown)
        card = c
        addSubview(c)
    }

    override func layout() {
        super.layout()
        card?.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard card != nil else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    init(mark: String?, markColor: NSColor?, title: String, detail: String?, quiet: Bool = false, symbol: String? = nil) {
        self.mark = mark
        self.markColor = markColor
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.quiet = quiet
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
        recheckHover()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func rightMouseDown(with event: NSEvent) {
        if let l = link, LinkMenus.popUp(l.target, from: l.from, on: l.on, with: event, for: self) { return }
        super.rightMouseDown(with: event)
    }

    /// Lit only if the pointer is over it now: scrolled out from under a
    /// still pointer, no exit comes, and its band stayed.
    func recheckHover() {
        guard let window, superview != nil else { return hovering = false }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hovering = bounds.contains(p) && visibleRect.contains(p) && isUnderPointer
    }
    /// Where a press began, and whether it became a drag.
    private var pressedAt: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = pressedAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        let writers = dragItems?(self) ?? drag?().map { [$0] } ?? []
        guard !writers.isEmpty else { return }
        dragged = true
        let items = writers.map { w -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: Drags.writer(w) ?? w)
            item.setDraggingFrame(bounds, contents: nil)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        DragPill.dress(session, from: self, at: NSEvent.mouseLocation)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { DragCursor.began() }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { DragCursor.moved() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { DragCursor.ended() }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        let mods = event.modifierFlags.intersection([.command, .shift])
        if !mods.isEmpty, let onChoose { return onChoose(self, mods) }
        (superview?.enclosingScrollView?.superview as? ProjectSidebar)?.unchoose()
        onClick?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        // A card draws itself (ringed, chosen).
        guard card == nil else { return }
        if chosen {
            Flat.chosen(emphasized: false).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Radius.control, yRadius: Radius.control).fill()
        } else if hovering {
            Flat.hovered.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Radius.control, yRadius: Radius.control).fill()
        }
        var x: CGFloat = 14
        if let mark {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemMono(ofSize: 11, weight: .semibold), .foregroundColor: markColor ?? Theme.secondaryText]
            (mark as NSString).draw(at: NSPoint(x: x, y: 5), withAttributes: a)
            x += 16
        }
        if let symbol, let image = Theme.symbol(symbol, size: 12, weight: .medium, color: Theme.secondaryText) {
            image.draw(in: image.centered(in: NSRect(x: x, y: 4, width: 16, height: 16)), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            x += 22
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = quiet ? .byTruncatingTail : (mark != nil ? .byTruncatingMiddle : .byTruncatingTail)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIType.body, .foregroundColor: quiet ? Tints.accentText : Theme.text, .paragraphStyle: para]
        (title as NSString).draw(in: NSRect(x: x, y: 4, width: bounds.width - x - 12, height: 16), withAttributes: titleAttrs)
        if let detail {
            let detailAttrs: [NSAttributedString.Key: Any] = [.font: UIType.footnote, .foregroundColor: Theme.secondaryText, .paragraphStyle: para]
            (detail as NSString).draw(in: NSRect(x: x, y: 21, width: bounds.width - x - 12, height: 15), withAttributes: detailAttrs)
        }
    }

    var debugState: String { (card != nil ? "[card] " : "") + (mark.map { $0 + " " } ?? "") + title + (detail.map { " — " + $0 } ?? "") }
}

/// A project's languages as one thin bar, each its share wide in its
/// colour, and the first few named under it with their shares.
private final class LanguageBar: NSView {
    private let shares: [LanguageShare]
    let height: CGFloat = 46

    init(_ shares: [LanguageShare]) {
        self.shares = shares
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 14, y: 6, width: bounds.width - 28, height: 6)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).addClip()
        var x = track.minX
        for s in shares {
            let w = (track.width * CGFloat(s.share)).rounded()
            s.color.setFill()
            NSRect(x: x, y: track.minY, width: max(w, 1), height: track.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
        // The first few, named.
        var lx = track.minX, ly: CGFloat = 20
        for s in shares.prefix(4) {
            let words = NSAttributedString(string: "\(s.name) \(Self.percent(s.share))", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])
            let w = words.size().width + 18
            if lx + w > track.maxX, lx > track.minX { break }
            s.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: lx, y: ly + 4, width: 7, height: 7)).fill()
            words.draw(at: NSPoint(x: lx + 11, y: ly))
            lx += w
        }
    }

    static func percent(_ share: Double) -> String {
        share >= 0.995 ? "100%" : share < 0.001 ? "<0.1%" : share < 0.1 ? String(format: "%.1f%%", share * 100) : "\(Int((share * 100).rounded()))%"
    }

    var debugState: String { "LANGUAGES " + shares.map { "\($0.name) \(Self.percent($0.share))" }.joined(separator: ", ") }
}
