import AppKit
import ManifoldCore

/// What the window keeps of threads (§3.12): the card shown, the chats
/// on screen (to be kept up to date), and what each last showed.
final class ThreadUI {
    /// The card shown, and its popover: both let go of as it closes
    /// (§ M36 in STATE-MACHINES.md) — not kept, refreshed and acted on.
    var popover: NSPopover?
    var card: ThreadCardView?
    var cardClosed: NSObjectProtocol?
    /// Keeps the card up, a click elsewhere notwithstanding, while
    /// something's written in it.
    let cardKeeper = PopoverKeeper()
    /// Every chat on screen, held weakly: a card's, a tile's, the overlay's.
    var chats: [Weak<ThreadChatView>] = []
    /// Every timeline on screen.
    var timelines: [Weak<ThreadTimelineView>] = []
    /// The overlay, while it's up.
    var overlay: ThreadOverlayView?
    /// Agents asked, waiting for their turn to end.
    var asks: [MainWindowController.PendingAsk] = []
    /// What each thread looked like when last shown, to show again only
    /// what changed.
    var shown: [ObjectIdentifier: String] = [:]
    /// The threads' state as last seen, to tell editors and diffs only
    /// when something did change.
    var lastSignature = ""
}

/// A thread as a tile of its own (§3.12): its chat, filling the tile.
final class ThreadTileView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    let chat = ThreadChatView()
    var focusView: NSView { chat.composer }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        chat.fits = false
        chat.maxHeight = .greatestFiniteMagnitude
        addSubview(chat)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {}

    override func layout() {
        super.layout()
        chat.frame = bounds
    }

    func maniText(_ options: ManiReadOptions) async -> String? { nil }
}

/// A card at a place (§3.12): its threads' chat — one at a time, stepped
/// through when there are more — or the composer for a new one.
final class ThreadCardView: NSView {
    let chat = ThreadChatView()
    private let nav = NSStackView()
    private let count = NSTextField.label(font: UIType.caption, color: Theme.secondaryText)
    private let prev = IconButton("chevron.left", size: 10)
    private let next = IconButton("chevron.right", size: 10)
    var threads: [BlockID] = [] { didSet { index = min(index, max(0, threads.count - 1)); updateNav() } }
    var index = 0 { didSet { updateNav() } }
    var onStep: ((Int) -> Void)?
    static let width: CGFloat = 420

    override init(frame: NSRect) {
        super.init(frame: frame)
        prev.target = self; prev.action = #selector(stepBack)
        next.target = self; next.action = #selector(stepOn)
        nav.orientation = .horizontal
        nav.spacing = 4
        nav.addArrangedSubview(prev)
        nav.addArrangedSubview(count)
        nav.addArrangedSubview(next)
        addSubview(nav)
        addSubview(chat)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func stepBack() { if index > 0 { index -= 1; onStep?(index) } }
    @objc private func stepOn() { if index + 1 < threads.count { index += 1; onStep?(index) } }

    private func updateNav() {
        nav.isHidden = threads.count < 2
        count.stringValue = "\(index + 1) of \(threads.count) threads here"
        prev.isEnabled = index > 0
        next.isEnabled = index + 1 < threads.count
        needsLayout = true
    }

    var wantedSize: NSSize {
        NSSize(width: Self.width, height: chat.wantedHeight + (nav.isHidden ? 0 : 24))
    }

    override func layout() {
        super.layout()
        let navH: CGFloat = nav.isHidden ? 0 : 24
        nav.frame = NSRect(x: 12, y: bounds.height - navH, width: bounds.width - 24, height: navH)
        chat.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - navH)
    }
}

extension MainWindowController: ThreadChatDelegate {
    // MARK: Showing a thread

    /// A thread's chat as it stands: its place and how that's moved, what
    /// you hadn't seen, the agents at work on it.
    func chatModel(thread: Block?, place: ThreadPlace?, inTile: Bool = false) -> ThreadChatModel {
        var m = ThreadChatModel()
        m.thread = thread
        m.place = place
        m.inTile = inTile
        let about = thread?.thread?.about ?? place
        if let about {
            let (title, drift, gone) = describe(about)
            m.placeTitle = title
            m.drift = drift
            m.gone = gone
            // As a card: its name, and where it is (a page's site, a
            // file's folder, the host it's on).
            let b = hosts.block(about.block)
            let words = title.components(separatedBy: " · ")
            m.placeName = words.first ?? title
            var whereIs = Array(words.dropFirst())
            if let url = b?.web?.url.flatMap({ URL(string: $0) }), let host = url.host { whereIs.insert(host, at: 0) }
            else if let path = b?.path { whereIs.insert(Self.tilde((path as NSString).deletingLastPathComponent), at: 0) }
            m.placeWhere = whereIs.joined(separator: " · ")
            m.placeSymbol = b.map { Theme.symbolName(for: $0) } ?? "doc"
            m.placeImage = b?.web.flatMap { Favicons.image(forPage: $0.url) }
        }
        if let t = thread {
            m.seenMark = hosts.seenMark(t.id)
            for a in t.thread?.agents ?? [] where hosts.block(a.block)?.statusState == .working {
                // At work since it was last asked here.
                if case .asked? = t.thread?.entries.last?.kind { m.working.insert(a.block) }
            }
        }
        m.icon = { [weak self] id in
            guard let a = self?.hosts.block(id)?.agent else { return nil }
            return AgentIcons.image(a.command, size: 12)
        }
        // The agent's thread, and who Ask would make it.
        m.askName = askingAgent?.name ?? "Claude"
        if let kind = thread.flatMap({ asksAgent(of: $0) }) {
            m.asks = kind.name
            m.asksIcon = AgentIcons.image(kind.command, size: 14)
        }
        return m
    }

