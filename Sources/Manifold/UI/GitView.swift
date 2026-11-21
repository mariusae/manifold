import AppKit
import ManifoldCore

protocol GitViewDelegate: AnyObject {
    /// Open a diff beside the git block.
    func gitView(_ view: GitView, openDiff subject: DiffSubject)
    /// Its bar's buttons or words changed (counts, syncing, refreshing).
    func gitViewBarChanged(_ view: GitView)
    /// Open a file beside it.
    func gitView(_ view: GitView, open path: String)
    /// The repository read again on its host; `done` once it has been.
    func gitViewRefresh(_ view: GitView, done: @escaping () -> Void)
    /// Pull (fast-forward) or push the branch, on the repository's host;
    /// `done` with what went wrong, if anything.
    func gitView(_ view: GitView, sync push: Bool, done: @escaping (String?) -> Void)
    /// A diff of what's chosen, for the pane under the list (its block
    /// made, or found, to show it).
    func gitView(_ view: GitView, previewFor subject: DiffSubject) -> DiffView?
    /// How the repository's SCIP index stands (§2.5), if it has one.
    func gitView(_ view: GitView, indexStatus done: @escaping (SCIPStatus?) -> Void)
}

/// The git lens (DESIGN.md §7.5): a repository's branch, what's changed,
/// and its recent history, as the host last looked. The change or commit
/// chosen shows in a pane under the list, as a mail reader shows the
/// message chosen; double-clicked (or ⏎), it opens as a diff beside it.
final class GitView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSMenuDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: GitViewDelegate?
    var source: () -> Block? = { nil }

    /// On its tile's bar, not a strip of its own under it (§7): pull, push
    /// and refresh among the bar's buttons; how far ahead or behind, and the
    /// index, after its place — the branch is the bar's title already.
    private var ahead = 0, behind = 0
    /// Pulling or pushing, till it's done; reading again, till it has.
    private var syncing = false
    private var refreshing = false
    private var aheadBehind: String { [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil].compactMap { $0 }.joined(separator: " ") }
    var barDetail: String? {
        let words = [aheadBehind, indexWords].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        return words.isEmpty ? nil : words
    }
    var barButtons: [BarButton] {
        [BarButton(symbol: "arrow.down", tooltip: behind > 0 ? "Pull \(behind): the branch brought up to its upstream (fast-forward only)" : "Pull: the branch brought up to its upstream (fast-forward only)",
                   enabled: !syncing, action: { [weak self] in self?.pullClicked() }),
         BarButton(symbol: "arrow.up", tooltip: ahead > 0 ? "Push \(ahead): the branch's commits sent to its upstream" : "Push: the branch's commits sent to its upstream",
                   enabled: !syncing, action: { [weak self] in self?.pushClicked() }),
         BarButton(symbol: "arrow.clockwise", tooltip: refreshing ? "Reading it again…" : "Refresh: the repository read again",
                   enabled: !refreshing, action: { [weak self] in self?.refreshClicked() })]
    }
    private let scroll = ClippingScrollView()
    private let table = FlatTable(column: "row", rowHeight: TileMetrics.nameRow)

    private enum Row {
        /// A section's heading: what it says, and which (`changes`,
        /// `history`) — clicked, folded or unfolded.
        case section(String, key: String)
        case change(GitStatusEntry)
        case commit(GitCommit)
        case note(String)
        /// Every change at once, as plain `git diff` shows them.
        case allChanges
    }
    private var rows: [Row] = []
    private var refreshedAt: Stamp?
    /// "Reading…" until the host first says how the repository stands.
    private let note = BusyNote()
    private var root = ""
    private var vcs: VCS = .git
    /// How the project's SCIP index stands, in words (none: nothing said).
    private var indexWords = ""
    /// The pane under the list: the chosen row's diff; the split between
    /// them is kept with the tile.
    private let split = NSSplitView()
    private let listBox = NSView()
    private let paneBox = NSView()
    private let paneNote = NSTextField.label(color: Theme.secondaryText, align: .center)
    private var pane: DiffView?
    private var paneSubject: DiffSubject?
    private let paneWork = Debouncer()
    private var splitPlaced = false
    /// The sections folded (by key), kept with the tile.
    private var foldedSections: Set<String> = []
    /// Shorter than this, no pane: the list alone.
    static let paneFrom: CGFloat = 320

    var focusView: NSView { table }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }

        table.dataSource = self
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowChosen)
        // Several changes, commits, chosen at once (⌘-, ⇧-click): dragged
        // together, opened together with ⏎.
        table.allowsMultipleSelection = true
        // A row right-clicked: its menu, or the menu of every row chosen with it.
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.hold(table)
        listBox.addSubview(scroll)
        listBox.addSubview(note)
        note.host = block.host
        paneBox.addSubview(paneNote)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(listBox)
        split.addArrangedSubview(paneBox)
        addSubview(split)
        keeper.keepScroll(of: scroll)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        pane?.destroy()
        keeper.flush()
    }

    private func rowKey(_ row: Row) -> String? {
        switch row {
        case let .change(s): "change:" + s.path
        case let .commit(c): "commit:" + c.sha
        case .allChanges: "all"
        default: nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        keeper.note(["selected": row >= 0 && row < rows.count ? (rowKey(rows[row]) ?? "") : ""])
        // Arrowing through: shown once the choice stays a moment.
        paneWork.schedule(after: pane == nil ? 0 : 0.12) { [weak self] in self?.showPane() }
    }

    /// What a row shows, as a diff: the change against HEAD, the commit,
    /// or every change.
    private func subject(_ row: Row) -> DiffSubject? {
        switch row {
        case let .change(s):
            let path = root.appendingPathComponent(s.path)
            return .sides(old: DiffSide(path: path, revision: "HEAD"), new: DiffSide(path: path))
        case let .commit(c): return .commit(repo: root, sha: c.sha)
        case .allChanges: return root.isEmpty ? nil : .uncommitted(repo: root)
        default: return nil
        }
    }

    /// The chosen row's diff in the pane (made again only if it's another).
    private func showPane() {
        let row = table.selectedRow
        let subject = row >= 0 && row < rows.count ? subject(rows[row]) : nil
        guard subject != paneSubject || (subject != nil && pane == nil) else { return }
        paneSubject = subject
        pane?.destroy()
        pane?.removeFromSuperview()
        pane = subject.flatMap { delegate?.gitView(self, previewFor: $0) }
        if let pane { paneBox.addSubview(pane) }
        paneNote.isHidden = pane != nil
        needsLayout = true
    }

    private func restoreState() {
        guard !keeper.restored, !rows.isEmpty else { return }
        keeper.restored = true
        if let folded = keeper.value("folded"), !folded.isEmpty {
            foldedSections = Set(folded.split(separator: ",").map(String.init))
            refill()
        }
        if let key = keeper.value("selected"), let i = rows.firstIndex(where: { rowKey($0) == key }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        keeper.restoreScroll(of: scroll)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        split.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        // The pane only once there's a diff in it (a row chosen): till then
        // the list has the tile, not over an empty half.
        let tall = split.frame.height >= Self.paneFrom && pane != nil
        if paneBox.isHidden == tall {
            paneBox.isHidden = !tall
            split.adjustSubviews()
            if tall { placeSplit() }
        }
        if !splitPlaced, tall, split.frame.height > 0 { placeSplit() }
        layoutBoxes()
    }

    /// What's in the list's half and the pane's, to their size: at the
    /// tile's layout, and as the divider between them moves (which lays
    /// out the halves, not the tile — the list was left at its old
    /// height, pinned to its half's foot, over the pane or short of the top).
    private func layoutBoxes() {
        scroll.frame = listBox.bounds
        note.frame = scroll.frame
        table.tableColumns[0].width = scroll.contentSize.width
        pane?.frame = paneBox.bounds
        paneNote.frame = NSRect(x: 0, y: paneBox.bounds.midY - 9, width: paneBox.bounds.width, height: 18)
    }

    /// Where it was left, or two fifths of the way down.
    private func placeSplit() {
        splitPlaced = true
        let h = split.frame.height
        let kept = keeper.double("split")
        split.setPosition(kept.map { min(max($0, 100), h - 120) } ?? (h * 0.4).rounded(), ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 80 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 100
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        layoutBoxes()
        guard splitPlaced, !paneBox.isHidden, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        keeper.note(["split": "\(listBox.frame.height)"])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.gitViewRefresh(self) {} }
    }

    func documentChanged() {
        pane?.documentChanged()
        note.set(source()?.git?.refreshedAt == nil && source()?.git?.error == nil ? .busy("Reading…") : .idle)
        guard let b = source(), let g = b.git else { return }
        root = b.path ?? ""
        vcs = g.vcs ?? .git
        // How far ahead and behind, on its bar.
        if (ahead, behind) != (g.ahead, g.behind) {
            (ahead, behind) = (g.ahead, g.behind)
            delegate?.gitViewBarChanged(self)
        }
        guard g.refreshedAt != refreshedAt else { return }
        refreshedAt = g.refreshedAt
        // The project's index, as it stands, beside the branch.
        delegate?.gitView(self, indexStatus: { [weak self] s in
            guard let self else { return }
            let words: String
            switch s?.state {
            case .indexing: words = "indexing…"
            case .current: words = "indexed" + (s?.at.map { " " + Age.short(Stamp(wall: Int64($0.timeIntervalSince1970 * 1000))) } ?? "")
            case .failed: words = "index failed"
            default: words = ""
            }
            if words != self.indexWords {
                self.indexWords = words
                self.delegate?.gitViewBarChanged(self)
            }
        })
        refill(refreshed: true)
        restoreState()
    }

    /// The rows, from the repository as last read: each section's under
    /// its heading, unless it's folded. Read again (`refreshed`), a row
    /// chosen that's gone leaves the one in its place chosen; folded away,
    /// none.
    private func refill(refreshed: Bool = false) {
        guard let g = source()?.git else { return }
        var out: [Row] = []
        if let e = g.error { out.append(.note(e)) }
        out.append(.section(g.status.isEmpty ? "No changes" : "\(g.status.count) change\(g.status.count == 1 ? "" : "s")", key: "changes"))
        if !foldedSections.contains("changes") {
            if !g.status.isEmpty { out.append(.allChanges) }
            for s in g.status { out.append(.change(s)) }
        }
        out.append(.section("History", key: "history"))
        if !foldedSections.contains("history") { for c in g.log { out.append(.commit(c)) } }
        // The rows chosen stay chosen, by what they are, as it's read again.
        let old = rows
        let chosen = Set(table.selectedRowIndexes.compactMap { old.indices.contains($0) ? rowKey(old[$0]) : nil })
        let last = table.selectedRow
        rows = out
        table.reloadData()
        var again = IndexSet(rows.indices.filter { rowKey(rows[$0]).map(chosen.contains) == true })
        if again.isEmpty, refreshed, last >= 0, last < rows.count, selectable(last) { again = [last] }
        if !again.isEmpty { table.selectRowIndexes(again, byExtendingSelection: false) }
    }

    /// A section's heading clicked: folded, or unfolded.
    @objc private func sectionClicked(_ g: NSClickGestureRecognizer) {
        guard let cell = g.view else { return }
        let r = table.row(for: cell)
        guard rows.indices.contains(r), case let .section(_, key) = rows[r] else { return }
        toggleSection(key)
    }

    func toggleSection(_ key: String) {
        if foldedSections.remove(key) == nil { foldedSections.insert(key) }
        keeper.note(["folded": foldedSections.sorted().joined(separator: ",")])
        refill()
    }

    private func pullClicked() { sync(push: false) }
    private func pushClicked() { sync(push: true) }

    /// Pulled or pushed, on the repository's host: the buttons off, said
    /// busy, till it's done (the tile refreshed then by the host).
    private func sync(push: Bool) {
        guard !syncing else { return }
        syncing = true
        delegate?.gitViewBarChanged(self)
        note.set(.busy(push ? "Pushing…" : "Pulling…"))
        delegate?.gitView(self, sync: push) { [weak self] _ in
            guard let self else { return }
            self.syncing = false
            self.delegate?.gitViewBarChanged(self)
            self.note.set(.idle)
        }
    }

    var debugSync: String { "pull \(behind) push \(ahead)\(syncing ? " syncing" : "")" }

    /// Debugging: Pull or Push clicked.
    func debugClick(push: Bool) -> String {
        sync(push: push)
        return debugSync
    }

    /// Refresh clicked (or chosen in Source Control): the button a spinner till the host has read
    /// the repository — a beat at least, so a quick one is seen to happen.
    @objc func refreshRepository(_ sender: Any?) { refreshClicked() }

    @objc func refreshClicked() {
        guard !refreshing else { return }
        refreshing = true
        delegate?.gitViewBarChanged(self)
        let started = Date()
        delegate?.gitViewRefresh(self) { [weak self] in
            let left = max(0, 0.4 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + left) {
                guard let self else { return }
                self.refreshing = false
                self.delegate?.gitViewBarChanged(self)
            }
        }
    }

    var debugRefreshing: Bool { refreshing }

    /// Double-clicked, its row; ⏎, each row chosen.
    @objc private func rowChosen() {
        if table.clickedRow >= 0 { return open(table.clickedRow) }
        for row in table.selectedRowIndexes.prefix(12) { open(row) }
    }

    private func open(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case let .change(s):
            let path = root.appendingPathComponent(s.path)
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true || s.workTree == "D" && s.index == " " {
                delegate?.gitView(self, open: path)
            } else {
                delegate?.gitView(self, openDiff: .sides(old: DiffSide(path: path, revision: "HEAD"), new: DiffSide(path: path)))
            }
        case let .commit(c):
            delegate?.gitView(self, openDiff: .commit(repo: root, sha: c.sha))
        case .allChanges:
            showAllChanges()
        default: break
        }
    }

    /// The rows a right-click acts on: every row chosen, if it's one of
    /// them; else it alone.
    private var menuRows: [Int] {
        let r = table.clickedRow
        guard selectable(r) else { return [] }
        return table.selectedRowIndexes.contains(r) ? Array(table.selectedRowIndexes) : [r]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in menuItems(for: menuRows) { menu.addItem(item) }
    }

    /// What can be done with rows: their diffs opened, changes' files
    /// opened, revealed, their paths copied; commits' shas copied.
    func menuItems(for picked: [Int]) -> [NSMenuItem] {
        let root = root
        let changes = picked.compactMap { i -> GitStatusEntry? in if case let .change(s) = rows[i] { s } else { nil } }
        let commits = picked.compactMap { i -> GitCommit? in if case let .commit(c) = rows[i] { c } else { nil } }
        let subjects = picked.compactMap { subject(rows[$0]) }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : "\(n) \(many)" }
        var items: [NSMenuItem] = []
        if !subjects.isEmpty {
            items.append(ClosureMenuItem("Open " + count(subjects.count, "Diff", "Diffs"), symbol: "plus.forwardslash.minus") { [weak self] in
                guard let self else { return }
                for s in subjects { self.delegate?.gitView(self, openDiff: s) }
            })
        }
        let files = changes.filter { !($0.workTree == "D" && $0.index == " ") && $0.index != "D" }.map { root.appendingPathComponent($0.path) }
        if !files.isEmpty {
            items.append(ClosureMenuItem("Open " + count(files.count, "File", "Files"), symbol: "doc") { [weak self] in
                guard let self else { return }
                for f in files { self.delegate?.gitView(self, open: f) }
            })
        }
        let paths = changes.map { root.appendingPathComponent($0.path) }
        if !paths.isEmpty || !commits.isEmpty { items.append(.separator()) }
        if !files.isEmpty, block.host == Drags.localHost {
            items.append(ClosureMenuItem(files.count == 1 ? "Reveal in Finder" : "Reveal \(files.count) Files in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: $0) })
            })
        }
        if !paths.isEmpty {
            items.append(ClosureMenuItem("Copy " + count(paths.count, "Path", "Paths"), symbol: "doc.on.clipboard") {
                NSPasteboard.copy(paths.joined(separator: "\n"))
            })
        }
        if !commits.isEmpty {
            items.append(ClosureMenuItem("Copy " + count(commits.count, "SHA", "SHAs"), symbol: "number") {
                NSPasteboard.copy(commits.map(\.sha).joined(separator: "\n"))
            })
        }
        // One file: the rest of what a link to it has (`LinkMenus`) — those
        // not here already.
        if picked.count == 1, files.count == 1, let made = LinkMenus.make?(files[0], placement, block.host) {
            let have = Set(items.map(\.title) + ["Open", "Copy Path", "Copy Name"])
            var extra = made.items.filter { $0.isSeparatorItem || !have.contains($0.title) }
            while extra.first?.isSeparatorItem == true { extra.removeFirst() }
            while extra.last?.isSeparatorItem == true { extra.removeLast() }
            if !extra.isEmpty {
                items.append(.separator())
                for i in extra { made.removeItem(i); items.append(i) }
            }
        }
        return items
    }

    /// Every outstanding change in one diff beside it, as plain `git diff`.
    func showAllChanges() {
        guard !root.isEmpty else { return }
        delegate?.gitView(self, openDiff: .uncommitted(repo: root))
    }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("All Changes as One Diff", symbol: "doc.on.doc") { [weak self] in self?.showAllChanges() }]
    }

    override func doCommand(by selector: Selector) {
        guard window?.firstResponder === table else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): rowChosen()
        default: super.doCommand(by: selector)
        }
    }

    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === table, event.isReturn { return rowChosen() }
        super.keyDown(with: event)
    }

    /// "select <row>", or nothing: its rows, the chosen one marked, and
    /// what the pane shows.
    func debug(_ arg: String) -> String {
        let words = arg.split(separator: " ")
        if words.first == "fold", words.count > 1 { toggleSection(String(words[1])) }
        if words.first == "message" { return pane?.debugFoldMessage() ?? "no pane" }
        // "split <y>": the divider moved there, as a drag moves it; whether
        // the list and the pane fill their halves after.
        if words.first == "split", words.count > 1, let y = Double(words[1]) {
            split.setPosition(y, ofDividerAt: 0)
            return "list half \(Int(listBox.frame.height)), list \(Int(scroll.frame.minY))+\(Int(scroll.frame.height)); "
                + "pane half \(Int(paneBox.frame.height)), pane \(pane.map { "\(Int($0.frame.minY))+\(Int($0.frame.height))" } ?? "none")"
        }
        if words.first == "select", words.count > 1 {
            table.selectRowIndexes(IndexSet(words.dropFirst().compactMap { Int($0) }.filter(selectable)), byExtendingSelection: false)
        }
        // "menu <row>": the menu of that row right-clicked, as the chosen
        // make it; "menu <row> <i>": its item i done.
        if words.first == "menu", words.count > 1, let r = Int(words[1]), selectable(r) {
            let items = menuItems(for: table.selectedRowIndexes.contains(r) ? Array(table.selectedRowIndexes) : [r])
            if words.count > 2, let i = Int(words[2]), items.indices.contains(i), let item = items[i] as? ClosureMenuItem {
                item.perform()
                return "did \(item.title)"
            }
            return items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: "\n")
        }
        var lines = rows.enumerated().map { i, r -> String in
            let mark = table.selectedRowIndexes.contains(i) ? "*" : " "
            switch r {
            case let .section(t, key): return "\(mark)\(i) \(foldedSections.contains(key) ? "▸" : "▾") \(t)"
            case let .change(s): return "\(mark)\(i) change \(s.path)"
            case let .commit(c): return "\(mark)\(i) commit \(c.short) \(c.summary)"
            case let .note(t): return "\(mark)\(i) note \(t)"
            case .allChanges: return "\(mark)\(i) all changes"
            }
        }
        lines.append("bar " + (barDetail ?? ""))
        lines.append("pane " + (paneBox.isHidden ? "hidden" : pane.map { "\($0.block) \(Int(paneBox.frame.height)) high" } ?? "empty"))
        return lines.joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// A change dragged out: its file, as a folder's entry is; a commit,
    /// the commit (its diff, its sha). Each row chosen, if it's one of them.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        Drags.writer(rowItem(row))
    }

    private func rowItem(_ row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .change(entry): return Drags.file(root + "/" + entry.path, isDirectory: false, on: block.host)
        case let .commit(c): return Drags.commit(c.sha, summary: c.summary, in: root, on: block.host)
        default: return nil
        }
    }

    /// What dragging its chosen rows writes (debugging).
    var debugDragItems: [NSPasteboardWriting] { table.debugDragItems }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = SelectionRowView()
        v.inert = !selectable(row)
        return v
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { selectable(row) }

    private func selectable(_ row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .change, .commit, .allChanges: return true
        default: return false
        }
    }

    /// ⇧-clicked across a heading: the rows either side, not it.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet(includeInteger: selectable)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[row] { return TileMetrics.sectionHeight(first: row == 0) }
        return TileMetrics.nameRow
    }

    /// A section's heading: a chevron (folded, pointing on; open, down),
    /// then what it says, in the band at the foot of its row (under the
    /// air that parts it from the section before). Clicked, folded or
    /// unfolded.
    private func sectionCell(_ tableView: NSTableView, title: String, folded: Bool) -> NSView {
        let cell = tableView.makeView(withIdentifier: .init("section"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("section")
            let chevron = NSImageView()
            let f = NSTextField(labelWithString: "")
            f.lineBreakMode = .byTruncatingTail
            for v in [chevron, f] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(v)
            }
            c.imageView = chevron
            c.textField = f
            // (Not the table's action: a heading isn't a row to choose.)
            c.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(sectionClicked(_:))))
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                chevron.centerYAnchor.constraint(equalTo: c.bottomAnchor, constant: -TileMetrics.sectionRow / 2),
                chevron.widthAnchor.constraint(equalToConstant: 10),
                f.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
                f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                f.centerYAnchor.constraint(equalTo: c.bottomAnchor, constant: -TileMetrics.sectionRow / 2),
            ])
            return c
        }()
        cell.imageView?.image = Theme.symbol(folded ? "chevron.right" : "chevron.down", size: 9, weight: .bold, color: Theme.secondaryText)
        cell.textField?.attributedStringValue = NSMutableAttributedString(string: title, attributes: [.font: UIType.section, .foregroundColor: Theme.secondaryText]).truncatingTail()
        cell.setAccessibilityLabel(title + (folded ? ", folded" : ""))
        return cell
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case let .section(title, key) = rows[row] { return sectionCell(tableView, title: title, folded: foldedSections.contains(key)) }
        let cell = tableView.makeView(withIdentifier: .init("row"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("row")
            let f = NSTextField(labelWithString: "")
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        guard let f = cell.textField else { return cell }
        let mono = FontTheme.code(11.5)
        switch rows[row] {
        case .section: break
        case let .note(text):
            f.attributedStringValue = NSMutableAttributedString(string: text, attributes: [.font: UIType.body, .foregroundColor: Status.failed]).truncatingTail()
        case let .change(s):
            let letters = (s.index == " " ? "·" : s.index) + (s.workTree == " " ? "·" : s.workTree)
            let color: NSColor = s.isUntracked ? Theme.secondaryText : (s.index != " " ? TextView.addedColor : TextView.modifiedColor)
            // Pierre's squircles where they're the icons: the index's filled, the work tree's outlined.
            let a = PierreIcons.changeMarks(index: s.index, workTree: s.workTree, font: mono).map(NSMutableAttributedString.init)
                ?? NSMutableAttributedString(string: letters + "  ", attributes: [.font: mono, .foregroundColor: color])
            a.append(NSAttributedString(string: s.path, attributes: [.font: UIType.row, .foregroundColor: Theme.text]))
            f.attributedStringValue = a.truncatingTail()
        case .allChanges:
            let a = NSMutableAttributedString(string: "±   ", attributes: [.font: mono, .foregroundColor: Theme.secondaryText])
            a.append(NSAttributedString(string: "All changes as one diff", attributes: [.font: UIType.row, .foregroundColor: Theme.text]))
            a.append(NSAttributedString(string: vcs == .sapling ? "   sl diff" : "   git diff", attributes: [.font: mono, .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = a.truncatingTail()
        case let .commit(c):
            let a = NSMutableAttributedString(string: c.short + "  ", attributes: [.font: mono, .foregroundColor: Theme.secondaryText])
            // What's said about the code, in the technical face, beside its sha.
            let technical = FontTheme.current.technicalFont(size: 12)
            a.append(NSAttributedString(string: c.summary, attributes: [.font: technical, .foregroundColor: Theme.text,
                                                                         .kern: FontTheme.current.technicalTracking(technical)]))
            let when = Age.ago(Date(timeIntervalSince1970: c.date))
            a.append(NSAttributedString(string: "   \(c.author), \(when)", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = a.truncatingTail()
        }
        return cell
    }
}

extension GitView: FollowsFontTheme {
    func fontThemeChanged() {
        table.reloadData()
        pane?.theme = FontTheme.current
    }
}
