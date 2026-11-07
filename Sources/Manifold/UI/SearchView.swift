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
/// for case, .* for a regular expression), the folder it's under beneath
/// it — a path to edit, and Expand to Project when it's inside a
/// repository it isn't the root of — the hits
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
    private let caseButton = FlatButton("Aa", toggles: true, font: .systemMono(ofSize: 11, weight: .medium))
    /// A symbol's search (§2.5): its name as text, its references, or its
    /// callers — the one query, asked another way.
    private let relationControl = FlatSegments(titles: ["Text", "References", "Callers"], font: UIType.detail)
    private let regexButton = FlatButton(".*", toggles: true, font: .systemMono(ofSize: 11, weight: .medium))
    /// The folder searched under: typed (↩ searches there), or widened.
    private let pathBox = FlatFieldBox(symbol: "folder", clears: false, fontSize: 12)
    private var pathField: FlatField { pathBox.field }
    private let projectButton = FlatButton("Expand to Project", symbol: "arrow.up.left.and.arrow.down.right", font: UIType.detail)
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
        /// A project's search (§2.6): its symbols and files by name, each
        /// under a heading, above the text's hits.
        case section(String)
        case symbol(SymbolHit)
        case name(String)

        /// Where it goes, as a hit: a symbol's definition, a file's top.
        func asHit(root: String) -> SearchHit? {
            switch self {
            case let .hit(h): h
            case let .symbol(s): SearchHit(path: s.path, line: s.line + 1, column: s.character + 1, text: s.text)
            case let .name(rel): SearchHit(path: root.appendingPathComponent(rel), line: 1, column: 1, text: "")
            default: nil
            }
        }
        var isHeading: Bool {
            switch self {
            case .file, .section: true
            default: false
            }
        }
    }
    private var shownNames: (symbols: [SymbolHit]?, files: [String]?) = (nil, nil)
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
        pathField.placeholderString = "Under this folder"
        pathField.font = UIType.detail
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.sendsActionOnEndEditing = false
        pathField.target = self
        pathField.action = #selector(pathEntered)
        pathField.toolTip = "The folder searched under: edit it and press Return"
        projectButton.target = self
        projectButton.action = #selector(expandToProject)
        projectButton.isHidden = true
        status.font = UIType.detail
        status.textColor = Theme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        relationControl.isHidden = true
        relationControl.onChange = { [weak self] i in self?.relationChosen(i) }
        relationControl.setToolTip("The name, as text, under the folder", forSegment: 0)
        relationControl.setToolTip("Where the symbol is used (the project's index)", forSegment: 1)
        relationControl.setToolTip("The definitions that call it, and theirs", forSegment: 2)
        for v in [fieldBox, caseButton, regexButton, pathBox, projectButton, status, relationControl] { addSubview(v) }

        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // On the tile's ground, the theme's, not the system's white.
        table.backgroundColor = .clear
        table.dataSource = self
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.delegate = self
        table.rowHeight = 20
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.target = self
        table.doubleAction = #selector(rowChosen)
        // Several hits chosen (⌘-, ⇧-click): dragged together.
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
        addSubview(split)
        preview.host = block.host
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
        if row >= 0, row < rows.count, let h = rows[row].asHit(root: query?.root ?? "") { keeper.note(["selected": "\(h.path):\(h.line)"]) }
        updatePreview()
    }

    /// The selected hit in its file; with none, the first.
    private func updatePreview() {
        guard !preview.isHidden else { return }
        let row = table.selectedRow
        var hit: SearchHit?
        let root = query?.root ?? ""
        if row >= 0, row < rows.count { hit = rows[row].asHit(root: root) }
        if hit == nil { hit = rows.lazy.compactMap { $0.asHit(root: root) }.first }
        guard hit != preview.hit else { return }
        preview.show(hit, query: query, root: query?.root ?? "")
    }

    /// Back as it was: the hit chosen, the scroll, a query typed but not asked.
    private func restoreState() {
        guard !keeper.restored else { return }
        keeper.restored = true
        if let draft = keeper.value("draft"), !draft.isEmpty, field.currentEditor() == nil { fieldBox.stringValue = draft }
        if let key = keeper.value("selected"), let i = rows.firstIndex(where: { $0.asHit(root: query?.root ?? "").map { "\($0.path):\($0.line)" == key } ?? false }) {
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
        // The folder, under the query: its field, and the button to widen it.
        let pathY = midY - Flat.fieldHeight - 6
        projectButton.sizeToFit()
        let pw = projectButton.isHidden ? 0 : projectButton.frame.width + 6
        projectButton.frame = NSRect(x: w - 12 - projectButton.frame.width, y: pathY - Flat.buttonHeight / 2,
                                     width: projectButton.frame.width, height: Flat.buttonHeight)
        pathBox.frame = NSRect(x: 12, y: pathY - Flat.fieldHeight / 2, width: max(60, w - 24 - pw), height: Flat.fieldHeight)
        status.frame = NSRect(x: 12, y: pathBox.frame.minY - 22, width: w - 24, height: 16)
        if !relationControl.isHidden {
            relationControl.sizeToFit()
            let rw = relationControl.frame.width
            relationControl.frame = NSRect(x: w - 12 - rw, y: status.frame.midY - Flat.buttonHeight / 2, width: rw, height: Flat.buttonHeight)
            status.frame.size.width = max(0, relationControl.frame.minX - 8 - 12)
        }
        // The preview beside the hits when there's width for both, else
        // beneath them when there's height, else not at all.
        let area = NSRect(x: 0, y: 0, width: w, height: max(0, status.frame.minY - 6))
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
            // Into the field unless something's being typed in it (a new
            // search, the field given the keyboard as it opens, empty).
            if let q = s.query, field.currentEditor() == nil || field.stringValue.isEmpty {
                fieldBox.stringValue = q.text
                caseButton.state = q.caseSensitive ? .on : .off
                regexButton.state = q.regex ? .on : .off
            }
            if pathField.currentEditor() == nil { pathBox.stringValue = s.query?.root.abbreviatingHome ?? "" }
            // A symbol's: asked as text, its references, or its callers.
            let hasSymbol = s.query?.symbol != nil
            if relationControl.isHidden == hasSymbol { relationControl.isHidden = !hasSymbol; needsLayout = true }
            relationControl.selectedSegment = ["references": 1, "callers": 2][s.query?.relation ?? ""] ?? 0
            // Widened already, or in no repository: nothing to expand to.
            let canExpand = s.query.map { q in q.project.map { $0 != q.root } ?? false } ?? false
            if projectButton.isHidden == canExpand {
                projectButton.isHidden = !canExpand
                needsLayout = true
            }
            projectButton.toolTip = s.query?.project.map { "Search the whole repository, \($0.abbreviatingHome)" }
            rows = []
            // The table told too: a new search with no hits yet doesn't
            // rebuild, and the table asked for its old rows (scrolled).
            table.reloadData()
            hitCount = 0
            fileCount = 0
            shownHits = 0
            shownNames = (nil, nil)
            preview.forget()
            preview.show(nil, query: nil, root: "")
        }
        if s.hits.count != shownHits || s.symbols != shownNames.symbols || s.files != shownNames.files { rebuild(s) }
        var text: String
        if s.running {
            text = hitCount == 0 ? "Searching…" : "\(hitCount) so far…"
        } else if let e = s.error {
            text = e
        } else if s.query == nil {
            text = ""
        } else {
            text = hitCount == 0 ? (s.query?.kinds?.contains("text") == false ? "" : "Nothing found") : "\(hitCount) in \(fileCount) file\(fileCount == 1 ? "" : "s")"
            if s.truncated { text += ", stopped at \(hitCount)" }
        }
        // A project's search: what it found by name, before the text.
        var names: [String] = []
        if let n = s.symbols?.count, n > 0 { names.append(n == 1 ? "1 symbol" : "\(n) symbols") }
        if let n = s.files?.count, n > 0 { names.append(n == 1 ? "1 file by name" : "\(n) files by name") }
        if !names.isEmpty { text = names.joined(separator: ", ") + (text.isEmpty ? "" : "; " + text) }
        status.stringValue = text
    }

    private func rebuild(_ s: SearchState) {
        let hits = s.hits
        // Hits come in order, grouped by file as the command walks the tree.
        var out: [Row] = []
        if let symbols = s.symbols, !symbols.isEmpty {
            out.append(.section("Symbols"))
            out += symbols.map { .symbol($0) }
        }
        if let files = s.files, !files.isEmpty {
            out.append(.section("Files"))
            out += files.map { .name($0) }
        }
        if !out.isEmpty, !hits.isEmpty { out.append(.section("Text")) }
        shownNames = (s.symbols, s.files)
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
        let selected = table.selectedRowIndexes.filteredIndexSet { $0 < rows.count }
        table.reloadData()
        if !selected.isEmpty { table.selectRowIndexes(selected, byExtendingSelection: false) }
        if !s.running { restoreState() }
        updatePreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        keeper.note(["draft": field.stringValue == query?.text ? "" : field.stringValue])
    }

    // MARK: Asking

    private var currentQuery: SearchQuery {
        var q = SearchQuery(text: field.stringValue, regex: regexButton.state == .on, caseSensitive: caseButton.state == .on,
                            root: query?.root ?? "", glob: query?.glob)
        // A project's search asks for its names again too.
        q.kinds = query?.kinds
        // A symbol's, its symbol kept — asked again as it was, unless the name typed is another.
        if let old = query, old.symbol != nil {
            q.symbol = old.symbol
            q.symbolPath = old.symbolPath
            if field.stringValue == old.text { q.relation = old.relation }
        }
        return q
    }

    /// A symbol's search asked another way: its name as text, its
    /// references, its callers.
    private func relationChosen(_ i: Int) {
        guard var q = query, q.symbol != nil else { return }
        q.relation = [nil, "references", "callers"][max(0, min(i, 2))]
        if q.relation == nil { q.caseSensitive = true }
        delegate?.searchView(self, run: q)
    }

    /// Debugging: the relation chosen (0 text, 1 references, 2 callers).
    func debugRelation(_ i: Int) { relationChosen(i) }

    /// A folder typed: the search asked again under it (`~` as home, a
    /// relative path from the folder it was under).
    @objc private func pathEntered() {
        let typed = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        var root = (typed as NSString).expandingTildeInPath
        if !root.hasPrefix("/"), let old = query?.root { root = (old as NSString).appendingPathComponent(root) }
        search(under: root)
        window?.makeFirstResponder(field)
    }

    /// Expand to Project: the search under the repository's root.
    @objc private func expandToProject() {
        guard let project = query?.project else { return }
        search(under: project)
    }

    private func search(under root: String) {
        var q = currentQuery
        q.root = root
        delegate?.searchView(self, run: q)
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
        case .symbol, .name:
            if let h = rows[row].asHit(root: query?.root ?? "") { delegate?.searchView(self, open: h.path, line: h.line) }
        case .file, .section: select(row: row + 1, forward: true)
        }
    }

    /// Selects a hit row, skipping file headers.
    private func select(row: Int, forward: Bool) {
        var r = row
        while r >= 0, r < rows.count, rows[r].isHeading { r += forward ? 1 : -1 }
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
        if arg.hasPrefix("choose ") {
            // "choose <i> <i>…": those hits chosen together.
            let hitRows = rows.indices.filter { !rows[$0].isHeading }
            let picks = arg.dropFirst(7).split(separator: " ").compactMap { Int($0) }.filter { $0 < hitRows.count }.map { hitRows[$0] }
            table.selectRowIndexes(IndexSet(picks), byExtendingSelection: false)
            return table.selectedRowIndexes.compactMap { rows[$0].asHit(root: query?.root ?? "").map { "\($0.path.lastPathComponent):\($0.line)" } }.joined(separator: " ")
        }
        if let n = Int(arg) {
            let hitRows = rows.indices.filter { !rows[$0].isHeading }
            if n < hitRows.count { table.selectRowIndexes([hitRows[n]], byExtendingSelection: false); table.scrollRowToVisible(hitRows[n]) }
        }
        return (preview.isHidden ? "hidden " : "") + preview.debugState
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// A file or a hit dragged out: the file, as a folder's entry is.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        Drags.writer(rowItem(row))
    }

    private func rowItem(_ row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case let .file(path, _): return Drags.file(path, isDirectory: false, on: block.host)
        case .section: return nil
        case .hit, .symbol, .name:
            guard let hit = rows[row].asHit(root: query?.root ?? "") else { return nil }
            return Drags.file(hit.path, isDirectory: false, on: block.host, fragment: "line=\(hit.line)")
        }
    }

    /// What dragging its chosen rows writes (debugging).
    var debugDragItems: [NSPasteboardWriting] {
        table.selectedRowIndexes.compactMap { tableView(table, pasteboardWriterForRow: $0) }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        DragPill.dress(session, from: tableView, at: screenPoint)
        DragCursor.began()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
    }
    // Each row looked up only where it is: asked for one the table still
    // thinks it has, nothing.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if rows.indices.contains(row), rows[row].isHeading { return FileHeaderRowView() }
        return SelectionRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isHeading
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && !rows[row].isHeading
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if rows.indices.contains(row), rows[row].isHeading { return 24 }
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
        guard let f = cell.textField, rows.indices.contains(row) else { return cell }
        switch rows[row] {
        case let .file(path, count):
            var shown = path
            if let root = query?.root, shown.hasPrefix(root + "/") { shown = String(shown.dropFirst(root.count + 1)) }
            let s = NSMutableAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text])
            s.append(NSAttributedString(string: "  \(count)", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = s.truncatingTail()
        case let .hit(h):
            let s = NSMutableAttributedString(string: "\(h.line)  ", attributes: [.font: NSFont.systemDigits(ofSize: 11), .foregroundColor: Theme.secondaryText])
            let line = h.text.trimmingCharacters(in: .whitespaces)
            let body = NSMutableAttributedString(string: line, attributes: [.font: UIType.body, .foregroundColor: Theme.text])
            for r in query?.ranges(in: line, limit: 20) ?? [] {
                body.addAttribute(.backgroundColor, value: TextView.matchColor, range: r)
            }
            s.append(body)
            // Where it is, said: the definition it's in (a relation's hit).
            if let c = h.context { s.append(NSAttributedString(string: "  " + c, attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])) }
            f.attributedStringValue = s.truncatingTail()
        case let .section(words):
            f.attributedStringValue = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.secondaryText])
        case let .symbol(h):
            let s = NSMutableAttributedString(string: h.kind.isEmpty ? "" : h.kind + "  ", attributes: [.font: NSFont.systemMono(ofSize: 10.5, weight: .medium), .foregroundColor: Theme.secondaryText])
            s.append(NSAttributedString(string: h.qualified, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.text]))
            var at = h.path
            if let root = query?.root, at.hasPrefix(root + "/") { at = String(at.dropFirst(root.count + 1)) }
            s.append(NSAttributedString(string: "  \(at):\(h.line + 1)  \(h.source == .index ? "index" : "server")", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText]))
            f.attributedStringValue = s.truncatingTail()
        case let .name(rel):
            f.attributedStringValue = NSAttributedString(string: rel, attributes: [.font: UIType.body, .foregroundColor: Theme.text])
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
