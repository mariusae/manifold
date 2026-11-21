import AppKit
import ManifoldCore

/// A path's editor, as apex's crumbs bring one down: a folder's entries
/// under where it was asked for, listed by its host — its folders (and
/// files, where a file can be gone to), the folder itself first as `./` —
/// narrowed as a name is typed, the best first. ⏎ chooses (the folder
/// itself, with nothing chosen); → or ⇥ goes into the folder chosen; ← or
/// ⌫ with nothing typed goes up; ⎋, or a click elsewhere, puts it away.
/// Used for a search's folder and for a tile's place (its bar's path),
/// to go elsewhere.
final class FolderPicker: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The one showing, if any (it goes when another comes).
    private static var shown: FolderPicker?

    /// A folder's entries on its host (nil: couldn't be listed).
    typealias Lister = (String, @escaping ([DirectoryEntry]?) -> Void) -> Void

    private let list: Lister
    private let filesToo: Bool
    private let onChoose: (String, _ isFolder: Bool) -> Void
    /// The folder listed, with its slash.
    private(set) var dir: String
    private var entries: [DirectoryEntry]?
    private var rows: [Row] = []
    private var asked = 0

    private struct Row { var name: String?; var isFolder: Bool }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let ground = NSVisualEffectView()
    private let crumbs = NSTextField.label(font: UIType.detail, color: Theme.secondaryText, cut: .byTruncatingHead)
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let status = NSTextField.label(font: UIType.detail, color: Theme.tertiaryText)

    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 24
    static let rowsShown = 12

    private final class Panel: NSPanel {
        var onResign: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func resignKey() {
            super.resignKey()
            onResign?()
        }
    }

    /// Brought down under `anchor` (in `window`'s coordinates), on `path`'s
    /// folder (a file's, its own).
    @discardableResult
    static func show(at path: String, filesToo: Bool = false, under anchor: NSRect, in window: NSWindow,
                     list: @escaping Lister, choose: @escaping (String, _ isFolder: Bool) -> Void) -> FolderPicker {
        shown?.close()
        let p = FolderPicker(dir: path, filesToo: filesToo, list: list, choose: choose)
        shown = p
        p.place(under: anchor, in: window)
        return p
    }

    static func closeShown() { shown?.close() }

    private init(dir: String, filesToo: Bool, list: @escaping Lister, choose: @escaping (String, Bool) -> Void) {
        var d = dir.isEmpty ? "/" : dir
        if !d.hasSuffix("/") { d += "/" }
        self.dir = d
        self.filesToo = filesToo
        self.list = list
        self.onChoose = choose
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.onResign = { [weak self] in self?.close() }

        ground.material = .menu
        ground.state = .active
        ground.blendingMode = .behindWindow
        ground.wantsLayer = true
        ground.layer?.cornerRadius = Radius.surface
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        ground.layer?.borderWidth = 0.5
        ground.themed { v in v.layer?.borderColor = Theme.panelBorder.cgColor }
        panel.contentView = ground

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = UIType.row
        field.placeholderString = "A name — ← up, → into"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        for v in [crumbs, field, scroll, status] as [NSView] { ground.addSubview(v) }
        load()
    }

    // MARK: Showing

    private func place(under anchor: NSRect, in window: NSWindow) {
        let height = 30 + 28 + CGFloat(Self.rowsShown) * Self.rowHeight + 10
        let screen = window.convertToScreen(anchor)
        var frame = NSRect(x: screen.minX, y: screen.minY - 4 - height, width: Self.width, height: height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            if frame.minY < visible.minY + 8 { frame.origin.y = screen.maxY + 4 }
        }
        panel.setFrame(frame, display: false)
        layout()
        window.addChildWindow(panel, ordered: .above)
        // The keyboard only while the app's in front: a panel that takes it
        // with the app behind takes what's typed in another app.
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        } else {
            panel.orderFront(nil)
        }
    }

    private func layout() {
        let b = ground.bounds
        crumbs.frame = NSRect(x: 12, y: b.height - 26, width: b.width - 24, height: 16)
        field.frame = NSRect(x: 12, y: b.height - 54, width: b.width - 24, height: 22)
        scroll.frame = NSRect(x: 4, y: 6, width: b.width - 8, height: b.height - 62)
        table.tableColumns.first?.width = scroll.frame.width
        status.frame = NSRect(x: 12, y: scroll.frame.maxY - 30, width: b.width - 24, height: 16)
    }

    func close() {
        guard panel.isVisible || Self.shown === self else { return }
        panel.onResign = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.shown === self { Self.shown = nil }
    }

    // MARK: Listing

    /// The folder's entries, asked of its host.
    private func load() {
        crumbs.stringValue = dir.abbreviatingHome
        entries = nil
        asked += 1
        let n = asked
        refresh()
        list(dir) { [weak self] found in
            DispatchQueue.main.async {
                guard let self, self.asked == n else { return }
                self.entries = found ?? []
                self.status.stringValue = found == nil ? "Can't be listed" : ""
                self.refresh()
            }
        }
        status.stringValue = "Listing…"
    }

    /// The rows for what's typed: the folder itself while nothing is, then
    /// its folders (and files) — all, by name, or those that match, best first.
    private func refresh() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        var out: [Row] = q.isEmpty ? [Row(name: nil, isFolder: true)] : []
        let shown = (entries ?? []).filter { (filesToo || $0.isDirectory) && (!$0.isHidden || q.hasPrefix(".")) }
        if q.isEmpty {
            let sorted = shown.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            out += sorted.map { Row(name: $0.name, isFolder: $0.isDirectory) }
        } else {
            let scored = shown.compactMap { e in Self.score(q, e.name).map { (e, $0) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
            out += scored.map { Row(name: $0.0.name, isFolder: $0.0.isDirectory) }
        }
        rows = out
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        status.isHidden = entries != nil && status.stringValue.isEmpty || !rows.filter({ $0.name != nil }).isEmpty
    }

    /// How well a name answers what's typed: its start best, then a word's
    /// start, then anywhere, then its letters in order; nil, not at all.
    static func score(_ q: String, _ name: String) -> Double? {
        let n = name.lowercased(), t = q.lowercased()
        if n == t { return 4 }
        if n.hasPrefix(t) { return 3 }
        if let r = n.range(of: t) {
            let before = r.lowerBound == n.startIndex ? nil : n[n.index(before: r.lowerBound)]
            return before.map { "-_. ".contains($0) } == true ? 2.5 : 2
        }
        var i = n.startIndex
        for c in t {
            guard let f = n[i...].firstIndex(of: c) else { return nil }
            i = n.index(after: f)
        }
        return 1
    }

    // MARK: Choosing

    private var chosen: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    private func path(of row: Row) -> String {
        guard let name = row.name else { return dir == "/" ? "/" : String(dir.dropLast()) }
        return dir + name
    }

    private func choose() {
        guard let row = chosen else { return }
        let p = path(of: row)
        close()
        onChoose(p, row.isFolder)
    }

    private func into() -> Bool {
        guard let row = chosen, let name = row.name, row.isFolder else { return false }
        dir += name + "/"
        field.stringValue = ""
        load()
        return true
    }

    private func up() {
        guard dir != "/" else { return }
        let was = String(dir.dropLast()).lastPathComponent
        var parent = String(dir.dropLast()).deletingLastPathComponent
        if parent.isEmpty { parent = "/" }
        dir = parent.hasSuffix("/") ? parent : parent + "/"
        field.stringValue = ""
        load()
        // The folder come up from, chosen once it's listed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let i = self.rows.firstIndex(where: { $0.name == was }) else { return }
            self.table.selectRowIndexes([i], byExtendingSelection: false)
            self.table.scrollRowToVisible(i)
        }
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        choose()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let atEnd = textView.selectedRange().location == (textView.string as NSString).length && textView.selectedRange().length == 0
        switch selector {
        case #selector(NSResponder.moveUp(_:)): CaretPopup.move(table, by: -1, count: rows.count)
        case #selector(NSResponder.moveDown(_:)): CaretPopup.move(table, by: 1, count: rows.count)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.insertTab(_:)): _ = into()
        case #selector(NSResponder.moveRight(_:)) where atEnd: if !into() { return false }
        case #selector(NSResponder.moveLeft(_:)) where field.stringValue.isEmpty: up()
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty: up()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    // MARK: Its rows

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = Theme.symbol(r.isFolder ? "folder" : "doc", size: 13, weight: .regular, color: Theme.secondaryText)
        let label = NSTextField.label(font: UIType.row, color: Theme.text, cut: .byTruncatingMiddle)
        label.stringValue = r.name.map { $0 + (r.isFolder ? "/" : "") } ?? "./  (this folder)"
        if r.name == nil { label.textColor = Theme.secondaryText }
        let more = NSImageView()
        more.image = r.isFolder && r.name != nil ? Theme.symbol("chevron.right", size: 9, weight: .semibold, color: Theme.tertiaryText) : nil
        for v in [image, label, more] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: more.leadingAnchor, constant: -6),
            more.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            more.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Debugging

    /// Debugging: typed into its field (as keys would), or a key ("up",
    /// "into", "choose"); what it lists.
    static func debug(_ arg: String) -> String {
        guard let p = shown else { return "no picker" }
        switch arg {
        case "": break
        case "up": p.up()
        case "into": _ = p.into()
        case "choose": p.choose(); return "chosen"
        case "down": CaretPopup.move(p.table, by: 1, count: p.rows.count)
        default:
            p.field.stringValue = String(arg.dropFirst(arg.hasPrefix("type ") ? 5 : 0))
            p.refresh()
        }
        return "\(p.dir) [\(p.field.stringValue)] " + p.rows.prefix(10).enumerated().map { i, r in
            (i == p.table.selectedRow ? "*" : "") + (r.name.map { $0 + (r.isFolder ? "/" : "") } ?? "./")
        }.joined(separator: " ")
    }
}
