import AppKit
import ManifoldCore

protocol DirectoryViewDelegate: AnyObject {
    func directoryView(_ view: DirectoryView, open path: String, isDirectory: Bool)
    func directoryViewRefresh(_ view: DirectoryView)
    /// A folder's entries on the block's host, ignored ones marked.
    func directoryView(_ view: DirectoryView, list path: String, done: @escaping ([DirectoryEntry]?) -> Void)
    /// The tree under a folder on the block's host, less what's ignored.
    func directoryView(_ view: DirectoryView, tree path: String, done: @escaping ([DirectoryEntry]?, Bool) -> Void)
    /// A local URL for a file of the block's host, fetched if need be.
    func directoryView(_ view: DirectoryView, localURLFor path: String, done: @escaping (URL?) -> Void)
    /// Whether the block's host is this machine.
    func directoryViewIsLocal(_ view: DirectoryView) -> Bool
    /// An entry dragged with ⇧: its block (made if need be), as the link
    /// a note takes, `[title](manifold:id)`; nil for a file no block shows.
    func directoryView(_ view: DirectoryView, linkFor path: String, isDirectory: Bool) -> String?
}

/// What each way of showing a folder does (§7.4).
protocol DirectoryMode: NSView {
    var focusView: NSView { get }
    /// The selection, as an absolute path.
    var selectedPath: String? { get }
    /// Shown and selected, its folders opened on the way.
    func select(_ path: String?)
    /// A folder's entries changed.
    func folderChanged(_ folder: String)
    /// Everything again: the filter, the sort or what's shown changed.
    func reloadAll()
    /// The folders it shows the insides of, besides the root.
    var shownFolders: [String] { get }
    func destroy()
}

/// The directory lens (§7.4): a folder as the Finder shows one — as a
/// list whose folders open in place into the tree under it, as columns
/// with a preview of the file chosen, or as a gallery — under a bar with
/// the way up (the enclosing folder, and each folder on the path), a
/// filter over the whole tree beneath (⌘F), and the three modes. What a
/// repository ignores and hidden files are left out (⇧⌘. shows them).
final class DirectoryView: NSView, PaneContent, KeepsViewState, NSSearchFieldDelegate {
    enum Mode: String, CaseIterable {
        case list, columns, gallery
        var symbol: String {
            switch self {
            case .list: "list.bullet"
            case .columns: "rectangle.split.3x1"
            case .gallery: "rectangle.bottomthird.inset.filled"
            }
        }
        var title: String {
            switch self {
            case .list: "as List"
            case .columns: "as Columns"
            case .gallery: "as Gallery"
            }
        }
    }

    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DirectoryViewDelegate?
    var source: () -> Block? = { nil }

    private(set) var model: DirectoryModel?
    private let header = NSView()
    private let up = NSButton()
    private let pathBar = PathBar()
    private let search = NSSearchField()
    private let pill = ModePill(symbols: Mode.allCases.map(\.symbol), tips: Mode.allCases.map { "Show " + $0.title })
    private let footer = NSTextField(labelWithString: "")
    private(set) var mode = Mode.list
    private var content: DirectoryMode?
    private var listedAt: Stamp?
    /// The selection, relative to the root, as all modes share it.
    private var selected: String?

