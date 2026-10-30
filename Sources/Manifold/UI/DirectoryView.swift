import AppKit
import ManifoldCore
import UniformTypeIdentifiers

/// What a folder's tile shows its files with (§7.4): a tree, or columns.
protocol DirectoryMode: NSView, DebugDescribing {
    var focusView: NSView { get }
    var selectedPath: String? { get }
    var selectedNode: BrowserNode? { get }
    /// The folders shown, below the root: those kept current.
    var shownFolders: [String] { get }
    /// ⏎ on a folder opens it here (in place, or in the next column),
    /// rather than going into it in the tile.
    var opensFoldersHere: Bool { get }
    func destroy()
    func folderChanged(_ folder: String)
    func reloadAll()
    func select(_ path: String?)
    /// The first entry (under the filter, the first match), chosen.
    func selectFirst()
    /// A folder opened here: in place, or in the next column.
    func toggle(_ n: BrowserNode)
    /// The folder a drop at a point goes into, if any is under it.
    func folder(at point: NSPoint) -> String?
}

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
/// the right (`DirectoryTreeMode`) — or in columns, as the Finder's
/// (`DirectoryColumnsMode`), under the way up and a field over the whole
/// tree beneath (⌘F): in the tree a search, listing the files matching it
/// best first as it's typed; in columns a filter, each column keeping what
/// matches and the folders on the way to it, in its own order. "?text"
/// searches inside the files instead. What a repository ignores and hidden
/// files are left out (⇧⌘. shows them).
final class DirectoryView: NSView, PaneContent, KeepsViewState, NSTextFieldDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DirectoryViewDelegate?
    var source: () -> Block? = { nil }

    private(set) var model: DirectoryModel?
    private let header = NSView()
    private let up = IconButton(symbol: "arrow.turn.left.up", size: 13, weight: .medium, target: nil, action: nil)
    /// Tree or columns, at the header's right.
    private let modes = FlatSegments(symbols: ["list.bullet.indent", "rectangle.split.3x1"])
    enum Mode: String { case tree, columns }
    private(set) var mode = Mode.tree
    /// The mode chosen last, in any folder's tile: one with none of its own
    /// (a folder gone into, a new tile) takes it, as a Finder window does.
    static var lastMode: Mode {
        get { UserDefaults.standard.string(forKey: "folderMode").flatMap(Mode.init) ?? .tree }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "folderMode") }
    }
    /// The filter, in its box: flat, as Claude Code's (`FlatFieldBox`).
    private let searchBox = FlatFieldBox()
    private var search: FlatField { searchBox.field }
    private let footer = NSTextField(labelWithString: "")
    /// Over the files: "Reading…" until the folder's listed, why if it
    /// can't be, or that there's nothing in it.
    private let note = BusyNote()
    private var footerWork: DispatchWorkItem?
    private var content: DirectoryMode?
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
        search.delegate = self
        searchBox.onChange = { [weak self] in self?.filterTyped() }
        modes.setToolTip("As a Tree", forSegment: 0)
        modes.setToolTip("As Columns", forSegment: 1)
        modes.onChange = { [weak self] i in self?.setMode(i == 1 ? .columns : .tree) }
        for v in [up, searchBox, modes] as [NSView] { header.addSubview(v) }
        addSubview(header)
        footer.font = UIType.footnote
        footer.textColor = Theme.secondaryText
        footer.alignment = .center
        footer.isHidden = true
        addSubview(footer)
        addSubview(note)
        registerForDraggedTypes(Dragged.types)
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
        mode = keeper.value("mode").flatMap(Mode.init) ?? Self.lastMode
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

    // MARK: The tree, or columns

    /// Shown as a tree or in columns, kept with the tile; the selection
    /// and the filter carry over.
    func setMode(_ m: Mode) {
        guard m != mode, model != nil else { return }
        let focused = (window?.firstResponder as? NSView).map { $0.isDescendant(of: self) && !$0.isDescendant(of: header) } ?? false
        mode = m
        keeper.note(["mode": m.rawValue])
        Self.lastMode = m
        content?.destroy()
        content?.removeFromSuperview()
        content = nil
        install()
        if focused { window?.makeFirstResponder(focusView) }
    }

    private func install() {
        guard let model else { return }
        modes.selectedSegment = mode == .columns ? 1 : 0
        // A search in the tree (ranked), a filter in columns (their order kept).
        search.placeholderString = mode == .columns ? "Filter, or ? to search in files" : "Find a file, or ? to search in files"
        let v: DirectoryMode = mode == .columns ? DirectoryColumnsMode(owner: self, model: model) : DirectoryTreeMode(owner: self, model: model)
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

    /// What dragging an entry writes (§3.11): the file, on its host — a
    /// folder takes it in, a terminal types its path, a note links to it,
    /// the grid opens it, another app takes its file (here).
    func pasteboardItem(for node: BrowserNode) -> NSPasteboardItem {
        Drags.file(node.path, isDirectory: node.isDirectory, on: block.host)
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
    /// The folder a drop over it would go into, as the hint names it.
    private var dropFolderShown: String?
    private var dropping = false {
        didSet {
            guard dropping != oldValue else { return }
            layer?.borderWidth = dropping ? 2.5 : 0
            layer?.borderColor = Theme.accent.cgColor
        }
    }

    /// Where a drop at a point goes: the folder under it (a row's, a
    /// column's), else the one shown.
    private func dropFolder(at p: NSPoint) -> String? {
        guard let model else { return nil }
        guard let content else { return model.root }
        return content.folder(at: content.convert(p, from: self)) ?? model.root
    }

    /// The files dragged, as they'd land in `folder`: none already there
    /// (an entry dragged within its own listing), nor a folder into itself.
    private func dropped(_ d: Dragged, into folder: String) -> [DroppedItem] {
        if d.things.isEmpty { return d.promised.map { .promised($0) } }
        return d.things.compactMap { t in
            guard let f = t.file else { return nil }
            if f.host == block.host, f.path.deletingLastPathComponent == folder || f.path == folder || folder.hasPrefix(f.path + "/") { return nil }
            return t.outside ? .local(URL(fileURLWithPath: f.path)) : .entry(host: f.host, path: f.path, isDirectory: f.isDirectory)
        }
    }

    /// Files dragged that are all where they'd go: nothing to do, and not
    /// the grid's either.
    private func alreadyHere(_ sender: NSDraggingInfo) -> Bool {
        guard let d = Dragged(sender.draggingPasteboard), !d.things.isEmpty, d.things.allSatisfy({ $0.file != nil }),
              let folder = dropFolder(at: convert(sender.draggingLocation, from: nil)) else { return false }
        return dropped(d, into: folder).isEmpty
    }

    /// Things dropped on the folder (§3.11): files copied in — this host's
    /// own entries moved, as the Finder moves within a disk (⌥: copied) —
    /// ⌃ for the other; anything else is the grid's.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if alreadyHere(sender) { dropping = false; return [] }
        let op = Dropping.updated(self, sender)
        if op.isEmpty { dropping = false }
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropping = false
        Dropping.exited(self, sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropping = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        if alreadyHere(sender) { return false }
        return Dropping.perform(self, sender)
    }

    /// An entry right-clicked, by its path.
    func menu(for node: BrowserNode) -> NSMenu? { delegate?.directoryView(self, menuFor: node.path, isDirectory: node.isDirectory) }

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
        if n.isDirectory, !into, content?.opensFoldersHere == true { return content?.toggle(n) ?? () }
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
        modes.sizeToFit()
        modes.frame.origin = NSPoint(x: w - 12 - modes.frame.width, y: (midY - modes.frame.height / 2).rounded())
        searchBox.frame = NSRect(x: up.frame.maxX + 6, y: midY - Flat.fieldHeight / 2, width: max(60, modes.frame.minX - 8 - up.frame.maxX - 6), height: Flat.fieldHeight)
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
        case "tree": setMode(.tree)
        case "columns": setMode(.columns)
        case "key":
            // "key left|right|up|down|enter": as pressed in the files.
            let codes: [String: (UInt16, String)] = ["left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "enter": (36, "\r")]
            if words.count > 1, let (code, chars) = codes[words[1]], let window,
               let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                window.makeFirstResponder(focusView)
                focusView.keyDown(with: e)
            }
        case "refresh":
            // As the timer does while the app's in use: listed again.
            delegate?.directoryViewRefresh(self)
            if let shown = content?.shownFolders { model?.refresh(shown) }
        case "focusfilter": performTextFinderAction(nil)
        case "drag":
            // "drag": what dragging the selection carries.
            guard let path = content?.selectedPath else { return "nothing selected" }
            var isDir: ObjCBool = false
            let local = delegate?.directoryViewIsLocal(self) == true && FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let node = BrowserNode(path: path, entry: DirectoryEntry(name: path.lastPathComponent, isDirectory: local && isDir.boolValue,
                                                                     size: 0, modified: 0, isHidden: false))
            let item = pasteboardItem(for: node)
            return item.types.map { "\($0.rawValue): \(item.string(forType: $0) ?? item.data(forType: $0).map { String(decoding: $0, as: UTF8.self) } ?? "")" }.joined(separator: "\n")
        case "enter":
            // ⏎ in the filter, as typed there.
            _ = control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        default: break
        }
        var lines = ["mode \(mode.rawValue) root \(model?.root ?? "?") selected \(content?.selectedPath.map { model?.relative($0) ?? $0 } ?? "none")"]
        if !footer.isHidden { lines.append("footer \(footer.stringValue)") }
        lines.append("note \(note.debugState)")
        if let a = model?.debugAsking, !a.isEmpty { lines.append("listing \(a)") }
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
        if let extra, extra.types.contains(type) { return extra.string(forType: type) ?? extra.data(forType: type) }
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

extension DirectoryView: DropTaking {
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] {
        guard let folder = dropFolder(at: p) else { return [] }
        let items = dropped(d, into: folder)
        guard !items.isEmpty, items.count == max(d.things.count, d.promised.count) else { return [] }
        let own = items.allSatisfy { if case let .entry(h, _, _) = $0 { h == block.host } else { false } }
        guard own else { return [.copy] }
        return NSEvent.modifierFlags.contains(.option) ? [.copy, .move] : [.move, .copy]
    }

    func dropHint(_ form: DropForm, _ d: Dragged) -> String {
        let name = (dropFolderShown ?? "").lastPathComponent
        let into = name.isEmpty ? " here" : " into “\(name)”"
        return (form == .move ? "Move" : "Copy") + into
    }

    func dropTrack(_ d: Dragged, at p: NSPoint) {
        dropping = true
        dropFolderShown = dropFolder(at: p)
    }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        guard let folder = p.flatMap({ dropFolder(at: $0) }) ?? model?.root else { return }
        let items = dropped(d, into: folder)
        guard !items.isEmpty else { return NSSound.beep() }
        delegate?.directoryView(self, receive: items, into: folder, moving: form == .move)
    }
}
