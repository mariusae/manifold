import AppKit
import ManifoldCore
import UniformTypeIdentifiers

/// What a folder's tile shows its files with (§7.4): a tree, or columns.
protocol DirectoryMode: NSView, DebugDescribing {
    var focusView: NSView { get }
    var selectedPath: String? { get }
    var selectedNode: BrowserNode? { get }
    /// The entries chosen: several (⌘-, ⇧-click), the one, or none.
    var selectedPaths: [String] { get }
    /// Debugging: these entries (of one folder, in columns) chosen together.
    func debugChoose(_ paths: [String])
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
    /// The chosen entry renamed in its row (`renameInline`); false if it
    /// isn't shown, or several are chosen.
    func renameInRow() -> Bool
    /// The folder a drop at a point goes into, if any is under it.
    func folder(at point: NSPoint) -> String?
}

protocol DirectoryViewDelegate: AnyObject {
    func directoryView(_ view: DirectoryView, open path: String, isDirectory: Bool)
    func directoryViewRefresh(_ view: DirectoryView)
    /// The folders shown watched on the block's host, `changed` told those
    /// that change — in place of those watched before; false where its
    /// server can't (one from before), or it isn't attached.
    func directoryView(_ view: DirectoryView, watch folders: Set<String>, changed: @escaping (Set<String>) -> Void) -> Bool
    func directoryViewUnwatch(_ view: DirectoryView)
    /// Told when what's at work anywhere changes (a terminal's or an
    /// agent's block), nil to stop.
    func directoryView(_ view: DirectoryView, watchPresence changed: (() -> Void)?)
    /// A folder's entries on the block's host, ignored ones marked.
    func directoryView(_ view: DirectoryView, list path: String, done: @escaping ([DirectoryEntry]?) -> Void)
    /// The tree under a folder on the block's host, less what's ignored.
    func directoryView(_ view: DirectoryView, tree path: String, done: @escaping ([DirectoryEntry]?, Bool) -> Void)
    /// A local URL for a file of the block's host, fetched if need be, to
    /// `done`; what it returns gives up on it.
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
    /// A new file (empty, then opened) or folder made on the host at
    /// `path`; `done` with what went wrong ("exists": something's there).
    func directoryView(_ view: DirectoryView, make path: String, isDirectory: Bool, done: @escaping (String?) -> Void)
    /// An entry renamed on the host (`to`, beside it), not over one there.
    func directoryView(_ view: DirectoryView, rename path: String, to: String, done: @escaping (String?) -> Void)
    /// Entries moved to the host's trash.
    func directoryView(_ view: DirectoryView, trash paths: [String], done: @escaping (String?) -> Void)
    /// Several entries chosen, one of them right-clicked: what can be done
    /// with them all.
    func directoryView(_ view: DirectoryView, menuFor entries: [(path: String, isDirectory: Bool)]) -> NSMenu?
    /// ⌘[ and ⌘]: the folders this tile showed before (or after), as a
    /// Finder window's back and forward go; false if there's none.
    func directoryView(_ view: DirectoryView, history direction: Int) -> Bool
    /// "?text" in the filter: the files under the folder searched for it.
    func directoryView(_ view: DirectoryView, searchContents text: String)
    /// The project at the folder (§2.6), if it's one.
    func directoryViewProject(_ view: DirectoryView) -> Project?
    /// The project a folder is in, below its root: the nearest above it.
    func directoryViewParentProject(_ view: DirectoryView) -> Project?
    /// The folder made a project, or no longer one.
    func directoryView(_ view: DirectoryView, makeProject: Bool)
    /// The project's git block (its repository's, scoped to it): made,
    /// or found and refreshed.
    func directoryView(_ view: DirectoryView, gitFor project: Project) -> BlockID?
    func directoryView(_ view: DirectoryView, block id: BlockID) -> Block?
    /// How the project's index stands, or why it can't have one.
    func directoryView(_ view: DirectoryView, indexOf project: Project, done: @escaping (SCIPStatus?, _ missing: String?) -> Void)
    /// What its homepage asks for.
    func directoryView(_ view: DirectoryView, project: Project, do action: ProjectAction)
    /// A block not shown here read as it changes (a project's git block,
    /// its search's): `changed` told each time, while the view lives.
    func directoryView(_ view: DirectoryView, watch block: BlockID, _ changed: @escaping () -> Void)
    /// The project searched (§2.6): asked again in `block`, if it's given,
    /// else in a new search block; that block.
    func directoryView(_ view: DirectoryView, search query: SearchQuery, in block: BlockID?) -> BlockID?
    /// Something its search found, gone to (beside).
    func directoryView(_ view: DirectoryView, open found: ProjectSearchView.Found, root: String)
    /// The search in a tile of its own, beside.
    func directoryView(_ view: DirectoryView, popOut search: BlockID)
    /// What's at work in the project: terminals and agents there, notes
    /// about its files.
    func directoryView(_ view: DirectoryView, presenceIn project: Project) -> [Presence]
    /// The project's languages, as its host counts them (as GitHub does).
    func directoryView(_ view: DirectoryView, languagesOf project: Project, done: @escaping ([Linguist.Count]?) -> Void)
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
/// files are left out (⇧⌘. shows them). A README in the folder is shown
/// under it, as GitHub shows one (`FolderReadme`).
final class DirectoryView: NSView, PaneContent, KeepsViewState, NSTextFieldDelegate, MarkdownViewDelegate, FollowsFontTheme {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DirectoryViewDelegate?
    var source: () -> Block? = { nil }

    private(set) var model: DirectoryModel?
    private let header = NSView()
    private let up = IconButton("arrow.turn.left.up", size: 13, weight: .medium, tip: "Enclosing Folder (⌘↑)")
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
    private let footer = NSTextField.label(font: UIType.footnote, color: Theme.secondaryText, align: .center)
    /// Over the files: "Reading…" until the folder's listed, why if it
    /// can't be, or that there's nothing in it.
    private let note = BusyNote()
    private let footerWork = Debouncer()
    private var content: DirectoryMode?
    /// The folder's README, under the files: the entry shown (as it was
    /// listed, so a change reads it again) and its text.
    private let readme = FolderReadme()
    private var readmeEntry: DirectoryEntry?
    private var readmeText: (text: String, version: Int)?
    private var readmeCancel: (() -> Void)?
    /// Collapsed to its bar, in this tile — else as last left in any.
    private var readmeCollapsed: Bool {
        get { keeper.value("readme").map { $0 == "collapsed" } ?? Self.lastReadmeCollapsed }
        set {
            keeper.note(["readme": newValue ? "collapsed" : "open"], after: 0)
            Self.lastReadmeCollapsed = newValue
        }
    }
    static var lastReadmeCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "folderReadmeCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "folderReadmeCollapsed") }
    }
    /// The Markdown pages shown (a file previewed, the README), told when
    /// the font theme changes.
    private let pages = NSHashTable<MarkdownView>.weakObjects()
    private var listedAt: Stamp?
    /// The selection, relative to the root, as all modes share it.
    private var selected: String?

