import AppKit
import ManifoldCore

/// A project's search on its homepage (§2.6): what's typed in its header's
/// field found as symbols (from its index and its language servers, each
/// marked by which), files by name, and the files' text, each under its
/// heading as it comes, best first — in the homepage's place for files.
/// The search is a block of its own (`SearchState`, its names and hits as
/// the host found them), so Open in a Tile shows the same beside, to keep.
final class ProjectSearchView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Found: Equatable {
        case symbol(SymbolHit)
        /// A file, relative to the root.
        case file(String)
        case hit(SearchHit)
    }
    /// Something chosen (⏎, a click): gone to.
    var onOpen: ((Found) -> Void)?
    /// Open in a Tile: the search's block, beside.
    var onPopOut: (() -> Void)?
    /// ⎋ from the results: back to the field.
    var onBack: (() -> Void)?

    private enum Row {
        case heading(String)
        case found(Found)
        case more(String)
    }
    private var rows: [Row] = []
    private let status = NSTextField.label(font: UIType.detail, color: Theme.secondaryText)
    private let popOut = FlatButton("Open in a Tile", symbol: "arrow.up.right.square", font: UIType.detail)
    private let scroll = ClippingScrollView()
    private let table = FlatTable(column: "found")
    private var state: SearchState?
    private var root = ""
    /// The host its project is on: whose files its rows drag.
    var host = Drags.localHost
    /// The tile it's in: what its rows open beside.
    var placement: PlacementID?
    /// How many of each are shown here; the tile has them all.
    static let symbolsShown = 8, filesShown = 6, hitsShown = 80

    var focusView: NSView { table }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        popOut.target = self
        popOut.action = #selector(popOutClicked)
        popOut.toolTip = "This search in a tile of its own, beside: every symbol, file and line found, kept"
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onKey = { [weak self] event in self?.key(event.keyCode) ?? false }
        // Several chosen (⌘-, ⇧-click): dragged together, not opened.
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        scroll.hold(table)
        for v in [status, popOut, scroll] as [NSView] { addSubview(v) }
        // Right-clicked: what's there, as ⌘-right-click has a link.
        LinkMenus.attach(to: table, target: { [weak self] in self?.linkTarget($0) }, from: { [weak self] _ in (self?.placement, self?.host) })
    }

    /// What a row goes to, as a link names it: a file, at its line.
    private func linkTarget(_ row: Int) -> String? {
        guard rows.indices.contains(row), case let .found(f) = rows[row] else { return nil }
        func full(_ p: String) -> String { p.hasPrefix("/") ? p : root.appendingPathComponent(p) }
        switch f {
        case let .symbol(h): return full(h.path) + ":\(h.line + 1)"
        case let .file(p): return full(p)
        case let .hit(h): return full(h.path) + ":\(h.line)"
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func popOutClicked() { onPopOut?() }

    override func layout() {
        super.layout()
        let w = bounds.width, top = bounds.height
        popOut.sizeToFit()
        popOut.frame.origin = NSPoint(x: w - 10 - popOut.frame.width, y: top - 6 - popOut.frame.height)
        status.frame = NSRect(x: 14, y: popOut.frame.midY - 8, width: popOut.frame.minX - 22, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, popOut.frame.minY - 4))
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    /// The search as the host has it now.
    func show(_ s: SearchState?, root: String) {
        guard s != state || root != self.root else { return }
        let selected = selectedFound
        let chosen: [Found] = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? { if case let .found(f) = $0 { f } else { nil } }(rows[$0]) : nil }
        state = s
        self.root = root
        var out: [Row] = []
        if let symbols = s?.symbols, !symbols.isEmpty {
            out.append(.heading("Symbols"))
            out += symbols.prefix(Self.symbolsShown).map { .found(.symbol($0)) }
            if symbols.count > Self.symbolsShown { out.append(.more("\(symbols.count - Self.symbolsShown) more symbols")) }
        }
        if let files = s?.files, !files.isEmpty {
            out.append(.heading("Files"))
            out += files.prefix(Self.filesShown).map { .found(.file($0)) }
            if files.count > Self.filesShown { out.append(.more("\(files.count - Self.filesShown) more files")) }
        }
        if var hits = s?.hits, !hits.isEmpty {
            // A line once, however many times it matches.
            var lines: Set<String> = []
            hits = hits.filter { lines.insert("\($0.path):\($0.line)").inserted }
            let files = Set(hits.map(\.path)).count
            out.append(.heading("Text — \(hits.count)\(s?.truncated == true ? "+" : "") in \(files) file\(files == 1 ? "" : "s")"))
            out += hits.prefix(Self.hitsShown).map { .found(.hit($0)) }
            if hits.count > Self.hitsShown { out.append(.more("\(hits.count - Self.hitsShown) more lines")) }
        }
        rows = out
        table.reloadData()
        // Several chosen stay chosen, where they're still there.
        let again = IndexSet(rows.indices.filter { if case let .found(f) = rows[$0] { chosen.contains(f) } else { false } })
        if chosen.count > 1, again.count > 1 {
            table.selectRowIndexes(again, byExtendingSelection: false)
        // The one chosen stays chosen, where it's still there.
        } else if let selected, let i = rows.firstIndex(where: { if case .found(selected) = $0 { return true } else { return false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        status.stringValue = words(s)
    }

    private func words(_ s: SearchState?) -> String {
        guard let s, let q = s.query else { return "" }
        let kinds = Set(q.kinds ?? ["text"])
        let looking = (kinds.contains("symbols") && s.symbols == nil) || (kinds.contains("files") && s.files == nil) || s.running
        let n = (s.symbols?.count ?? 0) + (s.files?.count ?? 0) + s.hits.count
        if n == 0 { return looking ? "Looking…" : s.error ?? "Nothing found for “\(q.text)”" }
        var parts: [String] = []
        if let c = s.symbols?.count, c > 0 { parts.append(c == 1 ? "1 symbol" : "\(c) symbols") }
        if let c = s.files?.count, c > 0 { parts.append(c == 1 ? "1 file" : "\(c) files") }
        let lines = Set(s.hits.map { "\($0.path):\($0.line)" }).count
        if lines > 0 { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
        return parts.joined(separator: ", ") + (looking ? ", looking…" : "")
    }

    // MARK: Choosing

    private var selectedFound: Found? {
        let r = table.selectedRow
        guard r >= 0, r < rows.count, case let .found(f) = rows[r] else { return nil }
        return f
    }

    /// The first found chosen (↓ from the field), or the best opened (⏎ there).
    func selectFirst() {
        guard let i = rows.firstIndex(where: { if case .found = $0 { return true } else { return false } }) else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    /// ⏎ in the field: the one chosen, else the best, gone to.
    func openChosen() {
        if selectedFound == nil { selectFirst() }
        if let f = selectedFound { onOpen?(f) }
    }

    var hasFound: Bool { rows.contains { if case .found = $0 { return true } else { return false } } }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty != false else { return }
        switch rows[r] {
        case let .found(f): onOpen?(f)
        case .more: onPopOut?()
        case .heading: break
        }
    }

    /// ⏎ opens, ⎋ goes back to the field, ↑ past the first too.
    private func key(_ code: UInt16) -> Bool {
        switch code {
        case 36, 76: openChosen(); return true
        case 53: onBack?(); return true
        case 126:
            let first = rows.firstIndex { if case .found = $0 { return true } else { return false } }
            if table.selectedRow <= (first ?? 0) { onBack?(); return true }
            return false
        default: return false
        }
    }

    // MARK: The table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// Debugging: found rows `picks` (counted among those found) chosen
    /// together; what dragging them writes.
    func debugChoose(_ picks: [Int]) -> String {
        let found = rows.indices.filter { if case .found = rows[$0] { true } else { false } }
        table.selectRowIndexes(IndexSet(picks.filter(found.indices.contains).map { found[$0] }), byExtendingSelection: false)
        return debugState
    }

    var debugDragItems: [NSPasteboardWriting] { table.debugDragItems }

    /// A symbol, a line dragged out: its file at its line; a file, the file.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        Drags.writer(rowItem(row))
    }

    private func rowItem(_ row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), case let .found(f) = rows[row] else { return nil }
        switch f {
        case let .symbol(h): return Drags.place?(Place(file: h.path, on: host, at: .line(h.line + 1), name: h.name), nil)
        case let .file(p): return Drags.file(root.appendingPathComponent(p), isDirectory: false, on: host)
        case let .hit(h): return Drags.place?(Place(file: h.path, on: host, at: .line(h.line)), nil)
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if rows.indices.contains(row), case .heading = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if rows.indices.contains(row), case .found = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return TileMetrics.nameRow }
        switch rows[row] {
        case .heading: return TileMetrics.sectionHeight(first: row == 0)
        case .found(.symbol): return 38
        default: return TileMetrics.nameRow
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if rows.indices.contains(row), case .heading = rows[row] { return FileHeaderRowView() }
        return SelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("found"), owner: nil) as? FoundCell ?? FoundCell()
        guard rows.indices.contains(row) else { return cell }
        let query = state?.query
        switch rows[row] {
        case let .heading(words):
            cell.set(NSAttributedString(string: words, attributes: [.font: UIType.caption, .foregroundColor: Theme.secondaryText]), nil, heading: true)
        case let .more(words):
            cell.set(NSAttributedString(string: words + " — Open in a Tile", attributes: [.font: UIType.detail, .foregroundColor: Tints.accentText]), nil)
        case let .found(.symbol(h)):
            let a = NSMutableAttributedString()
            if !h.kind.isEmpty {
                a.append(NSAttributedString(string: h.kind + "  ", attributes: [.font: NSFont.systemMono(ofSize: 10.5, weight: .medium), .foregroundColor: Theme.secondaryText]))
            }
            let name = NSMutableAttributedString(string: h.name, attributes: [.font: UIType.title, .foregroundColor: Theme.text])
            Self.mark(query?.text ?? "", in: name)
            a.append(name)
            if !h.container.isEmpty {
                a.append(NSAttributedString(string: "  in \(h.container)", attributes: [.font: UIType.detail, .foregroundColor: Theme.secondaryText]))
            }
            a.append(NSAttributedString(string: "   " + (h.source == .index ? "index" : "server"),
                                        attributes: [.font: UIType.count, .foregroundColor: Theme.secondaryText.withAlphaComponent(0.8)]))
            let under = NSMutableAttributedString(string: relative(h.path) + ":\(h.line + 1)", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])
            if !h.text.isEmpty {
                under.append(NSAttributedString(string: "   " + h.text, attributes: [.font: NSFont.systemMono(ofSize: 10.5, weight: .regular), .foregroundColor: Theme.secondaryText]))
            }
            cell.set(a.truncatingTail(), under.truncatingTail())
        case let .found(.file(path)):
            let a = NSMutableAttributedString(string: path, attributes: [.font: UIType.body, .foregroundColor: Theme.text])
            for i in FileFinder.positions(query?.text ?? "", path) ?? [] where i < path.count {
                let r = NSRange(path.index(path.startIndex, offsetBy: i)..<path.index(path.startIndex, offsetBy: i + 1), in: path)
                a.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .bold), range: r)
            }
            cell.set(a.truncatingHead(), nil)
        case let .found(.hit(h)):
            let a = NSMutableAttributedString(string: relative(h.path) + ":\(h.line)  ", attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])
            let line = h.text.trimmingCharacters(in: .whitespaces)
            let body = NSMutableAttributedString(string: line, attributes: [.font: NSFont.systemMono(ofSize: 11.5, weight: .regular), .foregroundColor: Theme.text])
            for r in query?.ranges(in: line, limit: 20) ?? [] { body.addAttribute(.backgroundColor, value: TextView.matchColor, range: r) }
            a.append(body)
            cell.set(a.truncatingTail(), nil)
        }
        return cell
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path.abbreviatingHome
    }

    /// The query's letters in a name, emphasised where they run together.
    private static func mark(_ query: String, in s: NSMutableAttributedString) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let r = (s.string as NSString).range(of: q.split(separator: ".").last.map(String.init) ?? q, options: .caseInsensitive)
        if r.location != NSNotFound { s.addAttribute(.backgroundColor, value: TextView.matchColor, range: r) }
    }

    var debugState: String {
        ([status.stringValue] + rows.map { r -> String in
            switch r {
            case let .heading(w): return "## " + w
            case let .more(w): return "… " + w
            case let .found(.symbol(h)): return "\(h.kind) \(h.qualified) \(relative(h.path)):\(h.line + 1) [\(h.source.rawValue)]"
            case let .found(.file(p)): return "file \(p)"
            case let .found(.hit(h)): return "\(relative(h.path)):\(h.line) \(h.text.trimmingCharacters(in: .whitespaces))"
            }
        } + (table.selectedRowIndexes.count > 1 ? ["chosen \(table.selectedRowIndexes.count)"] : selectedFound.map { ["chosen \($0)"] } ?? [])).joined(separator: "\n")
    }
}

/// A row of results: a line, and a second under it for a symbol.
private final class FoundCell: NSTableCellView {
    private let top = NSTextField(labelWithString: "")
    private let bottom = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .init("found")
        for f in [top, bottom] {
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            addSubview(f)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A heading's words in the band at the foot of its row, under its air.
    private var heading = false

    func set(_ line: NSAttributedString, _ under: NSAttributedString?, heading: Bool = false) {
        self.heading = heading
        top.attributedStringValue = line
        bottom.attributedStringValue = under ?? NSAttributedString()
        bottom.isHidden = under == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width - 28
        if bottom.isHidden {
            let band = heading ? min(bounds.height, TileMetrics.sectionRow) : bounds.height
            top.frame = NSRect(x: 14, y: (band - 17) / 2, width: w, height: 17)
        } else {
            top.frame = NSRect(x: 14, y: bounds.height - 4 - 17, width: w, height: 17)
            bottom.frame = NSRect(x: 14, y: 4, width: w, height: 15)
        }
    }
}
