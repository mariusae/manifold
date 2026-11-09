import AppKit
import ManifoldCore

protocol DiffViewDelegate: AnyObject {
    /// Open the new side's file at a line, beside the diff.
    func diffView(_ view: DiffView, open path: String, line: Int)
    func diffViewReload(_ view: DiffView)
    /// A file's row right-clicked: its versions, its changes alone.
    func diffView(_ view: DiffView, menuFor path: String) -> NSMenu?
    /// A file's new side, as the diff has it (a commit's, the working
    /// tree's): for more of it around the changes; nil if it can't be had.
    func diffView(_ view: DiffView, textOf file: String, done: @escaping (String?) -> Void)
}

/// The diff lens (DESIGN.md §7.5): a file at two points, or a commit, as
/// rows of context, additions and removals with line numbers on both
/// sides, long stretches of context folded (click to unfold). Double-click
/// a row to open the file there.
final class DiffView: NSView, PaneContent, KeepsViewState {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DiffViewDelegate?
    var source: () -> Block? = { nil }
    var theme: FontTheme {
        didSet {
            guard theme != oldValue else { return }
            rowsView.font = theme.font(.monospaced, size: 12)
            rowsView.needsDisplay = true
            loadedAt = nil
            documentChanged()
        }
    }

    private let note = NSTextField(labelWithString: "")
    /// While its host compares (and sends what it found): said in the
    /// middle, a moment on — with how much has come, from another host.
    private let waiting = BusyNote()
    private let scroll = ClippingScrollView()
    private let rowsView = DiffRowsView()
    fileprivate var printableRows: [DiffRow] { rowsView.rows }
    private var loadedAt: Stamp?
    private var unfolded = false
    /// A commit's heading, over its rows: its message rendered.
    private var commitHeader: CommitHeaderView?
    /// Files folded to their heading, by name (kept with the tile).
    private var collapsed: Set<String> = []
    /// More of a patch's files around their changes: their new side's
    /// lines, once had; how many more above each hunk (by the line its
    /// header says) and below the last; each hunk row's header line.
    private var fileLines: [String: [String]] = [:]
    private var moreAbove: [String: [Int: Int]] = [:]
    private var moreBelow: [String: Int] = [:]
    private var hunkLines: [Int: Int] = [:]
    static let moreLines = 20
    /// The heading of the file the top of the view is in, kept at the top
    /// while its own row's scrolled past; clicked, the file folded.
    private let sticky = StickyFileHeading()

    var focusView: NSView { rowsView }
    var isDead: Bool { false }

    // MARK: Find

    private lazy var finder = FindHost(view: self, target: self)
    private var foundRows: [Int] = []
    private var foundAt: Int?

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    init(placement: PlacementID, block: BlockID, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        note.font = UIType.detail
        note.textColor = Theme.secondaryText
        note.alignment = .right
        addSubview(note)
        waiting.host = block.host
        addSubview(waiting)
        rowsView.font = theme.font(.monospaced, size: 12)
        rowsView.onFold = { [weak self] row in
            guard let self else { return }
            if row.text == "below", let i = self.rowsView.rows.firstIndex(of: row), let file = self.rowsView.file(of: self.rowsView.rows[i]) {
                return self.more(in: file) { self.moreBelow[file, default: 0] += Self.moreLines }
            }
            self.unfolded = true
            self.rebuild()
            self.keeper.note(["unfolded": "1"])
        }
        rowsView.onHunk = { [weak self] i in
            guard let self, let n = self.hunkLines[i], let file = self.rowsView.file(of: self.rowsView.rows[i]) else { return }
            self.more(in: file) { self.moreAbove[file, default: [:]][n, default: 0] += Self.moreLines }
        }
        rowsView.onOpen = { [weak self] row in
            guard let self, let b = self.source(), let subject = b.diff?.subject else { return }
            switch subject {
            case let .sides(_, new): self.delegate?.diffView(self, open: new.path, line: row.newLine ?? row.oldLine ?? 1)
            case let .commit(repo, _):
                if let file = self.rowsView.file(of: row) { self.delegate?.diffView(self, open: repo.appendingPathComponent(file), line: row.newLine ?? 1) }
            case .versions:
                if let path = b.path { self.delegate?.diffView(self, open: path, line: row.newLine ?? row.oldLine ?? 1) }
            case let .patch(root, _), let .uncommitted(root), let .since(root, _, _), let .trees(root, _, _, _):
                if let file = self.rowsView.file(of: row) { self.delegate?.diffView(self, open: root.appendingPathComponent(file), line: row.newLine ?? 1) }
            }
        }
        // A row right-clicked: its file's versions, its changes alone.
        rowsView.onMenu = { [weak self] row in
            guard let self, let i = self.rowsView.rows.firstIndex(of: row), let path = self.filePath(ofRow: i) else { return nil }
            return self.delegate?.diffView(self, menuFor: path)
        }
        rowsView.onThreads = { [weak self] line, rect in
            guard let self, let first = self.rowsView.rows(onLines: line...line).first else { return }
            self.onThreads?(first, self.convert(rect, from: self.rowsView))
        }
        rowsView.onToggleFile = { [weak self] name in self?.toggleFile(name) }
        // Text selected: said, for `mani`'s @selection.
        rowsView.onSelected = { [weak self] in NotificationCenter.default.post(name: .manifoldSelectionMade, object: self) }
        // Lines selected, dragged out: a reference to them in their file
        // (anchored as they're dropped), with their words.
        rowsView.dragOut = { [weak self] in
            guard let self, let p = self.place(rows: self.selectedRows) else { return nil }
            return Drags.place?(p, self.selectedText)
        }
        scroll.documentView = rowsView
        scroll.hasVerticalScroller = true
        // Across, the rows' text scrolls under their numbers (DiffRowsView).
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        sticky.rows = rowsView
        sticky.isHidden = true
        sticky.onClick = { [weak self] in if let name = self?.sticky.name { self?.toggleFile(name) } }
        addSubview(sticky)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.updateSticky() }
        keeper.keepScroll(of: scroll, x: true)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    private func restoreState() {
        guard !keeper.restored, !rowsView.rows.isEmpty else { return }
        keeper.restored = true
        if keeper.value("outline") == "1", !sidebarShown { toggleSidebar() }
        if keeper.value("unfolded") == "1", !unfolded {
            unfolded = true
            rebuild()
        }
        if let c = keeper.value("collapsed"), !c.isEmpty, collapsed.isEmpty {
            collapsed = Set(c.components(separatedBy: "\n"))
            rebuild()
        }
        keeper.restoreScroll(of: scroll, x: true)
    }