    // A project's homepage (§2.6).
    /// The project at the folder, if it's one.
    private(set) var project: Project?
    /// How it stands; its git block, its index.
    private var facts: ProjectFacts?
    private var projectGit: BlockID?
    private var indexAskedAt: Date?
    /// The homepage round the files, or the files alone: a project's,
    /// beside the modes; kept with the tile, on at first.
    private let homeButton = FlatButton("", symbol: "house", toggles: true)
    /// The project's + (a new agent pinned in it), in the header when its
    /// strip has nothing else to say and isn't shown.
    private let newAgent = IconButton("plus", size: 10, tip: "New Agent — pinned in this project, asked in its threads; shown under Pinned")
    @objc private func newAgentClicked() { projectAction(.newAgent) }
    private var homeShown = true
    /// The homepage shows: a project's, and not turned off.
    var home: Bool { homeShown && project != nil }
    private let strip = ProjectStrip()
    private let sidebar = ProjectSidebar()
    /// Its search's results, in the files' place while something's typed
    /// in the field (§2.6), and the block they're in.
    private let results = ProjectSearchView()
    private var projectSearch: BlockID?
    /// The project search, a moment after the last key (§ M31): typing
    /// over it cancels it, ⏎ runs it now.
    private let searchSoon = Debouncer()
    /// Something typed in a project's homepage's field: it's searched,
    /// not filtered.
    private var searchingProject: Bool { home && !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Offered, quietly, where the folder looks like a project's root (a
    /// repository's, a language's manifest) and isn't one yet.
    private let makeProject = FlatButton("Make Project", symbol: "shippingbox", font: UIType.detail)
    /// In a project, below its root: its name, to go up to its homepage.
    private let toProject = FlatButton("", symbol: "arrow.up.to.line", font: UIType.detail)
    private var parentProject: Project?
    private var looksLikeProject = false
    /// Narrower than this, a homepage has no sidebar.
    static let sidebarFrom: CGFloat = 600

    var focusView: NSView { content?.focusView ?? self }
    static let headerHeight = TileMetrics.controlHeader

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }

