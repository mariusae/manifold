import AppKit
import ManifoldCore
import UniformTypeIdentifiers

protocol DirectoryViewDelegate: AnyObject {
    func directoryView(_ view: DirectoryView, open path: String, isDirectory: Bool)
    func directoryViewRefresh(_ view: DirectoryView)
    /// A folder's entries on the block's host, ignored ones marked.
    func directoryView(_ view: DirectoryView, list path: String, done: @escaping ([DirectoryEntry]?) -> Void)
    /// The tree under a folder on the block's host, less what's ignored.
    func directoryView(_ view: DirectoryView, tree path: String, done: @escaping ([DirectoryEntry]?, Bool) -> Void)
    /// A local URL for a file of the block's host, fetched if need be.
    /// A local URL for a path, to `done`; what it returns gives up on it.
    func directoryView(_ view: DirectoryView, localURLFor path: String, done: @escaping (URL?) -> Void) -> () -> Void
    /// Whether the block's host is this machine.
    func directoryViewIsLocal(_ view: DirectoryView) -> Bool
    /// An entry dragged with ⇧: its block (made if need be), as the link
    /// a note takes, `[title](manifold:id)`; nil for a file no block shows.
    func directoryView(_ view: DirectoryView, linkFor path: String, isDirectory: Bool) -> String?
    /// Files dropped on the folder — this Mac's, or a folder tile's entries
    /// on any host — put in `folder`, on the block's host.
    func directoryView(_ view: DirectoryView, receive items: [DroppedItem], into folder: String, moving: Bool)
    /// An entry of another host's dragged out to another app: brought to
    /// `url` on this Mac.
    func directoryView(_ view: DirectoryView, download path: String, isDirectory: Bool, to url: URL, done: @escaping (String?) -> Void)
    /// An entry right-clicked: what can be done with it.
    func directoryView(_ view: DirectoryView, menuFor path: String, isDirectory: Bool) -> NSMenu?
    /// ⌘[ and ⌘]: the folders this tile showed before (or after), as a
    /// Finder window's back and forward go; false if there's none.
    func directoryView(_ view: DirectoryView, history direction: Int) -> Bool
    /// "?text" in the filter: the files under the folder searched for it.
    func directoryView(_ view: DirectoryView, searchContents text: String)
}

/// What's dropped on a folder's tile: a file or folder of this Mac's, or
/// an entry of a folder's tile, on its host.
enum DroppedItem {
    case local(URL)
    /// Files another app promises (Photos, Mail), written here when dropped.
    case promised(NSFilePromiseReceiver)
    case entry(host: HostID, path: String, isDirectory: Bool)
}