    /// The agent a thread is (§3.12), if it's an agent's thread: every
    /// comment of yours asks it, untagged. Kept as the thread's annotation.
    func asksAgent(of thread: Block) -> AgentCatalog.Agent? {
        thread.annotations?[Self.asksKey].flatMap { AgentCatalog.agent(inCommand: $0) }
    }
    static let asksKey = "asks"

    /// The agent Ask makes a thread: Settings' (its agent command), else Claude Code.
    var askingAgent: AgentCatalog.Agent? {
        AgentCatalog.agent(inCommand: desk.settings.agentCommand) ?? AgentCatalog.agent(inCommand: "claude")
    }

    func threadChatGoToPlace(_ view: ThreadChatView) {
        guard let id = view.threadID else { return }
        goToPlace(ofThread: id)
    }

    func threadChat(_ view: ThreadChatView, asks: Bool) {
        guard let id = view.threadID, let kind = askingAgent else { return }
        hosts.append(.annotate([Self.asksKey: asks ? kind.command : ""]), to: .block(id))
    }

    /// A path with the home said as ~.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// What a place is called, where it is now against where it was
    /// written, and whether it's gone.
    func describe(_ p: ThreadPlace) -> (title: String, drift: String?, gone: Bool) {
        guard let b = hosts.block(p.block) else { return (p.title ?? "Gone", "no longer here", true) }
        if b.kind == .arrangement { return ("The space " + (b.arrangement.map(title(of:)) ?? b.displayTitle), nil, false) }
        var parts = [p.title ?? b.path?.lastPathComponent ?? b.displayTitle]
        if let name = p.name, !name.isEmpty, name != parts[0] { parts.append(name) }
        // A notebook's cell: by its words now (gone, if it is).
        if case let .cell(id)? = p.anchor.flatMap(Locator.init(fragment:)) {
            guard let s = b.summary(at: .cell(id)) else { return (parts.joined(separator: " · "), "the cell is gone", true) }
            if p.name?.isEmpty ?? true { parts.append(s.title) }
            return (parts.joined(separator: " · "), nil, false)
        }
        guard let id = p.anchor, let a = b.anchors?[id] else {
            if let l = p.line { parts.append("line \(l)") }
            return (parts.joined(separator: " · "), nil, false)
        }
        switch a.at {
        case .command, .page: return (parts.joined(separator: " · "), nil, false)
        default: break
        }
        guard let rope = b.text?.text, !(b.text?.isUnread ?? true) else {
            if let l = p.line { parts.append("line \(l)") }
            return (parts.joined(separator: " · "), nil, false)
        }
        guard let (range, _) = Anchoring.locate(a, in: b) else {
            if let l = p.line { parts.append("line \(l)") }
            return (parts.joined(separator: " · "), "gone from the file", true)
        }
        let now = rope.line(at: range.start) + 1
        parts.append("line \(now)")
        let drift = p.line.flatMap { $0 != now ? "written at line \($0)" : nil }
        return (parts.joined(separator: " · "), drift, false)
    }

    /// Every chat on screen brought up to date — those whose thread
    /// changed — and the editors' and diffs' marks, when threads did.
    func threadsChanged() {
        deliverAsks()
        let all = hosts.threads
        var sig = ""
        for t in all {
            let th = t.thread
            sig += "\(t.id)/\(th?.entries.count ?? 0)/\(th?.resolved == true)/\(hosts.seenMark(t.id)?.wall ?? 0);"
        }
        for case let w in threadUI.chats {
            guard let chat = w.value else { continue }
            refresh(chat)
        }
        threadUI.chats.removeAll { $0.value == nil }
        guard sig != threadUI.lastSignature else { return }
        threadUI.lastSignature = sig
        threadUI.timelines.removeAll { $0.value == nil }
        for w in threadUI.timelines { if let t = w.value { refresh(t) } }
        // The sidebar's list (its rows), or its count.
        refreshSidebarThreads()
        for v in views.values {
            (v as? EditorView)?.refreshPills()
            if let d = v as? DiffView { markThreads(in: d) }
            if let o = v as? OutlineNoteView { o.threadPlaces = places(of: o.block) }
        }
    }