        up.target = self
        up.action = #selector(goUp)
        search.delegate = self
        searchBox.onChange = { [weak self] in self?.queryHistory.typed(); self?.filterTyped() }
        modes.setToolTip("As a Tree", forSegment: 0)
        modes.setToolTip("As Columns", forSegment: 1)
        modes.onChange = { [weak self] i in self?.setMode(i == 1 ? .columns : .tree) }
        homeButton.target = self
        homeButton.action = #selector(toggleHome)
        homeButton.toolTip = "Project Home: its changes, commits and index round the files"
        homeButton.isHidden = true
        header.addSubview(homeButton)
        makeProject.target = self
        makeProject.action = #selector(makeProjectClicked)
        makeProject.toolTip = "Make this folder a project: its own homepage, index, changes and searches"
        makeProject.isHidden = true
        toProject.target = self
        toProject.action = #selector(goToProject)
        toProject.isHidden = true
        newAgent.target = self
        newAgent.action = #selector(newAgentClicked)
        newAgent.isHidden = true
        for v in [up, searchBox, modes, makeProject, toProject, newAgent] as [NSView] { header.addSubview(v) }
        addSubview(header)
        strip.isHidden = true
        strip.onAction = { [weak self] a in self?.projectAction(a) }
        sidebar.isHidden = true
        sidebar.onAction = { [weak self] a in self?.projectAction(a) }
        addSubview(strip)
        addSubview(sidebar)
        results.isHidden = true
        results.onOpen = { [weak self] f in
            guard let self, let project = self.project else { return }
            self.delegate?.directoryView(self, open: f, root: project.root)
        }
        results.onPopOut = { [weak self] in self?.popOutSearch() }
        results.onBack = { [weak self] in self?.focusFilter() }
        addSubview(results)
        footer.isHidden = true
        addSubview(footer)
        addSubview(note)
        note.host = block.host
        readme.isHidden = true
        readme.onToggle = { [weak self] in self?.toggleReadme() }
        readme.onResize = { [weak self] height, done in
            guard let self else { return }
            self.readmeHeight = height
            self.needsLayout = true
            if done { self.keeper.note(["readmeHeight": "\(Int(self.readme.frame.height))"], after: 0) }
        }
        addSubview(readme)
        registerForDraggedTypes(Dragged.types)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        readmeCancel?()
        keepCurrent(false)
        keeper.flush()
        content?.destroy()
    }

    // MARK: The block

    /// The block (or its listing) may have changed.
    func documentChanged() {
        guard let b = source(), let path = b.path else { return }
        projectChanged(delegate?.directoryViewProject(self))
        parentProjectChanged(project == nil ? delegate?.directoryViewParentProject(self) : nil)
        if model == nil { setUp(path) }
        up.isEnabled = path != "/"
        if let d = b.directory, d.listedAt != nil, d.listedAt != listedAt {
            listedAt = d.listedAt
            model?.setRootEntries(d.entries)
            readEntries(d.entries)
            looksLikeProject = Project.looksLikeRoot(Set(d.entries.map(\.name)))
            updateMakeProject()
        }
        updateNote()
        if home { showFacts() }
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

    /// Kept current while it's in a window: the folder and those open in
    /// it watched on the host, each listed again when the host says it
    /// changed — told only what changed, so nothing moves (the selection
    /// stays). Where the host's server can't watch (one from before) or
    /// isn't attached yet, they're listed again every few seconds while
    /// the app's in use, until it can.
    private var refresher: Timer?
    /// The folders the host watches for it.
    private var watched: Set<String>?
    private var activation: NSObjectProtocol?
    private var watchDue = false

    private func keepCurrent(_ on: Bool) {
        refresher?.invalidate()
        refresher = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        delegate?.directoryView(self, watchPresence: nil)
        guard on else {
            if watched != nil { delegate?.directoryViewUnwatch(self) }
            watched = nil
            return
        }
        // A homepage's facts: who's at work as that changes; what's changed
        // since its index, as the host says (`foldersChanged`) and when
        // the app comes back to the front (files edited meanwhile).
        delegate?.directoryView(self, watchPresence: { [weak self] in
            guard let self, self.home else { return }
            self.showFacts()
        })
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.unchecked {
                guard let self, self.home else { return }
                self.showFacts()
                self.askIndex(now: true)
            }
        }
        if updateWatch() { return }
        refresher = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] t in
            guard let self else { return }
            if self.updateWatch() {
                t.invalidate()
                self.refresher = nil
                return
            }
            guard NSApp.isActive, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            self.delegate?.directoryViewRefresh(self)
            if let shown = self.content?.shownFolders { self.model?.refresh(shown) }
            if self.home { self.showFacts(); self.askIndex() }
        }
    }

    /// The folders shown changed (one opened, a column closed; its folder
    /// set up): watched, once whatever's changing them has — and, watched
    /// at last, no longer asked again and again.
    func shownFoldersChanged() {
        guard refresher != nil || watched != nil, !watchDue else { return }
        watchDue = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchDue = false
            guard self.window != nil, self.updateWatch() else { return }
            self.refresher?.invalidate()
            self.refresher = nil
        }
    }

    /// The folders shown watched on the host; false where it can't.
    @discardableResult private func updateWatch() -> Bool {
        guard let model else { return false }
        let folders = Set([model.root] + (content?.shownFolders ?? []))
        if folders == watched { return true }
        guard delegate?.directoryView(self, watch: folders, changed: { [weak self] in self?.foldersChanged($0) }) == true else { return false }
        watched = folders
        return true
    }

    /// The host says these changed: those open in it listed again (its
    /// own folder the host lists again itself, into the block); its
    /// homepage's facts asked again with its folder.
    private func foldersChanged(_ folders: Set<String>) {
        guard let model else { return }
        model.refresh(Array(folders))
        if folders.contains(model.root), home {
            showFacts()
            askIndex(now: true)
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
            self?.shownFoldersChanged()
        }
        m.filterChanged = { [weak self] in
            self?.content?.reloadAll()
            self?.updateFooter()
            self?.updateNote()
        }
        m.readingChanged = { [weak self] in self?.updateFooter() }
        // As it was left.
        m.showHidden = keeper.value("hidden") == "1"
        m.useGroups = keeper.value("groups") != "0"
        if let s = keeper.value("sort")?.split(separator: ":"), s.count == 2, let k = DirectoryModel.SortKey(rawValue: String(s[0])) {
            m.sortKey = k
            m.ascending = s[1] == "1"
        }
        model = m
        shownFoldersChanged()
        // A project's tile opens on its homepage, its files in columns,
        // unless it was left otherwise.
        homeShown = keeper.value("home") != "0"
        mode = keeper.value("mode").flatMap(Mode.init) ?? (project != nil ? .columns : Self.lastMode)
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
        search.placeholderString = "Filter, or ? to search"
        let v: DirectoryMode = mode == .columns ? DirectoryColumnsMode(owner: self, model: model) : DirectoryTreeMode(owner: self, model: model)
        v.clipsToBounds = true
        addSubview(v, positioned: .below, relativeTo: header)
        content = v
        homeChanged()
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
        if let p = pendingReveal { reveal(p) }
    }

    /// A file revealed: the folders on the way to it fetched (and opened,
    /// as they're listed), it chosen, the files focused — now, or once the
    /// folder's been read.
    private var pendingReveal: String?

    func reveal(_ path: String) {
        guard let model, let content else { return pendingReveal = path }
        pendingReveal = nil
        let root = model.root.hasSuffix("/") ? model.root : model.root + "/"
        guard path.hasPrefix(root) else { return }
        var wanted = [model.root], dir = path.deletingLastPathComponent
        while dir.count > model.root.count { wanted.append(dir); dir = dir.deletingLastPathComponent }
        model.prefetch(wanted)
        content.select(path)
        window?.makeFirstResponder(content.focusView)
    }

    var debugRevealing: String? { pendingReveal }

    // MARK: A project's homepage

    /// The desk says the folder is (or isn't) a project: Home offered, or
    /// taken away (back to the files).
    private func projectChanged(_ p: Project?) {
        guard p != project else { return }
        let was = project
        project = p
        updateMakeProject()
        if p == nil {
            facts = nil
            projectGit = nil
        } else if was == nil, model != nil, madeHere {
            // Just made one here: its homepage, its files in columns.
            madeHere = false
            setHome(true)
            if keeper.value("mode") == nil { setMode(.columns) }
        }
        homeChanged()
    }

    /// Make Project is the tile menu's (Dia's way: no button for what's
    /// done once); the header's stays hidden.
    private func updateMakeProject() {
        makeProject.isHidden = true
        needsLayout = true
    }

    /// The project it's in, below the root: offered to go up to.
    private func parentProjectChanged(_ p: Project?) {
        guard p != parentProject else { return }
        parentProject = p
        toProject.isHidden = p == nil
        toProject.title = p?.name ?? ""
        toProject.toolTip = p.map { "Go up to the project it's in, \($0.name): its homepage (\($0.root.abbreviatingHome))" }
        needsLayout = true
    }

    /// Up to the project it's in, in this tile, its homepage shown.
    @objc func goToProject() {
        guard let p = parentProject else { return NSSound.beep() }
        setHome(true)
        navigate(to: p.root)
    }

    @objc private func makeProjectClicked() {
        madeHere = true
        delegate?.directoryView(self, makeProject: true)
    }
    /// Made a project from this tile: it goes to the homepage when the host says so.
    private var madeHere = false

    @objc private func toggleHome() { setHome(!homeShown) }

    /// The homepage round the files, or not; kept with the tile.
    func setHome(_ on: Bool) {
        homeShown = on
        keeper.note(["home": on ? "1" : "0"])
        homeChanged()
    }

    /// Home shown or left: the homepage's parts, and what it's asked for.
    private func homeChanged() {
        let home = self.home
        homeButton.isHidden = project == nil
        homeButton.state = home ? .on : .off
        strip.isHidden = !home
        sidebar.isHidden = !home || bounds.width < Self.sidebarFrom
        // The sidebar has the right: no preview beside the tree.
        (content as? DirectoryTreeMode)?.previews = !home
        // Its field searches the project; elsewhere, it finds files here.
        search.placeholderString = home ? "Search \(project?.name ?? "the project")" : "Filter, or ? to search"
        if home, model?.filtering == true { model?.setFilter("") }
        if !home, !search.stringValue.isEmpty, model?.filter != search.stringValue, !searchingContents { model?.setFilter(search.stringValue) }
        // Something in the field already (kept with the tile, or typed
        // before Home was on): searched.
        if searchingProject, projectSearch == nil, !searchSoon.isPending { projectQueryTyped() }
        updateResults()
        needsLayout = true
        guard home else { return }
        // Its git block found again, and so refreshed: the project as it is now.
        projectGit = nil
        showFacts()
        askIndex(now: true)
    }

    /// How the project stands, from its git block and its index's last word.
    private func showFacts() {
        guard let project, home else { return }
        if projectGit == nil || (projectGit.flatMap { delegate?.directoryView(self, block: $0) } == nil && Date().timeIntervalSince(gitAskedAt ?? .distantPast) > 10) {
            gitAskedAt = Date()
            projectGit = delegate?.directoryView(self, gitFor: project)
            if let id = projectGit { delegate?.directoryView(self, watch: id) { [weak self] in self?.showFacts() } }
            // Its block comes with a change; none, in a moment it's no
            // longer waited for.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in self?.showFacts() }
        }
        let git = projectGit.flatMap { delegate?.directoryView(self, block: $0) }
        // Its languages, from its tree (now and then); what's at work in it.
        if Date().timeIntervalSince(languagesAt ?? .distantPast) > 120 {
            languagesAt = Date()
            delegate?.directoryView(self, languagesOf: project) { [weak self] counts in
                guard let self, let counts else { return }
                self.languages = LanguageShare.of(counts)
                self.showFacts()
            }
        }
        // Who's at work in it, from what this Mac has of the host: asked
        // again as their blocks change (`watchPresence`).
        presence = delegate?.directoryView(self, presenceIn: project) ?? []
        var f = facts?.project == project ? facts! : ProjectFacts(project: project)
        f.project = project
        f.repo = git?.path
        f.git = git?.git
        f.languages = languages
        f.presence = presence
        f.gitPending = git == nil && Date().timeIntervalSince(gitAskedAt ?? .distantPast) < 5
        guard f != facts else { return }
        facts = f
        strip.show(f)
        sidebar.host = block.host
        sidebar.placement = placement
        sidebar.show(f)
    }
    private var gitAskedAt: Date?
    private var languages: [LanguageShare] = []
    private var languagesAt: Date?
    private var presence: [Presence] = []

    /// The index's state asked again: at once, while it's being made, and
    /// otherwise now and then.
    private func askIndex(now: Bool = false) {
        guard let project, home else { return }
        let indexing = facts?.index?.state == .indexing
        if !now, !indexing, let last = indexAskedAt, Date().timeIntervalSince(last) < 15 { return }
        indexAskedAt = Date()
        delegate?.directoryView(self, indexOf: project) { [weak self] status, missing in
            guard let self, var f = self.facts, f.project.root == project.root else { return }
            f.index = status
            f.indexMissing = missing
            guard f != self.facts else { return }
            self.facts = f
            self.strip.show(f)
        }
    }

    // MARK: A project's search

    /// What's typed searched, a moment after the last key: symbols and
    /// files by name, and — two letters on — the text (`sym:`, `file:`,
    /// `text:` for one alone; `?` the text, as the filter has it).
    private func projectQueryTyped() {
        keeper.note(["filter": search.stringValue])
        // What was typed before, not searched (nor kept to be, by ⏎).
        searchSoon.cancel()
        updateResults()
        guard searchingProject, let project else { return }
        let typed = search.stringValue
        searchSoon.schedule(after: 0.15) { [weak self] in
            guard let self else { return }
            var pq = ProjectQuery(typed.hasPrefix("?") ? "text:" + typed.dropFirst() : typed)
            if pq.text.count < 2 { pq.kinds.removeAll { $0 == "text" } }
            guard !pq.text.isEmpty, !pq.kinds.isEmpty else { return }
            var q = SearchQuery(text: pq.text, root: project.root)
            q.kinds = pq.kinds
            let was = self.projectSearch
            self.projectSearch = self.delegate?.directoryView(self, search: q, in: was)
            if let id = self.projectSearch, id != was {
                self.delegate?.directoryView(self, watch: id) { [weak self] in self?.updateResults() }
            }
            self.updateResults()
        }
    }

    /// The results shown, in the files' place, while something's typed.
    private func updateResults() {
        let on = searchingProject
        if results.isHidden == on {
            results.isHidden = !on
            needsLayout = true
        }
        guard on, let project else { return }
        results.host = block.host
        results.placement = placement
        results.show(projectSearch.flatMap { delegate?.directoryView(self, block: $0)?.search }, root: project.root)
    }

    /// Open in a Tile: the search beside, kept; the homepage's field
    /// cleared, the next search a new one.
    private func popOutSearch() {
        guard let id = projectSearch else { return }
        delegate?.directoryView(self, popOut: id)
        projectSearch = nil
        searchBox.stringValue = ""
        filterTyped()
    }

    private func projectAction(_ a: ProjectAction) {
        guard let project else { return }
        delegate?.directoryView(self, project: project, do: a)
        if case .reindex = a {
            // Said as indexing at once; the host's word follows.
            if var f = facts, let s = f.index {
                f.index = SCIPStatus(root: s.root, indexer: s.indexer, state: .indexing)
                facts = f
                strip.show(f)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.askIndex(now: true) }
        }
    }

    /// The tile's menu: the folder made a project, or no longer one.
    var pillItems: [NSMenuItem] {
        if project != nil {
            // Its index made again (its chip shows only when there's
            // something to do about it).
            return [ClosureMenuItem("Index Again", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.projectAction(.reindex) },
                    ClosureMenuItem("Project Settings…", symbol: "gearshape") { [weak self] in self?.projectAction(.settings) },
                    ClosureMenuItem("No Longer a Project", symbol: "shippingbox") { [weak self] in
                guard let self else { return }
                self.delegate?.directoryView(self, makeProject: false)
            }]
        }
        return [ClosureMenuItem("Make Project", symbol: "shippingbox") { [weak self] in self?.makeProjectClicked() }]
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

    /// What dragging its chosen rows writes (debugging): the homepage's
    /// sidebar's (`sidebar`), its search's (`results`), else the files'.
    func debugDragItems(from part: String?) -> [NSPasteboardWriting] {
        if part == "sidebar" { return sidebar.debugDragItems }
        if part == "results" { return results.debugDragItems }
        guard let model else { return [] }
        return (content?.selectedPaths ?? []).compactMap { path in
            model.existingNode(path).map(pasteboardWriter)
        }
    }

    // MARK: Drops on the folder

    /// The folder taking a drop: outlined in the accent, as the Finder does.
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

    /// An entry right-clicked: its menu; one of several chosen, theirs.
    func menu(for node: BrowserNode) -> NSMenu? {
        let chosen = content?.selectedPaths ?? []
        if chosen.count > 1, chosen.contains(node.path), let model {
            let entries = chosen.map { (path: $0, isDirectory: model.existingNode($0)?.isDirectory ?? false) }
            return delegate?.directoryView(self, menuFor: entries)
        }
        return delegate?.directoryView(self, menuFor: node.path, isDirectory: node.isDirectory)
    }

    /// A mode's menu made for the entry right-clicked: `menu(for:)`'s
    /// items handed over to it, then New File and New Folder — in the
    /// folder clicked, beside the file, or (nothing clicked) in `folder`,
    /// a column's, else the listing's.
    func fill(_ menu: NSMenu, for node: BrowserNode?, in folder: String? = nil) {
        menu.removeAllItems()
        if let node, let m = self.menu(for: node) {
            for item in m.items { m.removeItem(item); menu.addItem(item) }
            menu.addItem(.separator())
            let chosen = content?.selectedPaths ?? []
            let them = chosen.count > 1 && chosen.contains(node.path) ? chosen : [node.path]
            if them.count == 1 {
                let rename = ClosureMenuItem("Rename…", symbol: "pencil", key: "r") { [weak self] in
                    // In its row when it's the one chosen (as ⌃⌘R), else in a sheet.
                    guard let self else { return }
                    if self.content?.selectedPaths == [node.path], self.content?.renameInRow() == true { return }
                    self.askRename(node.path)
                }
                rename.keyEquivalentModifierMask = [.command, .control]
                menu.addItem(rename)
            }
            let trash = ClosureMenuItem(them.count == 1 ? "Move to Trash" : "Move \(them.count) Items to Trash", symbol: "trash", key: "\u{8}") { [weak self] in
                self?.trash(them)
            }
            trash.keyEquivalentModifierMask = [.command]
            menu.addItem(trash)
            menu.addItem(.separator())
        }
        guard let model, let place = placeForNew(node, in: folder) else { return }
        let named = place == model.root ? "" : " in “\(place.lastPathComponent)”"
        menu.addItem(ClosureMenuItem("New File\(named)…", symbol: "doc.badge.plus") { [weak self] in self?.askNew(folder: false, in: place) })
        menu.addItem(ClosureMenuItem("New Folder\(named)…", symbol: "folder.badge.plus") { [weak self] in self?.askNew(folder: true, in: place) })
    }

    // MARK: Making files and folders

    /// Where what's new goes for an entry: in it, a folder; beside it, a
    /// file; none, in `folder`, else the listing's.
    func placeForNew(_ node: BrowserNode?, in folder: String? = nil) -> String? {
        if let node { return node.isDirectory ? node.path : node.path.deletingLastPathComponent }
        return folder ?? model?.root
    }

    /// File ▸ New File (⌃⌘N), New Folder (⇧⌘N): where the chosen entry is
    /// (in it, a folder), else in the listing's folder.
    @objc func newFile(_ sender: Any?) { placeForNew(content?.selectedNode).map { askNew(folder: false, in: $0) } }
    @objc func newFolder(_ sender: Any?) { placeForNew(content?.selectedNode).map { askNew(folder: true, in: $0) } }

    /// Its name asked (a sheet on the window), then made.
    func askNew(folder: Bool, in place: String) {
        guard let window, let model else { return NSSound.beep() }
        let alert = NSAlert()
        let shown = place == model.root ? place.lastPathComponent : model.relative(place)
        alert.messageText = (folder ? "New folder in “" : "New file in “") + (shown.isEmpty ? place : shown) + "”"
        alert.informativeText = folder
            ? "A path (a/b/c) makes the folders on the way too."
            : "A path (a/b/name) makes the folders on the way too; one ending in / is a folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = folder ? Self.untitledFolder : "name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.makeNew(field.stringValue, folder: folder, in: place)
        }
    }

    static let untitledFolder = "untitled folder"

    // MARK: Renaming and throwing away

    /// ⌃⌘R: the chosen entry renamed — in its row, as a name lingered on
    /// is; not shown there, in a sheet.
    @objc func renameChosen(_ sender: Any?) {
        guard let p = content?.selectedPaths, p.count == 1 else { return NSSound.beep() }
        if content?.renameInRow() != true { askRename(p[0]) }
    }

    /// The field a name's being renamed in, in its row; the entry's path.
    private var nameEditor: (field: NSTextField, path: String)?

    /// An entry's name made editable where it's drawn (`frame`, in
    /// `list`'s coordinates), its stem chosen: ⏎ or a click away renames
    /// it, esc leaves it as it was, as the Finder's.
    func renameInline(_ path: String, in list: NSView, at frame: NSRect) {
        endRenaming(keep: false)
        let name = path.lastPathComponent
        let field = NSTextField(frame: frame)
        field.stringValue = name
        field.font = UIType.row
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .exterior
        field.drawsBackground = true
        field.backgroundColor = Theme.panel
        field.textColor = Theme.text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        list.addSubview(field)
        nameEditor = (field, path)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (Self.stem(name) as NSString).length)
    }

    /// The row's field taken away: what was typed made the name (`keep`),
    /// or not; the keys back to the list.
    private func endRenaming(keep: Bool) {
        guard let (field, path) = nameEditor else { return }
        nameEditor = nil
        let typed = field.stringValue
        let list = field.superview
        field.delegate = nil
        let hadKeys = field.currentEditor() != nil
        field.removeFromSuperview()
        if hadKeys, let list { window?.makeFirstResponder(list) }
        if keep, typed.trimmingCharacters(in: .whitespacesAndNewlines) != path.lastPathComponent { rename(path, to: typed) }
    }

    var debugRenaming: String? { nameEditor.map { "\($0.path.lastPathComponent) → \($0.field.stringValue)" } }

    /// ⌘⌫: the chosen entries to the host's trash.
    @objc func trashChosen(_ sender: Any?) {
        guard let p = content?.selectedPaths, !p.isEmpty else { return NSSound.beep() }
        trash(p)
    }

    /// Its new name asked (a sheet, the name there to change, its stem
    /// chosen as the Finder's is), then renamed.
    func askRename(_ path: String) {
        guard let window else { return NSSound.beep() }
        let name = path.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename “\(name)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.rename(path, to: field.stringValue)
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (Self.stem(name) as NSString).length)
        }
    }

    /// A name's part before its extension (all of a dotfile's, a folder's
    /// with dots in it too, if it has none past the first).
    static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return name }
        return String(name.dropLast(ext.count + 1))
    }

    /// The name typed for an entry, checked: one name (no /, not . or ..),
    /// nil if it isn't; the same name, nothing to do.
    static func renamed(_ path: String, to typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return path.deletingLastPathComponent.appendingPathComponent(name)
    }

    private func rename(_ path: String, to typed: String) {
        guard let to = Self.renamed(path, to: typed) else { return NSSound.beep() }
        guard to != path else { return }
        delegate?.directoryView(self, rename: path, to: to) { [weak self] error in
            guard error == nil else { return }
            self?.choose(to, focus: true)
        }
    }

    /// Thrown away: the chosen entry after them (else before) chosen once
    /// they're gone, so the keys go on from there.
    private func trash(_ paths: [String]) {
        guard let model, let content else { return }
        let gone = Set(paths)
        let parent = paths[0].deletingLastPathComponent
        let siblings = (model.children(of: parent) ?? []).map(\.path)
        let at = siblings.firstIndex { gone.contains($0) } ?? 0
        let next = siblings[at...].first { !gone.contains($0) } ?? siblings[..<at].last
        delegate?.directoryView(self, trash: paths) { [weak self] error in
            guard let self else { return }
            self.delegate?.directoryViewRefresh(self)
            model.refresh(content.shownFolders)
            if error == nil { content.select(next ?? (parent == model.root ? nil : parent)) }
        }
    }

    /// What's typed, as a path under `place`: its folders on the way, a
    /// folder if it ends in /; nil if it's no name (empty, or . or .. in it).
    static func newPath(_ typed: String, folder: Bool, in place: String) -> (path: String, isDirectory: Bool)? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return (parts.reduce(place) { $0.appendingPathComponent($1) }, folder || name.hasSuffix("/"))
    }

    /// Made on the host, then chosen in the listing (a file, opened too —
    /// by the delegate — and so not focused here).
    private func makeNew(_ typed: String, folder: Bool, in place: String) {
        var typed = typed
        if folder, typed.trimmingCharacters(in: .whitespaces).isEmpty {
            // Nothing typed: "untitled folder" (or "… 2"), as the Finder's.
            let taken = Set((model?.children(of: place) ?? []).map(\.path.lastPathComponent))
            typed = MainWindowController.freeName(Self.untitledFolder, taken: taken)
        }
        guard let made = Self.newPath(typed, folder: folder, in: place) else { return NSSound.beep() }
        delegate?.directoryView(self, make: made.path, isDirectory: made.isDirectory) { [weak self] error in
            guard error == nil || error == "exists" else { return }
            self?.choose(made.path, focus: made.isDirectory)
        }
    }

    /// A path just made chosen once the listing has it: listed again now,
    /// then looked for a few times while the host's answer comes.
    private func choose(_ path: String, focus: Bool, tries: Int = 12) {
        guard let model, let content else { return }
        if tries == 12 {
            delegate?.directoryViewRefresh(self)
            model.refresh(content.shownFolders)
            model.prefetch(model.ancestors(of: path))
        }
        if model.children(of: path.deletingLastPathComponent)?.contains(where: { $0.path == path }) == true {
            if focus { return reveal(path) }
            return content.select(path)
        }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.choose(path, focus: focus, tries: tries - 1) }
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
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // ⌘⌫ (the Finder's) and ⌃⌘R, the entries' — not the filter's,
        // where ⌘⌫ is the line's to delete.
        if let r = window?.firstResponder as? NSView, r.isDescendant(of: self), !(r is NSText), content != nil {
            if mods == [.command], event.keyCode == 51 { trashChosen(nil); return true }
            if mods == [.command, .control], event.charactersIgnoringModifiers?.lowercased() == "r" { renameChosen(nil); return true }
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers == "." || event.charactersIgnoringModifiers == ">",
           let r = window?.firstResponder as? NSView, r.isDescendant(of: self) {
            toggleHidden()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// View ▸ Show Hidden Files (⇧⌘.), titled by what it will do.
    @objc func toggleHiddenFiles(_ sender: Any?) { toggleHidden() }

    /// View ▸ Use Groups (⌃⌘G): columns' entries under
    /// headers by kind, code by language; kept with the tile.
    @objc func toggleGroups(_ sender: Any?) {
        guard let model else { return }
        model.useGroups.toggle()
        keeper.note(["groups": model.useGroups ? "1" : "0"])
        content?.reloadAll()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleHiddenFiles(_:)) {
            item.title = model?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files"
        }
        if item.action == #selector(toggleGroups(_:)) {
            item.state = model?.useGroups == true ? .on : .off
            return mode == .columns
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

    /// A project's searches (and "?text" ones) asked before: ↑ ↓ in its field.
    private let queryHistory = SearchHistory("project")

    /// A search asked before, in the field, asked again.
    private func recall(_ q: String) {
        searchBox.stringValue = q
        search.showRecalled(q)
        filterTyped()
    }

    @objc private func filterTyped() {
        searchBox.update()
        if home { return projectQueryTyped() }
        model?.setFilter(searchingContents ? "" : search.stringValue)
        keeper.note(["filter": search.stringValue])
        updateFooter()
        updateNote()
        needsLayout = true
    }

    // The box's hairline in the accent while the filter has the keyboard
    // (from when it takes it, `FlatField`, to when it lets it go).
    func controlTextDidEndEditing(_ obj: Notification) {
        // The name's field left (a click away, ⇥): renamed as typed.
        if let e = nameEditor, obj.object as? NSTextField === e.field { return endRenaming(keep: true) }
        searchBox.needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let e = nameEditor, control === e.field {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): endRenaming(keep: true); return true
            case #selector(NSResponder.cancelOperation(_:)): endRenaming(keep: false); return true
            default: return false
            }
        }
        // ↑ (in a project's search, or a "?text" one): what was asked before;
        // ↓ back toward what was typed.
        if home || searchingContents || search.stringValue.isEmpty, selector == #selector(NSResponder.moveUp(_:)) {
            if let q = queryHistory.step(older: true, from: search.stringValue) { recall(q) }
            return true
        }
        if queryHistory.walking, selector == #selector(NSResponder.moveDown(_:)) {
            if let q = queryHistory.step(older: false, from: search.stringValue) { recall(q) }
            return true
        }
        // A project's search (§2.6): ↓ into what's found, ⏎ the best (or
        // the one chosen) gone to; ⎋ as the filter's.
        if searchingProject {
            switch selector {
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
                guard results.hasFound else { return true }
                queryHistory.add(search.stringValue)
                window?.makeFirstResponder(results.focusView)
                results.selectFirst()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                searchSoon.flush()
                queryHistory.add(search.stringValue)
                results.openChosen()
                return true
            default: break
            }
        }
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
            if !text.isEmpty { queryHistory.add(search.stringValue); delegate?.directoryView(self, searchContents: text) }
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
        if home {
            if !footer.isHidden { footer.isHidden = true; needsLayout = true }
            return
        }
        if searchingContents {
            let text = search.stringValue.dropFirst().trimmingCharacters(in: .whitespaces)
            footer.stringValue = text.isEmpty ? "" : "↩ searches for “\(text)”"
            footer.isHidden = false
            needsLayout = true
            return
        }
        // Not filtering: "Reading…" while folders opened are listed the first
        // time (a moment late, so a quick listing shows nothing).
        guard model.filtering else {
            if model.readingFolders {
                guard footer.isHidden, !footerWork.isPending else { return }
                footerWork.schedule(after: BusyNote.delay) { [weak self] in
                    guard let self, let m = self.model, !m.filtering, m.readingFolders else { return }
                    self.footer.stringValue = "Reading…"
                    self.footer.isHidden = false
                    self.needsLayout = true
                }
                return
            }
            footerWork.cancel()
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

    // MARK: How it's shown, under the pointer

    /// How it's shown — Project Home, a tree or columns — only while the
    /// pointer's on the tile (§3.1): quiet otherwise. Their room is kept.
    private var pointerIn = false {
        didSet {
            guard pointerIn != oldValue else { return }
            showViewButtons(animated: true)
        }
    }

    private func showViewButtons(animated: Bool) {
        let a: CGFloat = pointerIn || TilePill.buttonsAlways ? 1 : 0
        guard animated, !Motion.reduced else { for v in [homeButton, modes] as [NSView] { v.alphaValue = a }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            for v in [homeButton, modes] as [NSView] { v.animator().alphaValue = a }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.userInfo?["viewButtons"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: ["viewButtons": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["viewButtons"] != nil { pointerIn = true } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["viewButtons"] != nil { pointerIn = false } else { super.mouseExited(with: event) }
    }

    // MARK: Layout

    /// A project's sidebar shown at the right: room for less beside it.
    var showsProjectSidebar: Bool { !sidebar.isHidden }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - Self.headerHeight, width: w, height: Self.headerHeight)
        showViewButtons(animated: false)
        let midY = Self.headerHeight / 2
        up.frame = NSRect(x: 8, y: midY - 12, width: 26, height: 24)
        modes.sizeToFit()
        modes.frame.origin = NSPoint(x: w - 12 - modes.frame.width, y: (midY - modes.frame.height / 2).rounded())
        var fieldEnd = modes.frame.minX - 8
        if !homeButton.isHidden {
            homeButton.frame = NSRect(x: fieldEnd - 28, y: (midY - Flat.buttonHeight / 2).rounded(), width: 28, height: Flat.buttonHeight)
            fieldEnd = homeButton.frame.minX - 6
        }
        // The strip with nothing but its +: not shown, the + here.
        let stripShown = home && strip.hasChips
        newAgent.isHidden = !home || stripShown
        if !newAgent.isHidden {
            newAgent.frame = NSRect(x: fieldEnd - 20, y: (midY - 8).rounded(), width: 16, height: 16)
            fieldEnd = newAgent.frame.minX - 8
        }
        // Make Project is the tile menu's alone; the project's button gives
        // way before the field gets too narrow to type in.
        makeProject.frame = .zero
        let fieldLeast: CGFloat = 140
        if !toProject.isHidden {
            toProject.sizeToFit()
            toProject.frame.size.width = min(toProject.frame.width, 180)
            if fieldEnd - toProject.frame.width - 6 - up.frame.maxX - 6 >= fieldLeast {
                toProject.frame.origin = NSPoint(x: fieldEnd - toProject.frame.width, y: (midY - toProject.frame.height / 2).rounded())
                fieldEnd = toProject.frame.minX - 6
            } else {
                toProject.frame = .zero
            }
        }
        searchBox.frame = NSRect(x: up.frame.maxX + 6, y: midY - Flat.fieldHeight / 2, width: max(60, fieldEnd - up.frame.maxX - 6), height: Flat.fieldHeight)
        // A project's homepage: its strip under the header, its sidebar at
        // the right; the files and the README in what's left.
        var top = h - Self.headerHeight
        strip.isHidden = !stripShown
        if stripShown {
            strip.frame = NSRect(x: 0, y: top - ProjectStrip.height, width: w, height: ProjectStrip.height)
            top -= ProjectStrip.height
        }
        sidebar.isHidden = !home || w < Self.sidebarFrom
        let footerHeight: CGFloat = footer.isHidden ? 0 : 22
        footer.frame = NSRect(x: 0, y: 4, width: w, height: 14)
        // The README under the files (not over a filter's matches), as
        // wide as the tile, under the sidebar too: its bar alone when
        // collapsed, or when the tile's too short for both.
        var bottom = footerHeight
        let room = top - footerHeight
        let showsReadme = readmeText != nil && model?.filtering != true && !searchingContents && results.isHidden
        readme.isHidden = !showsReadme
        if showsReadme {
            let bar = FolderReadme.barHeight, least: CGFloat = 120
            let open = !readmeCollapsed && room >= bar + 2 * least
            let wanted = readmeHeight ?? keeper.double("readmeHeight").map { CGFloat($0) } ?? (room * 0.45).rounded()
            let height = open ? min(max(wanted, bar + least), room - least) : bar
            if readme.collapsed == open { readme.collapsed = !open }
            readme.frame = NSRect(x: 0, y: footerHeight, width: w, height: height)
            bottom += height
        }
        // The sidebar at the right of the files, above the README.
        var right = w
        if !sidebar.isHidden {
            right = w - ProjectSidebar.width
            sidebar.frame = NSRect(x: right, y: bottom, width: ProjectSidebar.width, height: max(0, top - bottom))
        }
        // What's left for the files: below the strip, left of the sidebar.
        let fw = right
        content?.frame = NSRect(x: 0, y: bottom, width: fw, height: max(0, top - bottom))
        note.frame = NSRect(x: 0, y: bottom, width: fw, height: max(0, top - bottom))
        // A project's search over the files and the README.
        results.frame = NSRect(x: 0, y: 0, width: fw, height: top)
        // (Over the README and the note, which are added before it.)
        content?.isHidden = !results.isHidden
    }

    // MARK: The README, and Markdown pages

    /// Its height as dragged, until the tile's laid out again.
    private var readmeHeight: CGFloat?

    private func toggleReadme() {
        readmeCollapsed = !readme.collapsed
        needsLayout = true
    }

    /// The folder's README among its entries: Markdown first, then plain
    /// text (README, README.txt, .rst…), whatever the letters' case.
    static func readme(in entries: [DirectoryEntry]) -> DirectoryEntry? {
        func rank(_ e: DirectoryEntry) -> Int? {
            guard !e.isDirectory else { return nil }
            let name = e.name.lowercased(), ext = name.pathExtension
            guard (ext.isEmpty ? name : String(name.dropLast(ext.count + 1))) == "readme" else { return nil }
            if Lens.isMarkdown(name) { return 0 }
            return ["", "txt", "rst", "adoc", "org", "text"].firstIndex(of: ext).map { $0 + 1 }
        }
        return entries.compactMap { e in rank(e).map { (e, $0) } }.min { $0.1 < $1.1 }?.0
    }

    /// The folder listed (again): its README read if it's new or changed.
    private func readEntries(_ entries: [DirectoryEntry]) {
        let found = Self.readme(in: entries)
        guard found != readmeEntry else { return }
        readmeEntry = found
        readmeCancel?()
        readmeCancel = nil
        guard let found, let model, found.size <= 4_000_000 else {
            readmeText = nil
            needsLayout = true
            return
        }
        let path = model.absolute(found.name)
        readmeCancel = resolve(path) { [weak self] url in
            guard let url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url) else { return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self, self.readmeEntry == found else { return }
                    // Plain text as it's written: in a block of its own.
                    let markdown = Lens.isMarkdown(found.name) ? text : Self.fenced(text)
                    self.readmeText = (markdown, (self.readmeText?.version ?? 0) + 1)
                    self.readme.show(name: found.name) { self.makePage(path) }
                    self.readme.page?.show(block: self.block, path: path)
                    self.readme.page?.textChanged()
                    self.needsLayout = true
                }
            }
        }
    }

    /// Text in a code block, its fence longer than any run of backticks in it.
    private static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for c in text { run = c == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "text\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence + "\n"
    }

    /// A page for Markdown, as a preview tile has it — its links followed
    /// as there — showing `path`; its text from `source`, else the README's.
    func makePage(_ path: String, source: (() -> (text: String, version: Int)?)? = nil) -> MarkdownView {
        let page = MarkdownView(placement: placement, block: block, path: path, theme: FontTheme.current)
        page.delegate = self
        page.source = source ?? { [weak self] in self?.readmeText }
        pages.add(page)
        return page
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
        case "reveal": if words.count > 1 { reveal(words[1]) }
        case "open": openSelected()
        case "up": goUp()
        case "go": if words.count > 1 { navigate(to: words[1]) }
        case "hidden": toggleHidden()
        case "renamerow":
            // "renamerow": the chosen entry's row made editable (⌃⌘R); "renamerow type <text>|enter|esc" in it.
            let rest = words.count > 1 ? words[1].split(separator: " ", maxSplits: 1).map(String.init) : []
            switch rest.first {
            case "type": nameEditor?.field.stringValue = rest.count > 1 ? rest[1] : ""
            case "enter": endRenaming(keep: true)
            case "esc": endRenaming(keep: false)
            default: renameChosen(nil)
            }
            return "renaming: \(debugRenaming ?? "none")"
        case "rename":
            // "rename <new name>": the chosen entry, as ⌃⌘R's sheet would.
            guard words.count > 1, let p = content?.selectedPaths, p.count == 1 else { return "rename <name>, one entry chosen" }
            rename(p[0], to: words[1])
            return "renaming \(p[0].lastPathComponent)"
        case "trash":
            guard let p = content?.selectedPaths, !p.isEmpty else { return "nothing chosen" }
            trash(p)
            return "trashing \(p.map(\.lastPathComponent).joined(separator: " "))"
        case "new":
            // "new file|folder <name>": made where the chosen entry is, as ⌃⌘N/⇧⌘N's sheet would.
            let rest = words.count > 1 ? words[1].split(separator: " ", maxSplits: 1).map(String.init) : []
            guard let kind = rest.first, let place = placeForNew(content?.selectedNode) else { return "new file|folder <name>" }
            makeNew(rest.count > 1 ? rest[1] : "", folder: kind == "folder", in: place)
            return "making in \(place)"
        case "groups": toggleGroups(nil)
        case "tree": setMode(.tree)
        case "columns": setMode(.columns)
        case "home": toggleHome()
        case "make": makeProjectClicked()
        case "toproject": goToProject()
        case "search":
            // "search <text>": typed in a project's homepage's field ("-": emptied); "search" alone, what's found.
            if words.count > 1 {
                searchBox.stringValue = words[1] == "-" ? "" : words[1]
                filterTyped()
                searchSoon.flush()
            }
            return results.isHidden ? "no search shown" : results.debugState
        case "searchenter": results.openChosen()
        case "searchchoose":
            // "searchchoose <i> <i>…": those found chosen together.
            return results.debugChoose(words.count > 1 ? words[1].split(separator: " ").compactMap { Int($0) } : [])
        case "popout": popOutSearch()
        case "project":
            // "project git|reindex|commit <n>|change <n>": as its homepage's buttons and rows do.
            let w = words.count > 1 ? words[1].split(separator: " ").map(String.init) : []
            guard let g = facts?.git, let repo = facts?.repo else { break }
            switch w.first {
            case "git": projectAction(.openGit)
            case "reindex": projectAction(.reindex)
            case "commit": if let n = w.last.flatMap(Int.init), n < g.log.count { projectAction(.openCommit(g.log[n], repo: repo)) }
            case "change": if let n = w.last.flatMap(Int.init), n < g.status.count { projectAction(.openChange(g.status[n], repo: repo)) }
            default: break
            }
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
        case "readme": toggleReadme()
        case "readmelink":
            // "readmelink <n>": the README's nth link clicked, as a reader would.
            readme.page?.debugClickLink(Int(words.count > 1 ? words[1] : "0") ?? 0)
            return "clicked"
        case "choose":
            // "choose <path> <path>…" (from the root): those entries chosen together.
            let paths = words.count > 1 ? words[1].split(separator: " ").map { model?.absolute(String($0)) ?? String($0) } : []
            content?.debugChoose(paths)
        case "menu":
            // "menu <path> [<i>]": the menu of that entry (from the root)
            // right-clicked, as the chosen make it; with i, its item i done.
            let w = words.count > 1 ? words[1].split(separator: " ").map(String.init) : []
            guard let rel = w.first, let model, let node = model.existingNode(model.absolute(rel)), let m = menu(for: node) else { return "no entry" }
            if w.count > 1, let i = Int(w[1]), m.items.indices.contains(i), let item = m.items[i] as? ClosureMenuItem {
                item.perform()
                return "did \(item.title)"
            }
            return m.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: "\n")
        case "sidebar":
            // "sidebar <i> <i>…": a homepage's draggable rows ⌘-clicked (-i: ⇧-clicked);
            // "sidebar dropping on|off": shown as it is with something to pin over it.
            if words.count > 1, words[1].hasPrefix("dropping") {
                sidebar.debugDropping(words[1].hasSuffix("on"))
                return "ok"
            }
            return sidebar.debugChoose(words.count > 1 ? words[1].split(separator: " ").compactMap { Int($0) } : [])
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
        if let project { lines.append("project \(project.root)" + (home ? " (home)\nstrip \(strip.debugState)\nsidebar \(sidebar.isHidden ? "hidden" : "\(Int(sidebar.frame.width)) wide")\n" + sidebar.debugState : "")) }
        if !makeProject.isHidden { lines.append("offers Make Project") }
        if let p = parentProject { lines.append("in project \(p.name), offered") }
        if !footer.isHidden { lines.append("footer \(footer.stringValue)") }
        lines.append("note \(note.debugState)")
        lines.append("watched " + (watched.map { $0.map { model?.relative($0) ?? $0 }.map { $0.isEmpty ? "." : $0 }.sorted().joined(separator: " ") } ?? "none (asked again every few seconds)"))
        if let e = readmeEntry {
            lines.append("readme \(e.name) \(readme.isHidden ? "hidden" : readme.collapsed ? "collapsed" : "open \(Int(readme.frame.height))")\(readmeText == nil ? " (unread)" : "")")
        }
        if let a = model?.debugAsking, !a.isEmpty { lines.append("listing \(a)") }
        if let d = content { lines.append(d.debugRows) }
        return lines.joined(separator: "\n")
    }
}

