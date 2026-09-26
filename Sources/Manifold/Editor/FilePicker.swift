import AppKit
import ManifoldCore

/// File ▸ Open (⌘O): one field that finds a file under a folder by name (or
/// takes a path), and opens it to edit. With nothing typed, it lists the
/// folder's files, nearest first.
final class FilePicker: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Told the chosen file's full path.
    var onOpen: ((String) -> Void)?

    private let panel: PickerPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var root = ""
    private var files: [String] = []
    private var shown: [String] = []
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
        field.placeholderString = "Open a file…"
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
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
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
    }

    // MARK: Showing

    /// Shows the files under `root`, over `window`.
    func show(root: String, over window: NSWindow?) {
        self.root = root
        field.stringValue = ""
        files = []
        shown = []
        table.reloadData()
        updateHint()
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
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        layout()
    }

    /// Types a query and says what's listed (for DebugControl).
    func debugQuery(_ query: String) -> [String] {
        field.stringValue = query
        refresh()
        return shown
    }

    func close() {
        listing += 1
        panel.orderOut(nil)
    }

    private func updateHint() {
        let folder = MainWindowController.abbreviate(root)
        hint.stringValue = files.isEmpty && listing > 0 ? "Looking in \(folder)…" : "In \(folder)    ↩ Open    ⎋ Close"
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
        hint.frame = NSRect(x: 16, y: 4, width: Self.width - 32, height: 16)
        panel.contentView?.subviews.first { $0 is NSImageView }?.frame.origin.y = height - Self.fieldHeight
    }

    // MARK: Finding

    func controlTextDidChange(_ notification: Notification) { refresh() }

    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        var results = FileFinder.rank(query, files)
        // A path typed out, to a file that's there: that first.
        if let typed = typedPath(query), !results.contains(where: { absolute($0) == typed }) {
            results.insert(typed, at: 0)
        }
        shown = results
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateHint()
        layout()
    }

    /// A query that's a path to a file, made absolute.
    private func typedPath(_ query: String) -> String? {
        guard query.hasPrefix("/") || query.hasPrefix("~") || query.hasPrefix(".") else { return nil }
        let expanded = (query as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : (root as NSString).appendingPathComponent(expanded)
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standard, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return standard
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
        default: return false
        }
        return true
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
        let path = absolute(shown[table.selectedRow])
        close()
        onOpen?(path)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        let item = shown[row]
        let name = (item as NSString).lastPathComponent
        let dir = (item as NSString).deletingLastPathComponent
        cell.show(title: name, detail: item.hasPrefix("/") ? MainWindowController.abbreviate(dir) : (dir.isEmpty ? "" : dir),
                  symbol: Self.symbol(for: name))
        return cell
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp": "photo"
        case "json", "yaml", "yml", "toml", "plist", "xml": "curlybraces"
        case "sh", "zsh", "bash", "fish": "terminal"
        case "": "doc"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// A file in the list: its name, and its folder under it.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        for field in [title, detail] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [symbol, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail folder: String, symbol name: String) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        title.stringValue = text
        detail.stringValue = folder
        detail.isHidden = folder.isEmpty
    }
}

/// The picker's window: floating, with no title bar to speak of, that can
/// take the keyboard and gives it back when it loses it.
final class PickerPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
