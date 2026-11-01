import AppKit
import ManifoldCore

protocol GitViewDelegate: AnyObject {
    /// Open a diff beside the git block.
    func gitView(_ view: GitView, openDiff subject: DiffSubject)
    /// Open a file beside it.
    func gitView(_ view: GitView, open path: String)
    func gitViewRefresh(_ view: GitView)
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
final class GitView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: GitViewDelegate?
    var source: () -> Block? = { nil }

    private let header = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let refresh = IconButton(symbol: "arrow.clockwise", size: 11, weight: .medium, target: nil, action: nil)
    private let scroll = ClippingScrollView()
    private let table = NSTableView()

    private enum Row {
        case section(String)
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
    private let paneNote = NSTextField(labelWithString: "Choose a change or a commit to see it")
    private var pane: DiffView?
    private var paneSubject: DiffSubject?
    private var paneWork: DispatchWorkItem?
    private var splitPlaced = false
    /// Shorter than this, no pane: the list alone.
    static let paneFrom: CGFloat = 320

    var focusView: NSView { table }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        header.font = UIType.label
        header.textColor = Theme.secondaryText
        header.lineBreakMode = .byTruncatingMiddle
        branchLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        branchLabel.textColor = Theme.text
        branchLabel.alignment = .right
        branchLabel.lineBreakMode = .byTruncatingTail
        refresh.target = self
        refresh.action = #selector(refreshClicked)
        refresh.toolTip = "Look again"
        for v in [header, branchLabel, refresh] { addSubview(v) }

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.delegate = self
        table.rowHeight = 22
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.target = self
        table.doubleAction = #selector(rowChosen)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        listBox.addSubview(scroll)
        listBox.addSubview(note)
        paneNote.font = UIType.body
        paneNote.textColor = Theme.secondaryText
        paneNote.alignment = .center
        paneBox.addSubview(paneNote)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(listBox)
        split.addArrangedSubview(paneBox)
        addSubview(split)
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
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
        paneWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPane() }
        paneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (pane == nil ? 0 : 0.12), execute: work)
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
        if let key = keeper.value("selected"), let i = rows.firstIndex(where: { rowKey($0) == key }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        header.frame = NSRect(x: 12, y: bounds.height - 24, width: w * 0.55, height: 16)
        refresh.frame = NSRect(x: w - 12 - 20, y: bounds.height - 26, width: 20, height: 20)
        branchLabel.frame = NSRect(x: w * 0.55 + 16, y: bounds.height - 24, width: w * 0.45 - 16 - 36, height: 16)
        split.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height - 32)
        let tall = split.frame.height >= Self.paneFrom
        if paneBox.isHidden == tall {
            paneBox.isHidden = !tall
            split.adjustSubviews()
            if tall { placeSplit() }
        }
        if !splitPlaced, tall, split.frame.height > 0 { placeSplit() }
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
        guard splitPlaced, !paneBox.isHidden, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        keeper.note(["split": "\(listBox.frame.height)"])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.gitViewRefresh(self) }
    }

    func documentChanged() {
        pane?.documentChanged()
        note.set(source()?.git?.refreshedAt == nil && source()?.git?.error == nil ? .busy("Reading…") : .idle)
        guard let b = source(), let g = b.git else { return }
        root = b.path ?? ""
        vcs = g.vcs ?? .git
        header.stringValue = root.abbreviatingHome + (g.vcs == .sapling ? " · Sapling" : "")
        var branch = g.branch ?? ""
        if g.ahead > 0 { branch += " ↑\(g.ahead)" }
        if g.behind > 0 { branch += " ↓\(g.behind)" }
        branchLabel.stringValue = branch + (indexWords.isEmpty ? "" : "   " + indexWords)
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
                self.branchLabel.stringValue = branch + (words.isEmpty ? "" : "   " + words)
            }
        })
        var out: [Row] = []
        if let e = g.error { out.append(.note(e)) }
        out.append(.section(g.status.isEmpty ? "No changes" : "\(g.status.count) change\(g.status.count == 1 ? "" : "s")"))
        if !g.status.isEmpty { out.append(.allChanges) }
        for s in g.status { out.append(.change(s)) }
        out.append(.section("History"))
        for c in g.log { out.append(.commit(c)) }
        rows = out
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0, selected < rows.count { table.selectRowIndexes([selected], byExtendingSelection: false) }
        restoreState()
    }

    @objc private func refreshClicked() { delegate?.gitViewRefresh(self) }

    @objc private func rowChosen() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
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
        if window?.firstResponder === table, event.keyCode == 36 || event.keyCode == 76 { return rowChosen() }
        super.keyDown(with: event)
    }

    /// "select <row>", or nothing: its rows, the chosen one marked, and
    /// what the pane shows.
    func debug(_ arg: String) -> String {
        let words = arg.split(separator: " ")
        if words.first == "select", words.count > 1, let i = Int(words[1]) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        var lines = rows.enumerated().map { i, r -> String in
            let mark = i == table.selectedRow ? "*" : " "
            switch r {
            case let .section(t): return "\(mark)\(i) — \(t)"
            case let .change(s): return "\(mark)\(i) change \(s.path)"
            case let .commit(c): return "\(mark)\(i) commit \(c.short) \(c.summary)"
            case let .note(t): return "\(mark)\(i) note \(t)"
            case .allChanges: return "\(mark)\(i) all changes"
            }
        }
        lines.append("pane " + (paneBox.isHidden ? "hidden" : pane.map { "\($0.block) \(Int(paneBox.frame.height)) high" } ?? "empty"))
        return lines.joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// A change dragged out: its file, as a folder's entry is.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), case let .change(entry) = rows[row] else { return nil }
        return Drags.file(root + "/" + entry.path, isDirectory: false, on: block.host)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        DragPill.dress(session, from: tableView, at: screenPoint)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .change, .commit, .allChanges: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[row] { return 26 }
        return 22
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        case let .section(title):
            f.attributedStringValue = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text]).truncatingTail()
        case let .note(text):
            f.attributedStringValue = NSMutableAttributedString(string: text, attributes: [.font: UIType.body, .foregroundColor: Status.failed]).truncatingTail()
        case let .change(s):
            let letters = (s.index == " " ? "·" : s.index) + (s.workTree == " " ? "·" : s.workTree)
            let color: NSColor = s.isUntracked ? Theme.secondaryText : (s.index != " " ? TextView.addedColor : TextView.modifiedColor)
            let a = NSMutableAttributedString(string: letters + "  ", attributes: [.font: mono, .foregroundColor: color])
            a.append(NSAttributedString(string: s.path, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]))
            f.attributedStringValue = a.truncatingTail()
        case .allChanges:
            let a = NSMutableAttributedString(string: "±   ", attributes: [.font: mono, .foregroundColor: Theme.secondaryText])
            a.append(NSAttributedString(string: "All changes as one diff", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]))
            a.append(NSAttributedString(string: vcs == .sapling ? "   sl diff" : "   git diff", attributes: [.font: mono, .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = a.truncatingTail()
        case let .commit(c):
            let a = NSMutableAttributedString(string: c.short + "  ", attributes: [.font: mono, .foregroundColor: Theme.secondaryText])
            a.append(NSAttributedString(string: c.summary, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]))
            let when = Self.relative.localizedString(for: Date(timeIntervalSince1970: c.date), relativeTo: Date())
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
