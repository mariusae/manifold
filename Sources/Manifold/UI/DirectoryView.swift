import AppKit
import ManifoldCore

protocol DirectoryViewDelegate: AnyObject {
    func directoryView(_ view: DirectoryView, open path: String)
    func directoryViewRefresh(_ view: DirectoryView)
}

/// The directory lens: a folder's entries as a list (name, date, size),
/// as the host lists them; opening one places its block beside the listing.
final class DirectoryView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DirectoryViewDelegate?
    var source: () -> Block? = { nil }
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let header = NSTextField(labelWithString: "")
    private var entries: [DirectoryEntry] = []
    private var listedAt: Stamp?
    private var path = ""

    var focusView: NSView { table }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = Theme.secondaryText
        header.lineBreakMode = .byTruncatingMiddle
        addSubview(header)
        for (id, title, width) in [("name", "Name", 300.0), ("modified", "Date Modified", 150.0), ("size", "Size", 80.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(doubleClicked)
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

    func destroy() { keeper.flush() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        keeper.note(["selected": row >= 0 && row < entries.count ? entries[row].name : ""])
    }

    /// Back as it was: the entry selected, the scroll.
    private func restoreState() {
        guard !keeper.restored, !entries.isEmpty else { return }
        keeper.restored = true
        if let name = keeper.value("selected"), let i = entries.firstIndex(where: { $0.name == name }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 12, y: bounds.height - 24, width: bounds.width - 24, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 30)
    }

    /// The block (or its listing) may have changed.
    func documentChanged() {
        guard let b = source() else { return }
        path = b.path ?? ""
        header.stringValue = path.abbreviatingHome
        let listing = b.directory?.entries ?? []
        if b.directory?.listedAt != listedAt || listing.count != entries.count {
            listedAt = b.directory?.listedAt
            entries = listing.filter { !$0.isHidden }
            table.reloadData()
            restoreState()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.directoryViewRefresh(self) }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < entries.count else { return }
        delegate?.directoryView(self, open: (path as NSString).appendingPathComponent(entries[table.clickedRow].name))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, table.selectedRow >= 0 { // return
            delegate?.directoryView(self, open: (path as NSString).appendingPathComponent(entries[table.selectedRow].name))
        } else if event.keyCode == 126, event.modifierFlags.contains(.command) { // ⌘↑: up a folder
            delegate?.directoryView(self, open: (path as NSString).deletingLastPathComponent)
        } else {
            super.keyDown(with: event)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let id = tableColumn?.identifier.rawValue ?? "name"
        let cell = tableView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("cell-" + id)
            let f = NSTextField(labelWithString: "")
            f.font = .systemFont(ofSize: 12.5)
            f.lineBreakMode = .byTruncatingMiddle
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            if id == "name" {
                let i = NSImageView()
                i.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(i)
                c.imageView = i
                NSLayoutConstraint.activate([
                    i.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    i.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    i.widthAnchor.constraint(equalToConstant: 16),
                    f.leadingAnchor.constraint(equalTo: i.trailingAnchor, constant: 6),
                ])
            } else {
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4).isActive = true
            }
            NSLayoutConstraint.activate([
                f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        switch id {
        case "name":
            cell.textField?.stringValue = e.name
            cell.imageView?.image = Theme.symbol(e.isDirectory ? "folder.fill" : Finder.symbol(forFile: e.name), size: 12)
            cell.imageView?.contentTintColor = e.isDirectory ? Theme.accent : Theme.secondaryText
        case "modified":
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            cell.textField?.stringValue = f.string(from: Date(timeIntervalSince1970: e.modified))
            cell.textField?.textColor = Theme.secondaryText
        default:
            cell.textField?.stringValue = e.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)
            cell.textField?.textColor = Theme.secondaryText
            cell.textField?.alignment = .right
        }
        return cell
    }
}
