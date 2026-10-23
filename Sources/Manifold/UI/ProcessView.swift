import AppKit
import ManifoldCore

protocol ProcessViewDelegate: AnyObject {
    func processViewRefresh(_ view: ProcessView)
    func processView(_ view: ProcessView, signal pid: Int32, _ signal: Int32)
    func processView(_ view: ProcessView, goTo block: BlockID)
}

/// The process lens (DESIGN.md §7.5): the trees of processes under the
/// host's terminals and agents, by block, each with its executable's
/// path, listed again every few seconds while shown. A field narrows
/// them; any number selected (⇧, ⌘, ⌘A) are ended (SIGTERM, End or ⌫)
/// or killed (SIGKILL, Force End or ⌥⌫, after asking) together, from
/// the buttons or a row's menu; a double-click (or ↩) goes to the block
/// a process runs under.
final class ProcessView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: ProcessViewDelegate?
    var source: () -> Block? = { nil }

    private let fieldBox = FlatFieldBox(fontSize: 12)
    private var field: FlatField { fieldBox.field }
    private let status = NSTextField(labelWithString: "")
    private let end = FlatButton("End")
    private let kill = FlatButton("Force End")
    private let scroll = ClippingScrollView()
    private let table = NSTableView()
    private let rowMenu = NSMenu()
    private var all: [ProcessEntry] = []
    /// A block's heading, or a process at a depth under it.
    enum Row { case group(BlockID), process(ProcessEntry, depth: Int) }
    private var shown: [Row] = []
    private var listedAt: Stamp?
    /// "Reading…" until the host first lists them.
    private let note = BusyNote()
    private var timer: Timer?
    /// What to call a block (the host's blocks are the controller's to know).
    var blockTitle: (BlockID) -> String? = { _ in nil }

    var focusView: NSView { table }
    var isDead: Bool { false }

    static let rowHeight: CGFloat = 17

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        field.placeholderString = "Filter"
        field.delegate = self
        fieldBox.onChange = { [weak self] in self?.filterChanged() }
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        for (b, action) in [(end, #selector(endClicked)), (kill, #selector(killClicked))] {
            b.target = self
            b.action = action
            b.isEnabled = false
        }
        for v in [fieldBox, status, end, kill] { addSubview(v) }
        for (id, title, width) in [("command", "Command", 300.0), ("pid", "PID", 56.0), ("cpu", "CPU", 48.0), ("memory", "Memory", 64.0), ("path", "Path", 300.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 40
            table.addTableColumn(c)
        }
        table.target = self
        table.doubleAction = #selector(rowOpened)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 4, height: 0)
        table.style = .plain
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        rowMenu.delegate = self
        table.menu = rowMenu
        Flat.headers(table)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        addSubview(note)
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        timer?.invalidate()
        keeper.flush()
    }

    private func restoreState() {
        guard !keeper.restored, !all.isEmpty else { return }
        keeper.restored = true
        if let f = keeper.value("filter"), f != field.stringValue {
            fieldBox.stringValue = f
            refilter()
        }
        if let s = keeper.value("selected") {
            let pids = Set(s.split(separator: ",").compactMap { Int32($0) })
            select(pids)
        }
        if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
    }

    /// The controls go under the pill's band, not beside it: the filter
    /// at the left and the buttons at the right while there's room for
    /// both; in a narrow tile the buttons take a row of their own under
    /// the filter, and the status gives way.
    override func layout() {
        super.layout()
        let w = bounds.width, top = bounds.height - GridView.band - 2
        let buttons: CGFloat = 84 + 6 + 56
        let wide = w >= 12 + 140 + 12 + buttons + 12
        let fieldWidth = wide ? min(220, w - buttons - 36) : w - 24
        let fh = Flat.fieldHeight, bh = Flat.buttonHeight
        fieldBox.frame = NSRect(x: 12, y: top - fh, width: max(fieldWidth, 60), height: fh)
        let buttonY = wide ? top - fh + (fh - bh) / 2 : top - fh - 6 - bh
        kill.frame = NSRect(x: max(w - 12 - 84, 12), y: buttonY, width: 84, height: bh)
        if wide || w >= 12 + 56 + 6 + 84 + 12 {
            end.frame = NSRect(x: kill.frame.minX - 6 - 56, y: buttonY, width: 56, height: bh)
        } else {
            // Too narrow for both side by side: End on a row of its own.
            end.frame = NSRect(x: 12, y: buttonY - 6 - bh, width: 56, height: bh)
        }
        let statusWidth = wide ? end.frame.minX - fieldBox.frame.maxX - 24 : 0
        status.isHidden = statusWidth < 80
        status.frame = NSRect(x: fieldBox.frame.maxX + 12, y: top - fh / 2 - 8, width: max(0, statusWidth), height: 15)
        let bottom = (wide ? fieldBox.frame.minY : end.frame.minY) - 6
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, bottom))
        note.frame = scroll.frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        delegate?.processViewRefresh(self)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.window != nil else { return }
            self.delegate?.processViewRefresh(self)
        }
    }

    /// While the filter is being typed, the pill is out of its way.
    var caretRectInWindow: NSRect? {
        guard field.currentEditor() != nil else { return nil }
        return field.convert(field.bounds, to: nil)
    }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("Refresh Now", symbol: "arrow.clockwise") { [weak self] in
            guard let self else { return }
            self.delegate?.processViewRefresh(self)
        }, ClosureMenuItem("Filter…", symbol: "line.3.horizontal.decrease.circle") { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
        }]
    }

    func documentChanged() {
        note.set(source()?.processes?.listedAt == nil ? .busy("Reading…") : .idle)
        guard let b = source(), let p = b.processes else { return }
        guard p.listedAt != listedAt else { return }
        listedAt = p.listedAt
        all = p.entries
        refilter()
    }

    /// The rows: each block's heading, then its tree, parents before
    /// children, children set in; with a filter, only the processes that
    /// match, under their blocks.
    private func refilter() {
        let q = field.stringValue.lowercased()
        let matching = q.isEmpty ? all : all.filter { $0.command.lowercased().contains(q) || ($0.path?.lowercased().contains(q) ?? false) || String($0.pid) == q }
        var rows: [Row] = []
        var seen: [BlockID] = []
        for e in all { if let b = e.block, !seen.contains(b) { seen.append(b) } }
        var count = 0
        for b in seen {
            let mine = matching.filter { $0.block == b }
            guard !mine.isEmpty else { continue }
            rows.append(.group(b))
            if q.isEmpty {
                let pids = Set(mine.map(\.pid))
                func walk(_ parent: Int32?, depth: Int) {
                    for e in mine where (parent == nil ? !pids.contains(e.parent) : e.parent == parent) {
                        rows.append(.process(e, depth: depth))
                        count += 1
                        walk(e.pid, depth: depth + 1)
                    }
                }
                walk(nil, depth: 0)
            } else {
                for e in mine { rows.append(.process(e, depth: 0)); count += 1 }
            }
        }
        let keep = selectedPIDs
        shown = rows
        table.reloadData()
        select(Set(keep))
        let listed = q.isEmpty ? "\(all.count) processes under \(seen.count) block\(seen.count == 1 ? "" : "s")" : "\(count) of \(all.count)"
        status.stringValue = listed
        selectionChanged()
        restoreState()
    }

    /// Selects the rows of these processes, those still listed.
    private func select(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        var indexes = IndexSet()
        for (i, r) in shown.enumerated() { if case let .process(e, _) = r, pids.contains(e.pid) { indexes.insert(i) } }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    /// Double-clicked, or ↩: the block the row's process runs under.
    @objc private func rowOpened() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < shown.count else { return }
        switch shown[row] {
        case let .group(b): delegate?.processView(self, goTo: b)
        case let .process(e, _): if let b = e.block { delegate?.processView(self, goTo: b) }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: rowOpened()
        case 51, 117:
            // ⌫: End the selection; ⌥⌫: Force End.
            if event.modifierFlags.contains(.option) { killClicked() } else { endClicked() }
        default: super.keyDown(with: event)
        }
    }

    private func filterChanged() {
        refilter()
        keeper.note(["filter": field.stringValue])
    }

    /// Only processes select; a heading is for going to its block.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .process = shown[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
        keeper.note(["selected": selectedPIDs.map { "\($0)" }.joined(separator: ",")])
    }

    /// The buttons name how many they'd act on.
    private func selectionChanged() {
        let n = selectedPIDs.count
        end.isEnabled = n > 0
        kill.isEnabled = n > 0
        end.title = n > 1 ? "End \(n)" : "End"
        kill.title = n > 1 ? "Force End \(n)" : "Force End"
        needsLayout = true
    }

    private var selectedPIDs: [Int32] {
        table.selectedRowIndexes.compactMap { i in
            guard i < shown.count, case let .process(e, _) = shown[i] else { return nil }
            return e.pid
        }
    }

    @objc private func endClicked() {
        for pid in selectedPIDs { delegate?.processView(self, signal: pid, SIGTERM) }
    }

    @objc private func killClicked() {
        let pids = selectedPIDs
        guard !pids.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = pids.count == 1 ? "Force End process \(pids[0])?" : "Force End \(pids.count) processes?"
        alert.informativeText = pids.count == 1 ? "It won't get to save anything." : "They won't get to save anything."
        alert.addButton(withTitle: "Force End")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            for pid in pids { self.delegate?.processView(self, signal: pid, SIGKILL) }
        }
    }

    // MARK: A row's menu

    /// Right-clicked: a row outside the selection becomes it, so the
    /// menu acts on what's under the pointer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < shown.count else { return }
        if case .process = shown[row], !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let n = selectedPIDs.count
        if n > 0 {
            menu.addItem(ClosureMenuItem(n > 1 ? "End \(n) Processes" : "End Process", symbol: "stop.circle") { [weak self] in self?.endClicked() })
            menu.addItem(ClosureMenuItem(n > 1 ? "Force End \(n) Processes" : "Force End Process", symbol: "xmark.octagon") { [weak self] in self?.killClicked() })
            menu.addItem(.separator())
        }
        let block: BlockID? = switch shown[row] { case let .group(b): b; case let .process(e, _): e.block }
        if let block {
            menu.addItem(ClosureMenuItem("Go to \(blockTitle(block) ?? "Block")", symbol: "arrow.right.circle") { [weak self] in
                guard let self else { return }
                self.delegate?.processView(self, goTo: block)
            })
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "command"
        let cell = tableView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("cell-" + id)
            let f = NSTextField(labelWithString: "")
            f.alignment = id == "command" || id == "path" ? .left : .right
            f.lineBreakMode = .byTruncatingTail
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let numeric = id == "pid" || id == "cpu" || id == "memory"
        cell.textField?.font = numeric ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        cell.textField?.textColor = Theme.text
        switch shown[row] {
        case let .group(b):
            cell.textField?.stringValue = id == "command" ? (blockTitle(b) ?? b.description) : ""
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = Theme.secondaryText
        case let .process(e, depth):
            switch id {
            case "pid": cell.textField?.stringValue = "\(e.pid)"
            case "cpu": cell.textField?.stringValue = e.cpu < 0.05 ? "–" : String(format: "%.1f", e.cpu)
            case "memory": cell.textField?.stringValue = e.memory >= 1_048_576 ? String(format: "%.1f GB", Double(e.memory) / 1_048_576) : e.memory >= 1024 ? "\(e.memory / 1024) MB" : "\(e.memory) KB"
            case "path":
                cell.textField?.stringValue = e.path?.abbreviatingHome ?? ""
                cell.textField?.textColor = Theme.secondaryText
            default: cell.textField?.stringValue = String(repeating: "  ", count: depth) + (depth > 0 ? "└ " : "") + e.command
            }
        }
        return cell
    }
}
