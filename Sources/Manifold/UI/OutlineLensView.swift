import AppKit
import ManifoldCore

protocol OutlineLensViewDelegate: AnyObject {
    /// An entry was clicked: the block's own tile goes there (a terminal
    /// to the command's row, an editor or a preview to the heading).
    func outline(_ view: OutlineLensView, go entry: OutlineLensView.Entry)
}

/// The outline lens (§3.8): what a block's scrubber marks, as a list of
/// its own — a terminal's commands with their outcome, a text's headings
/// — each clicked to go there in the block's tile. Beside a terminal or
/// a note, it's the outline to steer by.
final class OutlineLensView: NSView, PaneContent, KeepsViewState, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry: Equatable {
        /// A command's id, or a heading's index among the headings.
        var id: Int
        /// A heading's line (0-based) in the text.
        var line: Int?
        var title: String
        var detail: String
        var level = 0
        var failed = false
        var running = false
    }

    let keeper = ViewStateKeeper()
    let placement: PlacementID
    /// The outline block itself.
    let block: BlockID
    /// The block it outlines; `source` gives that block's state.
    var subject: BlockID?
    weak var delegate: OutlineLensViewDelegate?
    var source: () -> Block? = { nil }

    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "Nothing yet")
    private var entries: [Entry] = []
    private var shownVersion = -1
    private var shownCommands = -1

    var focusView: NSView { table }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        let c = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(c)
        table.headerView = nil
        table.target = self
        table.action = #selector(rowClicked)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = Theme.secondaryText
        empty.alignment = .center
        addSubview(empty)
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - GridView.band))
        empty.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }

    /// The block as it is now: a terminal's commands, else a text's headings.
    func documentChanged() {
        guard let b = source() else { return }
        var fresh: [Entry]
        if let t = b.terminal {
            let commands = t.commands ?? []
            guard commands.count != shownCommands || commands.contains(where: { $0.status == nil }) else { return }
            shownCommands = commands.count
            fresh = commands.map { c in
                let detail: String
                if let s = c.status { detail = s == 0 ? Age.short(c.at) : "exit \(s) · \(Age.short(c.at))" } else { detail = "running" }
                return Entry(id: c.id, title: c.text, detail: detail, failed: (c.status ?? 0) != 0, running: c.status == nil)
            }
        } else if let text = b.text {
            guard text.version != shownVersion else { return }
            shownVersion = text.version
            fresh = MarkdownOutline.headings(in: text.text.string).enumerated().map { i, h in
                Entry(id: i, line: h.line, title: h.text, detail: "", level: h.level - 1)
            }
        } else {
            return
        }
        guard fresh != entries else { return }
        entries = fresh
        table.reloadData()
        empty.isHidden = !entries.isEmpty
        if !keeper.restored {
            keeper.restored = true
            if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
        }
    }

    /// Debugging: the entries, and one clicked by its index.
    var debugEntries: String { entries.enumerated().map { "\($0.offset) \($0.element.title)" }.joined(separator: "\n") }
    func debugClick(_ n: Int) -> String {
        guard n >= 0, n < entries.count else { return "no entry \(n) of \(entries.count)" }
        delegate?.outline(self, go: entries[n])
        return "clicked \(entries[n].title)"
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < entries.count else { return }
        delegate?.outline(self, go: entries[row])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, table.selectedRow >= 0, table.selectedRow < entries.count {
            delegate?.outline(self, go: entries[table.selectedRow])
        } else {
            super.keyDown(with: event)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("entry"), owner: nil) as? OutlineLensRow ?? {
            let r = OutlineLensRow()
            r.identifier = .init("entry")
            return r
        }()
        cell.show(entries[row])
        return cell
    }
}

/// An outline row: a mark, the words, and the outcome in grey at the right.
final class OutlineLensRow: NSTableCellView {
    private let mark = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var level = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 1.5
        title.font = .systemFont(ofSize: 12)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = Theme.secondaryText
        detail.alignment = .right
        for v in [mark, title, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ e: OutlineLensView.Entry) {
        level = e.level
        title.stringValue = e.title
        title.font = e.line != nil ? .systemFont(ofSize: e.level == 0 ? 12.5 : 12, weight: e.level == 0 ? .semibold : .regular) : .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detail.stringValue = e.detail
        detail.isHidden = e.detail.isEmpty
        mark.layer?.backgroundColor = (e.failed ? Theme.statusError : e.running ? Theme.accent : Theme.secondaryText.withAlphaComponent(0.6)).cgColor
        toolTip = e.title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let x = 12 + CGFloat(level) * 14
        mark.frame = NSRect(x: x, y: (h - 3) / 2, width: 3, height: 3)
        var right = bounds.width - 10
        if !detail.isHidden {
            let w = min(140, ceil((detail.stringValue as NSString).size(withAttributes: [.font: detail.font!]).width) + 2)
            detail.frame = NSRect(x: right - w, y: (h - 14) / 2, width: w, height: 14)
            right -= w + 8
        }
        title.frame = NSRect(x: x + 10, y: (h - 16) / 2, width: max(0, right - x - 10), height: 16)
    }
}
