import AppKit
import ManifoldCore

protocol ProcessViewDelegate: AnyObject {
    func processViewRefresh(_ view: ProcessView)
    func processView(_ view: ProcessView, signal pid: Int32, _ signal: Int32)
    func processView(_ view: ProcessView, goTo block: BlockID)
}

/// The process lens (DESIGN.md §7.5), in two modes. Blocks: the trees of
/// processes under the host's terminals and agents, by block, each with
/// its executable's path, listed again every few seconds while shown.
/// Machine: the whole machine — its cores, memory, network and disks, the
/// last five minutes of each (`MachinePanels`) — over every process on it,
/// the busiest first (or as a column's header sorts them), read every two
/// seconds while shown. A field narrows them; any number selected (⇧, ⌘,
/// ⌘A) are ended (SIGTERM, End or ⌫) or killed (SIGKILL, Force End or
/// ⌥⌫, after asking) together, from the buttons or a row's menu; a
/// double-click (or ↩) goes to the block a process runs under.
final class ProcessView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: ProcessViewDelegate?
    var source: () -> Block? = { nil }

    enum Mode: String { case blocks, machine }
    private(set) var mode = Mode.blocks
    private let modes = FlatSegments(titles: ["Blocks", "Machine"], font: UIType.body)
    private let panels = MachinePanels()
    /// The host's client, for the machine (it keeps the history).
    var client: () -> HostClient? = { nil }
    private var machineQuery = MachineQuery(limit: 150)
    private var machine: MachineSample?
    private var asked: Date?
    private let fieldBox = FlatFieldBox(fontSize: 12)
    private var field: FlatField { fieldBox.field }
    private let status = NSTextField(labelWithString: "")
    private let end = FlatButton("End")
    private let kill = FlatButton("Force End")
    private let scroll = ClippingScrollView()
    private let table = NSTableView()
    private let rowMenu = NSMenu()
    private var all: [ProcessEntry] = []
    /// A block's heading, or a process at a depth under it; or, the
    /// machine's, a process.
    /// A block's heading, its processes, and a foot closing its panel.
    enum Row { case group(BlockID), process(ProcessEntry, depth: Int), foot(BlockID), machine(MachineProcess) }
    private var shown: [Row] = []
    private var listedAt: Stamp?
    /// "Reading…" until the host first lists them.
    private let note = BusyNote()
    private var timer: Timer?
    /// What to call a block, and its summary card (the host's blocks are
    /// the controller's to know).
    var blockTitle: (BlockID) -> String? = { _ in nil }
    var blockCard: (BlockID) -> SummaryCardContent? = { _ in nil }
    /// Each heading's card, as read at the last listing.
    private var cards: [BlockID: SummaryCardContent] = [:]

    var focusView: NSView { table }
    var isDead: Bool { false }

    static let rowHeight: CGFloat = 17
    /// The blocks' rows, roomier; the air over each block's panel (less
    /// over the first), and its foot.
    static let blockRowHeight: CGFloat = 20
    static let gap: CGFloat = 14, firstGap: CGFloat = 6, foot: CGFloat = 6

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        field.placeholderString = "Filter"
        field.delegate = self
        fieldBox.onChange = { [weak self] in self?.filterChanged() }
        status.font = UIType.footnote
        status.textColor = Theme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        for (b, action) in [(end, #selector(endClicked)), (kill, #selector(killClicked))] {
            b.target = self
            b.action = action
            b.isEnabled = false
        }
        for v in [modes, fieldBox, status, end, kill] { addSubview(v) }
        modes.setToolTip("The processes under the host's terminals and agents", forSegment: 0)
        modes.setToolTip("The whole machine: its cores, memory, network, disks and every process", forSegment: 1)
        modes.onChange = { [weak self] i in self?.setMode(i == 1 ? .machine : .blocks) }
        panels.isHidden = true
        addSubview(panels)
        for (id, title, width) in [("command", "Command", 300.0), ("pid", "PID", 56.0), ("user", "User", 72.0), ("threads", "Threads", 52.0),
                                   ("cpu", "CPU", 64.0), ("memory", "Memory", 64.0), ("path", "Path", 300.0)] {
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
        table.floatsGroupRows = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        rowMenu.delegate = self
        table.menu = rowMenu
        Flat.headers(table)
        showColumns()
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
        guard !keeper.restored, !all.isEmpty || machine != nil else { return }
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
        let segments = modes.intrinsicContentSize.width + 8
        let wide = w >= 12 + segments + 140 + 12 + buttons + 12
        let fieldWidth = wide ? min(220, w - buttons - segments - 36) : w - 24 - segments
        let fh = Flat.fieldHeight, bh = Flat.buttonHeight
        modes.frame = NSRect(x: 12, y: top - fh + (fh - bh) / 2, width: segments - 8, height: bh)
        fieldBox.frame = NSRect(x: 12 + segments, y: top - fh, width: max(fieldWidth, 60), height: fh)
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
        var bottom = (wide ? fieldBox.frame.minY : end.frame.minY) - 6
        // The machine's panels over its processes: whole where there's room
        // for them and a good many rows, a band of small ones where there's
        // less, none in a tile too short for either.
        panels.isHidden = mode != .machine
        if mode == .machine {
            let inner = w - 24
            panels.compact = false
            var h = panels.height(for: inner)
            if bottom - h < 200 {
                panels.compact = true
                h = panels.height(for: inner)
            }
            if bottom - h < 120 {
                panels.isHidden = true
            } else {
                panels.frame = NSRect(x: 12, y: bottom - 2 - h, width: inner, height: h)
                bottom = panels.frame.minY - 6
            }
        }
        let wider = scroll.frame.width != w
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, bottom))
        // The panels and cards are as wide as what's in view, not the
        // table: redrawn as that changes.
        if wider {
            table.enumerateAvailableRowViews { v, _ in
                v.needsDisplay = true
                v.subviews.forEach { $0.needsLayout = true }
            }
        }
        // The machine's command takes what the numbers leave.
        if mode == .machine, let command = table.tableColumns.first(where: { $0.identifier.rawValue == "command" }) {
            let others = table.tableColumns.filter { !$0.isHidden && $0 !== command }.reduce(CGFloat(0)) { $0 + $1.width + table.intercellSpacing.width }
            command.width = max(160, w - others - 20)
        }
        note.frame = mode == .machine && !panels.isHidden ? panels.frame : scroll.frame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        if !keeper.restored, keeper.value("mode") == Mode.machine.rawValue, mode != .machine { setMode(.machine, noting: false) }
        refresh()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: mode == .machine ? 2 : 5, repeats: true) { [weak self] _ in
            guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            self.refresh()
        }
    }

    /// Listed again: the blocks' processes, or the machine as it stands.
    func refresh() {
        guard mode == .machine else { return delegate?.processViewRefresh(self) ?? () }
        guard let c = client() else { return }
        guard c.readsMachine else {
            note.set(.idle)
            panels.waiting = c.isConnected ? "This host's server is from before the machine view: restart it to see the machine." : "Not connected"
            return
        }
        // One at a time; one unanswered for long is given up on.
        if let asked, Date().timeIntervalSince(asked) < 6 { return }
        asked = Date()
        var q = machineQuery
        q.filter = field.stringValue
        q.keep = selectedPIDs
        c.machine(q) { [weak self] sample in
            guard let self else { return }
            self.asked = nil
            guard let sample, self.mode == .machine else { return }
            self.show(sample, history: c.machineHistory)
        }
    }

    private func show(_ sample: MachineSample, history: [MachinePoint]) {
        machine = sample
        panels.sample = sample
        panels.history = history
        note.set(.idle)
        refilter()
    }

    /// Blocks or the machine: the other's columns, its timer's pace.
    func setMode(_ m: Mode, noting: Bool = true) {
        guard m != mode else { return }
        mode = m
        modes.selectedSegment = m == .machine ? 1 : 0
        if noting { keeper.note(["mode": m.rawValue]) }
        showColumns()
        if m == .machine, let c = client(), let latest = c.machineLatest {
            machine = latest
            panels.sample = latest
            panels.history = c.machineHistory
        }
        note.set(m == .machine ? (machine == nil ? .busy("Reading the machine…") : .idle) : (source()?.processes?.listedAt == nil ? .busy("Reading…") : .idle))
        refilter()
        needsLayout = true
        if window != nil {
            refresh()
            startTimer()
        }
    }

    private static let widths: [String: CGFloat] = ["command": 300, "pid": 56, "user": 72, "threads": 52, "cpu": 64, "memory": 64, "path": 300]

    private func showColumns() {
        let machine = mode == .machine
        // The machine's command takes what's left (layout); the blocks'
        // path, last, does.
        table.columnAutoresizingStyle = machine ? .noColumnAutoresizing : .lastColumnOnlyAutoresizingStyle
        for c in table.tableColumns {
            let id = c.identifier.rawValue
            switch id {
            case "user", "threads": c.isHidden = !machine
            case "path": c.isHidden = machine
            default: break
            }
            if id != "command", id != "path", let w = Self.widths[id] { c.width = w }
        }
        sortChanged()
    }

    /// The sorted column's title marked, the way it goes.
    private func sortChanged() {
        let key: [MachineQuery.Sort: String] = [.name: "command", .pid: "pid", .user: "user", .threads: "threads", .cpu: "cpu", .memory: "memory"]
        let titles = ["command": "Command", "pid": "PID", "user": "User", "threads": "Threads", "cpu": "CPU", "memory": "Memory", "path": "Path"]
        for c in table.tableColumns {
            let id = c.identifier.rawValue
            var t = titles[id] ?? id
            if mode == .machine, key[machineQuery.sort] == id { t += machineQuery.ascending ? " ▴" : " ▾" }
            c.headerCell.stringValue = t
        }
        table.headerView?.needsDisplay = true
    }

    /// A header clicked, the machine's: sorted by it, the busiest (or the
    /// first by name) first; again, the other way.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard mode == .machine else { return }
        let sorts: [String: MachineQuery.Sort] = ["command": .name, "pid": .pid, "user": .user, "threads": .threads, "cpu": .cpu, "memory": .memory]
        guard let s = sorts[tableColumn.identifier.rawValue] else { return }
        if machineQuery.sort == s {
            machineQuery.ascending.toggle()
        } else {
            machineQuery.sort = s
            machineQuery.ascending = s == .name || s == .user
        }
        sortChanged()
        asked = nil
        refresh()
    }

    /// While the filter is being typed, the pill is out of its way.
    var caretRectInWindow: NSRect? {
        guard field.currentEditor() != nil else { return nil }
        return field.convert(field.bounds, to: nil)
    }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem(mode == .machine ? "Show Blocks' Processes" : "Show the Machine", symbol: mode == .machine ? Theme.symbolName(for: .terminal) : "gauge.medium") { [weak self] in
            guard let self else { return }
            self.setMode(self.mode == .machine ? .blocks : .machine)
        }, ClosureMenuItem("Refresh Now", symbol: "arrow.clockwise") { [weak self] in
            guard let self else { return }
            self.asked = nil
            self.refresh()
        }, ClosureMenuItem("Filter…", symbol: "line.3.horizontal.decrease.circle") { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
        }]
    }

    func documentChanged() {
        guard mode == .blocks else { return }
        note.set(source()?.processes?.listedAt == nil ? .busy("Reading…") : .idle)
        guard let b = source(), let p = b.processes else { return }
        guard p.listedAt != listedAt else { return }
        listedAt = p.listedAt
        all = p.entries
        refilter()
    }

    /// The rows: each block's heading (its summary card), then its tree,
    /// parents before children, children set in; with a filter, only the
    /// processes that match, under their blocks.
    private func refilter() {
        if mode == .machine { return refilterMachine() }
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
            cards[b] = blockCard(b)
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
            rows.append(.foot(b))
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

    /// The machine's processes as the host sorted and narrowed them.
    private func refilterMachine() {
        let keep = selectedPIDs
        shown = (machine?.processes ?? []).map { .machine($0) }
        table.reloadData()
        select(Set(keep))
        if let m = machine {
            let q = field.stringValue.trimmingCharacters(in: .whitespaces)
            status.stringValue = q.isEmpty ? "\(m.processCount) processes · \(m.hostname)" : "\(m.matching) of \(m.processCount)"
        } else {
            status.stringValue = ""
        }
        selectionChanged()
        restoreState()
    }

    /// Selects the rows of these processes, those still listed.
    private func select(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        var indexes = IndexSet()
        for (i, r) in shown.enumerated() {
            if case let .process(e, _) = r, pids.contains(e.pid) { indexes.insert(i) }
            if case let .machine(p) = r, pids.contains(p.pid) { indexes.insert(i) }
        }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    /// Double-clicked, or ↩: the block the row's process runs under.
    @objc private func rowOpened() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < shown.count else { return }
        switch shown[row] {
        case let .group(b), let .foot(b): delegate?.processView(self, goTo: b)
        case let .process(e, _): if let b = e.block { delegate?.processView(self, goTo: b) }
        case let .machine(p): if let b = p.block { delegate?.processView(self, goTo: b) }
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
        if mode == .machine {
            asked = nil
            refresh()
        } else {
            refilter()
        }
        keeper.note(["filter": field.stringValue])
    }

    /// Only processes select; a heading is for going to its block.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .process = shown[row] { return true }
        return mode == .machine
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
            guard i < shown.count else { return nil }
            switch shown[i] {
            case .group, .foot: return nil
            case let .process(e, _): return e.pid
            case let .machine(p): return p.pid
            }
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
        if shown[row].isChoosable, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let n = selectedPIDs.count
        if n > 0 {
            menu.addItem(ClosureMenuItem(n > 1 ? "End \(n) Processes" : "End Process", symbol: "stop.circle") { [weak self] in self?.endClicked() })
            menu.addItem(ClosureMenuItem(n > 1 ? "Force End \(n) Processes" : "Force End Process", symbol: "xmark.octagon") { [weak self] in self?.killClicked() })
            menu.addItem(.separator())
        }
        let block: BlockID? = switch shown[row] { case let .group(b), let .foot(b): b; case let .process(e, _): e.block; case let .machine(p): p.block }
        if let block {
            menu.addItem(ClosureMenuItem("Go to \(blockTitle(block) ?? "Block")", symbol: "arrow.right.circle") { [weak self] in
                guard let self else { return }
                self.delegate?.processView(self, goTo: block)
            })
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func debugSort(_ column: String) {
        if let c = table.tableColumns.first(where: { $0.identifier.rawValue == column }) { tableView(table, didClick: c) }
    }

    func debugFilter(_ q: String) {
        fieldBox.stringValue = q
        filterChanged()
    }

    func debugHover(_ p: NSPoint) { panels.debugHover(p) }

    func debugPicture(_ path: String) -> String {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return "no picture" }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no png" }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return error.localizedDescription }
        return "wrote \(path)"
    }

    /// What a process was started with, after its name: its arguments,
    /// not the executable's path again (that's in its tooltip).
    static func arguments(_ p: MachineProcess) -> String {
        guard p.command != p.name else { return "" }
        // A path to it, spaces in it or not, then what follows.
        if p.command.hasPrefix("/"), let r = p.command.range(of: "/" + p.name + " ") ?? (p.command.hasSuffix("/" + p.name) ? p.command.range(of: "/" + p.name, options: .backwards) : nil) {
            let after = p.command[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return after.isEmpty ? "" : "  " + after
        }
        let words = p.command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = words.first else { return "" }
        let program = (String(first) as NSString).lastPathComponent
        if program == p.name || p.name.hasPrefix(program) || program.hasPrefix(p.name) {
            return words.count > 1 ? "  " + words[1] : ""
        }
        return "  " + p.command
    }

    /// Debugging: the mode, what's shown, the panels' state.
    var debugDescription_: String {
        let rows = shown.prefix(8).map { r -> String in
            switch r {
            case let .group(b): "[\(blockTitle(b) ?? "?")]"
            case .foot: "–"
            case let .process(e, d): String(repeating: " ", count: d) + e.command
            case let .machine(p): "\(p.pid) \(p.name) \(MachineWords.cpu(p.cpu)) \(MachineWords.memory(p.memory))"
            }
        }
        let m = machine.map { "cores=\($0.cores.count) cpu=\(MachineWords.percent($0.now.cpu)) mem=\(MachineWords.percent($0.memory.usedFraction)) disks=\($0.disks.map(\.mount)) procs=\($0.processCount) history=\(panels.history.count)" } ?? "no sample"
        return "mode=\(mode.rawValue) \(m) panels=\(panels.isHidden ? "hidden" : panels.compact ? "compact" : "full") \(Int(panels.frame.height))\n" + rows.joined(separator: "\n")
    }
    /// Each block on a panel of its own: its card at the top, its
    /// processes on it, a foot closing it.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = SelectionRowView()
        switch shown[row] {
        case .group: v.panel = .init(first: true, lead: row == 0 ? Self.firstGap : Self.gap, quiet: true)
        case .process: v.panel = .init()
        case .foot: v.panel = .init(last: true, quiet: true)
        case .machine: break
        }
        return v
    }

    /// A heading spans the row: its block's card.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { shown[row].isGroup }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let lead = row == 0 ? Self.firstGap : Self.gap
        switch shown[row] {
        case let .group(b): return lead + (cards[b].map { SummaryCard.height(for: $0) } ?? Self.blockRowHeight + 6)
        case .process: return Self.blockRowHeight
        case .foot: return Self.foot
        case .machine: return Self.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .foot = shown[row] { return nil }
        if case let .group(b) = shown[row], let content = cards[b] {
            let v = tableView.makeView(withIdentifier: .init("card"), owner: nil) as? SummaryCardRow ?? SummaryCardRow(content)
            v.identifier = .init("card")
            v.card.content = content
            v.lead = row == 0 ? Self.firstGap : Self.gap
            v.card.onClick = { [weak self] in
                guard let self else { return }
                delegate?.processView(self, goTo: b)
            }
            return v
        }
        let id = tableColumn?.identifier.rawValue ?? "command"
        let cell = tableView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? MeterCell ?? {
            let c = MeterCell()
            c.identifier = .init("cell-" + id)
            let f = NSTextField(labelWithString: "")
            f.alignment = id == "command" || id == "path" ? .left : .right
            f.lineBreakMode = .byTruncatingTail
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            c.lead = f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4)
            NSLayoutConstraint.activate([
                c.lead!,
                f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let numeric = id == "pid" || id == "cpu" || id == "memory" || id == "threads"
        cell.textField?.font = numeric ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : UIType.footnote
        cell.textField?.textColor = Theme.text
        cell.fraction = nil
        cell.textField?.toolTip = nil
        // A block's processes under its card's words.
        if case .process = shown[row], id == "command" { cell.lead?.constant = 41 } else { cell.lead?.constant = 4 }
        switch shown[row] {
        case let .machine(p):
            switch id {
            case "pid": cell.textField?.stringValue = "\(p.pid)"
            case "user":
                cell.textField?.stringValue = p.user
                cell.textField?.textColor = Theme.secondaryText
            case "threads": cell.textField?.stringValue = p.threads.map(String.init) ?? "–"
            case "cpu":
                cell.textField?.stringValue = MachineWords.cpu(p.cpu)
                // A core's worth fills it; more, it's full.
                cell.fraction = min(1, p.cpu / 100)
            case "memory":
                cell.textField?.stringValue = MachineWords.memory(p.memory)
                cell.fraction = machine.map { m in m.memory.total > 0 ? Double(p.memory) / Double(m.memory.total) : 0 }
            default:
                // Its name, then what it was started with; a block's mark
                // when it runs under one of the host's terminals.
                let rest = Self.arguments(p)
                let one = NSMutableParagraphStyle()
                one.lineBreakMode = .byTruncatingTail
                let text = NSMutableAttributedString(string: (p.block != nil ? "▸ " : "") + p.name, attributes: [.font: UIType.footnote, .foregroundColor: Theme.text, .paragraphStyle: one])
                text.append(NSAttributedString(string: rest, attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText, .paragraphStyle: one]))
                cell.textField?.attributedStringValue = text
                cell.textField?.toolTip = p.block.flatMap { blockTitle($0) }.map { "\(p.command)\nIn \($0)" } ?? p.command
            }
        case .foot: break
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

private extension ProcessView.Row {
    var isGroup: Bool { if case .group = self { true } else { false } }
    var isChoosable: Bool { switch self { case .process, .machine: true; case .group, .foot: false } }
}

/// A block's heading in the list: its summary card, on its panel (the
/// row draws that), as wide as what's in view (the table's columns can run
/// on past it), `lead` of air above.
final class SummaryCardRow: NSView {
    let card: SummaryCard
    var lead: CGFloat = 0 { didSet { needsLayout = true } }

    init(_ content: SummaryCardContent) {
        card = SummaryCard(content)
        card.plain = true
        super.init(frame: .zero)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let seen = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        card.frame = NSRect(x: 6, y: 0, width: max(0, min(bounds.width, seen) - 12), height: max(0, bounds.height - lead))
    }
}

/// A table cell with, where it's set, a bar behind its number: how much of
/// a core, of the memory.
final class MeterCell: NSTableCellView {
    /// Its text's left edge: set in under a block's card.
    var lead: NSLayoutConstraint?
    var fraction: Double? { didSet { if fraction != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let f = fraction, f > 0.001 else { return }
        let r = bounds.insetBy(dx: 3, dy: 3)
        let w = max(2, r.width * CGFloat(min(f, 1)))
        MachineInk.one.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.maxX - w, y: r.minY, width: w, height: r.height), xRadius: 3, yRadius: 3).fill()
    }
}
