import AppKit
import ManifoldCore

protocol GitViewDelegate: AnyObject {
    /// Open a diff beside the git block.
    func gitView(_ view: GitView, openDiff subject: DiffSubject)
    /// Open a file beside it.
    func gitView(_ view: GitView, open path: String)
    func gitViewRefresh(_ view: GitView)
}

/// The git lens (DESIGN.md §7.5): a repository's branch, what's changed,
/// and its recent history, as the host last looked; a change or a commit
/// opens as a diff beside it.
final class GitView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: GitViewDelegate?
    var source: () -> Block? = { nil }

    private let header = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let refresh = NSButton(title: "", target: nil, action: nil)
    private let scroll = NSScrollView()
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
    private var root = ""
    private var vcs: VCS = .git

    var focusView: NSView { table }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = Theme.secondaryText
        header.lineBreakMode = .byTruncatingMiddle
        branchLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        branchLabel.textColor = Theme.text
        branchLabel.alignment = .right
        branchLabel.lineBreakMode = .byTruncatingTail
        refresh.image = Theme.symbol("arrow.clockwise", size: 11, weight: .medium)
        refresh.bezelStyle = .accessoryBarAction
        refresh.isBordered = false
        refresh.target = self
        refresh.action = #selector(refreshClicked)
        refresh.toolTip = "Look again"
        for v in [header, branchLabel, refresh] { addSubview(v) }

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.target = self
        table.doubleAction = #selector(rowChosen)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

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
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height - 32)
        table.tableColumns[0].width = scroll.contentSize.width
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.gitViewRefresh(self) }
    }

    func documentChanged() {
        guard let b = source(), let g = b.git else { return }
        root = b.path ?? ""
        vcs = g.vcs ?? .git
        header.stringValue = root.abbreviatingHome + (g.vcs == .sapling ? " · Sapling" : "")
        var branch = g.branch ?? ""
        if g.ahead > 0 { branch += " ↑\(g.ahead)" }
        if g.behind > 0 { branch += " ↓\(g.behind)" }
        branchLabel.stringValue = branch
        guard g.refreshedAt != refreshedAt else { return }
        refreshedAt = g.refreshedAt
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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
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
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        switch rows[row] {
        case let .section(title):
            f.attributedStringValue = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text]).truncatingTail()
        case let .note(text):
            f.attributedStringValue = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed]).truncatingTail()
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
            a.append(NSAttributedString(string: "   \(c.author), \(when)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = a.truncatingTail()
        }
        return cell
    }
}
