import AppKit
import ManifoldCore

/// Language Servers…: which server runs for which files, on every host
/// (DESIGN.md §7.1). A row per language: its name, the file extensions it
/// takes, the command (run through the shell, in the workspace root), the
/// files that mark a root, and whether it's on at all. Changes are settings
/// on the desk, so they're everywhere this app is; each host runs its own.
final class LanguageServersWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var source: (() -> [LanguageServerConfig])?
    var states: (() -> [String: String])?
    var onChange: (([LanguageServerConfig]) -> Void)?

    private var configs: [LanguageServerConfig] = []
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let remove = IconButton(symbol: "minus", size: 12, weight: .medium, target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Language Servers"
        window.minSize = NSSize(width: 600, height: 300)
        super.init(window: window)
        window.center()
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        window?.backgroundColor = Theme.windowBackground
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

        let add = IconButton(symbol: "plus", size: 12, weight: .medium, target: self, action: #selector(addRow))
        remove.target = self
        remove.action = #selector(removeRow)
        let defaults = FlatButton("Restore Defaults", target: self, action: #selector(restoreDefaults))
        let note = NSTextField(wrappingLabelWithString: "Files are matched by extension. Commands run through the shell, in the workspace root: the nearest folder up from the file with a root marker, else the repository, else the file's own folder. Each host runs its own; a server stops and restarts with its next file when its command changes.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.secondaryText
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.secondaryText
        for v in [add, remove, defaults, note, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
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

    func refresh() {
        let editing = table.editedRow >= 0
        if !editing {
            configs = source?() ?? []
            table.reloadData()
        }
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
        remove.isEnabled = table.selectedRow >= 0
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
        configs = LanguageServerConfig.defaults
        changed()
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
        func words(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty } }
        switch id {
        case "enabled": c.enabled = (object as? Bool) ?? ((object as? Int) == 1)
        case "id": c.id = text.isEmpty ? c.id : text
        case "extensions": c.extensions = words(text).map { $0.lowercased() }
        case "command": c.command = text
        case "rootMarkers": c.rootMarkers = words(text)
        default: break
        }
        guard c != configs[row] else { return }
        configs[row] = c
        onChange?(configs)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        remove.isEnabled = table.selectedRow >= 0
    }
}