    override func layout() {
        super.layout()
        // What's compared is the bar's; here only how much changed, at the right.
        note.frame = NSRect(x: 12, y: bounds.height - Self.strip + 4, width: bounds.width - 24, height: 16)
        var left: CGFloat = 0
        if let sidebar, !sidebar.isHidden {
            left = TileSidebar.width(in: bounds.width)
            sidebar.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height - Self.strip)
        }
        var top = bounds.height - Self.strip
        if let commitHeader {
            let h = commitHeader.height(width: bounds.width - left, limit: (top * 0.45).rounded())
            commitHeader.frame = NSRect(x: left, y: top - h, width: bounds.width - left, height: h)
            top -= h
        }
        scroll.frame = NSRect(x: left, y: 0, width: bounds.width - left, height: top)
        sticky.frame = NSRect(x: left, y: top - rowsView.rowHeightShown, width: bounds.width - left, height: rowsView.rowHeightShown)
        waiting.frame = scroll.frame
        rowsView.minWidth = scroll.contentSize.width
        rowsView.relayout()
        finder.layout(in: bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.diffViewReload(self) }
    }

    func documentChanged() {
        guard let b = source() else { return waiting.set(.busy("Comparing…")) }
        let d = b.diff
        // Waiting until it's compared (or said why not).
        waiting.set(d?.loadedAt == nil && d?.error == nil ? .busy("Comparing…") : .idle)
        guard let d else { return }
        guard d.loadedAt != loadedAt else { return }
        loadedAt = d.loadedAt
        rebuild()
    }

    /// Debugging: how long the last rebuild's steps took.
    static var debugTiming = "none"

    private func rebuild() {
        guard let b = source(), let d = b.diff else { return }
        let t0 = CACurrentMediaTime()
        var rows: [DiffRow] = []
        if let e = d.error {
            note.stringValue = e
        } else if let patch = d.patch {
            rows = DiffRows.patch(patch)
            // More of each file around its changes, as asked for.
            if canShowMore {
                (rows, hunkLines) = DiffRows.withContext(rows, texts: fileLines, above: moreAbove, below: moreBelow)
            }
            rowsView.expandable = canShowMore
            // A commit's heading (its fields, its message) shown over the
            // rows, as a message's in a mail reader — the message as Markdown.
            if case .commit = d.subject {
                let first = rows.firstIndex { if case .file = $0.kind { true } else { false } } ?? rows.count
                // From the patch itself: its rows leave out blank lines,
                // the message's paragraphs' breaks.
                let head = patch.range(of: "\ndiff --git ").map { String(patch[..<$0.lowerBound]) } ?? patch
                if let h = CommitHeaderView.Heading(head.components(separatedBy: "\n")) {
                    rows.removeFirst(first)
                    let v = commitHeader ?? CommitHeaderView()
                    if commitHeader == nil {
                        addSubview(v)
                        commitHeader = v
                        v.onFold = { [weak self] _ in self?.needsLayout = true }
                    }
                    v.show(h, theme: theme)
                    needsLayout = true
                }
            }
        } else if let old = d.oldText, let new = d.newText {
            rows = DiffRows.sides(old: old, new: new, unfolded: unfolded)
        } else {
            note.stringValue = ""
        }
        waiting.set(d.loadedAt == nil && d.error == nil ? .busy("Comparing…") : .idle)
        if d.error == nil, d.loadedAt != nil {
            let added = rows.filter { $0.kind == .added }.count, removed = rows.filter { $0.kind == .removed }.count
            note.stringValue = added + removed == 0 ? "No difference" : "+\(added) −\(removed)"
        }
        // Files folded: their heading alone.
        if !collapsed.isEmpty {
            var kept: [DiffRow] = [], skipping = false
            for r in rows {
                if case let .file(name) = r.kind { skipping = collapsed.contains(name); kept.append(r) } else if !skipping { kept.append(r) }
            }
            rows = kept
        }
        rowsView.collapsedFiles = collapsed
        let t1 = CACurrentMediaTime()
        rowsView.rows = rows
        rowsView.relayout()
        let t2 = CACurrentMediaTime()
        if d.loadedAt != nil { restoreState() }
        fillOutline()
        updateSticky()
        let t3 = CACurrentMediaTime()
        Self.debugTiming = String(format: "%d rows: rows %.0f ms, layout %.0f ms, outline %.0f ms", rows.count, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000)
    }

    // MARK: More of a file

    /// Whether more of a patch's files can be had: its new side is a
    /// commit's or the working tree's.
    private var canShowMore: Bool {
        switch source()?.diff?.subject {
        case .commit?, .uncommitted?, .patch?, .since?: true
        case let .trees(_, _, to, _)?: to == nil
        default: false
        }
    }

    /// More of a file shown (`ask`, once its text is had), the rows
    /// where they were on screen kept there.
    private func more(in file: String, _ ask: @escaping () -> Void) {
        guard canShowMore else { return }
        if fileLines[file] != nil {
            ask()
            return keepingPlace { rebuild() }
        }
        delegate?.diffView(self, textOf: file) { [weak self] text in
            guard let self, let text else { return NSSound.beep() }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            self.fileLines[file] = lines
            ask()
            self.keepingPlace { self.rebuild() }
        }
    }

    /// The row at the top of the view kept where it is through a change of rows above it.
    private func keepingPlace(_ change: () -> Void) {
        let top = scroll.contentView.bounds.minY, h = rowsView.rowHeightShown
        let rows = rowsView.rows, at = min(Int(top / h), rows.count - 1)
        let anchor = at >= 0 ? rows[at] : nil
        change()
        guard let anchor, let now = rowsView.rows.firstIndex(of: anchor) else { return }
        let y = rowsView.rect(ofRow: now).minY + (top - CGFloat(at) * h)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, rowsView.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Debugging: more above a hunk (by row) or below a file.
    func debugMore(above row: Int?, below file: String?) -> String {
        if let row { rowsView.onHunk?(row) }
        if let file { more(in: file) { self.moreBelow[file, default: 0] += Self.moreLines } }
        return "hunks at rows \(hunkLines.keys.sorted()) · \(rowsView.rows.count) rows"
    }

    // MARK: Files folded, and the heading kept at the top

    /// A file folded to its heading, or unfolded: the heading kept where
    /// it was on screen (at the top, if it had scrolled past).
    func toggleFile(_ name: String) {
        func headingY() -> CGFloat? {
            rowsView.rows.firstIndex { $0.kind == .file(name) }.map { rowsView.rect(ofRow: $0).minY }
        }
        let was = headingY().map { max(0, $0 - scroll.contentView.bounds.minY) } ?? 0
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        keeper.note(["collapsed": collapsed.sorted().joined(separator: "\n")])
        rebuild()
        if let y = headingY() {
            let top = max(0, rowsView.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y - was), top)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateSticky()
    }

    private func updateSticky() {
        let top = scroll.contentView.bounds.minY, h = rowsView.rowHeightShown
        guard top > 0.5, let f = rowsView.file(atLine: Int(top / h)), CGFloat(f.line) * h < top - 0.5 else {
            sticky.isHidden = true
            return
        }
        if sticky.name != f.name { sticky.name = f.name; sticky.needsDisplay = true }
        sticky.isHidden = false
    }

    /// Debugging: a file folded or unfolded, and what's shown.
    func debugFold(_ name: String?) -> String {
        if let name { toggleFile(name) }
        let files = rowsView.rows.indices.compactMap { i -> String? in if case let .file(n) = rowsView.rows[i].kind { "\(n)@\(i)" } else { nil } }
        return "collapsed \(collapsed.sorted()) · \(rowsView.rows.count) rows · files \(files) · sticky \(sticky.isHidden ? "hidden" : sticky.name ?? "?")"
    }

    // MARK: Selection

    var selectedRows: [Int] { rowsView.selectedRows }
    var selectedText: String? { rowsView.selectedText }

    // MARK: Here (§2.5)

    /// Here: the rows chosen (text selected chooses its rows too).
    var here: Place? { place(rows: chosenRows) }

    /// Where it's scrolled to, for Back and Forward (§3.5).
    var navLocation: NavLocation? { .offset(Double(scroll.contentView.bounds.minY)) }

    func go(to location: NavLocation) {
        guard case let .offset(y) = location else { return }
        rowsView.scroll(NSPoint(x: 0, y: max(0, y)))
    }

    /// What's selected, for `mani`'s @selection: its words, and the lines
    /// of its file they're on (the side they're on).
    func maniSelection() async -> ManiSelected? {
        guard let text = selectedText, !text.isEmpty else { return nil }
        guard case let .lines(s, e)? = place(rows: selectedRows)?.at else { return ManiSelected(text: text) }
        return ManiSelected(text: text, lines: s...e)
    }

    /// The place rows are in their file (§3.12): the lines of the side
    /// they're on (removed lines alone, where they were: the next line
    /// that's there), with the rows as they are, and the diff — found
    /// again by their words when they're a commit's or an older version's.
    /// What a comment on them is about; lines selected, dragged out, a
    /// reference to.
    func place(rows: [Int]) -> Place? {
        guard let first = rows.first, let path = filePath(ofRow: first), let subject = source()?.diff?.subject else { return nil }
        let all = self.rows
        let rows = rows.filter { all.indices.contains($0) && filePath(ofRow: $0) == path }
        let newLines = rows.compactMap { all[$0].kind == .removed ? nil : all[$0].newLine }
        let isNew = !newLines.isEmpty
        let sideLines = isNew ? newLines : rows.compactMap { all[$0].oldLine }
        guard let start = sideLines.min(), let end = sideLines.max() else { return nil }
        let fileLine = isNew ? start : (all[(rows.last ?? 0)...].lazy.compactMap { $0.kind == .removed ? nil : $0.newLine }.first ?? 1)
        var commit: String?
        var current = false
        switch subject {
        case let .commit(_, sha): commit = sha
        case .uncommitted, .patch: current = true
        case let .sides(_, new): current = new.revision == nil
        case let .versions(_, _, to): current = to == nil
        default: break
        }
        var p = Place(file: path, on: block.host, at: .lines(fileLine, isNew ? end : fileLine))
        p.context = rows.prefix(16).map { i -> String in
            let r = all[i]
            return (r.kind == .added ? "+" : r.kind == .removed ? "-" : " ") + r.text
        }.joined(separator: "\n")
        p.diff = DiffPlace(block: block, file: path, new: isNew, start: start, end: end, commit: commit)
        p.unsure = !current
        return p
    }

    /// Debugging: text selected from (line, offset) to (line, offset) on a side; what it says.
    func debugSelect(side: Int, from: (Int, Int), to: (Int, Int)) -> String {
        rowsView.selection = (side, .init(line: from.0, col: from.1), .init(line: to.0, col: to.1))
        rowsView.chosen = min(from.0, to.0)...max(from.0, to.0)
        return "rows \(selectedRows) text \(selectedText.map { "“\($0)”" } ?? "none")"
    }

    func debugScrollAcross(_ dx: CGFloat) -> String {
        rowsView.hOffset = max(0, rowsView.hOffset + dx)
        return "across \(Int(rowsView.hOffset))"
    }

    // MARK: The outline (§7.5)

    /// The files, their hunks under them, each chosen to go there; the
    /// one you're in marked: as ticks at the tile's upper right, and in the
    /// sidebar at its left.
    private lazy var changesOutline: Outline = {
        let o = Outline()
        o.onPick = { [weak self] i in
            guard let self, self.marks.indices.contains(i) else { return }
            let r = self.rowsView.rect(ofRow: self.marks[i])
            NavJumps.willJump?(self)
            self.rowsView.scroll(NSPoint(x: 0, y: max(r.minY - 4, 0)))
            self.changesOutline.current = i
        }
        // A file (or a change in it) dragged out: the file, on the diff's host.
        o.writerFor = { [weak self] i in
            guard let self, self.marks.indices.contains(i), let path = self.filePath(ofRow: self.marks[i]) else { return nil }
            return Drags.file(path, isDirectory: false, on: self.block.host)
        }
        o.menuFor = { [weak self] i in
            guard let self, self.marks.indices.contains(i), let path = self.filePath(ofRow: self.marks[i]) else { return nil }
            return self.delegate?.diffView(self, menuFor: path)
        }
        o.block = block
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.markCurrent() }
        return o
    }()
    var outline: Outline? { changesOutline }
    /// Under the header (what's compared, and how much changed).
    var outlineInset: CGFloat { Self.strip }
    /// The line over the changes: how much changed.
    static let strip: CGFloat = 22
    private var sidebar: TileSidebar?
    private var marks: [Int] = []
    var hasSidebar: Bool { true }
    var sidebarShown: Bool { sidebar?.isHidden == false }

    func toggleSidebar() {
        if sidebar == nil {
            let s = TileSidebar(outline: changesOutline, emptyText: "One file")
            s.isHidden = true
            addSubview(s)
            sidebar = s
        }
        sidebar?.isHidden.toggle()
        keeper.note(["outline": sidebarShown ? "1" : "0"], after: 0)
        fillOutline()
        needsLayout = true
    }

    private func fillOutline() {
        var entries: [Outline.Item] = []
        marks = []
        for (i, r) in rowsView.rows.enumerated() {
            switch r.kind {
            case let .file(name): entries.append(.init(title: name, level: 0, path: true)); marks.append(i)
            case .hunk:
                // The hunk by what it's in (the function a patch names), else its line.
                let heading = r.text.trimmingCharacters(in: .whitespaces)
                entries.append(.init(title: heading.isEmpty ? "Line \(r.newLine ?? r.oldLine ?? 1)" : heading, level: 1)); marks.append(i)
            default: break
            }
        }
        changesOutline.set(entries)
        markCurrent()
    }

    /// Debugging: a commit's message folded or unfolded, as its chevron
    /// does; its heading's height after.
    func debugFoldMessage() -> String {
        guard let commitHeader else { return "no commit" }
        commitHeader.foldClicked()
        layoutSubtreeIfNeeded()
        return "message \(commitHeader.folded ? "folded" : "whole"), heading \(Int(commitHeader.frame.height)) high"
    }

    var debugSidebar: String { sidebar.map { $0.isHidden ? "hidden" : $0.debugEntries } ?? "none" }

    // MARK: Threads (§3.12)

    /// Threads at rows (by index): how many, whether one's open, whether one's not seen.
    var threadRows: [Int: ThreadMark.State] {
        get { rowsView.threadMarks }
        set { rowsView.threadMarks = newValue }
    }
    /// A row's thread mark clicked: the first row there, and where the mark is (in this view).
    var onThreads: ((Int, NSRect) -> Void)?

    var rows: [DiffRow] { rowsView.rows }

    /// The rows chosen to comment on, by index; none, the row under the
    /// top of the view.
    var chosenRows: [Int] {
        guard let c = rowsView.chosen else { return [] }
        return rowsView.rows(onLines: c).filter {
            switch rowsView.rows[$0].kind {
            case .added, .removed, .context: true
            default: false
            }
        }
    }

    /// Where the rows chosen are, in this view.
    var chosenRect: NSRect? {
        guard let c = rowsView.chosen else { return nil }
        let a = rowsView.rect(ofRow: rowsView.rows(onLines: c.lowerBound...c.lowerBound).first ?? 0)
        return convert(NSRect(x: 0, y: a.minY, width: 40, height: CGFloat(c.count) * a.height), from: rowsView)
    }

    func debugChoose(_ lines: ClosedRange<Int>) { rowsView.chosen = lines }
    /// Where a row is, in this view.
    func rect(ofRow i: Int) -> NSRect { convert(rowsView.rect(ofRow: i), from: rowsView) }

    /// The file a row is in, as a path on the diff's host.
    func filePath(ofRow i: Int) -> String? {
        guard let subject = source()?.diff?.subject, rowsView.rows.indices.contains(i) else { return nil }
        switch subject {
        case let .sides(_, new): return new.path
        case .versions: return source()?.path
        case let .commit(root, _), let .patch(root, _), let .uncommitted(root), let .since(root, _, _), let .trees(root, _, _, _):
            return rowsView.file(of: rowsView.rows[i]).map { root + "/" + $0 }
        }
    }

    private func markCurrent() {
        let y = scroll.contentView.bounds.minY + 8
        changesOutline.current = marks.lastIndex { rowsView.rect(ofRow: $0).minY <= y } ?? (marks.isEmpty ? nil : 0)
    }
}