    private func refresh(_ chat: ThreadChatView) {
        let thread = chat.threadID.flatMap { hosts.block($0) }
        // A new one not come yet: as it was.
        if chat.threadID != nil, thread == nil { return }
        let m = chatModel(thread: thread, place: chat.newPlace, inTile: chat.model.inTile)
        let th = thread?.thread
        let key = "\(thread?.id.description ?? "new")/\(th?.entries.count ?? 0)/\(th?.resolved == true)/\(m.drift ?? "")/\(m.placeTitle)/\(m.working.count)"
        guard threadUI.shown[ObjectIdentifier(chat)] != key else { return }
        threadUI.shown[ObjectIdentifier(chat)] = key
        // The New rule stays where it was while the chat is open.
        var keep = m
        if chat.model.thread?.id == thread?.id, chat.model.thread != nil { keep.seenMark = chat.model.seenMark }
        chat.show(keep)
        if let card = threadUI.card, card.chat === chat { resizeCard() }
    }

    /// A chat kept up to date from now on.
    /// A block referred to in a comment, as a card: its icon (a page's
    /// own), its name, and where it is.
    func mentionChip(_ id: String) -> ChatBox.Chip? {
        guard let bid = BlockID(string: id), let b = hosts.block(bid) else { return nil }
        var whereIs = ""
        if let url = b.web?.url.flatMap({ URL(string: $0) }), let host = url.host { whereIs = host }
        else if let path = b.path { whereIs = Self.tilde((path as NSString).deletingLastPathComponent) }
        else if let a = b.agent { whereIs = a.name }
        else if let cwd = b.terminal?.cwd { whereIs = Self.tilde(cwd) }
        else { whereIs = b.isNote ? "Note" : b.kind.defaultTitle }
        return ChatBox.Chip(symbol: Theme.symbolName(for: b), image: b.agent.flatMap { AgentIcons.image($0.command, size: 16) } ?? b.web.flatMap { Favicons.image(forPage: $0.url) },
                            title: Self.linkTitle(b), detail: whereIs)
    }

    func watch(_ chat: ThreadChatView) {
        if ChatBox.chipFor == nil { ChatBox.chipFor = { [weak self] id in self?.mentionChip(id) } }
        chat.delegate = self
        chat.composer.mentionSource = { [weak self] in self?.mentionSource() ?? { _ in [] } }
        if !threadUI.chats.contains(where: { $0.value === chat }) { threadUI.chats.append(Weak(chat)) }
        threadUI.shown.removeValue(forKey: ObjectIdentifier(chat))
        refresh(chat)
    }

    // MARK: The card

