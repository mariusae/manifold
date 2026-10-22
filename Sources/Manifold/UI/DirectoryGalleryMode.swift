import AppKit
import ManifoldCore

/// A folder as a gallery (§7.4), as the Finder's: the file chosen large —
/// Quick Look's view of it, with its name, kind, size and date — over a
/// strip of thumbnails of the folder's files (under a filter, of every
/// file that matched), ← and → going along it.
final class DirectoryGalleryMode: NSView, DirectoryMode, DebugDescribing, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
    private unowned let owner: DirectoryView
    private let model: DirectoryModel
    private let preview = FilePreviewView()
    private let scroll = ClippingScrollView()
    private let strip = GalleryStrip()
    private let divider = NSBox()
    private var items: [BrowserNode] = []
    private var pendingSelect: String?
    private var restoring = false
    static let stripHeight: CGFloat = 92

    var focusView: NSView { strip }

    init(owner: DirectoryView, model: DirectoryModel) {
        self.owner = owner
        self.model = model
        super.init(frame: .zero)
        preview.centered = true
        preview.resolve = { [weak owner] path, done in
            guard let owner else { return done(nil) }
            owner.resolve(path, done: done)
        }
        addSubview(preview)
        divider.boxType = .separator
        addSubview(divider)
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 72, height: 72)
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        strip.collectionViewLayout = layout
        strip.isSelectable = true
        strip.allowsMultipleSelection = false
        strip.allowsEmptySelection = true
        strip.backgroundColors = [.clear]
        strip.dataSource = self
        strip.menu = NSMenu()
        strip.menu?.delegate = self
        strip.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
        strip.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        strip.delegate = self
        strip.register(GalleryItem.self, forItemWithIdentifier: GalleryItem.id)
        strip.opened = { [weak self] i in
            guard let self, i < self.items.count else { return }
            self.owner.open(self.items[i])
        }
        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { preview.close() }

    override func layout() {
        super.layout()
        let h = Self.stripHeight
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        divider.frame = NSRect(x: 0, y: h, width: bounds.width, height: 1)
        preview.frame = NSRect(x: 0, y: h + 1, width: bounds.width, height: max(0, bounds.height - h - 1))
    }

    // MARK: Data

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GalleryItem.id, for: indexPath) as! GalleryItem
        let n = items[indexPath.item]
        item.show(n, local: owner.isLocal, scale: window?.backingScaleFactor ?? 2)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionMoved() }

    func folder(at point: NSPoint) -> String? { nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let window = strip.window,
              let i = strip.indexPathForItem(at: strip.convert(window.mouseLocationOutsideOfEventStream, from: nil))?.item,
              items.indices.contains(i), let m = owner.menu(for: items[i]) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? owner.pasteboardWriter(for: items[indexPath.item]) : nil
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionMoved() }

    private func selectionMoved() {
        preview.show(selectedPath.flatMap { model.existingNode($0) })
        guard !restoring else { return }
        pendingSelect = nil
        owner.selectionChanged(selectedPath)
    }

    var selectedPath: String? {
        guard let i = strip.selectionIndexPaths.first?.item, i < items.count else { return nil }
        return items[i].path
    }

    func select(_ path: String?) {
        guard let path else { return }
        guard let i = items.firstIndex(where: { $0.path == path }) else {
            // Deeper than the strip goes (chosen in another mode): what holds it.
            if !model.filtering, path.hasPrefix(model.root + "/"), case let top = model.root + "/" + model.relative(path).split(separator: "/")[0],
               top != path, items.contains(where: { $0.path == top }) {
                return select(top)
            }
            pendingSelect = path
            return
        }
        pendingSelect = nil
        let ip = IndexPath(item: i, section: 0)
        restoring = true
        strip.selectionIndexPaths = [ip]
        restoring = false
        strip.scrollToItems(at: [ip], scrollPosition: .centeredHorizontally)
        preview.show(items[i])
    }

    var shownFolders: [String] { [] }

    // MARK: Changes

    func folderChanged(_ folder: String) {
        guard folder == model.root, !model.filtering else { return }
        reloadAll()
    }

    func reloadAll() {
        let keep = pendingSelect ?? selectedPath
        items = model.filtering ? model.matchedFiles() : (model.children(of: model.root) ?? [])
        restoring = true
        strip.reloadData()
        restoring = false
        select(keep ?? items.first?.path)
        if strip.selectionIndexPaths.isEmpty { preview.show(nil) }
    }

    var debugRows: String {
        let chosen = strip.selectionIndexPaths.first?.item
        return "strip: " + items.prefix(20).enumerated().map { $0.offset == chosen ? "[\($0.element.name)]" : $0.element.name }.joined(separator: " ")
            + "\npreview: " + (preview.node?.name ?? "none") + ", " + preview.debugState
    }
}

/// The strip: a double-click (or ⏎) opens what it's on.
final class GalleryStrip: NSCollectionView {
    var opened: (Int) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2, let i = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item else { return }
        opened(i)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let i = selectionIndexPaths.first?.item {
            opened(i)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// One thumbnail in the strip, rounded and lifted when chosen.
final class GalleryItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("gallery")
    private let picture = NSImageView()
    private var path: String?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        picture.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(picture)
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        picture.frame = view.bounds.insetBy(dx: 6, dy: 6)
    }

    func show(_ n: BrowserNode, local: Bool, scale: CGFloat) {
        path = n.path
        view.toolTip = n.name
        picture.alphaValue = n.isMuted ? 0.5 : 1
        Thumbnails.load(n, local: local, size: 60, scale: scale) { [weak self] image in
            guard let self, self.path == n.path else { return }
            self.picture.image = image
        }
    }

    override var isSelected: Bool {
        didSet {
            // The strong selection's ring, thick enough to see without its hue.
            view.layer?.backgroundColor = isSelected ? Theme.selection.cgColor : nil
            view.layer?.borderWidth = isSelected ? 3 : 0
            view.layer?.borderColor = Theme.strongSelection.cgColor
        }
    }
}