/// The rows, drawn: two line-number gutters, then the text; colored by
/// kind.
final class DiffRowsView: NSView, NSDraggingSource {
    var rows: [DiffRow] = [] { didSet { (pairs, rowLines) = Self.pair(rows) } }
    /// Rows found (⌘F), by index into `rows`, and the one gone to.
    var found: Set<Int> = [] { didSet { foundLines = Dictionary(found.map { ($0 < rowLines.count ? rowLines[$0] : $0, $0) }, uniquingKeysWith: { a, _ in a }); needsDisplay = true } }
    var current: Int? { didSet { currentLine = current.map { $0 < rowLines.count ? rowLines[$0] : $0 }; needsDisplay = true } }
    /// What's looked for, so each match is marked where it is in its row.
    var query: (text: String, options: String.CompareOptions)? { didSet { needsDisplay = true } }
    /// The same, by line on screen, side by side.
    private var foundLines: [Int: Int] = [:]
    private var currentLine: Int?
    /// Each row's line on screen, side by side.
    private var rowLines: [Int] = []
    var font: NSFont = .systemMono(ofSize: 12, weight: .regular) { didSet { relayout() } }
    var minWidth: CGFloat = 0
    /// How far the lines' text is scrolled across, under line numbers that
    /// stay (a side by side's two sides together).
    var hOffset: CGFloat = 0 { didSet { if hOffset != oldValue { needsDisplay = true } } }
    /// Files folded to their heading row, by name; a heading clicked folds or unfolds its file.
    var collapsedFiles: Set<String> = [] { didSet { needsDisplay = true } }
    var onToggleFile: ((String) -> Void)?
    var onFold: ((DiffRow) -> Void)?
    /// A hunk's header clicked (by row): more above it.
    var onHunk: ((Int) -> Void)?
    var onOpen: ((DiffRow) -> Void)?
    private let rowHeight: CGFloat = 19
    private let gutter: CGFloat = 92
    /// Each side's gutter, side by side.
    private let sideGutter: CGFloat = 52
    private var widest: CGFloat = 0
    /// Rows paired for side-by-side: a removed line beside the added one
    /// that replaced it, or either alone; a context, hunk, file or fold
    /// row spanning both sides.
    private var pairs: [(left: DiffRow?, right: DiffRow?, span: DiffRow?)] = []
    /// Side by side when there's room for two columns of the widest line.
    private(set) var sideBySide = false