    /// The threads at a place, or the composer for a new one about it, as
    /// a card by `rect` in `view`.
    func showThreadCard(threads: [BlockID], newPlace: ThreadPlace? = nil, space: BlockID? = nil, at rect: NSRect, in view: NSView) {
        threadUI.popover?.close()
        let card = ThreadCardView()
        let order = threads.compactMap { hosts.block($0) }
            .sorted { a, b in (a.thread?.resolved == true ? 1 : 0, a.created) < (b.thread?.resolved == true ? 1 : 0, b.created) }.map(\.id)
        card.threads = order
        card.chat.threadID = order.first
        card.chat.newPlace = order.isEmpty ? newPlace : nil
        card.chat.newSpace = space ?? selected
        card.onStep = { [weak self, weak card] i in
            guard let self, let card else { return }
            card.chat.threadID = card.threads[i]
            self.watch(card.chat)
        }
        let vc = NSViewController()
        vc.view = card
        card.frame = NSRect(x: 0, y: 0, width: ThreadCardView.width, height: 200)
        let pop = NSPopover()
        // Closed by a click in the window or ⎋, not by Manifold going to the back.
        pop.behavior = .semitransient
        pop.animates = false
        // Frosted and without its arrow, as the other menus and cards are
        // (the system's own switch; skipped where it hasn't one).
        if pop.responds(to: Selector(("setShouldHideAnchor:"))) { pop.setValue(true, forKey: "shouldHideAnchor") }
        pop.contentViewController = vc
        // A click elsewhere puts it away — unless something's written in it
        // (or a comment's being edited): that kept, until ⎋ or it's sent.
        threadUI.cardKeeper.keep = { [weak card] in
            guard let chat = card?.chat else { return false }
            return chat.editing != nil || !chat.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        pop.delegate = threadUI.cardKeeper
        threadUI.popover = pop
        threadUI.card = card
        if let o = threadUI.cardClosed { NotificationCenter.default.removeObserver(o) }
        threadUI.cardClosed = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self, weak pop] _ in
            MainActor.assumeIsolated {
                guard let self, self.threadUI.popover === pop else { return }
                self.threadUI.popover = nil
                self.threadUI.card = nil
                if let o = self.threadUI.cardClosed { NotificationCenter.default.removeObserver(o) }
                self.threadUI.cardClosed = nil
            }
        }
        card.chat.composer.onCancel = { [weak pop] in pop?.close() }
        watch(card.chat)
        pop.contentSize = card.wantedSize
        pop.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        card.layoutSubtreeIfNeeded()
        resizeCard()
        card.chat.scrollToEnd()
        card.chat.focusComposer()
    }

    func resizeCard() {
        guard let pop = threadUI.popover, let card = threadUI.card else { return }
        card.layoutSubtreeIfNeeded()
        let size = card.wantedSize
        if abs(pop.contentSize.height - size.height) > 1 { pop.contentSize = size }
    }

    // MARK: ThreadChatDelegate

    func threadChat(_ view: ThreadChatView, send text: String) {
        if let id = view.threadID {
            hosts.addToThread(id, .comment(text))
            askAgents(in: id, comment: text, author: Hosts.you)
            return
        }
        guard let place = view.newPlace else { return }
        let space = view.newSpace ?? selected
        let id = hosts.newThread(about: place, space: space, text: text) { [weak self] error in
            if let error { self?.toast.say("The thread wasn't made: \(error)", .brief) }
        }
        view.threadID = id
        view.newPlace = nil
        // Made with Ask on: the agent's thread, and asked from the first comment.
        let asks = view.asksNew ? askingAgent : nil
        view.madeAsking()
        askAgents(in: id, comment: text, author: Hosts.you, asks: asks)
        // The card's threads now this one.
        if let card = threadUI.card, card.chat === view { card.threads = [id] }
        // The overlay's: a thread now, to make a tile of at once.
        if let o = threadUI.overlay, o.chat === view {
            o.hereThreads = [id] + o.hereThreads
            o.canPopOut = true
        }
    }

    func threadChat(_ view: ThreadChatView, edit entry: String, text: String) {
        guard let id = view.threadID else { return }
        hosts.editThreadComment(id, entry: entry, text: text) { [weak self] error in
            if let error { self?.toast.say("The comment wasn't changed: \(error)", .brief) }
        }
    }

    func threadChat(_ view: ThreadChatView, resolve: Bool) {
        guard let id = view.threadID else { return }
        hosts.addToThread(id, resolve ? .resolved : .reopened)
    }

    func threadChat(_ view: ThreadChatView, follow address: String) {
        open(address, from: arrangement?.focused)
    }

    func threadChatOpenTile(_ view: ThreadChatView) {
        guard let id = view.threadID else { return }
        threadUI.popover?.close()
        if threadUI.overlay?.chat === view { closeThreadOverlay() }
        popOutThread(id)
    }

    func threadChatSeen(_ view: ThreadChatView) {
        guard let id = view.threadID, let t = hosts.block(id) else { return }
        hosts.markSeen(t)
    }

    /// The threads at a place in a text, by its line: those about the
    /// anchors on it.
    func threads(inText id: BlockID, line: Int) -> [BlockID] {
        guard let b = hosts.block(id), let rope = b.text?.text else { return [] }
        var out: [BlockID] = []
        for a in (b.anchors ?? [:]).values {
            guard let r = a.range, r.start <= rope.count, rope.line(at: r.start) == line else { continue }
            out += hosts.threads(about: id, anchor: a.id).map(\.id)
        }
        return out
    }

    /// An editor's thread mark clicked: its threads, as a card there.
    func editorThreadsClicked(_ e: EditorView, line: Int, rect: NSRect) {
        let ids = threads(inText: e.block, line: line)
        guard !ids.isEmpty else { return }
        showThreadCard(threads: ids, at: e.convert(rect, from: e.textView), in: e)
    }

    // MARK: Places in diffs

    /// A diff's thread marks: threads made in it, at their rows.
    func markThreads(in d: DiffView) {
        var marks: [Int: ThreadMark.State] = [:]
        let rows = d.rows
        guard !rows.isEmpty else { d.threadRows = [:]; return }
        let made = hosts.threads.filter { $0.thread?.about?.diff?.block == d.block }
        guard !made.isEmpty else { d.threadRows = [:]; return }
        for t in made {
            guard let place = t.thread?.about?.diff else { continue }
            guard let i = rows.indices.first(where: { i in
                let r = rows[i]
                let line = place.new ? (r.kind == .removed ? nil : r.newLine) : (r.kind == .added ? nil : r.oldLine)
                return line == place.start && d.filePath(ofRow: i) == place.file
            }) else { continue }
            let open = t.thread?.resolved != true, unseen = !hosts.unseen(t).isEmpty
            let old = marks[i]
            marks[i] = ThreadMark.State(count: (old?.count ?? 0) + 1, open: open || old?.open == true, unseen: unseen || old?.unseen == true)
        }
        d.threadRows = marks
    }

    /// A diff's thread mark clicked: the threads made at that row.
    func diffThreadsClicked(_ d: DiffView, row: Int, rect: NSRect) {
        let rows = d.rows
        guard rows.indices.contains(row) else { return }
        let ids = hosts.threads.filter { t in
            guard let place = t.thread?.about?.diff, place.block == d.block else { return false }
            let r = rows[row]
            let line = place.new ? r.newLine : r.oldLine
            return line == place.start && d.filePath(ofRow: row) == place.file
        }.map(\.id)
        guard !ids.isEmpty else { return }
        showThreadCard(threads: ids, at: rect, in: d)
    }

    // MARK: Comment (⌥⌘M)

    /// A thread about where you are: the selection or the caret's place in
    /// in. Elsewhere, the overlay: on a page's words selected, a
    /// terminal's command, a PDF's page, the tile; or the space.
    @objc func commentHere(_ sender: Any?) {
        guard let f = focusedShown, let v = views[f.placement.id] else { return showThreadOverlay(nil) }
        if threadUI.overlay?.superview != nil { return closeThreadOverlay() }
        let here = self.here(in: f.placement.id)
        // A text's selection or caret: a card there, with the threads already about it.
        if let e = v as? EditorView, hosts.block(e.block)?.text != nil, let here {
            let rect = e.caretRectInWindow.map { e.convert($0, from: nil) } ?? NSRect(x: 40, y: e.bounds.midY, width: 10, height: 16)
            return threadPlace(here) { [weak self] place in
                guard let self, let place else { return }
                let existing = place.anchor.map { self.hosts.threads(about: e.block, anchor: $0).filter { $0.thread?.resolved != true }.map(\.id) } ?? []
                self.showThreadCard(threads: existing, newPlace: place, at: rect, in: e)
            }
        }
        // A diff's rows chosen: a card by them.
        if let d = v as? DiffView, let here = d.here {
            let rect = d.chosenRect ?? NSRect(x: 0, y: d.bounds.midY, width: 40, height: 16)
            return threadPlace(here) { [weak self] place in
                guard let self else { return }
                guard let place else { return self.toast.say("Those rows can't be commented on", .brief) }
                self.showThreadCard(threads: [], newPlace: place, at: rect, in: d)
            }
        }
        // A rendered page of a text, its words selected: the lines they came
        // from, quoted (else, as below, the page).
        if let m = v as? MarkdownView, hosts.block(m.block)?.text != nil {
            return m.selectedSourceLines { [weak self] sel in
                guard let self else { return }
                guard let sel else {
                    guard let here else { return self.showThreadOverlay(nil) }
                    return self.threadPlace(here) { [weak self] in self?.showThreadOverlay($0) }
                }
                var p = Place(block: m.block, at: sel.first == sel.last ? .line(sel.first) : .lines(sel.first, sel.last))
                p.title = here?.title
                if !sel.text.isEmpty { p.context = "“" + String(sel.text.prefix(400)) + "”" }
                self.threadPlace(p) { [weak self] in self?.showThreadOverlay($0) }
            }
        }
        // Elsewhere, the overlay: about a terminal's command, a PDF's page,
        // a page (its words selected, the quote it's about), the tile; or
        // the space.
        guard let here else { return showThreadOverlay(nil) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selected = f.block?.kind == .web ? await v.maniSelection() : nil
            self.threadPlace(here) { [weak self] place in
                var place = place
                if let s = selected?.text, !s.isEmpty { place?.context = "“" + String(s.prefix(400)) + "”" }
                self?.showThreadOverlay(place)
            }
        }
    }
}

