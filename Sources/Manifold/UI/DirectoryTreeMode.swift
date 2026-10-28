import AppKit
import ManifoldCore

/// A folder as one tree (§7.4), as Claude Code's file panel shows one:
/// flat, each folder opening in place (a click on it, or its chevron), a
/// file a small symbol in its type's colour; under a filter, the files
/// matching it instead, best first, the letters matched in bold and the
/// folder each is in beside it. The file chosen is previewed at the right,
/// as the Finder's columns do, when the tile is wide enough for both.
/// Which folders are open, and where the divider is, are kept with the tile.
final class DirectoryTreeMode: NSView, DebugDescribing, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSplitViewDelegate {
    private unowned let owner: DirectoryView
    private let model: DirectoryModel
    private let split = NSSplitView()
    private let left = NSView()
    private let scroll = ClippingScrollView()
    private let outline = TreeOutline()
    private let right = NSView()
    private let preview = FilePreviewView()
    private let nothing = NSTextField(labelWithString: "Choose a file to preview it")
    /// Open folders, relative to the root.
    private var expanded: Set<String>
    /// Each folder's shown entries, as last asked for.
    private var cache: [String: [BrowserNode]] = [:]
    /// Under the filter: the files matching it, best first.
    private var matched: [BrowserNode] = []
    private var pendingSelect: String?
    private var restoring = false
    private var scrollRestored = false

    var focusView: NSView { outline }

    /// Narrower than this, no preview: the tree alone.
    static let previewFrom: CGFloat = 520