    private static func pair(_ rows: [DiffRow]) -> ([(left: DiffRow?, right: DiffRow?, span: DiffRow?)], [Int]) {
        var out: [(left: DiffRow?, right: DiffRow?, span: DiffRow?)] = []
        var lines = [Int](repeating: 0, count: rows.count)
        var i = 0
        while i < rows.count {
            let r = rows[i]
            switch r.kind {
            case .removed, .added:
                var removed: [Int] = [], added: [Int] = []
                while i < rows.count, case .removed = rows[i].kind { removed.append(i); i += 1 }
                while i < rows.count, case .added = rows[i].kind { added.append(i); i += 1 }
                for j in 0..<max(removed.count, added.count) {
                    if j < removed.count { lines[removed[j]] = out.count }
                    if j < added.count { lines[added[j]] = out.count }
                    out.append((j < removed.count ? rows[removed[j]] : nil, j < added.count ? rows[added[j]] : nil, nil))
                }
            default:
                lines[i] = out.count
                out.append((nil, nil, r))
                i += 1
            }
        }
        return (out, lines)
    }

    /// A row right-clicked: its menu.
    var onMenu: ((DiffRow) -> NSMenu?)?

    // MARK: Rows chosen, and threads (§3.12)

    /// Lines on screen chosen — clicked, dragged across, ⇧-clicked — to
    /// comment on.
    var chosen: ClosedRange<Int>? { didSet { if chosen != oldValue { needsDisplay = true } } }
    private var chooseFrom: Int?
    /// Threads at rows (by index) — drawn on the rows' lines as they're
    /// laid out now, at their right (ThreadMarks.swift).
    var threadMarks: [Int: ThreadMark.State] = [:] { didSet { needsDisplay = true } }
    private var threadLines: [Int: ThreadMark.State] {
        var byLine: [Int: ThreadMark.State] = [:]
        for (i, m) in threadMarks where i < rows.count {
            let l = line(ofRow: i)
            guard let old = byLine[l] else { byLine[l] = m; continue }
            byLine[l] = ThreadMark.State(count: old.count + m.count, open: m.open || old.open, unseen: m.unseen || old.unseen)
        }
        return byLine
    }

    private func threadMarkRect(line i: Int, _ m: ThreadMark.State) -> NSRect {
        ThreadMark.rect(m, right: bounds.maxX, lineTop: CGFloat(i) * rowHeight, lineHeight: rowHeight)
    }

    /// The lines' thread marks, over their text.
    private func drawThreadMarks(first: Int, last: Int) {
        for (i, m) in threadLines where i >= first && i <= last { ThreadMark.draw(m, in: threadMarkRect(line: i, m)) }
    }
    /// A line's thread mark clicked: the line, and where the mark is.
    var onThreads: ((Int, NSRect) -> Void)?

    /// The line on screen a row is on.
    func line(ofRow i: Int) -> Int { sideBySide ? (i < rowLines.count ? rowLines[i] : 0) : i }

    /// The rows on lines on screen, in order.
    func rows(onLines r: ClosedRange<Int>) -> [Int] {
        sideBySide ? rows.indices.filter { r.contains(rowLines[$0]) } : Array(max(0, r.lowerBound)...min(rows.count - 1, r.upperBound))
    }

    /// What's drawn under a chosen line.
    private func drawChosenAndThreads(line i: Int, y: CGFloat) {
        if chosen?.contains(i) == true, ordered == nil {
            Theme.accent.withAlphaComponent(0.16).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            Theme.accent.setFill()
            NSRect(x: 0, y: y, width: 2, height: rowHeight).fill()
        }
    }

    // MARK: Selecting text

    /// A place in the text: a line on screen, and an offset (UTF-16) in its text.
    struct Spot: Comparable {
        var line: Int
        var col: Int
        static func < (a: Spot, b: Spot) -> Bool { (a.line, a.col) < (b.line, b.col) }
    }
    /// Text selected — on one side, side by side (1 old, 2 new; 0 unified)
    /// — from where it began to where it's been dragged.
    var selection: (side: Int, anchor: Spot, head: Spot)? { didSet { needsDisplay = true } }
    private var selectFrom: (side: Int, spot: Spot)?
    /// A press in the text selected: dragged, the lines go out (a
    /// reference to them); let go, the selection's gone.
    private var pressInSelection: NSEvent?
    /// What the lines selected carry dragged out.
    var dragOut: (() -> NSPasteboardWriting?)?
    /// Text selected, let go.
    var onSelected: (() -> Void)?

    private var ordered: (side: Int, from: Spot, to: Spot)? {
        guard let s = selection, s.anchor != s.head else { return nil }
        return (s.side, min(s.anchor, s.head), max(s.anchor, s.head))
    }

    /// A line's text on a side (0 unified, 1 old, 2 new): a context,
    /// added or removed line's; nil for headings, hunks and folds.
    func text(line: Int, side: Int) -> String? {
        if !sideBySide {
            guard rows.indices.contains(line) else { return nil }
            switch rows[line].kind {
            case .added, .removed, .context: return rows[line].text
            default: return nil
            }
        }
        guard pairs.indices.contains(line) else { return nil }
        let p = pairs[line]
        if let span = p.span { if case .context = span.kind { return span.text } else { return nil } }
        return side == 1 ? p.left?.text : p.right?.text
    }

    /// Where a side's text begins, scrolled across.
    private func textX(side: Int) -> CGFloat {
        switch side {
        case 1: sideGutter - hOffset
        case 2: (bounds.width / 2).rounded() + sideGutter - hOffset
        default: gutter - hOffset
        }
    }

    private func ctLine(_ text: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    }

    /// The side a point's over: in the text (or its numbers) on the left or right.
    private func side(at p: NSPoint) -> Int { sideBySide ? (p.x < bounds.width / 2 ? 1 : 2) : 0 }