extension MainWindowController {
    /// Debugging threads (§3.12): `threads` lists them; `threads comment
    /// <text>` comments where you are (⌥⌘M, then the text sent); `reply
    /// <text>`, `resolve`, `card`, `tile` act on the card shown; `choose a
    /// b` chooses a focused diff's lines on screen; `places` the focused
    /// editor's places with threads; `mark <line>` clicks one's mark.
    func debugThreads(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = words.count > 1 ? words[1] : ""
        func describe(_ t: Block) -> String {
            let th = t.thread
            var about = "?"
            if let p = th?.about {
                about = self.describe(p).title
                if let d = p.diff {
                    let commit: String = d.commit.map { " @" + String($0.prefix(7)) } ?? ""
                    about += " (diff " + (d.new ? "+" : "-") + "\(d.start)-\(d.end)" + commit + ")"
                }
            }
            let entries = th?.entries.map { e -> String in
                let what: String
                switch e.kind {
                case .comment(let c): what = "“\(c.prefix(60))”"
                default: what = "\(e.kind)".prefix(40).description
                }
                return "\(e.author.name): \(what)"
            }.joined(separator: " | ") ?? ""
            return "\(t.id.ulid.suffix(6)) [\(th?.resolved == true ? "resolved" : "open")\(hosts.unseen(t).isEmpty ? "" : ", \(hosts.unseen(t).count) unseen")] about \(about) in \(th?.space.map { String($0.ulid.suffix(6)) } ?? "-"): \(entries)"
        }
        switch words.first {
        case nil, "list":
            let all = hosts.threads.sorted { $0.created < $1.created }
            return all.isEmpty ? "no threads" : all.map(describe).joined(separator: "\n")
        case "comment":
            commentHere(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let chat = self?.threadUI.card?.chat else { return }
                chat.composer.string = rest
                self?.threadChat(chat, send: rest)
            }
            return "commenting"
        case "reply", "resolve", "reopen":
            guard let chat = threadUI.card?.chat else { return "no card" }
            if words[0] == "reply" { threadChat(chat, send: rest) } else { threadChat(chat, resolve: words[0] == "resolve") }
            return "done"
        case "card":
            guard let card = threadUI.card, let pop = threadUI.popover else { return "no card" }
            let m = card.chat.model
            return "shown \(pop.isShown) · thread \(card.chat.threadID.map { String($0.ulid.suffix(6)) } ?? "new") · \(card.threads.count) here · place “\(m.placeTitle)” drift \(m.drift ?? "none")\(m.gone ? " GONE" : "") · \(m.thread?.thread?.entries.count ?? 0) entries · new rule after \(m.seenMark.map { "\($0.wall)" } ?? "none") · size \(Int(pop.contentSize.width))x\(Int(pop.contentSize.height)) · tile button \(card.chat.debugTileButton)"
        case "close":
            threadUI.popover?.close()
            return "closed"
        case "ask":
            // "threads ask [on|off]": the overlay's (else the card's) Ask switched.
            guard let chat = threadUI.overlay?.chat ?? threadUI.card?.chat else { return "no chat" }
            return chat.debugAsk(rest == "on" ? true : rest == "off" ? false : nil)
                + " · thread asks \(chat.threadID.flatMap { hosts.block($0) }.flatMap { asksAgent(of: $0)?.name } ?? "nobody")"
        case "hoverpill":
            // "threads hoverpill": the pointer resting on the focused thread tile's first pill.
            guard let f = arrangement?.focused, let t = views[f] as? ThreadTileView else { return "no thread tile focused" }
            return t.chat.debugHoverPill()
        case "find":
            // "threads find <q>|next": ⌘F in the focused thread's tile.
            guard let f = arrangement?.focused, let t = views[f] as? ThreadTileView else { return "no thread tile focused" }
            return t.chat.debugFind(rest)
        case "tile":
            guard let chat = threadUI.card?.chat else { return "no card" }
            threadChatOpenTile(chat)
            return "opened"
        case "seen":
            hosts.markSeen(hosts.threads)
            return "marked"
        case "address":
            // Every open thread of the space handed to an agent at once.
            guard let space = selected else { return "no space" }
            let open = hosts.threads(inSpace: space).filter { $0.thread?.resolved != true }.map(\.id)
            addressThreads(open)
            return "handed \(open.count)"
        case "agentsay":
            // An agent's comment on the newest thread, as if one wrote it
            // (the first terminal here standing for it).
            guard let t = hosts.threads.max(by: { $0.created < $1.created }) else { return "no threads" }
            let term = hosts.blocks.first { $0.kind == .terminal }?.id ?? BlockID(host: host.host)
            hosts.addToThread(t.id, .comment(rest), author: .agent(block: term, name: "Claude", turn: nil))
            return "said on \(t.id.ulid.suffix(6))"
        case "choose":
            let n = rest.split(separator: " ").compactMap { Int($0) }
            guard let f = arrangement?.focused, let d = views[f] as? DiffView, n.count == 2 else { return "no diff focused, or not two lines" }
            d.debugChoose(n[0]...n[1])
            return "chose rows \(d.chosenRows)"
        case "places":
            guard let e = debugFocusedEditor else { return "no editor focused" }
            return places(of: e.block).filter { $0.threads > 0 }.map { "line \($0.line + 1): \($0.threads) thread(s), \($0.openThreads) open\($0.unseen ? ", unseen" : "")" }.joined(separator: "\n")
        case "mark":
            guard let e = debugFocusedEditor, let n = Int(rest) else { return "no editor focused" }
            e.scroll(toTopLine: Double(max(0, n - 3)))
            e.layoutSubtreeIfNeeded()
            editorThreadsClicked(e, line: n - 1, rect: NSRect(x: 4, y: e.textView.top(ofLine: n - 1), width: 12, height: 14))
            return "clicked"
        case "diffmark":
            guard let f = arrangement?.focused, let d = views[f] as? DiffView, let n = Int(rest) else { return "no diff focused" }
            diffThreadsClicked(d, row: n, rect: d.rect(ofRow: n).insetBy(dx: 0, dy: 0).divided(atDistance: 16, from: .minXEdge).slice)
            return "clicked; marks at rows \(d.threadRows.keys.sorted())"
        default:
            return "threads [list|comment <text>|reply <text>|resolve|reopen|card|close|tile|seen|choose a b|places|mark <line>|diffmark <row>]"
        }
    }
}

