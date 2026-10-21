import AppKit
import ManifoldCore

/// A folder as columns (§7.4), as the Finder's: each folder chosen opens
/// in the next column, and a file chosen is previewed in the last — Quick
/// Look's view of it, its name, kind, size and date.
final class DirectoryColumnsMode: NSView, DirectoryMode, DebugDescribing, NSBrowserDelegate {
    private unowned let owner: DirectoryView
    private let model: DirectoryModel
    private let browser = NSBrowser()
    private var cache: [String: [BrowserNode]] = [:]
    private var pendingSelect: String?
    private var restoring = false
    private var previews: [FilePreviewController] = []

    var focusView: NSView { browser }

    init(owner: DirectoryView, model: DirectoryModel) {
        self.owner = owner
        self.model = model
        super.init(frame: .zero)
        browser.delegate = self
        browser.isTitled = false
        browser.separatesColumns = true
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 150
        browser.allowsMultipleSelection = false
        browser.allowsEmptySelection = true
        browser.rowHeight = 22
        browser.backgroundColor = Theme.windowBackground
        browser.target = self
        browser.action = #selector(chosen)
        browser.doubleAction = #selector(doubleClicked)
        browser.cellPrototype = BrowserCell()
        addSubview(browser)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { previews.forEach { $0.preview.close() } }

    override func layout() {
        super.layout()
        browser.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        browser.backgroundColor = Theme.windowBackground
    }

    // MARK: Data

    private func kids(_ item: Any?) -> [BrowserNode]? {
        let folder = (item as? BrowserNode)?.path ?? model.root
        if let c = cache[folder] { return c }
        guard let c = model.children(of: folder) else { return nil }
        cache[folder] = c
        return c
    }

    func rootItem(for browser: NSBrowser) -> Any? { model.rootNode }
    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int { kids(item)?.count ?? 0 }
    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any { kids(item)![index] }
    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool { (item as? BrowserNode)?.isDirectory == false }
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? { (item as? BrowserNode)?.name }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? BrowserCell, let n = sender.item(atRow: row, inColumn: column) as? BrowserNode else { return }
        cell.node = n
    }

    func browser(_ browser: NSBrowser, shouldSizeColumn columnIndex: Int, forUserResize: Bool, toWidth suggestedWidth: CGFloat) -> CGFloat {
        forUserResize ? suggestedWidth : 220
    }

    func browser(_ browser: NSBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController? {
        let c = FilePreviewController()
        c.preview.resolve = { [weak owner] path, done in
            guard let owner else { return done(nil) }
            owner.resolve(path, done: done)
        }
        previews.append(c)
        return c
    }

    var shownFolders: [String] {
        guard browser.lastColumn >= 0 else { return [] }
        return (0...browser.lastColumn).compactMap { (browser.parentForItems(inColumn: $0) as? BrowserNode)?.path }.filter { $0 != model.root }
    }

    // MARK: Choosing

    var selectedPath: String? {
        let c = browser.selectedColumn
        guard c >= 0, case let r = browser.selectedRow(inColumn: c), r >= 0 else { return nil }
        return (browser.item(atRow: r, inColumn: c) as? BrowserNode)?.path
    }

    @objc private func chosen() {
        guard !restoring else { return }
        pendingSelect = nil
        owner.selectionChanged(selectedPath)
    }

    @objc private func doubleClicked() {
        guard let p = selectedPath, let n = model.existingNode(p) else { return }
        owner.open(n)
    }

    func select(_ path: String?) {
        guard let path, path != model.root else { return }
        // Each folder on the way chosen in its column, as far as they're listed.
        let parts = model.relative(path).split(separator: "/").map(String.init)
        var indexes: [Int] = []
        var folder = model.root
        for part in parts {
            guard let children = kids(model.existingNode(folder) ?? (folder == model.root ? model.rootNode : nil)) else {
                pendingSelect = path
                break
            }
            guard let i = children.firstIndex(where: { $0.name == part }) else {
                pendingSelect = nil
                break
            }
            indexes.append(i)
            folder = folder.appendingPathComponent(part)
        }
        guard !indexes.isEmpty else { return }
        restoring = true
        browser.selectionIndexPath = IndexPath(indexes: indexes)
        restoring = false
        if indexes.count == parts.count { pendingSelect = nil }
        browser.scrollColumnToVisible(min(indexes.count, browser.lastColumn))
    }

    // MARK: Changes

    func folderChanged(_ folder: String) {
        cache.removeValue(forKey: folder)
        let keep = pendingSelect ?? selectedPath
        guard (0...max(0, browser.lastColumn)).contains(where: { (browser.parentForItems(inColumn: $0) as? BrowserNode)?.path == folder }) || folder == model.root else {
            return
        }
        reload(keeping: keep)
    }

    func reloadAll() {
        let keep = pendingSelect ?? selectedPath
        cache.removeAll()
        reload(keeping: keep)
    }

    private func reload(keeping keep: String?) {
        restoring = true
        browser.loadColumnZero()
        restoring = false
        select(keep)
    }

    var debugRows: String {
        guard browser.lastColumn >= 0 else { return "" }
        return (0...browser.lastColumn).map { c -> String in
            let items = kids(browser.parentForItems(inColumn: c)) ?? []
            let chosen = browser.selectedRow(inColumn: c)
            return "column \(c): " + items.prefix(12).enumerated().map { $0.offset == chosen ? "[\($0.element.name)]" : $0.element.name }.joined(separator: " ")
        }.joined(separator: "\n") + "\npreviews \(previews.count): " + previews.map { "\($0.preview.node?.name ?? "none") \(Int($0.view.frame.width))x\(Int($0.view.frame.height)), \($0.preview.debugState)" }.joined(separator: ", ")
    }
}

/// A browser row: the type's icon, the name, dimmed when hidden or ignored.
final class BrowserCell: NSBrowserCell {
    var node: BrowserNode? {
        didSet {
            guard let node else { return }
            let i = node.icon.copy() as! NSImage
            i.size = NSSize(width: 16, height: 16)
            image = i
            isLeaf = !node.isDirectory
            attributedStringValue = NSAttributedString(string: node.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: Theme.text.withAlphaComponent(node.isMuted ? 0.5 : 1),
            ])
        }
    }

    override init(textCell string: String) { super.init(textCell: string) }
    override init(imageCell image: NSImage?) { super.init(imageCell: image) }
    required init(coder: NSCoder) { super.init(coder: coder) }
}
