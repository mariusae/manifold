import AppKit
import ManifoldCore

protocol SearchViewDelegate: AnyObject {
    /// Look for this (again).
    func searchView(_ view: SearchView, run query: SearchQuery)
    /// Open a hit beside the results.
    func searchView(_ view: SearchView, open hit: SearchHit)
    func searchViewCancel(_ view: SearchView)
    /// A file's text on the search's host, for the preview.
    func searchView(_ view: SearchView, read path: String, done: @escaping (String?) -> Void)
    /// A file opened at a line, beside the results.
    func searchView(_ view: SearchView, open path: String, line: Int)
}

/// The search lens (DESIGN.md §7.5): the query along the top (text, Aa
/// for case, .* for a regular expression, the root it's under), the hits
/// beneath grouped by file as the host finds them, and a line saying how
/// many. ⏎ in the field asks again; ⏎ or a double-click on a hit opens
/// the file there, beside the results.
final class SearchView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: SearchViewDelegate?
    var source: () -> Block? = { nil }

    private let fieldBox = FlatFieldBox()
    private var field: FlatField { fieldBox.field }
    private let caseButton = FlatButton("Aa", toggles: true, font: .monospacedSystemFont(ofSize: 11, weight: .medium))
    private let regexButton = FlatButton(".*", toggles: true, font: .monospacedSystemFont(ofSize: 11, weight: .medium))
    private let rootLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let scroll = ClippingScrollView()
    private let table = NSTableView()
    private let preview = SearchPreviewView()
    private let split = FlatDivider()
    /// The code face, for the preview.
    var codeFont: NSFont {
        get { preview.font }
        set { preview.font = newValue }
    }

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
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        field.target = self
        field.action = #selector(fieldEntered)
        for b in [caseButton, regexButton] {
            b.target = self
            b.action = #selector(optionChanged)
        }
        caseButton.toolTip = "Match case"
        regexButton.toolTip = "Regular expression"
        rootLabel.font = UIType.detail
        rootLabel.textColor = Theme.secondaryText
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.alignment = .right
        status.font = UIType.detail
        status.textColor = Theme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        for v in [fieldBox, caseButton, regexButton, rootLabel, status] { addSubview(v) }

        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
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
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
        addSubview(split)
        preview.read = { [weak self] path, done in
            guard let self, let d = self.delegate else { return done(nil) }
            d.searchView(self, read: path, done: done)
        }
        preview.open = { [weak self] path, line in
            guard let self else { return }
            self.delegate?.searchView(self, open: path, line: line)
        }
        addSubview(preview)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0, row < rows.count, case let .hit(h) = rows[row] { keeper.note(["selected": "\(h.path):\(h.line)"]) }
        updatePreview()
    }

    /// The selected hit in its file; with none, the first.
    private func updatePreview() {
        guard !preview.isHidden else { return }
        let row = table.selectedRow
        var hit: SearchHit?
        if row >= 0, row < rows.count, case let .hit(h) = rows[row] { hit = h }
        if hit == nil { hit = rows.lazy.compactMap { if case let .hit(h) = $0 { return h } else { return nil } }.first }
        guard hit != preview.hit else { return }
        preview.show(hit, query: query, root: query?.root ?? "")
    }

    /// Back as it was: the hit chosen, the scroll, a query typed but not asked.
    private func restoreState() {
        guard !keeper.restored else { return }
        keeper.restored = true
        if let draft = keeper.value("draft"), !draft.isEmpty, field.currentEditor() == nil { fieldBox.stringValue = draft }
        if let key = keeper.value("selected"), let i = rows.firstIndex(where: { if case let .hit(h) = $0 { return "\(h.path):\(h.line)" == key } else { return false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
    }

    override func layout() {
        super.layout()
        let top = bounds.height - 12
        let w = bounds.width
        let midY = top - 13
        caseButton.frame = NSRect(x: w - 12 - 32, y: midY - Flat.buttonHeight / 2, width: 32, height: Flat.buttonHeight)
        regexButton.frame = NSRect(x: caseButton.frame.minX - 4 - 32, y: caseButton.frame.minY, width: 32, height: Flat.buttonHeight)
        fieldBox.frame = NSRect(x: 12, y: midY - Flat.fieldHeight / 2, width: regexButton.frame.minX - 8 - 12, height: Flat.fieldHeight)
        rootLabel.frame = NSRect(x: w / 2, y: top - 46, width: w / 2 - 12, height: 16)
        status.frame = NSRect(x: 12, y: top - 46, width: w / 2 - 16, height: 16)
        // The preview beside the hits when there's width for both, else
        // beneath them when there's height, else not at all.
        let area = NSRect(x: 0, y: 0, width: w, height: max(0, top - 54))
        let wasHidden = preview.isHidden
        if w >= 620 {
            let left = max(260, (w * 0.42).rounded())
            scroll.frame = NSRect(x: 0, y: 0, width: left, height: area.height)
            split.frame = NSRect(x: left, y: 0, width: 1, height: area.height)
            preview.frame = NSRect(x: left + 1, y: 0, width: w - left - 1, height: area.height)
            preview.isHidden = false
        } else if area.height >= 380 {
            let below = (area.height * 0.5).rounded()
            preview.frame = NSRect(x: 0, y: 0, width: w, height: below)
            split.frame = NSRect(x: 0, y: below, width: w, height: 1)
            scroll.frame = NSRect(x: 0, y: below + 1, width: w, height: area.height - below - 1)
            preview.isHidden = false
        } else {
            scroll.frame = area
            preview.isHidden = true
        }
        split.isHidden = preview.isHidden
        if wasHidden, !preview.isHidden { updatePreview() }
        table.tableColumns[0].width = scroll.contentSize.width
    }

    /// The block (or its hits) may have changed.
    func documentChanged() {
        guard let b = source(), let s = b.search else { return }
        if s.query != query || s.ranAt != ranAt {
            query = s.query
            ranAt = s.ranAt
            if let q = s.query, field.currentEditor() == nil {
                fieldBox.stringValue = q.text
                caseButton.state = q.caseSensitive ? .on : .off
                regexButton.state = q.regex ? .on : .off
            }
            rootLabel.stringValue = s.query?.root.abbreviatingHome ?? ""
            rows = []
            hitCount = 0
            fileCount = 0
            shownHits = 0
            preview.forget()
            preview.show(nil, query: nil, root: "")
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
        // Each file's count, in one pass (not every hit gone through again
        // for each file: thousands of each, at every batch that comes).
        var counts: [String: Int] = [:]
        for h in hits { counts[h.path, default: 0] += 1 }
        for h in hits {
            if h.path != file {
                file = h.path
                files += 1
                out.append(.file(h.path, count: counts[h.path] ?? 0))
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
        if let s = source()?.search, !s.running { restoreState() }
        updatePreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        keeper.note(["draft": field.stringValue == query?.text ? "" : field.stringValue])
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

    /// Debugging: the preview, and a hit chosen (its index among the hits),
    /// or "query <text>" asked.
    func debugPreview(_ arg: String) -> String {
        if arg.hasPrefix("query ") {
            fieldBox.stringValue = String(arg.dropFirst(6))
            fieldEntered()
            return "asked"
        }
        if let n = Int(arg) {
            let hitRows = rows.indices.filter { if case .hit = rows[$0] { return true } else { return false } }
            if n < hitRows.count { table.selectRowIndexes([hitRows[n]], byExtendingSelection: false); table.scrollRowToVisible(hitRows[n]) }
        }
        return (preview.isHidden ? "hidden " : "") + preview.debugState
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// A file or a hit dragged out: the file, as a folder's entry is.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .file(path, _): return Drags.path?(path, false, block.host, Drags.modifiers)
        case let .hit(hit): return Drags.path?(hit.path, false, block.host, Drags.modifiers)
        }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .file = rows[row] { return FileHeaderRowView() }
        return SelectionRowView()
    }

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
            s.append(NSAttributedString(string: "  \(count)", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = s.truncatingTail()
        case let .hit(h):
            let s = NSMutableAttributedString(string: "\(h.line)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.secondaryText])
            let line = h.text.trimmingCharacters(in: .whitespaces)
            let body = NSMutableAttributedString(string: line, attributes: [.font: UIType.body, .foregroundColor: Theme.text])
            for r in query?.ranges(in: line, limit: 20) ?? [] {
                body.addAttribute(.backgroundColor, value: TextView.matchColor, range: r)
            }
            s.append(body)
            f.attributedStringValue = s.truncatingTail()
        }
        return cell
    }
}

/// A file's header among the hits: opaque, so that floating at the top it
/// stands in for the file scrolled under it rather than over its lines,
/// and the next file's header pushes it off as it arrives; a hairline
/// beneath while it floats.
final class FileHeaderRowView: NSTableRowView {
    override var isFloating: Bool { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        guard isFloating else { return }
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