protocol DebugDescribing { var debugRows: String { get } }

/// Its Markdown pages' links, followed as a preview tile's are (the tile
/// is theirs); ⌘[ ⌘] the folder's.
extension DirectoryView {
    func markdownView(_ view: MarkdownView, follow url: URL, modifiers: NSEvent.ModifierFlags) {
        (delegate as? MarkdownViewDelegate)?.markdownView(view, follow: url, modifiers: modifiers)
    }
    func markdownViewDidReveal(_ view: MarkdownView) {}
    func markdownView(_ view: MarkdownView, image data: Data, kind: String) {}
    func markdownView(_ view: MarkdownView, append markdown: String, naming blocks: [BlockID]) {}
    func markdownView(_ view: MarkdownView, history direction: Int) -> Bool {
        delegate?.directoryView(self, history: direction) ?? false
    }

    func fontThemeChanged() {
        for p in pages.allObjects { p.theme = FontTheme.current }
    }
}

extension NSImage {
    /// A template image drawn in a colour.
    /// In that colour (resolved as it's drawn, so a dynamic one follows the
    /// appearance): made once for the image and colour — a list's rows asked
    /// for theirs each time one was shown, scrolling.
    func tinted(_ color: NSColor) -> NSImage {
        let key = TintedKey(image: ObjectIdentifier(self), color: ObjectIdentifier(color))
        if let kept = NSImage.tintedKept[key] { return kept.out }
        let out = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        if NSImage.tintedKept.count > 4000 { NSImage.tintedKept = [:] }
        // The image and colour kept with it: their identities aren't another's while it's here.
        NSImage.tintedKept[key] = (self, color, out)
        return out
    }

    private struct TintedKey: Hashable { var image: ObjectIdentifier; var color: ObjectIdentifier }
    private static var tintedKept: [TintedKey: (image: NSImage, color: NSColor, out: NSImage)] = [:]

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

    func dropTrack(_ d: Dragged, at p: NSPoint) {
        dropping = true
    }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        guard let folder = p.flatMap({ dropFolder(at: $0) }) ?? model?.root else { return }
        let items = dropped(d, into: folder)
        guard !items.isEmpty else { return NSSound.beep() }
        delegate?.directoryView(self, receive: items, into: folder, moving: form == .move)
    }
}
