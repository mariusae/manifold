import AppKit
import ManifoldCore

protocol ProcessViewDelegate: AnyObject {
    func processViewRefresh(_ view: ProcessView)
    func processView(_ view: ProcessView, signal pid: Int32, _ signal: Int32)
}

/// The process lens (DESIGN.md §7.5): the host's processes as `ps` lists
/// them, listed again every few seconds while shown; a field narrows them,
/// the columns sort, and the selected one can be ended (SIGTERM) or
/// killed (SIGKILL).
final class ProcessView: NSView, PaneContent, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
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
    private var shown: [ProcessEntry] = []
    private var listedAt: Stamp?
    private var timer: Timer?
    private var sortKey = "cpu"
    private var ascending = false

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
        for (id, title, width) in [("pid", "PID", 60.0), ("cpu", "CPU", 55.0), ("memory", "Memory", 75.0), ("user", "User", 80.0), ("command", "Command", 400.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "command" || id == "user" || id == "pid")
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { timer?.invalidate() }

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

    private func refilter() {
        let q = field.stringValue.lowercased()
        var rows = q.isEmpty ? all : all.filter { $0.command.lowercased().contains(q) || $0.user.lowercased().contains(q) || String($0.pid) == q }
        rows.sort { a, b in
            let less: Bool
            switch sortKey {
            case "pid": less = a.pid < b.pid
            case "memory": less = a.memory < b.memory
            case "user": less = a.user < b.user
            case "command": less = a.command.lowercased() < b.command.lowercased()
            default: less = a.cpu < b.cpu
            }
            return ascending ? less : !less
        }
        let selectedPID = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].pid : nil
        shown = rows
        table.reloadData()
        if let selectedPID, let i = shown.firstIndex(where: { $0.pid == selectedPID }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        status.stringValue = q.isEmpty ? "\(all.count) processes" : "\(shown.count) of \(all.count)"
        end.isEnabled = table.selectedRow >= 0
        kill.isEnabled = table.selectedRow >= 0
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        ascending = d.ascending
        refilter()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        end.isEnabled = table.selectedRow >= 0
        kill.isEnabled = table.selectedRow >= 0
    }

    private var selectedPID: Int32? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row].pid : nil
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
            f.font = id == "command" || id == "user" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.alignment = id == "command" || id == "user" ? .left : .right
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
        let e = shown[row]
        switch id {
        case "pid": cell.textField?.stringValue = "\(e.pid)"
        case "cpu": cell.textField?.stringValue = String(format: "%.1f", e.cpu)
        case "memory": cell.textField?.stringValue = e.memory >= 1_048_576 ? String(format: "%.1f GB", Double(e.memory) / 1_048_576) : e.memory >= 1024 ? "\(e.memory / 1024) MB" : "\(e.memory) KB"
        case "user": cell.textField?.stringValue = e.user
        default: cell.textField?.stringValue = e.command
        }
        return cell
    }
}
