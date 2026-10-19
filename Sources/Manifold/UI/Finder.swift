import AppKit
import ManifoldCore

/// Something the finder can go to: a block (recalled), an arrangement, or a
/// file not yet a block.
struct FinderItem {
    var symbol: String
    var title: String
    var detail: String
    /// A word on the right: "edited", "dormant", "named", or where it is.
    var note: String
    /// How far in, in an outline (⌘\): 0 at the top.
    var level: Int = 0
    var run: () -> Void
}

/// ⌘O: one field that finds anything the attached hosts know, in one of
/// three scopes (⇥ goes round them): **names** — blocks by title and
/// path, workspaces by name, processes, files under the focused folder
/// by name — ranked by how well the query matches; **in files** — lines
/// in the files under the project, as the host finds them; **in blocks**
/// — lines in the texts of the workspace's blocks. ↩ goes there.
final class Finder: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Scope: Int, CaseIterable {
        case names, contents, blocks
        var title: String {
            switch self {
            case .names: "Names"
            case .contents: "In Files"
            case .blocks: "In Blocks"
            }
        }
    }

    /// Items for a query in a scope, given the files under the folder
    /// listed so far.
    var search: ((String, [String], Scope) -> [FinderItem])?
    /// The scope or query changed: what's asked of a host can start.
    var onQueryChanged: ((String, Scope) -> Void)?
    private(set) var scope: Scope = .names
    private let scopes = NSSegmentedControl(labels: Scope.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    var isShowing: Bool { panel.isVisible }
    /// ⌘\: the workspace as a hierarchy, filtered by a query, instead.
    private var outline: ((String) -> [FinderItem])?
    /// The row the outline begins at (where you are), while nothing is typed.
    private var outlineStart: Int?

    private let panel: PickerPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var root = ""
    private var files: [String] = []
    private var shown: [FinderItem] = []
    private var listing = 0

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 9

    override init() {
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.onResign = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))!)
        glass.contentTintColor = .secondaryLabelColor
        glass.frame = NSRect(x: 18, y: 0, width: 24, height: Self.fieldHeight)
        background.addSubview(glass)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "Find anything…"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        background.addSubview(field)

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        background.addSubview(scroll)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        background.addSubview(hint)
        scopes.segmentStyle = .capsule
        scopes.controlSize = .mini
        scopes.font = .systemFont(ofSize: 10)
        scopes.selectedSegment = 0
        scopes.target = self
        scopes.action = #selector(scopeChosen)
        background.addSubview(scopes)
    }

    @objc private func scopeChosen() {
        scope = Scope(rawValue: scopes.selectedSegment) ?? .names
        queryChanged()
        panel.makeFirstResponder(field)
    }

    private func cycleScope() {
        scope = Scope(rawValue: (scope.rawValue + 1) % Scope.allCases.count) ?? .names
        scopes.selectedSegment = scope.rawValue
        queryChanged()
    }

    private func queryChanged() {
        onQueryChanged?(field.stringValue.trimmingCharacters(in: .whitespaces), scope)
        refresh()
    }

    /// Results came in (a host's search): listed again.
    func refreshResults() {
        guard panel.isVisible else { return }
        refresh()
    }

    // MARK: Showing

    /// Shows, listing the files under `root` among everything else.
    func show(root: String, over window: NSWindow?) {
        self.root = root
        outline = nil
        scopes.isHidden = false
        field.placeholderString = "Find anything…"
        field.stringValue = ""
        files = []
        shown = []
        table.reloadData()
        listing += 1
        let token = listing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = FileFinder.list(root: root)
            DispatchQueue.main.async {
                guard let self, self.listing == token else { return }
                self.files = found
                self.refresh()
            }
        }
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Shows the workspace's outline (⌘\): tiles by column, and what is in
    /// them, as `provider` lists them for a query.
    func showOutline(_ provider: @escaping (String) -> [FinderItem], startingAt start: Int? = nil, over window: NSWindow?) {
        outline = provider
        outlineStart = start
        scopes.isHidden = true
        field.stringValue = ""
        field.placeholderString = "Go to a tile, or a heading in one…"
        files = []
        shown = []
        listing += 1
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Types a query and says what's listed (for DebugControl).
    func debugQuery(_ query: String) -> [String] {
        field.stringValue = query
        if outline == nil { onQueryChanged?(query, scope) }
        refresh()
        return shown.map { String(repeating: "  ", count: $0.level) + "\($0.title) — \($0.detail)" + ($0.note.isEmpty ? "" : " [\($0.note)]") }
    }

    /// Chooses the selected row, or moves the selection (for DebugControl).
    func debugChoose() { openSelected() }
    func debugScope(_ n: Int) {
        scope = Scope(rawValue: n) ?? .names
        scopes.selectedSegment = scope.rawValue
        queryChanged()
    }
    func debugMove(_ by: Int) { move(by) }

    func close() {
        listing += 1
        panel.orderOut(nil)
    }

    private func updateHint() {
        if outline != nil {
            hint.stringValue = "The workspace, by column and tile, headings within    ↩ Go    ⎋ Close"
            return
        }
        let folder = root.abbreviatingHome
        hint.stringValue = switch scope {
        case .names: files.isEmpty && listing > 0 ? "Looking in \(folder)…" : "Blocks, workspaces, processes, and files in \(folder)    ⇥ Scope    ↩ Open    ⎋ Close"
        case .contents: "Lines in the files under the project    ⇥ Scope    ↩ Open    ⎋ Close"
        case .blocks: "Lines in the workspace's texts    ⇥ Scope    ↩ Go    ⎋ Close"
        }
    }

    /// Sizes the panel to its results, keeping its top where it is.
    private func layout() {
        let rows = min(shown.count, Self.visibleRows)
        let listHeight = rows == 0 ? 0 : CGFloat(rows) * (Self.rowHeight + 2) + 12
        let hintHeight: CGFloat = 24
        let height = Self.fieldHeight + listHeight + hintHeight
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        field.frame = NSRect(x: 52, y: height - Self.fieldHeight + 13, width: Self.width - 70, height: 30)
        scroll.frame = NSRect(x: 0, y: hintHeight, width: Self.width, height: listHeight)
        scopes.sizeToFit()
        scopes.frame = NSRect(x: 14, y: 3, width: scopes.frame.width, height: 18)
        hint.frame = NSRect(x: scopes.frame.maxX + 8, y: 4, width: Self.width - scopes.frame.maxX - 24, height: 16)
        panel.contentView?.subviews.first { $0 is NSImageView }?.frame.origin.y = height - Self.fieldHeight
    }

    // MARK: Finding

    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        shown = outline.map { $0(query) } ?? search?(query, files.map { absolute($0) }, scope) ?? []
        table.reloadData()
        if !shown.isEmpty {
            let row = query.isEmpty && outline != nil ? min(outlineStart ?? 0, shown.count - 1) : 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateHint()
        layout()
    }

    private func absolute(_ item: String) -> String {
        item.hasPrefix("/") ? item : (root as NSString).appendingPathComponent(item)
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertTab(_:)) where outline == nil: cycleScope()
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        if outline == nil { onQueryChanged?(field.stringValue.trimmingCharacters(in: .whitespaces), scope) }
        refresh()
    }

    private func move(_ by: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        openSelected()
    }

    private func openSelected() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        let item = shown[table.selectedRow]
        close()
        item.run()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        let item = shown[row]
        cell.show(title: item.title, detail: item.detail, symbol: item.symbol, note: item.note, level: item.level)
        return cell
    }

    static func symbol(forFile name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp": "photo"
        case "json", "yaml", "yml", "toml", "plist", "xml": "curlybraces"
        case "sh", "zsh", "bash", "fish": "terminal"
        case "": "doc"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// How well `query` matches `text`: 0 for not at all.
    static func score(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        return FileFinder.score(query.lowercased(), text.lowercased()) ?? 0
    }
}

/// An item in the list: its title, where it is under it, and a note at the right.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private var lead: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.alignment = .right
        for field in [title, detail] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [symbol, title, detail, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        lead = symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            lead,
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: note.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: note.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail folder: String, symbol name: String, note text2: String, level: Int = 0) {
        lead.constant = 8 + CGFloat(level) * 22
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        title.stringValue = text
        detail.stringValue = folder
        detail.isHidden = folder.isEmpty
        note.stringValue = text2
    }
}

/// The finder's window: floating, with no title bar to speak of, that can
/// take the keyboard and gives it back when it loses it.
final class PickerPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