    /// Whether a point's in the text selected (on its side).
    private func inSelection(_ p: NSPoint) -> Bool {
        guard let s = ordered else { return false }
        let side = side(at: p), i = Int(p.y / rowHeight)
        guard s.side == side, i >= 0, i < lineCount, p.x >= textX(side: side) + hOffset - 4 else { return false }
        let at = Spot(line: i, col: spot(at: p, side: side).col)
        return at >= s.from && at <= s.to
    }

    /// Over the text selected, the open hand (it's dragged out); over a
    /// line's text, the I-beam; elsewhere (numbers, headings), the arrow.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), side = side(at: p), i = Int(p.y / rowHeight)
        // A thread's mark: clicked, its thread.
        if let m = threadLines[i], threadMarkRect(line: i, m).insetBy(dx: -2, dy: -2).contains(p) { return NSCursor.pointingHand.set() }
        if inSelection(p) { return NSCursor.openHand.set() }
        let inText = i >= 0 && i < lineCount && p.x >= textX(side: side) + hOffset - 4 && text(line: i, side: side) != nil
        (inText ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    /// Debug: the pointer over a line's column on a side — the cursor it
    /// gets; with `click`, pressed and let go there too.
    func debugPointer(side: Int, line: Int, col: Int, click: Bool) -> String {
        guard let window, line >= 0, line < lineCount else { return "no such line" }
        let t = text(line: line, side: side) ?? ""
        let x = textX(side: side) + CTLineGetOffsetForStringIndex(ctLine(t), min(col, t.utf16.count), nil)
        let at = convert(NSPoint(x: x + 1, y: (CGFloat(line) + 0.5) * rowHeight), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if click, let down = event(.leftMouseDown), let up = event(.leftMouseUp) { mouseDown(with: down); mouseUp(with: up) }
        guard let moved = event(.mouseMoved) else { return "no event" }
        updateCursor(moved)
        let c = NSCursor.current
        let name = c === NSCursor.openHand ? "open hand" : c === NSCursor.iBeam ? "I-beam" : c === NSCursor.arrow ? "arrow" : "other"
        return "\(name); selection \(ordered.map { "\($0.from.line):\($0.from.col)–\($0.to.line):\($0.to.col)" } ?? "none")"
    }

    /// The spot under a point, on a side.
    private func spot(at p: NSPoint, side: Int) -> Spot {
        let line = max(0, min(lineCount - 1, Int(p.y / rowHeight)))
        guard let t = text(line: line, side: side), !t.isEmpty else { return Spot(line: line, col: 0) }
        let i = CTLineGetStringIndexForPosition(ctLine(t), CGPoint(x: p.x - textX(side: side), y: 0))
        return Spot(line: line, col: max(0, min(i == kCFNotFound ? 0 : i, t.utf16.count)))
    }

    /// What's selected drawn under a line's text: from its offset to its
    /// end (and a little past, where the selection goes on to the next).
    private func drawSelection(line: Int, side: Int, text: String, origin: NSPoint, y: CGFloat) {
        guard let s = ordered, s.side == side, line >= s.from.line, line <= s.to.line else { return }
        let n = text.utf16.count, ct = ctLine(text)
        let from = line == s.from.line ? min(s.from.col, n) : 0, to = line == s.to.line ? min(s.to.col, n) : n
        let x0 = origin.x + CTLineGetOffsetForStringIndex(ct, from, nil)
        var x1 = origin.x + CTLineGetOffsetForStringIndex(ct, to, nil)
        if line < s.to.line { x1 += font.pointSize * 0.5 }
        guard x1 > x0 else { return }
        (window?.firstResponder === self ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        NSRect(x: x0, y: y + 1, width: x1 - x0, height: rowHeight - 2).fill()
    }

    /// The text selected, a line a line; nil with none.
    var selectedText: String? {
        guard let s = ordered else { return nil }
        var out: [String] = []
        for line in s.from.line...s.to.line {
            guard let t = text(line: line, side: s.side) else { continue }
            let u = Array(t.utf16), n = u.count
            let from = line == s.from.line ? min(s.from.col, n) : 0, to = line == s.to.line ? min(s.to.col, n) : n
            out.append(String(utf16CodeUnits: Array(u[from..<max(from, to)]), count: max(0, to - from)))
        }
        return out.joined(separator: "\n")
    }

    /// The rows (by index) the selection is on, on its side.
    var selectedRows: [Int] {
        guard let s = ordered else { return [] }
        if !sideBySide { return Array(s.from.line...s.to.line).filter { text(line: $0, side: 0) != nil } }
        var out: [Int] = []
        for line in s.from.line...s.to.line where pairs.indices.contains(line) {
            let p = pairs[line]
            let r = p.span ?? (s.side == 1 ? p.left : p.right)
            if let r, let i = rowIndex(of: r, line: line) { out.append(i) }
        }
        return out
    }

    private func rowIndex(of r: DiffRow, line: Int) -> Int? {
        rowLines.indices.first { rowLines[$0] == line && rows[$0] == r }
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText ?? chosen.map { c in
            rows(onLines: c).compactMap { i -> String? in
                switch rows[i].kind {
                case .added, .removed, .context: rows[i].text
                default: nil
                }
            }.joined(separator: "\n")
        }
        guard let text, !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.copy(text)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard lineCount > 0 else { return }
        let side = sideBySide ? 2 : 0, last = lineCount - 1
        selection = (side, Spot(line: 0, col: 0), Spot(line: last, col: text(line: last, side: side)?.utf16.count ?? 0))
        chosen = 0...last
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let press = pressInSelection {
            // Dragged far enough: the lines selected go out, as a reference.
            let start = convert(press.locationInWindow, from: nil)
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            pressInSelection = nil
            guard let w = dragOut?() ?? (selectedText.map { $0 as NSString }) else { return }
            let item = NSDraggingItem(pasteboardWriter: w)
            let label = NSAttributedString(string: selectedText?.components(separatedBy: "\n").first ?? "", attributes: [.font: font, .foregroundColor: Theme.text])
            let image = NSImage(size: NSSize(width: min(320, label.size().width + 12), height: rowHeight), flipped: false) { r in
                Theme.panel.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: 6, y: 3))
                return true
            }
            item.setDraggingFrame(NSRect(x: p.x - 8, y: p.y - rowHeight / 2, width: image.size.width, height: image.size.height), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
            return
        }
        if let from = selectFrom {
            let head = spot(at: p, side: from.side)
            selection = (from.side, from.spot, head)
            chosen = min(from.spot.line, head.line)...max(from.spot.line, head.line)
            autoscroll(with: event)
            return
        }
        guard let from = chooseFrom else { return }
        let i = max(0, min(lineCount - 1, Int(p.y / rowHeight)))
        chosen = min(from, i)...max(from, i)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pressInSelection != nil {
            // A click in what's selected, not a drag: it's let go.
            pressInSelection = nil
            selection = nil
            chosen = Int(convert(event.locationInWindow, from: nil).y / rowHeight)...Int(convert(event.locationInWindow, from: nil).y / rowHeight)
        }
        if selectFrom != nil {
            selectFrom = nil
            if ordered == nil { selection = nil } else { onSelected?() }
        }
        chooseFrom = nil
        updateCursor(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let line = Int(convert(event.locationInWindow, from: nil).y / rowHeight)
        // Right-clicked outside the rows chosen: that row chosen, for Comment.
        if !(chosen?.contains(line) ?? false), line >= 0, line < lineCount { chosen = line...line }
        let row: DiffRow?
        if sideBySide {
            row = pairs.indices.contains(line) ? (pairs[line].right ?? pairs[line].left ?? pairs[line].span) : nil
        } else {
            row = rows.indices.contains(line) ? rows[line] : nil
        }
        return row.flatMap { onMenu?($0) }
    }

    /// Where a row is on screen, to scroll it into view.
    func rect(ofRow i: Int) -> NSRect {
        let line = sideBySide ? (i < rowLines.count ? rowLines[i] : 0) : i
        return NSRect(x: 0, y: CGFloat(line) * rowHeight, width: bounds.width, height: rowHeight)
    }

    static let foundBackground = NSColor.themed { $0.diff.found }
    static let currentBackground = NSColor.themed { $0.found.current }

    /// A found row: a bar down its left edge — a shape, seen whatever the
    /// row's green or red, by any eye; the one gone to, wider and full.
    private func markRow(y: CGFloat, current: Bool) {
        Theme.text.withAlphaComponent(current ? 0.9 : 0.45).setFill()
        NSRect(x: 0, y: y + 1, width: current ? 4 : 3, height: rowHeight - 2).fill()
    }

    /// Each match in a row's text, drawn from `origin` in `attrs`: boxed
    /// behind its letters and ringed in the text's own colour (it shows
    /// on any band, and to eyes that don't tell the bands apart); the one
    /// gone to filled stronger, its ring thicker. Under the text, which is
    /// drawn after.
    private func markMatches(in text: String, at origin: NSPoint, attrs: [NSAttributedString.Key: Any], current: Bool) {
        guard let q = query, !q.text.isEmpty else { return }
        let s = text as NSString
        var from = 0
        let h = font.pointSize * 1.25
        while from < s.length {
            let r = s.range(of: q.text, options: q.options, range: NSRange(location: from, length: s.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            let x0 = NSAttributedString(string: s.substring(to: r.location), attributes: attrs).size().width
            let w = NSAttributedString(string: s.substring(with: r), attributes: attrs).size().width
            let box = NSRect(x: origin.x + x0 - 1.5, y: origin.y + (font.pointSize * 1.2 - h) / 2, width: w + 3, height: h)
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            (current ? Self.currentBackground : Self.foundBackground).setFill()
            path.fill()
            path.lineWidth = current ? 2 : 1
            Theme.text.withAlphaComponent(current ? 0.95 : 0.6).setStroke()
            path.stroke()
            from = r.location + r.length
        }
    }

    private var lineCount: Int { sideBySide ? pairs.count : rows.count }

    /// How far the text can scroll across: the widest line past the room for it.
    private var maxOffset: CGFloat {
        let room = sideBySide ? (bounds.width / 2).rounded() - sideGutter - 8 : bounds.width - gutter - 12
        return max(0, widest + 24 - room)
    }

    /// Across, the text scrolls under the line numbers (a mouse's wheel
    /// with ⇧, or a trackpad sideways); up and down, the rows as ever.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
        if dx != 0, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            hOffset = min(max(0, hOffset - dx), maxOffset)
            return
        }
        super.scrollWheel(with: event)
    }

    /// The arrows scroll a line (up, down) or a few characters (left,
    /// right); Page Up and Down a page; Home and End to either end.
    override func keyDown(with event: NSEvent) {
        let line = rowHeight, page = max(line, (enclosingScrollView?.contentSize.height ?? 200) - 2 * line)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        switch event.keyCode {
        case 126: scrollBy(-line)
        case 125: scrollBy(line)
        case 116: scrollBy(-page)
        case 121: scrollBy(page)
        case 115: scrollBy(-.greatestFiniteMagnitude)
        case 119: scrollBy(.greatestFiniteMagnitude)
        case 123: hOffset = max(0, hOffset - 4 * advance)
        case 124: hOffset = min(maxOffset, hOffset + 4 * advance)
        default: super.keyDown(with: event)
        }
    }

    private func scrollBy(_ dy: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let top = max(0, bounds.height - clip.bounds.height)
        let y = min(max(0, clip.bounds.minY + (dy.isFinite ? dy : dy > 0 ? top : -top)), top)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// The file heading the line on screen is under: its name, and its line.
    func file(atLine line: Int) -> (name: String, line: Int)? {
        var l = min(line, lineCount - 1)
        while l >= 0 {
            let r = sideBySide ? pairs[l].span : rows[l]
            if case let .file(name)? = r?.kind { return (name, l) }
            l -= 1
        }
        return nil
    }

    var rowHeightShown: CGFloat { rowHeight }

    /// A file's heading row: a chevron (folded or not), its name in the heading face.
    func drawFileHeading(_ name: String, in band: NSRect, textY: CGFloat) {
        Theme.hover.setFill(); band.fill()
        let folded = collapsedFiles.contains(name)
        if let image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: folded ? "Unfold" : "Fold")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [Theme.secondaryText]))) {
            image.draw(in: NSRect(x: band.minX + 12, y: band.minY + (rowHeight - 10) / 2, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), .foregroundColor: Theme.text]
        (name as NSString).draw(at: NSPoint(x: band.minX + 28, y: textY), withAttributes: attrs)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    // The drag's cursor as every other drag has it, and the right one after.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { DragCursor.began() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { DragCursor.ended() }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        widest = 0
        for r in rows.prefix(4000) where !r.text.isEmpty {
            widest = max(widest, (r.text as NSString).size(withAttributes: attrs).width)
        }
        sideBySide = minWidth >= 2 * (sideGutter + min(widest, 300) + 16) && minWidth >= 700
        // As wide as the tile: what's wider scrolls across under the numbers.
        let w = minWidth
        hOffset = min(hOffset, max(0, widest + 24 - (sideBySide ? (w / 2).rounded() - sideGutter - 8 : w - gutter - 12)))
        frame = NSRect(x: 0, y: 0, width: w, height: max(CGFloat(lineCount) * rowHeight + 20, minWidth > 0 ? (enclosingScrollView?.contentSize.height ?? 0) : 0))
        needsDisplay = true
    }

    /// The file a row (in a patch) is under.
    func file(of row: DiffRow) -> String? {
        guard let i = rows.firstIndex(of: row) else { return nil }
        for j in stride(from: i, through: 0, by: -1) {
            if case let .file(name) = rows[j].kind { return name }
        }
        return nil
    }

    /// What a fold row says: the lines it hides, or (a patch's file's
    /// end) that more of the file can be had below.
    static func foldWords(_ n: Int, _ r: DiffRow) -> String {
        r.text == "below" ? "⋯ More of the file below" : "⋯ \(n) unchanged line\(n == 1 ? "" : "s")"
    }

    /// Whether a hunk's header asks for more above it (it's clickable).
    var expandable = false

    /// A hunk's header that can show more above it: an arrow at its left.
    private func drawMoreAbove(y: CGFloat) {
        guard expandable, let image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: "More above")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium).applying(.init(paletteColors: [Theme.secondaryText]))) else { return }
        image.draw(in: NSRect(x: 22, y: y + (rowHeight - 11) / 2, width: 11, height: 11), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static let addedBackground = NSColor.themed { $0.diff.added }
    static let removedBackground = NSColor.themed { $0.diff.removed }
    static let hunkBackground = NSColor.themed { $0.diff.hunk }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let numberFont = NSFont.systemDigits(ofSize: font.pointSize * 0.85, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
        let dimAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: TextView.gutterText]
        if sideBySide { return drawSides(dirtyRect, textAttrs: textAttrs, dimAttrs: dimAttrs) }
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        for i in first...last {
            let r = rows[i]
            let y = CGFloat(i) * rowHeight
            let band = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            var attrs = textAttrs
            var marker = " "
            switch r.kind {
            case .added: Self.addedBackground.setFill(); band.fill(); marker = "+"
            case .removed: Self.removedBackground.setFill(); band.fill(); marker = "−"
            case .hunk: Self.hunkBackground.setFill(); band.fill(); attrs[.foregroundColor] = Theme.secondaryText
            case .file: break
            case .fold: attrs[.foregroundColor] = Theme.secondaryText
            case .context: break
            }
            if found.contains(i) { markRow(y: y, current: i == current) }
            drawChosenAndThreads(line: i, y: y)
            let textY = y + (rowHeight - font.pointSize * 1.2) / 2 - 1
            switch r.kind {
            case let .file(name):
                drawFileHeading(name, in: band, textY: textY)
            case let .fold(n):
                (Self.foldWords(n, r) as NSString).draw(at: NSPoint(x: gutter, y: textY), withAttributes: attrs)
            case .hunk:
                drawMoreAbove(y: y)
                ("@@ −\(r.oldLine ?? 0) +\(r.newLine ?? 0) @@ \(r.text)" as NSString).draw(at: NSPoint(x: gutter, y: textY), withAttributes: attrs)
            default:
                if let o = r.oldLine {
                    let s = NSAttributedString(string: "\(o)", attributes: dimAttrs)
                    s.draw(at: NSPoint(x: 40 - s.size().width, y: textY + 1))
                }
                if let n = r.newLine {
                    let s = NSAttributedString(string: "\(n)", attributes: dimAttrs)
                    s.draw(at: NSPoint(x: 76 - s.size().width, y: textY + 1))
                }
                (marker as NSString).draw(at: NSPoint(x: gutter - 12, y: textY), withAttributes: attrs)
                // The text scrolled across, under the numbers that stay.
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: gutter - 2, y: y, width: bounds.width - gutter + 2, height: rowHeight)).addClip()
                let at = NSPoint(x: gutter - hOffset, y: textY)
                drawSelection(line: i, side: 0, text: r.text, origin: at, y: y)
                if found.contains(i) { markMatches(in: r.text, at: at, attrs: attrs, current: i == current) }
                (r.text as NSString).draw(at: at, withAttributes: attrs)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        }
        drawThreadMarks(first: first, last: last)
    }

    /// Old on the left, new on the right, a line between; a removed line
    /// faces the added one that replaced it.
    private func drawSides(_ dirtyRect: NSRect, textAttrs: [NSAttributedString.Key: Any], dimAttrs: [NSAttributedString.Key: Any]) {
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(pairs.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let half = (bounds.width / 2).rounded()
        let textY = { (y: CGFloat) in y + (self.rowHeight - self.font.pointSize * 1.2) / 2 - 1 }
        var marking: Bool? = nil
        var lineNow = 0
        func side(_ row: DiffRow?, x: CGFloat, width: CGFloat, y: CGFloat, number: Int?) {
            guard let row else { return }
            let band = NSRect(x: x, y: y, width: width, height: rowHeight)
            var marker = " "
            switch row.kind {
            case .added: Self.addedBackground.setFill(); band.fill(); marker = "+"
            case .removed: Self.removedBackground.setFill(); band.fill(); marker = "−"
            default: break
            }
            if x == 0, let current = marking { markRow(y: y, current: current) }
            if let number {
                let s = NSAttributedString(string: "\(number)", attributes: dimAttrs)
                s.draw(at: NSPoint(x: x + 36 - s.size().width, y: textY(y) + 1))
            }
            (marker as NSString).draw(at: NSPoint(x: x + sideGutter - 12, y: textY(y)), withAttributes: textAttrs)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: x + sideGutter, y: y, width: max(0, width - sideGutter - 8), height: rowHeight)).addClip()
            let at = NSPoint(x: x + sideGutter - hOffset, y: textY(y))
            drawSelection(line: lineNow, side: x == 0 ? 1 : 2, text: row.text, origin: at, y: y)
            if let current = marking { markMatches(in: row.text, at: at, attrs: textAttrs, current: current) }
            (row.text as NSString).draw(at: at, withAttributes: textAttrs)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        for i in first...last {
            lineNow = i
            marking = foundLines[i] != nil ? (i == currentLine) : nil
            let pair = pairs[i]
            let y = CGFloat(i) * rowHeight
            if let r = pair.span {
                var attrs = textAttrs
                let band = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
                switch r.kind {
                case .hunk:
                    Self.hunkBackground.setFill(); band.fill(); attrs[.foregroundColor] = Theme.secondaryText
                    drawMoreAbove(y: y)
                    ("@@ −\(r.oldLine ?? 0) +\(r.newLine ?? 0) @@ \(r.text)" as NSString).draw(at: NSPoint(x: sideGutter, y: textY(y)), withAttributes: attrs)
                case let .file(name):
                    drawFileHeading(name, in: band, textY: textY(y))
                case let .fold(n):
                    attrs[.foregroundColor] = Theme.secondaryText
                    (Self.foldWords(n, r) as NSString).draw(at: NSPoint(x: sideGutter, y: textY(y)), withAttributes: attrs)
                default:
                    // Context: the same line on both sides, numbered each way.
                    side(r, x: 0, width: half, y: y, number: r.oldLine)
                    side(r, x: half, width: bounds.width - half, y: y, number: r.newLine)
                }
            } else {
                side(pair.left, x: 0, width: half, y: y, number: pair.left?.oldLine)
                side(pair.right, x: half, width: bounds.width - half, y: y, number: pair.right?.newLine)
            }
            drawChosenAndThreads(line: i, y: y)
        }
        Theme.divider.setFill()
        NSRect(x: half - 0.5, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        drawThreadMarks(first: first, last: last)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / rowHeight)
        // A thread's mark: its thread.
        if let m = threadLines[i], let onThreads, threadMarkRect(line: i, m).insetBy(dx: -2, dy: -2).contains(p) {
            return onThreads(i, threadMarkRect(line: i, m))
        }
        // A file's heading: its file folded or unfolded. A hunk's: more above it.
        if i >= 0, i < lineCount, event.clickCount == 1, let r = sideBySide ? pairs[i].span : rows[i] {
            if case let .file(name) = r.kind { onToggleFile?(name); return }
            if r.kind == .hunk, let onHunk, let index = sideBySide ? rowIndex(of: r, line: i) : i { onHunk(index); return }
        }
        let side = side(at: p)
        let inText = p.x >= textX(side: side) + hOffset - 4
        if i >= 0, i < lineCount, event.clickCount == 1 {
            if inSelection(p), !event.modifierFlags.contains(.shift) {
                // In what's selected: dragged, the lines go out.
                pressInSelection = event
                return
            }
            if event.modifierFlags.contains(.shift), let c = chosen {
                chosen = min(c.lowerBound, i)...max(c.upperBound, i)
                if let s = selection, s.side == side { selection = (side, s.anchor, spot(at: p, side: side)) }
            } else if inText {
                // In the text: a selection begun (the line chosen too, to comment on).
                chosen = i...i
                selection = nil
                selectFrom = (side, spot(at: p, side: side))
            } else {
                // On the numbers: rows chosen, dragged across.
                selection = nil
                chosen = i...i
                chooseFrom = i
            }
        }
        let row: DiffRow?
        if sideBySide {
            guard i >= 0, i < pairs.count else { return }
            let pair = pairs[i]
            row = pair.span ?? (p.x < bounds.width / 2 ? pair.left ?? pair.right : pair.right ?? pair.left)
        } else {
            guard i >= 0, i < rows.count else { return }
            row = rows[i]
        }
        guard let row else { return }
        if case .fold = row.kind { onFold?(row); return }
        if event.clickCount == 2 { onOpen?(row) }
    }
}