/// The directory lens (§7.4): a folder as one tree, as Claude Code's file
/// panel has it — folders opening in place, the file chosen previewed at
/// the right (`DirectoryTreeMode`) — under the way up and a filter over the
/// whole tree beneath (⌘F), which lists the files matching it as it's
/// typed; "?text" searches inside them instead. What a repository ignores
/// and hidden files are left out (⇧⌘. shows them).
final class DirectoryView: NSView, PaneContent, KeepsViewState, NSTextFieldDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DirectoryViewDelegate?
    var source: () -> Block? = { nil }

    private(set) var model: DirectoryModel?
    private let header = NSView()
    private let up = IconButton(symbol: "arrow.turn.left.up", size: 13, weight: .medium, target: nil, action: nil)
    /// The filter, in its box: flat, as Claude Code's (`FlatFieldBox`).
    private let searchBox = FlatFieldBox()
    private var search: FlatField { searchBox.field }
    private let footer = NSTextField(labelWithString: "")
    /// Over the files: "Reading…" until the folder's listed, why if it
    /// can't be, or that there's nothing in it.
    private let note = BusyNote()
    private var footerWork: DispatchWorkItem?
    private var content: DirectoryTreeMode?
    private var listedAt: Stamp?
    /// The selection, relative to the root, as all modes share it.
    private var selected: String?

    var focusView: NSView { content?.focusView ?? self }
    var isDead: Bool { false }
    static let headerHeight: CGFloat = 44

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }

        up.toolTip = "Enclosing Folder (⌘↑)"
        up.target = self
        up.action = #selector(goUp)
        search.placeholderString = "Filter, or ? to search in files"
        search.delegate = self
        searchBox.onChange = { [weak self] in self?.filterTyped() }
        for v in [up, searchBox] as [NSView] { header.addSubview(v) }
        addSubview(header)
        footer.font = UIType.footnote
        footer.textColor = Theme.secondaryText
        footer.alignment = .center
        footer.isHidden = true
        addSubview(footer)
        addSubview(note)
        registerForDraggedTypes([.fileURL, .manifoldPath] + Promises.types)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        keepCurrent(false)
        keeper.flush()
        content?.destroy()
    }

    // MARK: The block

    /// The block (or its listing) may have changed.
    func documentChanged() {
        guard let b = source(), let path = b.path else { return }
        if model == nil { setUp(path) }
        up.isEnabled = path != "/"
        if let d = b.directory, d.listedAt != nil, d.listedAt != listedAt {
            listedAt = d.listedAt
            model?.setRootEntries(d.entries)
        }
        updateNote()
    }

    /// What's said over the files, if anything.
    private func updateNote() {
        guard let model, !model.filtering, !searchingContents else { return note.set(.idle) }
        guard let d = source()?.directory, d.listedAt != nil else { return note.set(.busy("Reading…")) }
        if let e = d.error { return note.set(.message(e)) }
        if d.entries.isEmpty { return note.set(.message("Empty folder")) }
        // Whether any shows — not every entry sorted and made a node to
        // see (every render came here).
        if !d.entries.contains(where: model.shown) { return note.set(.message("Only hidden files")) }
        note.set(.idle)
    }

    /// Kept current while it's on screen and the app in use: the folder
    /// and those open in it listed again every few seconds — told only
    /// when something changed, so nothing moves (the selection stays).
    private var refresher: Timer?

    private func keepCurrent(_ on: Bool) {
        refresher?.invalidate()
        refresher = nil
        guard on else { return }
        refresher = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            self.delegate?.directoryViewRefresh(self)
            if let shown = self.content?.shownFolders { self.model?.refresh(shown) }
        }
    }

    private func setUp(_ path: String) {
        let m = DirectoryModel(root: path)
        m.list = { [weak self] p, done in
            guard let self, let d = self.delegate else { return done(nil) }
            d.directoryView(self, list: p, done: done)
        }
        m.listTree = { [weak self] p, done in
            guard let self, let d = self.delegate else { return done(nil, false) }
            d.directoryView(self, tree: p, done: done)
        }
        m.changed = { [weak self] folder in
            self?.content?.folderChanged(folder)
            self?.updateFooter()
        }
        m.filterChanged = { [weak self] in
            self?.content?.reloadAll()
            self?.updateFooter()
            self?.updateNote()
        }
        m.readingChanged = { [weak self] in self?.updateFooter() }
        // As it was left.
        m.showHidden = keeper.value("hidden") == "1"
        if let s = keeper.value("sort")?.split(separator: ":"), s.count == 2, let k = DirectoryModel.SortKey(rawValue: String(s[0])) {
            m.sortKey = k
            m.ascending = s[1] == "1"
        }
        model = m
        selected = keeper.value("selected").flatMap { $0.isEmpty ? nil : $0 }
        if let f = keeper.value("filter"), !f.isEmpty {
            searchBox.stringValue = f
            searchBox.update()
            if !f.hasPrefix("?") { m.setFilter(f) }
        }
        keeper.restored = true
        install()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.directoryViewRefresh(self) }
        keepCurrent(window != nil)
    }

    // MARK: The tree

    private func install() {
        guard let model else { return }
        let v = DirectoryTreeMode(owner: self, model: model)
        v.clipsToBounds = true
        addSubview(v, positioned: .below, relativeTo: header)
        content = v
        needsLayout = true
        layoutSubtreeIfNeeded()
        // The folders on the way to the selection, and those left open, asked for at once.
        var wanted = Set((keeper.value("expanded") ?? "").split(separator: "\n").map { model.absolute(String($0)) })
        if var dir = selected?.deletingLastPathComponent {
            while !dir.isEmpty { wanted.insert(model.absolute(dir)); dir = dir.deletingLastPathComponent }
        }
        model.prefetch(Array(wanted))
        v.reloadAll()
        v.select(selected.map { model.absolute($0) })
        // Focused before there was anything to focus: the files now.
        if window?.firstResponder === self { window?.makeFirstResponder(v.focusView) }
    }

    /// The selection moved.
    func selectionChanged(_ path: String?) {
        guard let model else { return }
        selected = path.map { model.relative($0) }
        keeper.note(["selected": selected ?? ""])
    }

    var isLocal: Bool { delegate?.directoryViewIsLocal(self) ?? true }

    func resolve(_ path: String, done: @escaping (URL?) -> Void) -> () -> Void {
        guard let delegate else { done(nil); return {} }
        return delegate.directoryView(self, localURLFor: path, done: done)
    }

    // MARK: Dragging

    /// An entry dragged out, as a tile's pill is with ⇧: its path, for a
    /// terminal to type or an editor to insert; its file, on this machine,
    /// for the grid to open where it lands (or another app to take); and,
    /// with ⇧, its block as a link — a note mentions it, a terminal or a
    /// tile it's dropped on is linked to it. ⌥⇧, the link alone.
    func pasteboardItem(for node: BrowserNode) -> NSPasteboardItem {
        pasteboardItem(for: node, mods: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
    }

    /// What dragging an entry writes: on this Mac, its item (the file's URL
    /// in it); on another host, the same carried by a promise of the file,
    /// so the Finder or Mail can have it — fetched when it's dropped there.
    func pasteboardWriter(for node: BrowserNode) -> NSPasteboardWriting {
        let item = pasteboardItem(for: node)
        guard delegate?.directoryViewIsLocal(self) == false, item.types.contains(.string) else { return item }
        let type = node.isDirectory ? UTType.folder : (UTType(filenameExtension: node.name.pathExtension) ?? .data)
        let promise = EntryPromise(fileType: type.identifier, delegate: promiseKeeper)
        promise.userInfo = node
        promise.extra = item
        return promise
    }

    private lazy var promiseKeeper = PromiseKeeper(view: self)

    // MARK: Drops on the folder

    /// The folder taking a drop: outlined in the accent, as the Finder does.
    private var dropping = false {
        didSet {
            guard dropping != oldValue else { return }
            layer?.borderWidth = dropping ? 2.5 : 0
            layer?.borderColor = Theme.accent.cgColor
        }
    }

    /// What's dragged, as it would land here: none of what's already in
    /// this folder (an entry dragged within its own listing).
    /// Where a drop at a point goes: the folder under it (a row's, a
    /// column's), else the one shown.
    private func dropFolder(_ sender: NSDraggingInfo) -> String? {
        guard let model else { return nil }
        guard let content else { return model.root }
        return content.folder(at: content.convert(sender.draggingLocation, from: nil)) ?? model.root
    }

    private func dropped(_ pb: NSPasteboard, into folder: String) -> [DroppedItem] {
        guard let model else { return [] }
        let entries: [DroppedItem] = (pb.pasteboardItems ?? []).compactMap { item in
            let f = item.string(forType: .manifoldPath)?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
            guard f.count == 3 else { return nil }
            let host = HostID(String(f[0])), path = String(f[1])
            // Not where it is already, nor into itself.
            if host == block.host, path.deletingLastPathComponent == folder || path == folder || folder.hasPrefix(path + "/") { return nil }
            return .entry(host: host, path: path, isDirectory: f[2] == "d")
        }
        if !entries.isEmpty || pb.types?.contains(.manifoldPath) == true { return entries }
        // A link alone (⌥⇧) or a tile's path isn't a file to put here.
        if pb.types?.contains(.manifoldLinkOnly) == true || pb.types?.contains(.manifoldBlockLink) == true { return [] }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { return Promises.receivers(pb).map { .promised($0) } }
        let local = delegate?.directoryViewIsLocal(self) == true
        return urls.filter { !(local && $0.deletingLastPathComponent().standardizedFileURL.path == folder) }.map { .local($0) }
    }

    /// Entries of this host's dropped without ⌥ move, as the Finder moves
    /// within a disk; anything else (⌥, another host, another app) is copied.
    private func moves(_ items: [DroppedItem], _ sender: NSDraggingInfo) -> Bool {
        guard !NSEvent.modifierFlags.contains(.option) else { return false }
        return items.allSatisfy { if case let .entry(h, _, _) = $0 { h == block.host } else { false } }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let folder = dropFolder(sender) else { return [] }
        let items = dropped(sender.draggingPasteboard, into: folder)
        dropping = !items.isEmpty
        return dropping ? (moves(items, sender) ? .move : .copy) : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropping = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropping = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        guard let folder = dropFolder(sender) else { return false }
        let items = dropped(sender.draggingPasteboard, into: folder)
        guard !items.isEmpty else { return false }
        delegate?.directoryView(self, receive: items, into: folder, moving: moves(items, sender))
        return true
    }

    /// An entry right-clicked, by its path.
    func menu(for node: BrowserNode) -> NSMenu? { delegate?.directoryView(self, menuFor: node.path, isDirectory: node.isDirectory) }

    func pasteboardItem(for node: BrowserNode, mods: NSEvent.ModifierFlags) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let link = mods.contains(.shift)
        // ⌥⇧: the link alone, nothing typed or put in.
        if link, mods.contains(.option), let text = delegate?.directoryView(self, linkFor: node.path, isDirectory: node.isDirectory) {
            item.setString(text, forType: .manifoldBlockLink)
            item.setString("1", forType: .manifoldLinkOnly)
            return item
        }
        item.setString(node.path, forType: .string)
        item.setString("\(block.host.raw)\t\(node.path)\t\(node.isDirectory ? "d" : "f")", forType: .manifoldPath)
        // A folder's URL only for a plain drag: a web view in the way
        // takes a dragged folder for a file list and reads it.
        if delegate?.directoryViewIsLocal(self) == true, !mods.contains(.shift) || !node.isDirectory {
            item.setString(URL(fileURLWithPath: node.path).absoluteString, forType: .fileURL)
        }
        if link, let text = delegate?.directoryView(self, linkFor: node.path, isDirectory: node.isDirectory) {
            item.setString(text, forType: .manifoldBlockLink)
        }
        return item
    }

    // MARK: Going places

    /// ⌘[ (the Back button of a Finder window): the folder shown before.
    @objc func goBack(_ sender: Any?) { if delegate?.directoryView(self, history: -1) != true { NSSound.beep() } }
    @objc func goForward(_ sender: Any?) { if delegate?.directoryView(self, history: 1) != true { NSSound.beep() } }

    /// A file opened beside; a folder gone into, in this tile.
    func open(_ node: BrowserNode) {
        delegate?.directoryView(self, open: node.path, isDirectory: node.isDirectory)
    }

    func navigate(to folder: String) {
        guard folder != model?.root else { return }
        delegate?.directoryView(self, open: folder, isDirectory: true)
    }

    @objc private func goUp() {
        guard let root = model?.root, root != "/" else { return }
        navigate(to: root.deletingLastPathComponent.isEmpty ? "/" : root.deletingLastPathComponent)
    }

    /// ⏎: a file opened beside; a folder opened or closed in the tree
    /// (`into`, ⌘↓: gone into, in this tile).
    private func openSelected(into: Bool = false) {
        guard let model, let n = content?.selectedNode else { return }
        if n.isDirectory, !into, !model.filtering { return content?.toggle(n) ?? () }
        open(n)
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: openSelected()  // ⏎
        case 126 where cmd: goUp()  // ⌘↑
        case 125 where cmd: openSelected(into: true)  // ⌘↓
        // /, as less and vim search: to the filter, from anywhere else here.
        case _ where event.charactersIgnoringModifiers == "/" && event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            focusFilter()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⇧⌘.: hidden and ignored files shown, or not (the Finder's key).
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .shift], event.charactersIgnoringModifiers == "." || event.charactersIgnoringModifiers == ">",
           let r = window?.firstResponder as? NSView, r.isDescendant(of: self) {
            toggleHidden()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// View ▸ Show Hidden Files (⇧⌘.), titled by what it will do.
    @objc func toggleHiddenFiles(_ sender: Any?) { toggleHidden() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleHiddenFiles(_:)) {
            item.title = model?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files"
        }
        return true
    }

    func toggleHidden() {
        guard let model else { return }
        model.showHidden.toggle()
        keeper.note(["hidden": model.showHidden ? "1" : "0"])
        model.setFilter(model.filter)  // the matches again, hidden ones in or out
        content?.reloadAll()
        updateFooter()
        updateNote()
    }

    // MARK: Filtering

    /// ⌘F: to the filter.
    @objc override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard tag == NSTextFinder.Action.showFindInterface.rawValue else { return }
        focusFilter()
    }

    /// To the filter, what's in it selected to be typed over (⌘F, /).
    func focusFilter() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    /// "?text": the files' insides to be searched (on ⏎), not their names.
    private var searchingContents: Bool { search.stringValue.hasPrefix("?") }

    @objc private func filterTyped() {
        searchBox.update()
        model?.setFilter(searchingContents ? "" : search.stringValue)
        keeper.note(["filter": search.stringValue])
        updateFooter()
        updateNote()
    }

    // The box's hairline in the accent while the filter has the keyboard
    // (from when it takes it, `FlatField`, to when it lets it go).
    func controlTextDidEndEditing(_ obj: Notification) { searchBox.needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            // ⎋: the filter cleared; again, back to the files.
            if search.stringValue.isEmpty {
                window?.makeFirstResponder(focusView)
            } else {
                searchBox.stringValue = ""
                filterTyped()
            }
            return true
        case #selector(NSResponder.insertNewline(_:)) where searchingContents:
            // "?text" ⏎: a search of the files under the folder, beside.
            let text = search.stringValue.dropFirst().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { delegate?.directoryView(self, searchContents: text) }
            return true
        case #selector(NSResponder.insertNewline(_:)) where model?.filtering == true:
            // ⏎ in the filter: its best match opened.
            content?.selectFirst()
            openSelected()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // ↓, ⏎ or ⇥ (⇧⇥): to the files, the first chosen if none is
            // (⇥ there comes back).
            focusFiles()
            return true
        default:
            return false
        }
    }

    /// To the files, the first (the best match, filtering) chosen if
    /// none is.
    func focusFiles() {
        window?.makeFirstResponder(focusView)
        if model?.filtering == true { content?.selectFirst() } else if content?.selectedPath == nil, let first = firstShown() { content?.select(first) }
    }

    /// The first entry.
    private func firstShown() -> String? {
        guard let model else { return nil }
        return model.children(of: model.root)?.first?.path
    }

    private func updateFooter() {
        guard let model else { return }
        if searchingContents {
            let text = search.stringValue.dropFirst().trimmingCharacters(in: .whitespaces)
            footer.stringValue = text.isEmpty ? "Type what to search the files for" : "⏎ searches the files for “\(text)”"
            footer.isHidden = false
            needsLayout = true
            return
        }
        // Not filtering: "Reading…" while folders opened are listed the first
        // time (a moment late, so a quick listing shows nothing).
        guard model.filtering else {
            if model.readingFolders {
                guard footer.isHidden, footerWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.footerWork = nil
                    guard let m = self.model, !m.filtering, m.readingFolders else { return }
                    self.footer.stringValue = "Reading…"
                    self.footer.isHidden = false
                    self.needsLayout = true
                }
                footerWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + BusyNote.delay, execute: work)
                return
            }
            footerWork?.cancel()
            footerWork = nil
            if !footer.isHidden {
                footer.isHidden = true
                needsLayout = true
            }
            return
        }
        footer.isHidden = false
        if model.isLoadingTree {
            footer.stringValue = "Looking…"
        } else {
            let n = model.matches.count
            footer.stringValue = (n == 0 ? "No files match" : n == 1 ? "1 file" : n >= DirectoryModel.matchLimit ? "The best \(n) files" : "\(n) files")
                + (model.treeComplete ? "" : " of the first 20,000")
        }
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - Self.headerHeight, width: w, height: Self.headerHeight)
        let midY = Self.headerHeight / 2
        up.frame = NSRect(x: 8, y: midY - 12, width: 26, height: 24)
        searchBox.frame = NSRect(x: up.frame.maxX + 6, y: midY - Flat.fieldHeight / 2, width: max(60, w - up.frame.maxX - 6 - 12), height: Flat.fieldHeight)
        let footerHeight: CGFloat = footer.isHidden ? 0 : 22
        footer.frame = NSRect(x: 0, y: 4, width: w, height: 14)
        content?.frame = NSRect(x: 0, y: footerHeight, width: w, height: max(0, h - Self.headerHeight - footerHeight))
        note.frame = NSRect(x: 0, y: footerHeight, width: w, height: max(0, h - Self.headerHeight - footerHeight))
    }

    // MARK: Debugging

    /// "mode", "filter <text>", "select <relative path>", "open", "up",
    /// "go <folder>", "hidden", or nothing: what it shows.
    func debug(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "filter":
            searchBox.stringValue = words.count > 1 ? words[1] : ""
            filterTyped()
        case "select": if words.count > 1, let model { content?.select(model.absolute(words[1])) }
        case "open": openSelected()
        case "up": goUp()
        case "go": if words.count > 1 { navigate(to: words[1]) }
        case "hidden": toggleHidden()
        case "refresh":
            // As the timer does while the app's in use: listed again.
            delegate?.directoryViewRefresh(self)
            if let shown = content?.shownFolders { model?.refresh(shown) }
        case "focusfilter": performTextFinderAction(nil)
        case "drag":
            // "drag [shift] [opt]": what dragging the selection carries.
            guard let path = content?.selectedPath else { return "nothing selected" }
            var isDir: ObjCBool = false
            let local = delegate?.directoryViewIsLocal(self) == true && FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let node = BrowserNode(path: path, entry: DirectoryEntry(name: path.lastPathComponent, isDirectory: local && isDir.boolValue,
                                                                     size: 0, modified: 0, isHidden: false))
            var mods: NSEvent.ModifierFlags = []
            if arg.contains("shift") { mods.insert(.shift) }
            if arg.contains("opt") { mods.insert(.option) }
            let item = pasteboardItem(for: node, mods: mods)
            return item.types.map { "\($0.rawValue): \(item.string(forType: $0) ?? "")" }.joined(separator: "\n")
        case "enter":
            // ⏎ in the filter, as typed there.
            _ = control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        default: break
        }
        var lines = ["root \(model?.root ?? "?") selected \(content?.selectedPath.map { model?.relative($0) ?? $0 } ?? "none")"]
        if !footer.isHidden { lines.append("footer \(footer.stringValue)") }
        lines.append("note \(note.debugState)")
        if let d = content { lines.append(d.debugRows) }
        return lines.joined(separator: "\n")
    }
}

