import AppKit
import ManifoldCore

/// Remoting…: how hosts are reached (DESIGN.md §8). A row per provider:
/// its name, and the command that runs a command line on a destination
/// with stdio connected — `%h` the destination, `%c` the command (appended
/// when the template has no `%c`). `ssh` is the built-in one; add your
/// own, such as `my_special_script.sh %h`, and attach to `name:target`.
final class RemotingWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var source: (() -> [RemoteProvider])?
    var onChange: (([RemoteProvider]) -> Void)?
    var onAttach: (() -> Void)?

    private var providers: [RemoteProvider] = []
    private let table = NSTableView()
    private let remove = NSButton(title: "−", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Remoting"
        window.minSize = NSSize(width: 480, height: 240)
        super.init(window: window)
        window.center()
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let scroll = ClippingScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        for (id, title, width) in [("name", "Provider", 120), ("command", "Command", 440)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 60
            let cell = NSTextFieldCell()
            cell.isEditable = true
            cell.font = id == "command" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            column.dataCell = cell
            table.addTableColumn(column)
        }
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        content.addSubview(scroll)

        let add = NSButton(title: "+", target: self, action: #selector(addRow))
        remove.target = self
        remove.action = #selector(removeRow)
        let attach = NSButton(title: "Attach to Host…", target: self, action: #selector(attachClicked))
        let note = NSTextField(wrappingLabelWithString: "A provider runs a command line on a destination with stdio connected, as ssh does: %h is the destination, %c the command (appended when there is no %c). Attach to a host as user@host for ssh, or provider:target for another. Manifold installs its server on the host, in ~/.manifold/bin, if it isn't already there.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        for v in [add, remove, attach, note] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        for b in [add, remove, attach] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            add.widthAnchor.constraint(equalToConstant: 28),
            remove.topAnchor.constraint(equalTo: add.topAnchor),
            remove.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 4),
            remove.widthAnchor.constraint(equalToConstant: 28),
            attach.topAnchor.constraint(equalTo: add.topAnchor),
            attach.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            note.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            // The note sits at the foot; the table takes the rest.
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
    }

    func refresh() {
        if table.editedRow < 0 {
            providers = source?() ?? RemoteProvider.defaults
            table.reloadData()
        }
        remove.isEnabled = table.selectedRow >= 0
    }

    private func changed() {
        onChange?(providers)
        table.reloadData()
    }

    /// For DebugControl: adds a row; what the table and the source list.
    func debugAdd() { addRow() }
    var debugRows: String { "table: \(providers.map(\.name)) source: \((source?() ?? []).map(\.name)) editing: \(table.editedRow)" }

    @objc private func addRow() {
        providers.append(RemoteProvider(name: "name", command: "my-remote %h %c"))
        changed()
        table.selectRowIndexes([providers.count - 1], byExtendingSelection: false)
        table.editColumn(0, row: providers.count - 1, with: nil, select: true)
    }

    @objc private func removeRow() {
        let row = table.selectedRow
        guard row >= 0, row < providers.count else { return }
        providers.remove(at: row)
        changed()
    }

    @objc private func attachClicked() { onAttach?() }

    func numberOfRows(in tableView: NSTableView) -> Int { providers.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < providers.count, let id = tableColumn?.identifier.rawValue else { return nil }
        return id == "name" ? providers[row].name : providers[row].command
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard row < providers.count, let id = tableColumn?.identifier.rawValue else { return }
        var p = providers[row]
        let text = (object as? String ?? "").trimmingCharacters(in: .whitespaces)
        if id == "name" {
            let name = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { p.name = name }
        } else {
            p.command = text
        }
        guard p != providers[row] else { return }
        providers[row] = p
        onChange?(providers)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        remove.isEnabled = table.selectedRow >= 0
    }
}