extension DiffView: Searchable {
    /// Rows holding the query, highlighted; the first from the one gone to
    /// (or the top) scrolled to.
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        guard !query.isEmpty else {
            foundRows = []
            foundAt = nil
            rowsView.found = []
            rowsView.current = nil
            rowsView.query = nil
            return done(nil)
        }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        rowsView.query = (query, options)
        foundRows = rowsView.rows.indices.filter { rowsView.rows[$0].text.range(of: query, options: options) != nil }
        rowsView.found = Set(foundRows)
        let from = foundAt == nil ? 0 : (rowsView.current ?? 0)
        foundAt = foundRows.firstIndex { $0 >= from } ?? (foundRows.isEmpty ? nil : 0)
        goToFound()
        done(foundRows.count)
    }

    func findNext(forward: Bool) {
        guard !foundRows.isEmpty else { return }
        let n = foundRows.count
        foundAt = ((foundAt ?? (forward ? -1 : 0)) + (forward ? 1 : n - 1)) % n
        goToFound()
    }

    private func goToFound() {
        guard let at = foundAt, at < foundRows.count else { rowsView.current = nil; return }
        let row = foundRows[at]
        rowsView.current = row
        rowsView.scrollToVisible(rowsView.rect(ofRow: row).insetBy(dx: 0, dy: -60))
    }

    func endSearch() {
        foundRows = []
        foundAt = nil
        rowsView.found = []
        rowsView.current = nil
        rowsView.query = nil
        window?.makeFirstResponder(rowsView)
    }

    func textForFind(_ done: @escaping (String?) -> Void) { done(nil) }
}