/// A space's threads as a tile of its own (§3.12): the timeline.
final class ThreadsTimelineTileView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    let timeline = ThreadTimelineView()
    var focusView: NSView { timeline.composer }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        timeline.space = block
        addSubview(timeline)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {}

    override func layout() {
        super.layout()
        timeline.frame = bounds
    }
}

extension MainWindowController: ThreadTimelineDelegate {
    // MARK: The timeline

    /// The project a space is about, for its timeline's second scope: the
    /// focused tile's, else the one most of its tiles are in.
    func project(ofSpace space: BlockID) -> (root: String, host: HostID)? {
        guard let a = hosts.arrangement(space) else { return nil }
        let order = (a.focusedPlacement.map { [$0] } ?? []) + a.placements
        var counts: [String: (Int, HostID)] = [:]
        for (i, p) in order.enumerated() {
            guard let root = hosts.client(p.block.host)?.node.graph.project(of: p.block) else { continue }
            if i == 0, a.focusedPlacement != nil { return (root, p.block.host) }
            counts[root, default: (0, p.block.host)].0 += 1
        }
        return counts.max { $0.value.0 < $1.value.0 }.map { ($0.key, $0.value.1) }
    }

    /// A timeline's runs: every entry of the threads in its scope, by time,
    /// a thread's entries that came together one run; the last 400.
    func timelineModel(for v: ThreadTimelineView) -> TimelineModel {
        var m = TimelineModel()
        guard let space = v.space ?? selected else { return m }
        let spaceTitle = hosts.arrangement(space).map(title(of:)) ?? "this space"
        let project = project(ofSpace: space)
        m.scopes = project.map { ["Space", $0.root.lastPathComponent] } ?? ["Space"]
        m.scope = min(v.model.scope, m.scopes.count - 1)
        var threads: [Block]
        if m.scope == 1, let project {
            threads = hosts.threads(inProject: project.root, on: project.host)
            m.title = "Threads in " + project.root.lastPathComponent
            m.composesNew = false
        } else {
            threads = hosts.threads(inSpace: space)
            m.title = "Threads in " + spaceTitle
        }
        switch v.filter {
        case .all: break
        case .open: threads = threads.filter { $0.thread?.resolved != true }
        case .unread: threads = threads.filter { !hosts.unseen($0).isEmpty }
        }
        if v.marksWhenOpened == nil {
            v.marksWhenOpened = Dictionary(uniqueKeysWithValues: threads.compactMap { t in hosts.seenMark(t.id).map { (t.id, $0) } })
        }
        let marks = v.marksWhenOpened ?? [:]
        var all: [(Block, ThreadEntry)] = []
        for t in threads { for e in t.thread?.entries ?? [] { all.append((t, e)) } }
        all.sort { $0.1.at < $1.1.at }
        if all.count > 400 { all.removeFirst(all.count - 400) }
        var described: [BlockID: (String, String?)] = [:]
        for (t, e) in all {
            if let last = m.runs.indices.last, m.runs[last].thread.id == t.id {
                m.runs[last].entries.append(e)
            } else {
                let d = described[t.id] ?? t.thread?.about.map { p in let x = describe(p); return (x.title, x.drift) } ?? ("A thread", nil)
                described[t.id] = d
                m.runs.append(TimelineRun(thread: t, placeTitle: d.0, drift: d.1, entries: [e]))
            }
            let i = m.runs.count - 1
            let mark = marks[t.id] ?? hosts.seenMark(t.id)
            if m.runs[i].firstUnseen == nil, e.isNotable, mark.map({ e.at > $0 }) ?? true {
                m.runs[i].firstUnseen = m.runs[i].entries.count - 1
            }
        }
        m.unseen = threads.reduce(0) { $0 + hosts.unseen($1).count }
        m.icon = { [weak self] id in
            guard let a = self?.hosts.block(id)?.agent else { return nil }
            return AgentIcons.image(a.command, size: 12)
        }
        return m
    }