    init(owner: DirectoryView, model: DirectoryModel) {
        self.owner = owner
        self.model = model
        expanded = Set((owner.keeper.value("expanded") ?? "").split(separator: "\n").map(String.init))
        super.init(frame: .zero)
        outline.onSlash = { [unowned owner] in owner.focusFilter() }
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = false
        outline.backgroundColor = .clear
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        // An entry right-clicked: its menu, made then.
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        left.addSubview(scroll)
        preview.resolve = { [weak owner] path, done in
            guard let owner else { done(nil); return {} }
            return owner.resolve(path, done: done)
        }
        nothing.font = UIType.body
        nothing.textColor = Theme.secondaryText
        nothing.alignment = .center
        right.addSubview(preview)
        right.addSubview(nothing)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        addSubview(split)
        scroll.watchScrolling { [weak owner] _, y in owner?.keeper.note(["scroll": "\(y)"]) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { preview.close() }

    // MARK: Layout

    override func layout() {
        super.layout()
        split.frame = bounds
        let wide = bounds.width >= Self.previewFrom
        if right.isHidden == wide {
            right.isHidden = !wide
            split.adjustSubviews()
            if wide { placeDivider() }
        }
        if !dividerPlaced, wide, bounds.width > 0 { placeDivider() }
        scroll.frame = left.bounds
        outline.tableColumns.first?.width = scroll.contentSize.width
        preview.frame = right.bounds.insetBy(dx: 12, dy: 12)
        nothing.frame = NSRect(x: 0, y: right.bounds.midY - 9, width: right.bounds.width, height: 18)
    }

    private var dividerPlaced = false

    /// Where it was left, or two fifths of the way across.
    private func placeDivider() {
        dividerPlaced = true
        let kept = owner.keeper.double("split")
        let x = kept.map { min(max($0, 200), bounds.width - 220) } ?? (bounds.width * 0.42).rounded()
        split.setPosition(x, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - 200
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard dividerPlaced, !right.isHidden, NSApp.currentEvent?.type == .leftMouseDragged else { return }
        owner.keeper.note(["split": "\(left.frame.width)"])
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === right }

    // MARK: Data

    private func kids(_ item: Any?) -> [BrowserNode] {
        if model.filtering { return item == nil ? matched : [] }
        let folder = (item as? BrowserNode)?.path ?? model.root
        if let c = cache[folder] { return c }
        guard let c = model.children(of: folder) else { return [] }
        cache[folder] = c
        return c
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { kids(item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { kids(item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !model.filtering && (item as? BrowserNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SelectionRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? BrowserNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: TreeCell.id, owner: nil) as? TreeCell ?? TreeCell()
        if model.filtering {
            let rel = model.relative(n.path)
            // Where its letters fell: those in its name, its name's own.
            let nameStart = rel.count - n.name.count
            let inName = (model.matchedAt[rel] ?? []).filter { $0 >= nameStart }.map { $0 - nameStart }
            cell.show(n, bold: inName, folder: rel.deletingLastPathComponent, chevron: outline.chevronWidth)
        } else {
            cell.show(n, bold: [], folder: nil, chevron: outline.chevronWidth)
        }
        return cell
    }

    func folder(at point: NSPoint) -> String? {
        let row = outline.row(at: outline.convert(point, from: self))
        guard row >= 0, let node = outline.item(atRow: row) as? BrowserNode, node.isDirectory else { return nil }
        return node.path
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? BrowserNode, let m = owner.menu(for: node) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? BrowserNode).map(owner.pasteboardWriter)
    }

    var shownFolders: [String] { model.filtering ? [] : expanded.map { model.absolute($0) } }

    // MARK: Choosing, opening

    /// A folder's row clicked: opened or closed (its chevron does that by
    /// itself); a file's, chosen — and previewed.
    @objc private func clicked() {
        let row = outline.clickedRow
        // A double-click's second: it opens (below), not toggles again.
        guard (NSApp.currentEvent?.clickCount ?? 1) < 2 else { return }
        guard row >= 0, let n = outline.item(atRow: row) as? BrowserNode, n.isDirectory, !model.filtering else { return }
        let p = outline.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
        if outline.frameOfOutlineCell(atRow: row).insetBy(dx: -4, dy: 0).contains(p) { return }
        toggle(n)
    }

    /// Double-clicked, a file or a folder opens, as its menu's Open does
    /// (a folder in this tile; ⌘ beside, ⌥ over).
    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? BrowserNode else { return }
        owner.open(n)
    }

    /// A folder opened if it's closed, closed if it's open.
    func toggle(_ n: BrowserNode) {
        if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        showPreview()
        guard !restoring else { return }
        pendingSelect = nil
        owner.selectionChanged(selectedPath)
    }

    private func showPreview() {
        let n = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? BrowserNode : nil
        preview.show(n)
        nothing.isHidden = n != nil
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, !model.filtering, let n = notification.userInfo?["NSObject"] as? BrowserNode else { return }
        expanded.insert(model.relative(n.path))
        noteExpanded()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, !model.filtering, let n = notification.userInfo?["NSObject"] as? BrowserNode else { return }
        let rel = model.relative(n.path)
        expanded = expanded.filter { $0 != rel && !$0.hasPrefix(rel + "/") }
        noteExpanded()
    }

    private func noteExpanded() { owner.keeper.note(["expanded": expanded.sorted().joined(separator: "\n")]) }

    var selectedPath: String? {
        outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? BrowserNode)?.path : nil
    }

    var selectedNode: BrowserNode? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? BrowserNode : nil
    }

    func select(_ path: String?) {
        guard let path, path != model.root else {
            outline.deselectAll(nil)
            return
        }
        if !model.filtering {
            // The folders on the way opened, as far as they're listed.
            var chain: [String] = []
            var dir = path.deletingLastPathComponent
            while dir.count > model.root.count, dir.hasPrefix(model.root) {
                chain.insert(dir, at: 0)
                dir = dir.deletingLastPathComponent
            }
            restoring = true
            for d in chain {
                guard let n = model.existingNode(d), outline.row(forItem: n) >= 0 else { break }
                if !outline.isItemExpanded(n) {
                    outline.expandItem(n)
                    expanded.insert(model.relative(d))
                }
            }
            restoring = false
            noteExpanded()
        }
        if let n = model.existingNode(path), case let row = outline.row(forItem: n), row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            pendingSelect = nil
        } else {
            pendingSelect = path
        }
    }

    /// The first row (a filter's best match), chosen.
    func selectFirst() {
        guard outline.numberOfRows > 0 else { return }
        outline.selectRowIndexes([0], byExtendingSelection: false)
        outline.scrollRowToVisible(0)
    }

    // MARK: Changes

    func folderChanged(_ folder: String) {
        cache.removeValue(forKey: folder)
        guard !model.filtering else { return }
        if folder == model.root { return reloadAll() }
        let keep = pendingSelect ?? selectedPath
        guard let n = model.existingNode(folder), outline.row(forItem: n) >= 0 else { return }
        restoring = true
        outline.reloadItem(n, reloadChildren: true)
        openAsKept()
        restoring = false
        select(keep)
    }

    func reloadAll() {
        let keep = pendingSelect ?? selectedPath
        cache.removeAll()
        matched = model.filtering ? model.matchedFiles() : []
        restoring = true
        outline.reloadData()
        if !model.filtering { openAsKept() }
        restoring = false
        select(keep)
        if model.filtering, outline.selectedRow < 0 { showPreview() }
        // The scroll as it was left, the first time.
        if !scrollRestored, !model.filtering, outline.numberOfRows > 0 {
            scrollRestored = true
            if let y = owner.keeper.double("scroll") {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let most = max(0, self.outline.frame.height - self.scroll.contentView.bounds.height)
                    self.scroll.scrollTo(x: 0, y: min(y, most))
                }
            }
        }
    }

    /// The folders opened as they were left.
    private func openAsKept() {
        var i = 0
        while i < outline.numberOfRows {
            if let n = outline.item(atRow: i) as? BrowserNode, n.isDirectory {
                let open = expanded.contains(model.relative(n.path))
                if open, !outline.isItemExpanded(n) { outline.expandItem(n) }
                if !open, outline.isItemExpanded(n) { outline.collapseItem(n) }
            }
            i += 1
        }
    }

    var debugRows: String {
        "preview \(right.isHidden ? "hidden" : "\(Int(right.frame.width)) wide: " + (preview.node?.name ?? "nothing") + " (" + preview.debugState + ")") tree \(Int(left.frame.width))\n"
            + (0..<min(outline.numberOfRows, 60)).compactMap { r -> String? in
                guard let n = outline.item(atRow: r) as? BrowserNode else { return nil }
                let mark = n.isDirectory ? (outline.isItemExpanded(n) ? "▾ " : "▸ ") : "  "
                var line = String(repeating: "  ", count: outline.level(forRow: r)) + mark + n.name
                if model.filtering { line += "  (" + model.relative(n.path).deletingLastPathComponent + ")" }
                return line + (outline.selectedRow == r ? "  ◀" : "")
            }.joined(separator: "\n")
    }
}

/// The tree's outline: a file's row starts where a folder's chevron is, so
/// the file's symbol stands in the chevron's column and every name lines
/// up, as Claude Code's do.
final class TreeOutline: NSOutlineView {
    /// How wide a folder's chevron is, as measured from one.
    private(set) var chevronWidth: CGFloat = 16
    /// /, typed in the list: to the filter (before select-by-typing takes it).
    var onSlash: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, event.charactersIgnoringModifiers == "/", let onSlash { return onSlash() }
        super.keyDown(with: event)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var f = super.frameOfCell(atColumn: column, row: row)
        guard let n = item(atRow: row) as? BrowserNode else { return f }
        if n.isDirectory {
            let chevron = frameOfOutlineCell(atRow: row)
            if chevron.width > 0 { chevronWidth = max(8, f.minX - chevron.minX) }
            return f
        }
        f.origin.x -= chevronWidth
        f.size.width += chevronWidth
        return f
    }
}

