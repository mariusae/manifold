import AppKit
import ManifoldCore

protocol ProcessViewDelegate: AnyObject {
    func processViewRefresh(_ view: ProcessView)
    func processView(_ view: ProcessView, signal pid: Int32, _ signal: Int32)
    func processView(_ view: ProcessView, goTo block: BlockID)
}

/// The process lens (DESIGN.md §7.5): the trees of processes under the
/// host's terminals and agents, by block, each with its executable's
/// path, listed again every few seconds while shown; a field narrows
/// them, the selected one can be ended (SIGTERM) or killed (SIGKILL), and
/// a double-click (or ↩) goes to the block a process runs under.
final class ProcessView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: ProcessViewDelegate?
    var source: () -> Block? = { nil }

    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let end = NSButton(title: "End", target: nil, action: nil)
    private let kill = NSButton(title: "Force End", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var all: [ProcessEntry] = []
    /// A block's heading, or a process at a depth under it.
    enum Row { case group(BlockID), process(ProcessEntry, depth: Int) }
    private var shown: [Row] = []
    private var listedAt: Stamp?
    private var timer: Timer?
    /// What to call a block (the host's blocks are the controller's to know).
    var blockTitle: (BlockID) -> String? = { _ in nil }

    var focusView: NSView { table }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        field.placeholderString = "Filter"
        field.font = .systemFont(ofSize: 12.5)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = Theme.secondaryText
        for (b, action) in [(end, #selector(endClicked)), (kill, #selector(killClicked))] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
            b.action = action
            b.isEnabled = false
        }
        for v in [field, status, end, kill] { addSubview(v) }
        for (id, title, width) in [("command", "Command", 380.0), ("pid", "PID", 60.0), ("cpu", "CPU", 55.0), ("memory", "Memory", 75.0), ("path", "Path", 300.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.target = self
        table.doubleAction = #selector(rowOpened)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
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

    func destroy() {
        timer?.invalidate()
        keeper.flush()
    }

    private func restoreState() {
        guard !keeper.restored, !all.isEmpty else { return }
        keeper.restored = true
        if let f = keeper.value("filter"), f != field.stringValue {
            field.stringValue = f
            refilter()
        }
        if let pid = keeper.int("selected"), let i = shown.firstIndex(where: { if case let .process(e, _) = $0 { return Int(e.pid) == pid } else { return false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, top = bounds.height - 12
        field.frame = NSRect(x: 12, y: top - 25, width: min(260, w * 0.4), height: 24)
        kill.frame = NSRect(x: w - 12 - 84, y: top - 24, width: 84, height: 22)
        end.frame = NSRect(x: kill.frame.minX - 6 - 56, y: top - 24, width: 56, height: 22)
        status.frame = NSRect(x: field.frame.maxX + 12, y: top - 22, width: max(0, end.frame.minX - field.frame.maxX - 24), height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, top - 36))
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

    func documentChanged() {
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
        let selectedPID = self.selectedPID
        shown = rows
        table.reloadData()
        if let selectedPID, let i = shown.firstIndex(where: { if case let .process(e, _) = $0 { return e.pid == selectedPID } else { return false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        status.stringValue = q.isEmpty ? "\(all.count) processes under \(seen.count) block\(seen.count == 1 ? "" : "s")" : "\(count) of \(all.count)"
        end.isEnabled = selectedPID != nil
        kill.isEnabled = selectedPID != nil
        restoreState()
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
        if event.keyCode == 36 { rowOpened() } else { super.keyDown(with: event) }
    }

    func controlTextDidChange(_ obj: Notification) {
        refilter()
        keeper.note(["filter": field.stringValue])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        end.isEnabled = selectedPID != nil
        kill.isEnabled = selectedPID != nil
        keeper.note(["selected": selectedPID.map { "\($0)" } ?? ""])
    }

    private var selectedPID: Int32? {
        let row = table.selectedRow
        guard row >= 0, row < shown.count, case let .process(e, _) = shown[row] else { return nil }
        return e.pid
    }

    @objc private func endClicked() {
        guard let pid = selectedPID else { return }
        delegate?.processView(self, signal: pid, SIGTERM)
    }

    @objc private func killClicked() {
        guard let pid = selectedPID, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Force End process \(pid)?"
        alert.informativeText = "It won't get to save anything."
        alert.addButton(withTitle: "Force End")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.delegate?.processView(self, signal: pid, SIGKILL)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "command"
        let cell = tableView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("cell-" + id)
            let f = NSTextField(labelWithString: "")
            f.font = id == "command" || id == "path" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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
        cell.textField?.font = .systemFont(ofSize: 12)
        cell.textField?.textColor = Theme.text
        switch shown[row] {
        case let .group(b):
            cell.textField?.stringValue = id == "command" ? (blockTitle(b) ?? b.description) : ""
            cell.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
        case let .process(e, depth):
            switch id {
            case "pid": cell.textField?.stringValue = "\(e.pid)"
            case "cpu": cell.textField?.stringValue = String(format: "%.1f", e.cpu)
            case "memory": cell.textField?.stringValue = e.memory >= 1_048_576 ? String(format: "%.1f GB", Double(e.memory) / 1_048_576) : e.memory >= 1024 ? "\(e.memory / 1024) MB" : "\(e.memory) KB"
            case "path":
                cell.textField?.stringValue = e.path?.abbreviatingHome ?? ""
                cell.textField?.textColor = Theme.secondaryText
            default: cell.textField?.stringValue = String(repeating: "   ", count: depth) + (depth > 0 ? "└ " : "") + e.command
            }
        }
        return cell
    }
}