protocol DebugDescribing { var debugRows: String { get } }

extension NSImage {
    /// A template image drawn in a colour.
    func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    /// Where it draws at its own size, centred in `r` (shrunk to fit, never
    /// stretched).
    func centered(in r: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return r }
        let k = min(1, r.width / size.width, r.height / size.height)
        let w = size.width * k, h = size.height * k
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}

/// A promise of another host's file or folder, carrying the entry's own
/// drag (its path, its block's link) too, for drops in Manifold.
final class EntryPromise: NSFilePromiseProvider {
    var extra: NSPasteboardItem?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + (extra?.types ?? [])
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        extra?.types.contains(type) == true ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if let extra, extra.types.contains(type) { return extra.string(forType: type) }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Keeps a folder tile's promises: the file named, and fetched from the
/// host when the Finder (or whatever took it) asks for it.
final class PromiseKeeper: NSObject, NSFilePromiseProviderDelegate {
    private weak var view: DirectoryView?
    init(view: DirectoryView) { self.view = view }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? BrowserNode)?.name ?? "file"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let node = provider.userInfo as? BrowserNode, let view, let delegate = view.delegate else {
            return completionHandler(CocoaError(.fileWriteUnknown))
        }
        delegate.directoryView(view, download: node.path, isDirectory: node.isDirectory, to: url) { error in
            completionHandler(error.map { NSError(domain: "Manifold", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]) })
        }
    }

    /// Fetched on the main queue, where the host's answers come.
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }
}