extension DiffView: Printable {
    /// The changes as a patch reads: each file, its hunks, + and − lines.
    func printOperation() -> NSPrintOperation? {
        let lines = printableRows.map { r -> String in
            switch r.kind {
            case let .file(name): "\n=== " + name
            case .hunk: r.text
            case .added: "+ " + r.text
            case .removed: "- " + r.text
            case .context: "  " + r.text
            case let .fold(n): "  … \(n) lines"
            }
        }
        return TextPrint.operation(lines.joined(separator: "\n"), title: source()?.displayTitle ?? "Diff", font: TextPrint.codeFont)
    }
}

extension DiffView: FollowsFontTheme {
    func fontThemeChanged() {
        rowsView.font = theme.font(.monospaced, size: 12)
        rowsView.needsDisplay = true
    }
}

/// A commit's heading over its diff, as a mail reader shows a message's:
/// who and when, small, then the message rendered as Markdown — scrolling
/// on its own past a share of the tile.
/// Text drawn as a web page draws its (`-webkit-font-smoothing:
/// antialiased`, the preview's): without the system's font smoothing,
/// which thickens strokes, so it reads as light as the preview beside it.
final class ReadingTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }
}

final class CommitHeaderView: NSView {
    private let meta = NSTextField(labelWithString: "")
    /// The message folded to its subject, or whole.
    private let fold = IconButton(symbol: "chevron.down", size: 9, weight: .semibold, target: nil, action: nil)
    private(set) var folded = CommitHeaderView.foldsMessages
    /// Folded or unfolded by its chevron (or a click on the line above the message).
    var onFold: ((Bool) -> Void)?
    /// Whether commits' messages show folded: as one was last left, in
    /// every diff (a git tile's pane shows the next commit so too).
    static var foldsMessages: Bool {
        get { UserDefaults.standard.bool(forKey: "CommitMessagesFolded") }
        set { UserDefaults.standard.set(newValue, forKey: "CommitMessagesFolded") }
    }
    private var heading: Heading?
    private var theme: FontTheme = .current
    private let scroll = ClippingScrollView()
    private let text = ReadingTextView()
    private let rule = NSView()