    func refresh(_ v: ThreadTimelineView) {
        v.delegate = self
        v.show(timelineModel(for: v))
    }

    /// Timelines on screen, kept up to date.
    func watch(_ v: ThreadTimelineView) {
        v.composer.mentionSource = { [weak self] in self?.mentionSource() ?? { _ in [] } }
        if !threadUI.timelines.contains(where: { $0.value === v }) { threadUI.timelines.append(Weak(v)) }
        refresh(v)
    }

    /// Show Threads: the space's timeline, as a tile beside.
    @objc func showThreads(_ sender: Any?) {
        guard let space = selected else { return NSSound.beep() }
        show(space, lens: .threads, .here, kind: .opened, context: "threads")
    }

    // MARK: ThreadTimelineDelegate

    func timeline(_ view: ThreadTimelineView, send text: String, to thread: BlockID?) {
        if let thread {
            hosts.addToThread(thread, .comment(text))
            askAgents(in: thread, comment: text, author: Hosts.you)
            return
        }
        guard let space = view.space ?? selected else { return }
        let name = hosts.arrangement(space).map(title(of:))
        let id = hosts.newThread(about: ThreadPlace(block: space, title: name), space: space, text: text)
        askAgents(in: id, comment: text, author: Hosts.you)
    }

    func timeline(_ view: ThreadTimelineView, address threads: [BlockID]) {
        addressThreads(threads)
    }

