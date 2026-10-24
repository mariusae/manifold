import AppKit
import ManifoldCore

/// Settings ▸ Language Servers: which server runs for which files, on every host
/// (DESIGN.md §7.1). A row per language: its name, the file extensions it
/// takes, the command (run through the shell, in the workspace root), the
/// files that mark a root, and whether it's on at all. Changes are settings
/// on the desk, so they're everywhere this app is; each host runs its own.
/// Set for one host (§7.2), the same table: what it runs, its command and
/// root markers its own where they differ (the host's preferences, which
/// every Mac attached to it shares), and a root marker for every language.
final class LanguageServersPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var source: (() -> [LanguageServerConfig])?
    var states: (() -> [String: String])?
    var onChange: (([LanguageServerConfig]) -> Void)?
    /// The hosts it can be set for, besides all of them: each one's id and name.
    var hosts: (() -> [(HostID, String)])?
    var preferences: ((HostID) -> HostPreferences?)?
    var setPreferences: ((HostID, HostPreferences, @escaping (String?) -> Void) -> Void)?

    private var configs: [LanguageServerConfig] = []
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let remove = IconButton(symbol: "minus", size: 12, weight: .medium, target: nil, action: nil)
    private let add = IconButton(symbol: "plus", size: 12, weight: .medium, target: nil, action: nil)
    private let defaults = FlatButton("Restore Defaults")
    /// Which hosts it's set for: all (nil), or one.
    private(set) var scope: HostID?
    private var scopeHosts: [HostID] = []
    private var scopeBar = FlatSegments(titles: ["All Hosts"])
    private let scopeHolder = NSView()
    private let rootLabel = NSTextField(labelWithString: "Root marker for every language:")
    private let rootBox = FlatFieldBox(symbol: nil, clears: true, fontSize: 12)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var problem: String?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Language Servers"
    }

    /// Settings' Language Servers pane.
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 520))
        // Its size fixed: Settings sizes its window to each pane's.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 780),
            view.heightAnchor.constraint(equalToConstant: 520),
        ])
        preferredContentSize = view.frame.size
        build()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let content = view
        scopeHolder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scopeHolder)
        let scroll = ClippingScrollView()
        scroll.hasVerticalScroller = true
        Flat.outline(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, width) in [("enabled", "", 24), ("id", "Language", 90), ("extensions", "Files", 150), ("command", "Command", 220), ("rootMarkers", "Root Markers", 200)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = CGFloat(id == "enabled" ? 24 : 60)
            if id == "enabled" {
                column.dataCell = FlatCheckboxCell(textCell: "")
            } else {
                let cell = NSTextFieldCell()
                cell.isEditable = true
                cell.font = .systemFont(ofSize: 12)
                column.dataCell = cell
            }
            table.addTableColumn(column)
        }
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        Flat.headers(table)
        scroll.documentView = table
        content.addSubview(scroll)

        add.target = self
        add.action = #selector(addRow)
        remove.target = self
        remove.action = #selector(removeRow)
        defaults.target = self
        defaults.action = #selector(restoreDefaults)
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.secondaryText
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.secondaryText
        rootLabel.font = .systemFont(ofSize: 12)
        rootLabel.textColor = Theme.text
        rootBox.field.placeholderString = "as for all hosts"
        NotificationCenter.default.addObserver(self, selector: #selector(rootEdited), name: NSControl.textDidEndEditingNotification, object: rootBox.field)
        for v in [add, remove, defaults, note, status, rootLabel, rootBox] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scopeHolder.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scopeHolder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scopeHolder.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scopeHolder.heightAnchor.constraint(equalToConstant: Flat.buttonHeight),
            rootLabel.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            rootLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            rootBox.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            rootBox.leadingAnchor.constraint(equalTo: rootLabel.trailingAnchor, constant: 8),
            rootBox.widthAnchor.constraint(equalToConstant: 220),
            rootBox.heightAnchor.constraint(equalToConstant: Flat.fieldHeight),
            scroll.topAnchor.constraint(equalTo: scopeHolder.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            add.widthAnchor.constraint(equalToConstant: 24),
            add.heightAnchor.constraint(equalToConstant: 24),
            remove.topAnchor.constraint(equalTo: add.topAnchor),
            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 4),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24),
            defaults.topAnchor.constraint(equalTo: add.topAnchor),
            defaults.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            note.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            status.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            status.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
    }

    /// The configs for all hosts, as the desk has them.
    private var base: [LanguageServerConfig] { source?() ?? [] }
    /// The host's own settings (`HostPreferences.lsp`), when set for one.
    private var hostSettings: [String: String] { scope.flatMap { preferences?($0)?.lsp } ?? [:] }

    /// Set for all hosts (nil) or one.
    func select(_ host: HostID?) {
        scope = host
        problem = nil
        refresh()
    }

    func refresh() {
        updateScopeBar()
        let editing = table.editedRow >= 0
        if !editing {
            configs = scope == nil ? base : LanguageServerConfig.applying(base, hostSettings)
            table.reloadData()
        }
        let one = scope != nil
        add.isHidden = one
        remove.isHidden = one
        rootLabel.isHidden = !one
        rootBox.isHidden = !one
        defaults.title = one ? "Use All Hosts' Settings" : "Restore Defaults"
        if one, !rootBox.hasKeyboard { rootBox.stringValue = hostSettings["root"] ?? "" }
        note.stringValue = one
            ? "What this host runs: a command or root markers set here are its own (in the accent color); the rest are as for all hosts. Every Mac attached to it shares these."
            : "Files are matched by extension. Commands run through the shell, in the workspace root: the nearest folder up from the file with a root marker, else the repository, else the file's own folder. Each host runs its own; a server stops and restarts with its next file when its command changes."
        let running = states?() ?? [:]
        if running.isEmpty {
            status.stringValue = "No language server is running."
        } else {
            status.stringValue = running.keys.sorted().map { key in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let home = NSHomeDirectory()
                var root = parts.count > 1 ? parts[1] : ""
                if root.hasPrefix(home) { root = "~" + root.dropFirst(home.count) }
                return "\(parts[0]) \(root): \(running[key] ?? "")"
            }.joined(separator: "\n")
        }
        if let problem { status.stringValue = problem + "\n" + status.stringValue }
        remove.isEnabled = table.selectedRow >= 0
    }

    /// The segments: all hosts, and each attached one — made again when
    /// the hosts change.
    private func updateScopeBar() {
        let list = hosts?() ?? []
        let ids = list.map(\.0)
        if ids != scopeHosts || scopeBar.superview == nil {
            scopeHosts = ids
            scopeBar.removeFromSuperview()
            scopeBar = FlatSegments(titles: ["All Hosts"] + list.map(\.1), font: .systemFont(ofSize: 12))
            scopeBar.onChange = { [weak self] i in
                guard let self else { return }
                self.select(i == 0 ? nil : self.scopeHosts[i - 1])
            }
            scopeBar.frame.origin = .zero
            scopeHolder.addSubview(scopeBar)
        }
        if let scope, !scopeHosts.contains(scope) { self.scope = nil }
        scopeBar.selectedSegment = scope.flatMap { s in scopeHosts.firstIndex(of: s).map { $0 + 1 } } ?? 0
    }

    /// The host's settings changed to `lsp`: sent, and the table as the host
    /// now has them (or why not).
    private func setHost(_ edit: (inout [String: String]) -> Void) {
        guard let host = scope, var p = preferences?(host) else { return }
        edit(&p.lsp)
        setPreferences?(host, p) { [weak self] error in
            self?.problem = error.map { "Not set: \($0)" }
            self?.refresh()
        }
    }

    @objc private func rootEdited() {
        let text = rootBox.stringValue.split(whereSeparator: { $0 == " " || $0 == "," }).joined(separator: ",")
        guard text != (hostSettings["root"] ?? "") else { return }
        setHost { $0["root"] = text.isEmpty ? nil : text }
    }

    private func changed() {
        onChange?(configs)
        table.reloadData()
    }

    @objc private func addRow() {
        configs.append(LanguageServerConfig(id: "language", extensions: [], command: "", rootMarkers: []))
        changed()
        table.selectRowIndexes([configs.count - 1], byExtendingSelection: false)
        table.editColumn(1, row: configs.count - 1, with: nil, select: true)
    }

    @objc private func removeRow() {
        let row = table.selectedRow
        guard row >= 0, row < configs.count else { return }
        configs.remove(at: row)
        changed()
    }

    @objc private func restoreDefaults() {
        // For a host: its own settings let go of.
        if scope != nil { return setHost { $0 = [:] } }
        configs = LanguageServerConfig.defaults
        changed()
    }

    /// Whether a column of a row is the host's own (not as for all hosts).
    private func isHosts(_ column: String, row: Int) -> Bool {
        guard scope != nil, row < configs.count else { return false }
        let id = configs[row].id, s = hostSettings
        switch column {
        case "command": return s[id] != nil
        case "rootMarkers": return s[id + ".root"] != nil || s["root"] != nil
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        // For a host, only what a host can have its own of.
        guard scope != nil else { return true }
        return ["command", "rootMarkers"].contains(tableColumn?.identifier.rawValue ?? "")
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        let id = tableColumn?.identifier.rawValue ?? ""
        if let c = cell as? NSTextFieldCell {
            c.textColor = isHosts(id, row: row) ? Theme.accent
                : scope != nil && !["command", "rootMarkers"].contains(id) ? Theme.secondaryText : Theme.text
        }
        if let b = cell as? NSButtonCell { b.isEnabled = scope == nil }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { configs.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < configs.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let c = configs[row]
        switch id {
        case "enabled": return c.enabled
        case "id": return c.id
        case "extensions": return c.extensions.joined(separator: " ")
        case "command": return c.command
        case "rootMarkers": return c.rootMarkers.joined(separator: " ")
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard row < configs.count, let id = tableColumn?.identifier.rawValue else { return }
        var c = configs[row]
        let text = (object as? String ?? "").trimmingCharacters(in: .whitespaces)
        // Words, split at spaces and commas; an extension's dot left off
        // (".py" is "py"), a marker's kept (".hg").
        func words(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        func extensions(_ s: String) -> [String] { words(s).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty } }
        // For a host: its own command or markers — none where they're as for
        // all hosts (and its markers for every language, if set, apply).
        if scope != nil {
            guard let all = base.first(where: { $0.id == c.id }) else { return }
            switch id {
            case "command":
                guard text != c.command else { return }
                setHost { $0[c.id] = text == all.command || text.isEmpty ? nil : text }
            case "rootMarkers":
                let markers = words(text)
                guard markers != c.rootMarkers else { return }
                setHost { $0[c.id + ".root"] = markers == all.rootMarkers || markers.isEmpty ? nil : markers.joined(separator: ",") }
            default: break
            }
            return
        }
        switch id {
        case "enabled": c.enabled = (object as? Bool) ?? ((object as? Int) == 1)
        case "id": c.id = text.isEmpty ? c.id : text
        case "extensions": c.extensions = extensions(text).map { $0.lowercased() }
        case "command": c.command = text
        case "rootMarkers": c.rootMarkers = words(text)
        default: break
        }
        guard c != configs[row] else { return }
        configs[row] = c
        onChange?(configs)
    }

    /// For DebugControl: "all" or a host's name chosen; a cell set as typed
    /// ("<language> command|rootMarkers <text>"); "root <markers>". Then the
    /// rows, a host's own settings marked *.
    func debug(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 2).map(String.init)
        switch words.first {
        case "all": select(nil)
        case "host":
            let name = words.dropFirst().joined(separator: " ")
            guard let h = (hosts?() ?? []).first(where: { $0.1 == name })?.0 else { return "no host \(name)" }
            select(h)
        case "root":
            rootBox.stringValue = words.count > 1 ? words.dropFirst().joined(separator: " ") : ""
            rootEdited()
        case "clear": restoreDefaults()
        case let lang? where words.count >= 2:
            guard let row = configs.firstIndex(where: { $0.id == lang }), let column = table.tableColumns.first(where: { $0.identifier.rawValue == words[1] }) else { return "no \(lang) \(words[1])" }
            tableView(table, setObjectValue: words.count > 2 ? words[2] : "", for: column, row: row)
        default: break
        }
        return "for \(scope.map { s in (hosts?() ?? []).first { $0.0 == s }?.1 ?? "?" } ?? "all hosts")" + (problem.map { " (\($0))" } ?? "") + "\n"
            + configs.indices.map { i in
                let c = configs[i]
                return "\(c.id): \(isHosts("command", row: i) ? "*" : "")\(c.command) | \(isHosts("rootMarkers", row: i) ? "*" : "")\(c.rootMarkers.joined(separator: " "))"
            }.joined(separator: "\n") + (scope != nil ? "\nhost settings: \(hostSettings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))" : "")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        remove.isEnabled = table.selectedRow >= 0
    }
}