    var focusView: NSView { content?.focusView ?? self }
    var isDead: Bool { false }
    static let headerHeight: CGFloat = 40

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }

        up.isBordered = false
        up.bezelStyle = .accessoryBarAction
        up.image = Theme.symbol("arrow.turn.left.up", size: 13, weight: .medium)
        up.contentTintColor = Theme.secondaryText
        up.toolTip = "Enclosing Folder (⌘↑)"
        up.target = self
        up.action = #selector(goUp)
        pathBar.go = { [weak self] path in self?.navigate(to: path) }
        search.placeholderString = "Filter"
        search.font = .systemFont(ofSize: 12)
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.focusRingType = .none
        search.delegate = self
        search.target = self
        search.action = #selector(filterTyped)
        pill.changed = { [weak self] i in self?.setMode(Mode.allCases[i]) }
        for v in [up, pathBar, search, pill] as [NSView] { header.addSubview(v) }
        addSubview(header)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.secondaryText
        footer.alignment = .center
        footer.isHidden = true
        addSubview(footer)
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
        pathBar.path = path
        up.isEnabled = path != "/"
        if let d = b.directory, d.listedAt != nil, d.listedAt != listedAt {
            listedAt = d.listedAt
            model?.setRootEntries(d.entries)
        }
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
        m.changed = { [weak self] folder in self?.content?.folderChanged(folder) }
        m.filterChanged = { [weak self] in
            self?.content?.reloadAll()
            self?.updateFooter()
        }
        // As it was left.
        m.showHidden = keeper.value("hidden") == "1"
        if let s = keeper.value("sort")?.split(separator: ":"), s.count == 2, let k = DirectoryModel.SortKey(rawValue: String(s[0])) {
            m.sortKey = k
            m.ascending = s[1] == "1"
        }
        model = m
        selected = keeper.value("selected").flatMap { $0.isEmpty ? nil : $0 }
        mode = keeper.value("mode").flatMap(Mode.init) ?? .list
        if let f = keeper.value("filter"), !f.isEmpty {
            search.stringValue = f
            m.setFilter(f)
        }
        keeper.restored = true
        install(mode)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.directoryViewRefresh(self) }
        keepCurrent(window != nil)
    }

    // MARK: Modes

    func setMode(_ m: Mode) {
        guard m != mode || content == nil else { return }
        mode = m
        keeper.note(["mode": m.rawValue])
        let hadFocus = content.map { window?.firstResponder === $0.focusView || ($0.focusView as NSView?).map { window?.firstResponder === $0 } == true } ?? false
        install(m)
        if hadFocus { window?.makeFirstResponder(focusView) }
    }

    private func install(_ m: Mode) {
        guard let model else { return }
        content?.destroy()
        content?.removeFromSuperview()
        let v: DirectoryMode
        switch m {
        case .list: v = DirectoryListMode(owner: self, model: model)
        case .columns: v = DirectoryColumnsMode(owner: self, model: model)
        case .gallery: v = DirectoryGalleryMode(owner: self, model: model)
        }
        v.clipsToBounds = true
        addSubview(v, positioned: .below, relativeTo: header)
        content = v
        pill.selected = Mode.allCases.firstIndex(of: m) ?? 0
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

    /// The selection moved, in whichever mode.
    func selectionChanged(_ path: String?) {
        guard let model else { return }
        selected = path.map { model.relative($0) }
        keeper.note(["selected": selected ?? ""])
    }

    var isLocal: Bool { delegate?.directoryViewIsLocal(self) ?? true }

    func resolve(_ path: String, done: @escaping (URL?) -> Void) {
        guard let delegate else { return done(nil) }
        delegate.directoryView(self, localURLFor: path, done: done)
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

    private func openSelected() {
        guard let model, let p = content?.selectedPath else { return }
        if let n = model.existingNode(p) { open(n) }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: openSelected()  // ⏎
        case 126 where cmd: goUp()  // ⌘↑
        case 125 where cmd: openSelected()  // ⌘↓
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

    func toggleHidden() {
        guard let model else { return }
        model.showHidden.toggle()
        keeper.note(["hidden": model.showHidden ? "1" : "0"])
        model.setFilter(model.filter)  // the matches again, hidden ones in or out
        content?.reloadAll()
        updateFooter()
    }

    func sortChanged(_ key: DirectoryModel.SortKey, ascending: Bool) {
        guard let model else { return }
        model.sortKey = key
        model.ascending = ascending
        keeper.note(["sort": "\(key.rawValue):\(ascending ? 1 : 0)"])
        content?.reloadAll()
    }

    // MARK: Filtering

    /// ⌘F: to the filter.
    @objc override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard tag == NSTextFinder.Action.showFindInterface.rawValue else { return }
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    @objc private func filterTyped() {
        model?.setFilter(search.stringValue)
        keeper.note(["filter": search.stringValue])
        updateFooter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            // ⎋: the filter cleared; again, back to the files.
            if search.stringValue.isEmpty {
                window?.makeFirstResponder(focusView)
            } else {
                search.stringValue = ""
                filterTyped()
            }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(focusView)
            if content?.selectedPath == nil, let first = firstShown() { content?.select(first) }
            return true
        default:
            return false
        }
    }

    /// The first match, or the first entry.
    private func firstShown() -> String? {
        guard let model else { return nil }
        if model.filtering { return model.matches.first.map { model.absolute($0) } }
        return model.children(of: model.root)?.first?.path
    }

    private func updateFooter() {
        guard let model, model.filtering else {
            footer.isHidden = true
            return needsLayout = true
        }
        footer.isHidden = false
        if model.isLoadingTree {
            footer.stringValue = "Looking…"
        } else {
            let n = model.matches.count
            footer.stringValue = (n == 0 ? "No matches" : n == 1 ? "1 match" : "\(n) matches") + (model.treeComplete ? "" : " in the first 20,000 files")
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
        let pillSize = pill.intrinsicContentSize
        pill.frame = NSRect(x: w - 10 - pillSize.width, y: midY - pillSize.height / 2, width: pillSize.width, height: pillSize.height)
        let searchWidth = max(80, min(200, (w - 40 - pillSize.width) * 0.38))
        search.frame = NSRect(x: pill.frame.minX - 8 - searchWidth, y: midY - 11, width: searchWidth, height: 22)
        pathBar.frame = NSRect(x: up.frame.maxX + 4, y: midY - 11, width: max(0, search.frame.minX - 10 - up.frame.maxX - 4), height: 22)
        pathBar.isHidden = pathBar.frame.width < 40
        let footerHeight: CGFloat = footer.isHidden ? 0 : 22
        footer.frame = NSRect(x: 0, y: 4, width: w, height: 14)
        content?.frame = NSRect(x: 0, y: footerHeight, width: w, height: max(0, h - Self.headerHeight - footerHeight))
    }

    // MARK: Debugging

    /// "mode", "filter <text>", "select <relative path>", "open", "up",
    /// "go <folder>", "hidden", or nothing: what it shows.
    func debug(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "mode": if words.count > 1, let m = Mode(rawValue: words[1]) { setMode(m) }
        case "filter":
            search.stringValue = words.count > 1 ? words[1] : ""
            filterTyped()
        case "select": if words.count > 1, let model { content?.select(model.absolute(words[1])) }
        case "open": openSelected()
        case "up": goUp()
        case "go": if words.count > 1 { navigate(to: words[1]) }
        case "hidden": toggleHidden()
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
        default: break
        }
        var lines = ["mode \(mode.rawValue) root \(model?.root ?? "?") selected \(content?.selectedPath.map { model?.relative($0) ?? $0 } ?? "none")"]
        if !footer.isHidden { lines.append("footer \(footer.stringValue)") }
        if let d = content as? DebugDescribing { lines.append(d.debugRows) }
        return lines.joined(separator: "\n")
    }
}

protocol DebugDescribing { var debugRows: String { get } }

/// The folders from the top down to this one, each clicked to go there;
/// those that don't fit, the nearest kept, elided at the front.
final class PathBar: NSView {
    var path = "" { didSet { if path != oldValue { needsDisplay = true; resetCursorRects() } } }
    var go: (String) -> Void = { _ in }
    private var hits: [(NSRect, String)] = []
    private var hovered: String?

    override var isFlipped: Bool { true }

    private var components: [(title: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out: [(String, String)] = []
        var base: String
        var rest: String
        if path == home || path.hasPrefix(home + "/") {
            out.append(("~", home))
            base = home
            rest = String(path.dropFirst(home.count))
        } else {
            out.append(("/", "/"))
            base = ""
            rest = path
        }
        for part in rest.split(separator: "/") {
            base = base + "/" + part
            out.append((String(part), base))
        }
        return out
    }

    private func attrs(_ last: Bool, _ hovered: Bool) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12.5, weight: last ? .semibold : .regular),
         .foregroundColor: last || hovered ? Theme.text : Theme.secondaryText]
    }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        let comps = components
        guard !comps.isEmpty else { return }
        let sep = NSAttributedString(string: " › ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.secondaryText.withAlphaComponent(0.6)])
        let ellipsis = NSAttributedString(string: "…", attributes: attrs(false, false))
        // From the last back, as many as fit; the first (the top) kept if there's room.
        var shown: [Int] = []
        var width: CGFloat = 0
        for i in comps.indices.reversed() {
            let s = NSAttributedString(string: comps[i].title, attributes: attrs(i == comps.count - 1, false))
            let need = s.size().width + (shown.isEmpty ? 0 : sep.size().width)
            if width + need > bounds.width - (i > 0 ? ellipsis.size().width + sep.size().width : 0), !shown.isEmpty { break }
            width += need
            shown.insert(i, at: 0)
        }
        var x: CGFloat = 0
        let y = (bounds.height - 16) / 2
        if let first = shown.first, first > 0 {
            ellipsis.draw(at: NSPoint(x: x, y: y))
            x += ellipsis.size().width
            sep.draw(at: NSPoint(x: x, y: y))
            x += sep.size().width
        }
        for (k, i) in shown.enumerated() {
            let last = i == comps.count - 1
            let s = NSAttributedString(string: comps[i].title, attributes: attrs(last, hovered == comps[i].path))
            let r = NSRect(x: x, y: y, width: min(s.size().width, bounds.width - x), height: 16)
            s.draw(with: r, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            if !last { hits.append((r.insetBy(dx: -2, dy: -3), comps[i].path)) }
            x += r.width
            if k < shown.count - 1 {
                sep.draw(at: NSPoint(x: x, y: y))
                x += sep.size().width
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for (r, _) in hits { addCursorRect(r, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = hits.first { $0.0.contains(p) }?.1
        if h != hovered { hovered = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let h = hits.first(where: { $0.0.contains(p) }) { go(h.1) }
    }
}

/// A capsule of symbols, one of them chosen, as the Finder's view modes.
final class ModePill: NSView {
    let symbols: [String]
    let tips: [String]
    var selected = 0 { didSet { needsDisplay = true } }
    var changed: (Int) -> Void = { _ in }
    private let segment = NSSize(width: 32, height: 24)
    private let inset: CGFloat = 3

    init(symbols: [String], tips: [String]) {
        self.symbols = symbols
        self.tips = tips
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segment.width * CGFloat(symbols.count) + 2 * inset, height: segment.height + 2 * inset)
    }

    private func rect(_ i: Int) -> NSRect {
        NSRect(x: inset + CGFloat(i) * segment.width, y: inset, width: segment.width, height: segment.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.text.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let r = rect(selected)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        Theme.selected.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, s) in symbols.enumerated() {
            guard let image = Theme.symbol(s, size: 13, weight: .medium) else { continue }
            let tinted = image.tinted(i == selected ? Theme.text : Theme.secondaryText)
            let sr = rect(i)
            tinted.draw(in: NSRect(x: sr.midX - image.size.width / 2, y: sr.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }

    override func resetCursorRects() {
        for i in symbols.indices { addCursorRect(rect(i), cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        for (i, t) in tips.enumerated() { addToolTip(rect(i), owner: t as NSString, userData: nil) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = symbols.indices.first(where: { rect($0).contains(p) }) else { return }
        selected = i
        changed(i)
    }
}

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
}