/// An entry's row: a file's type as a small symbol in its colour (a folder
/// has its chevron), its name in the system font — the letters a filter
/// matched in bold — and, under a filter, the folder it's in, in grey.
final class TreeCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("tree-cell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isFolder = false
    private var chevron: CGFloat = 16

    func show(_ n: BrowserNode, bold: [Int], folder: String?, chevron: CGFloat) {
        isFolder = n.isDirectory
        self.chevron = chevron
        let fade: CGFloat = n.isMuted ? 0.5 : 1
        if n.isDirectory {
            icon.image = nil
        } else {
            let g = Self.glyph(n.name)
            icon.image = Theme.symbol(g.symbol, size: 12, weight: .medium)?.tinted(g.color.withAlphaComponent(fade))
        }
        let text = NSMutableAttributedString(string: n.name, attributes: [
            // Muted (ignored, hidden): the tertiary grey, which still reads.
            .font: UIType.row, .foregroundColor: n.isMuted ? Theme.tertiaryText : Theme.text,
        ])
        let length = (n.name as NSString).length
        for i in bold {
            // Offsets in characters; the string's in UTF-16.
            guard let r = n.name.index(n.name.startIndex, offsetBy: i, limitedBy: n.name.endIndex), r < n.name.endIndex else { continue }
            let range = NSRange(r...r, in: n.name)
            if range.location + range.length <= length { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: range) }
        }
        if let folder, !folder.isEmpty {
            text.append(NSAttributedString(string: "  " + folder, attributes: [
                .font: UIType.body, .foregroundColor: Theme.secondaryText,
            ]))
        }
        label.attributedStringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        // A file's row starts a chevron's width further left (`TreeOutline`):
        // its symbol in the chevron's column, its name where a folder's is.
        icon.frame = NSRect(x: ((chevron - 14) / 2).rounded(), y: (h - 14) / 2, width: 14, height: 14)
        let x: CGFloat = isFolder ? 2 : chevron + 2
        label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, bounds.width - x - 8), height: 17)
    }

    /// A file's type at a glance: a symbol, and a colour.
    static func glyph(_ name: String) -> (symbol: String, color: NSColor) {
        let lower = name.lowercased()
        let ext = lower.pathExtension
        if lower.hasPrefix(".git") { return ("arrow.triangle.branch", .systemOrange) }
        switch ext {
        case "swift", "swiftinterface": return ("swift", .systemOrange)
        case "sh", "bash", "zsh", "fish", "command": return ("apple.terminal", .systemGreen)
        case "md", "markdown", "txt", "rst", "org", "tex": return ("doc.text", Theme.secondaryText)
        case "pdf": return ("doc.richtext", .systemRed)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "ico", "tiff", "bmp": return ("photo", .systemPurple)
        case "json", "yaml", "yml", "toml", "plist", "ini", "conf", "cfg", "xcconfig", "lock": return ("curlybraces", .systemYellow)
        case "patch", "diff": return ("plus.forwardslash.minus", .systemGreen)
        case "zip", "tar", "gz", "tgz", "xz", "bz2", "zst", "dmg": return ("archivebox", .systemBrown)
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "go", "py", "rb", "java", "kt", "zig", "js", "jsx", "ts", "tsx",
             "html", "css", "scss", "lua", "ex", "exs", "hs", "ml", "php", "cs", "scala", "dart", "vue":
            return ("chevron.left.forwardslash.chevron.right", .systemBlue)
        case "mp3", "wav", "m4a", "aac", "flac": return ("waveform", .systemPink)
        case "mp4", "mov", "m4v", "webm": return ("film", .systemPink)
        default:
            if ["makefile", "dockerfile", "package.swift", "license", "readme"].contains(lower) { return ("doc.text", Theme.secondaryText) }
            return ("doc", Theme.secondaryText)
        }
    }
}