    /// What a commit's heading says: its fields (commit, Author, Date —
    /// or a Sapling changeset's), and its message.
    struct Heading: Equatable {
        var sha = ""
        var author = ""
        var date = ""
        var message = ""

        /// From a patch's lines before its first file, as `git show`
        /// writes them: fields, a blank line, the message indented.
        init?(_ lines: [String]) {
            var fields = true
            var message: [String] = []
            for line in lines {
                if fields {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { fields = false; continue }
                    // The message begins, indented, with no blank line said.
                    if line.hasPrefix("    ") { fields = false; message.append(String(line.dropFirst(4))); continue }
                    if line.hasPrefix("commit ") { sha = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                    else if let r = line.range(of: ":") {
                        let key = line[..<r.lowerBound].lowercased(), value = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        switch key {
                        case "author", "user": author = value
                        case "date": date = value
                        case "changeset": sha = value
                        default: break
                        }
                    }
                } else {
                    message.append(line.hasPrefix("    ") ? String(line.dropFirst(4)) : line)
                }
            }
            while message.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { message.removeLast() }
            self.message = message.joined(separator: "\n")
            guard !sha.isEmpty || !self.message.isEmpty else { return nil }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        meta.font = UIType.detail
        meta.textColor = Theme.secondaryText
        meta.lineBreakMode = .byTruncatingTail
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        rule.wantsLayer = true
        rule.themed { $0.layer?.backgroundColor = Theme.divider.cgColor }
        fold.target = self
        fold.action = #selector(foldClicked)
        for v in [meta, scroll, rule, fold] { addSubview(v) }
        updateFold()
    }

    @objc func foldClicked() {
        setFolded(!folded)
        Self.foldsMessages = folded
        onFold?(folded)
    }

    /// The message folded to its subject line, or shown whole.
    func setFolded(_ on: Bool) {
        guard on != folded else { return }
        folded = on
        updateFold()
        if let heading { show(heading, theme: theme) }
    }

    private func updateFold() {
        fold.image = Theme.symbol(folded ? "chevron.right" : "chevron.down", size: 9, weight: .semibold)
        fold.toolTip = folded ? "Show the whole message" : "Fold the message to its subject"
        fold.setAccessibilityLabel(folded ? "Show Message" : "Fold Message")
    }

    /// A click on the line above the message folds or unfolds it, as its chevron does.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y >= meta.frame.minY - 2 { return foldClicked() }
        super.mouseDown(with: event)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let inset: CGFloat = 12

    func show(_ h: Heading, theme: FontTheme) {
        heading = h
        self.theme = theme
        meta.stringValue = [String(h.sha.prefix(12)), h.author, h.date].filter { !$0.isEmpty }.joined(separator: " · ")
        // In the technical face — what's said about code, as its comments
        // are — beside the code's own.
        let body = theme.technicalFont(size: 13), code = theme.font(.monospaced, size: 12)
        // The message as written, its subject a paragraph like the rest:
        // the line above names the commit already, and a subject is often
        // a sentence, not a heading. Folded: its subject (its first
        // paragraph's first line) alone, cut short.
        var message = h.message.trimmingCharacters(in: .newlines)
        if folded { message = message.components(separatedBy: "\n").first ?? message }
        let shown = NSMutableAttributedString(attributedString: MarkdownText.attributed(
            message, font: body, code: code, color: Theme.text, strong: Theme.text,
            lineHeight: 1.3, tracking: theme.technicalTracking(body)))
        if folded {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            shown.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: shown.length))
        }
        text.textStorage?.setAttributedString(shown)
        needsLayout = true
        superview?.needsLayout = true
    }

    /// Its height at a width: the message whole, at most `limit`.
    func height(width: CGFloat, limit: CGFloat) -> CGFloat {
        let w = max(width - 2 * Self.inset, 50)
        text.frame.size.width = w
        text.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0
        return min(ceil(used) + 18 + 10 + 12, folded ? .greatestFiniteMagnitude : limit)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, inset = Self.inset
        fold.frame = NSRect(x: inset - 4, y: h - 8 - 18, width: 18, height: 20)
        meta.frame = NSRect(x: inset + 14, y: h - 8 - 16, width: w - 2 * inset - 14, height: 16)
        scroll.frame = NSRect(x: inset, y: 12, width: w - 2 * inset, height: max(0, h - 12 - 28))
        text.frame.size.width = scroll.contentSize.width
        rule.frame = NSRect(x: 0, y: 0, width: w, height: 1)
    }
}


/// The heading of the file the top of a diff is in, over its rows while
/// the file's own heading row has scrolled past: drawn as that row is;
/// clicked, the file folded.
final class StickyFileHeading: NSView {
    var name: String?
    weak var rows: DiffRowsView?
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let name, let rows else { return }
        Theme.windowBackground.withAlphaComponent(1).setFill()
        bounds.fill()
        rows.drawFileHeading(name, in: bounds, textY: (bounds.height - rows.font.pointSize * 1.2) / 2 - 1)
        Theme.divider.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
