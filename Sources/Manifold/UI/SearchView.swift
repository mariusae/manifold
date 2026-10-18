import AppKit
import ManifoldCore

protocol SearchViewDelegate: AnyObject {
    /// Look for this (again).
    func searchView(_ view: SearchView, run query: SearchQuery)
    /// Open a hit beside the results.
    func searchView(_ view: SearchView, open hit: SearchHit)
    func searchViewCancel(_ view: SearchView)
}

/// The search lens (DESIGN.md §7.5): the query along the top (text, Aa
/// for case, .* for a regular expression, the root it's under), the hits
/// beneath grouped by file as the host finds them, and a line saying how
/// many. ⏎ in the field asks again; ⏎ or a double-click on a hit opens
/// the file there, beside the results.
final class SearchView: NSView, PaneContent, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let placement: PlacementID
    let block: BlockID
    weak var delegate: SearchViewDelegate?
    var source: () -> Block? = { nil }

    private let field = NSTextField()
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let regexButton = NSButton(title: ".*", target: nil, action: nil)
    private let rootLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = NSTableView()

    private enum Row {
        case file(String, count: Int)
        case hit(SearchHit)
    }
    private var rows: [Row] = []
    private var hitCount = 0
    private var fileCount = 0
    private var query: SearchQuery?
    private var ranAt: Stamp?
    private var shownHits = 0

    var focusView: NSView { field }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }

        field.placeholderString = "Find in files"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.cell?.sendsActionOnEndEditing = false
        field.target = self
        field.action = #selector(fieldEntered)
        for b in [caseButton, regexButton] {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            b.target = self
            b.action = #selector(optionChanged)
        }
        caseButton.toolTip = "Match case"
        regexButton.toolTip = "Regular expression"
        rootLabel.font = .systemFont(ofSize: 11.5)
        rootLabel.textColor = Theme.secondaryText
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.alignment = .right
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = Theme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        for v in [field, caseButton, regexButton, rootLabel, status] { addSubview(v) }

        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.target = self
        table.doubleAction = #selector(rowChosen)
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {}

    override func layout() {
        super.layout()
        let top = bounds.height - 12
        let w = bounds.width
        caseButton.frame = NSRect(x: w - 12 - 36, y: top - 24, width: 36, height: 22)
        regexButton.frame = NSRect(x: w - 12 - 36 - 4 - 36, y: top - 24, width: 36, height: 22)
        field.frame = NSRect(x: 12, y: top - 25, width: regexButton.frame.minX - 8 - 12, height: 24)
        rootLabel.frame = NSRect(x: w / 2, y: top - 46, width: w / 2 - 12, height: 16)
        status.frame = NSRect(x: 12, y: top - 46, width: w / 2 - 16, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, top - 54))
        table.tableColumns[0].width = scroll.contentSize.width
    }

    /// The block (or its hits) may have changed.
    func documentChanged() {
        guard let b = source(), let s = b.search else { return }
        if s.query != query || s.ranAt != ranAt {
            query = s.query
            ranAt = s.ranAt
            if let q = s.query, field.currentEditor() == nil {
                field.stringValue = q.text
                caseButton.state = q.caseSensitive ? .on : .off
                regexButton.state = q.regex ? .on : .off
            }
            rootLabel.stringValue = s.query?.root.abbreviatingHome ?? ""
            rows = []
            hitCount = 0
            fileCount = 0
            shownHits = 0
        }
        if s.hits.count != shownHits { rebuild(s.hits) }
        var text: String
        if s.running {
            text = hitCount == 0 ? "Searching…" : "\(hitCount) so far…"
        } else if let e = s.error {
            text = e
        } else if s.query == nil {
            text = ""
        } else {
            text = hitCount == 0 ? "Nothing found" : "\(hitCount) in \(fileCount) file\(fileCount == 1 ? "" : "s")"
            if s.truncated { text += ", stopped at \(hitCount)" }
        }
        status.stringValue = text
    }

    private func rebuild(_ hits: [SearchHit]) {
        // Hits come in order, grouped by file as the command walks the tree.
        var out: [Row] = []
        var file: String?
        var files = 0
        var count = 0
        for h in hits {
            if h.path != file {
                file = h.path
                files += 1
                count = hits.filter { $0.path == h.path }.count
                out.append(.file(h.path, count: count))
            }
            out.append(.hit(h))
        }
        rows = out
        hitCount = hits.count
        fileCount = files
        shownHits = hits.count
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0, selected < rows.count { table.selectRowIndexes([selected], byExtendingSelection: false) }
    }

    // MARK: Asking

    private var currentQuery: SearchQuery {
        SearchQuery(text: field.stringValue, regex: regexButton.state == .on, caseSensitive: caseButton.state == .on,
                    root: query?.root ?? "", glob: query?.glob)
    }

    @objc private func fieldEntered() {
        let q = currentQuery
        guard !q.text.isEmpty else { return }
        delegate?.searchView(self, run: q)
    }

    @objc private func optionChanged() {
        if !field.stringValue.isEmpty { fieldEntered() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            // Down from the field: to the hits.
            guard !rows.isEmpty else { return true }
            window?.makeFirstResponder(table)
            if table.selectedRow < 0 { select(row: 0, forward: true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.searchViewCancel(self)
            return true
        default:
            return false
        }
    }

    // MARK: Hits

    @objc private func rowChosen() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case let .hit(h): delegate?.searchView(self, open: h)
        case .file: select(row: row + 1, forward: true)
        }
    }

    /// Selects a hit row, skipping file headers.
    private func select(row: Int, forward: Bool) {
        var r = row
        while r >= 0, r < rows.count, case .file = rows[r] { r += forward ? 1 : -1 }
        guard r >= 0, r < rows.count else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    /// Keys the table doesn't take come here as commands: ⏎ opens the
    /// hit, ⎋ goes back to the field.
    override func doCommand(by selector: Selector) {
        guard window?.firstResponder === table else { return super.doCommand(by: selector) }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): rowChosen()
        case #selector(NSResponder.cancelOperation(_:)): window?.makeFirstResponder(field)
        default: super.doCommand(by: selector)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === table else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: rowChosen()  // ⏎
        case 53: window?.makeFirstResponder(field)  // ⎋ back to the field
        default: super.keyDown(with: event)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .hit = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .file = rows[row] { return 24 }
        return 20
    }

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
        switch rows[row] {
        case let .file(path, count):
            var shown = path
            if let root = query?.root, shown.hasPrefix(root + "/") { shown = String(shown.dropFirst(root.count + 1)) }
            let s = NSMutableAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text])
            s.append(NSAttributedString(string: "  \(count)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = s
        case let .hit(h):
            let s = NSMutableAttributedString(string: "\(h.line)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.secondaryText])
            let line = h.text.trimmingCharacters(in: .whitespaces)
            let body = NSMutableAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.text])
            if let q = query, !q.regex, let r = line.range(of: q.text, options: q.caseSensitive ? [] : [.caseInsensitive]) {
                body.addAttribute(.backgroundColor, value: TextView.matchColor, range: NSRange(r, in: line))
            }
            s.append(body)
            f.attributedStringValue = s
        }
        return cell
    }
}