    func timeline(_ view: ThreadTimelineView, resolve: Bool, _ thread: BlockID) {
        hosts.addToThread(thread, resolve ? .resolved : .reopened)
    }

    /// A run's heading clicked: its place gone to (a space's thread has
    /// none but the space) and the thread read in the overlay — unless it's
    /// the overlay's own timeline, which reads it there.
    func timeline(_ view: ThreadTimelineView, goToPlaceOf thread: BlockID) {
        if !aboutTheSpace(thread) { goToPlace(ofThread: thread) }
        DispatchQueue.main.async { [weak self] in self?.showThreadOverlay(nil, thread: thread) }
    }

    func timeline(_ view: ThreadTimelineView, popOut thread: BlockID) {
        popOutThread(thread)
    }

    /// A thread as a tile of its own, placed as acme places a window: in
    /// the active column, below its biggest tile.
    func popOutThread(_ id: BlockID) {
        show(id, lens: .thread, .here, kind: .opened, context: "a thread opened")
    }

    /// Whether a thread is about the space itself (no place but it).
    func aboutTheSpace(_ thread: BlockID) -> Bool {
        guard let about = hosts.block(thread)?.thread?.about else { return true }
        return hosts.block(about.block)?.kind == .arrangement
    }

    func timeline(_ view: ThreadTimelineView, follow address: String) {
        open(address, from: arrangement?.focused)
    }

    func timelineChanged(_ view: ThreadTimelineView) {
        view.marksWhenOpened = nil
        refresh(view)
    }

    func timeline(_ view: ThreadTimelineView, seen threads: [BlockID]) {
        hosts.markSeen(threads.compactMap { hosts.block($0) })
    }

    /// A thread's place gone to: its block, at its anchor; a space's
    /// thread, its tile.
    func goToPlace(ofThread id: BlockID) {
        guard let about = hosts.block(id)?.thread?.about else { return }
        if hosts.block(about.block)?.kind == .arrangement { return popOutThread(id) }
        open(Self.address(about.block, anchor: about.anchor), from: arrangement?.focused)
    }
}

extension MainWindowController {
    /// Debugging the timeline: `timeline` (the space's, as a tile),
    /// `timeline scope <n>|filter <all|open|unread>|read|choose <i>|send <text>`,
    /// and what it shows.
    func debugTimeline(_ arg: String) -> String {
        let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let tile = views.values.compactMap { $0 as? ThreadsTimelineTileView }.first
        if w.first == "open" || (tile == nil && w.isEmpty) {
            showThreads(nil)
            return "opened"
        }
        guard let t = tile?.timeline else { return "no timeline tile" }
        switch w.first {
        case "scope":
            refresh(t)
            t.debugScope(Int(w.dropFirst().first ?? "0") ?? 0)
        case "filter": t.filter = ["all": .all, "open": .open, "unread": .unread][w.dropFirst().first ?? "all"] ?? .all; timelineChanged(t)
        case "read": timeline(t, seen: t.model.runs.map(\.thread.id))
        case "choose": if let i = Int(w.dropFirst().first ?? ""), t.model.runs.indices.contains(i) { t.choose(t.model.runs[i].thread.id) }
        case "send": timeline(t, send: w.dropFirst().first ?? "", to: t.chosen)
        default: break
        }
        let m = t.model
        let runs = m.runs.map { r in "[\(r.placeTitle)\(r.firstUnseen.map { " NEW@\($0)" } ?? "")] " + r.entries.map { e in e.author.name + ":" + (e.comment.map { String($0.prefix(30)) } ?? "\(e.kind)".prefix(20).description) }.joined(separator: ", ") }
        return "\(m.title) · scopes \(m.scopes) at \(m.scope) · filter \(t.filter) · \(m.unseen) unseen · replying to \(t.chosen.map { String($0.ulid.suffix(6)) } ?? "none")\n" + runs.joined(separator: "\n")
    }
}

/// A popover's delegate that keeps it up, against what would put it away
/// by itself (a click elsewhere), while `keep` says so; closing it outright
/// (⎋, `close()`) isn't asked.
final class PopoverKeeper: NSObject, NSPopoverDelegate {
    var keep: () -> Bool = { false }
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !keep() }
}
