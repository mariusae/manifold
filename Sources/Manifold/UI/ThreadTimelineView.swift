import AppKit
import ManifoldCore

/// What the timeline asks of whoever shows it.
protocol ThreadTimelineDelegate: AnyObject {
    /// A comment written: a reply to a thread, or — none chosen — a new
    /// thread about the space.
    func timeline(_ view: ThreadTimelineView, send text: String, to thread: BlockID?)
    func timeline(_ view: ThreadTimelineView, resolve: Bool, _ thread: BlockID)
    /// A thread's place gone to.
    func timeline(_ view: ThreadTimelineView, goToPlaceOf thread: BlockID)
    /// A thread popped out: a tile of its own.
    func timeline(_ view: ThreadTimelineView, popOut thread: BlockID)
    /// A link in a comment, or an agent's pill, followed.
    func timeline(_ view: ThreadTimelineView, follow address: String)
    /// The scope or filter changed: shown again.
    func timelineChanged(_ view: ThreadTimelineView)
    /// What it shows was on screen a moment: seen.
    func timeline(_ view: ThreadTimelineView, seen threads: [BlockID])
    /// The open threads shown handed to an agent at once.
    func timeline(_ view: ThreadTimelineView, address threads: [BlockID])
}

/// One run of a timeline: a thread's entries that came together.
struct TimelineRun {
    var thread: Block
    var placeTitle: String
    var drift: String?
    var entries: [ThreadEntry]
    /// Of `entries`, the first you hadn't seen (a New rule above it).
    var firstUnseen: Int?
}

/// A list's group of threads (§3.12): its heading, and each thread as
/// its card.
struct ThreadGroup {
    var title: String
    var rows: [(id: BlockID, card: SummaryCardContent)]
}

/// What a timeline shows.
struct TimelineModel {
    var title = ""
    /// The scopes there are (a space, its project), and which is shown.
    var scopes: [String] = ["Space"]
    var scope = 0
    var runs: [TimelineRun] = []
    /// As a list: the threads in groups, as the list's grouping has them.
    var groups: [ThreadGroup] = []
    /// The threads shown (filtered), however they're shown.
    var shown: [Block] = []
    var unseen = 0
    /// Making a thread about the space, with no thread chosen.
    var composesNew = true
    var icon: (BlockID) -> NSImage? = { _ in nil }
}

/// The timeline (§3.12): every entry of every thread of a space, or of a
/// project, interleaved by time, newest last — each run headed by its
/// place (clicked, gone to), the first not seen under a New rule; All,
/// Open or Unread; Mark All Read. A run chosen, the composer replies to
/// it; none, it starts a thread about the space.
final class ThreadTimelineView: NSView {
    /// ⌘ over its comments: their paths and addresses, to go to.
    private lazy var commandLinks = CommentCommandLinks(self)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        commandLinks.watch(window)
    }

    enum Filter: Int { case all, open, unread }
    /// Every entry by time, or the threads as a list of cards in groups.
    enum Mode: Int { case timeline, list }
    /// How a list groups its threads: by how each stands (unread, at work,
    /// open, resolved), by what it's about, by the agents in it.
    enum Grouping: Int { case state, place, agent }
    weak var delegate: ThreadTimelineDelegate?
    var mode: Mode = .timeline { didSet { if mode != oldValue { arriving = true; updateViewButton() } } }
    var grouping: Grouping = .state { didSet { updateViewButton() } }
    /// What its threads are those of, when it's not a space's (§3.12): a
    /// project's (its block), an agent's, a file's — the threads it's in.
    var subject: BlockID?
    private(set) var model = TimelineModel()
    /// The thread the composer replies to.
    private(set) var chosen: BlockID?
    /// What had been seen of each thread when it was first shown: the New
    /// rule stays where it was while it's open, as Quip's does.
    var marksWhenOpened: [BlockID: Stamp]? { didSet { if marksWhenOpened == nil { arriving = true } } }
    /// Come to (shown first, or opened again): to the New rule, as Quip
    /// opens a conversation at what you haven't read — else the end —
    /// once it's laid out at its size.
    private var arriving = true
    private weak var ruleView: NSView?
    /// The space it's of.
    var space: BlockID?

    /// How it's shown, in a few words, and a menu of the rest (§3.12):
    /// which threads (all, open, unread), from where (the space, its
    /// project), as a timeline or a list and how a list groups; Mark All
    /// Read and Hand to Agent. Its title is its tile's bar's.
    private let viewButton = MenuTitleButton()
    var filter: Filter = .all { didSet { updateViewButton() } }
    /// Narrow (the sidebar's): no view menu — the sidebar's header has
    /// the filter and Mark All Read.
    var compact = false {
        didSet {
            viewButton.isHidden = compact
            list.spacing = compact ? 10 : 14
            needsLayout = true
        }
    }

    /// Where its threads are from: the space (0), or its project (1).
    func setScope(_ i: Int) {
        model.scope = i
        chosen = nil
        updateViewButton()
    }
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let replyingTo = NSTextField.label(font: UIType.footnote, color: Theme.secondaryText)
    private let clearReply = IconButton.close()
    let composer = ComposerTextView()
    private(set) lazy var box = ChatBox(composer: composer)
    private var placeholder: NSTextField { box.placeholder }
    private var seenTimer: Timer?
    private var runViews: [BlockID: NSView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        viewButton.onClick = { [weak self] in self?.popViewMenu() }
        viewButton.toolTip = "Which Threads, and How"
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14
        list.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        empty.font = UIType.body
        empty.textColor = Theme.secondaryText
        empty.alignment = .center
        clearReply.target = self
        clearReply.action = #selector(unchoose)
        composer.font = AgentConversationView.inputFont
        composer.isRichText = true
        composer.importsGraphics = false
        composer.allowsUndo = true
        composer.isVerticallyResizable = true
        composer.textContainer?.widthTracksTextView = true
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in
            guard let self else { return }
            self.placeholder.isHidden = !self.composer.string.isEmpty
            self.box.updateMentions()
            self.box.canSend = !self.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (self.chosen != nil || self.model.composesNew)
            self.needsLayout = true
        }
        box.onSend = { [weak self] in self?.send() }
        for v in [viewButton, scroll, empty, replyingTo, clearReply, box] as [NSView] { addSubview(v) }
        updateViewButton()
        // Scrolled away from its end: a button at its foot back there; others'
        // entries come meanwhile: said on it, not scrolled to.
        addSubview(newBelow)
        newBelow.onClick = { [weak self] in self?.scrollToEnd() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.unchecked { self?.placeNewBelow() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { seenTimer?.invalidate() }

    // MARK: Showing

    func show(_ m: TimelineModel) {
        let atEnd = scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 4
        let first = model.runs.isEmpty
        let before = model.runs.reduce(0) { $0 + $1.entries.count }
        let now = m.runs.reduce(0) { $0 + $1.entries.count }
        let newest = m.runs.flatMap(\.entries).filter { $0.comment != nil }.max { $0.at < $1.at }
        model = m
        updateViewButton()
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runViews = [:]
        if mode == .list { return showList(m) }
        list.spacing = compact ? 10 : 14
        // One New rule: above the first run's first entry not seen, or
        // within it.
        var ruled = false
        for run in m.runs {
            var ruleAt: Int?
            if !ruled, let u = run.firstUnseen {
                ruled = true
                if u == 0 { list.addArrangedSubview(fill(rule())) } else { ruleAt = u }
            }
            let v = runView(run, ruleAt: ruleAt)
            runViews[run.thread.id] = v
            list.addArrangedSubview(fill(v))
        }
        empty.isHidden = !m.runs.isEmpty
        empty.stringValue = filter == .unread ? "Nothing unread." : "No threads yet. ⌥⌘M starts one."
        if let c = chosen, !m.runs.contains(where: { $0.thread.id == c }) { chosen = nil }
        updateReplying()
        needsLayout = true
        layoutSubtreeIfNeeded()
        // What you sent come in: scrolled to, wherever it was. Others' come
        // while scrolled up: said at its foot.
        let yoursCame = sentPending && now > before && newest?.author.isYou == true
        if yoursCame { sentPending = false }
        if first || arriving {
            arriving = true
            needsLayout = true
        } else if atEnd || yoursCame {
            scrollToEnd()
        } else if now > before {
            newBelow.announce("New")
        }
        placeNewBelow()
        watchSeen()
    }

    /// As a list: each group under its heading, each thread its card —
    /// clicked, opened as a tile; from the top.
    private func showList(_ m: TimelineModel) {
        // Rows one under another, hairlines between, not cards apart.
        list.spacing = 0
        for g in m.groups where !g.rows.isEmpty {
            let label = SectionLabel(g.title + " · \(g.rows.count)")
            label.heightAnchor.constraint(equalToConstant: label.height).isActive = true
            list.addArrangedSubview(fill(label))
            for (id, card) in g.rows {
                let row = HomeRow(card: card, flat: true)
                row.heightAnchor.constraint(equalToConstant: row.height).isActive = true
                row.onClick = { [weak self] in
                    guard let self else { return }
                    self.delegate?.timeline(self, popOut: id)
                }
                row.toolTip = "Open the thread"
                list.addArrangedSubview(fill(row))
            }
        }
        empty.isHidden = !m.groups.allSatisfy(\.rows.isEmpty)
        empty.stringValue = filter == .unread ? "Nothing unread." : filter == .open ? "No open threads." : "No threads."
        chosen = nil
        updateReplying()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if arriving {
            arriving = false
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        newBelow.place(over: scroll.frame, away: false)
        // Its cards aren't its threads read: nothing's marked seen.
        seenTimer?.invalidate()
    }

    /// To the New rule, a little room above it; none, the end.
    private func arrive() {
        guard let doc = scroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        guard let rule = ruleView, rule.isDescendant(of: list) else { return scrollToEnd() }
        let top = list.convert(rule.bounds, from: rule).minY - 24
        let y = min(max(0, top), max(0, doc.frame.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func placeNewBelow() {
        newBelow.place(over: scroll.frame, away: mode == .timeline && scroll.contentView.bounds.maxY < (scroll.documentView?.frame.height ?? 0) - 4)
    }

    func scrollToEnd() {
        guard let doc = scroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Seen once it's been on screen a moment, the window in front.
    private func watchSeen() {
        seenTimer?.invalidate()
        guard model.unseen > 0 else { return }
        seenTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self, let w = self.window, w.isVisible, w.isKeyWindow || w.isMainWindow || (w as? NSPanel) != nil, !self.isHiddenOrHasHiddenAncestor,
                  // On screen: not in a sidebar slid out of the window.
                  let content = w.contentView, content.bounds.intersects(self.convert(self.bounds, to: content)) else { return }
            self.delegate?.timeline(self, seen: self.model.runs.filter { $0.firstUnseen != nil }.map(\.thread.id))
        }
    }

    // MARK: Runs

    private func runView(_ run: TimelineRun, ruleAt: Int?) -> NSView {
        let t = run.thread.thread
        let resolved = t?.resolved == true
        let place = LinkLabel(run.placeTitle + (run.drift.map { " — \($0)" } ?? ""), symbol: resolved ? "checkmark.bubble" : "text.bubble") { [weak self] in
            guard let self else { return }
            self.delegate?.timeline(self, goToPlaceOf: run.thread.id)
        }
        let replyWord = chosen == run.thread.id ? "Replying" : "Reply", resolveWord = resolved ? "Reopen" : "Resolve"
        // Narrow, glyphs: the place has the room.
        let reply = compact ? FlatButton("", symbol: "arrowshape.turn.up.left", font: UIType.footnote) : FlatButton(replyWord, font: UIType.footnote)
        let resolve = compact ? FlatButton("", symbol: resolved ? "arrow.uturn.backward" : "checkmark", font: UIType.footnote)
            : FlatButton(resolveWord, font: UIType.footnote)
        reply.toolTip = replyWord
        resolve.toolTip = resolveWord
        let popOut = compact ? FlatButton("", symbol: "arrow.up.left.and.arrow.down.right", font: UIType.footnote) : FlatButton("Open", font: UIType.footnote)
        popOut.toolTip = "Open as a Tile"
        if compact, chosen == run.thread.id { reply.contentTintColor = Theme.accent }
        let head = NSStackView(views: [place, NSView(), popOut, reply, resolve])
        head.spacing = 6
        place.strong = true
        let id = run.thread.id
        reply.onClick = { [weak self] in self?.choose(id) }
        popOut.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.timeline(self, popOut: id)
        }
        resolve.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.timeline(self, resolve: !resolved, id)
        }
        let column = NSStackView(views: [head])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false
        let divider = HairlineView()
        column.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        head.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        var previous: ThreadEntry?
        for (i, e) in run.entries.enumerated() {
            if i == ruleAt { column.addArrangedSubview(rule()); previous = nil }
            if e.isEmptyComment { continue }
            let v = entryView(e, after: previous)
            column.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            previous = e
        }
        let box = RunBox(column, chosen: chosen == id, resolved: resolved)
        box.onClick = { [weak self] in self?.choose(id) }
        // Its buttons under the pointer, or while it's the one replied to.
        box.hoverViews = chosen == id ? [] : [popOut, reply, resolve]
        return box
    }

    private func entryView(_ e: ThreadEntry, after previous: ThreadEntry?) -> NSView {
        let when = BlockSummary.ago(e.at, now: Date()) ?? ""
        switch e.kind {
        case .comment(let text):
            let width = (scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width) - 24
            let v = CommentView(e, text: text, icon: e.author.agentBlock.flatMap(model.icon), continued: CommentView.continues(e, after: previous), width: width)
            v.onAuthor = { [weak self] in
                guard let self, let b = e.author.agentBlock else { return }
                self.delegate?.timeline(self, follow: MainWindowController.address(b))
            }
            v.onLink = { [weak self] url in
                guard let self else { return }
                self.delegate?.timeline(self, follow: url.absoluteString)
            }
            v.body.text.onCommandLink = { [weak self] target, _ in
                guard let self else { return }
                self.delegate?.timeline(self, follow: target)
            }
            return v
        default:
            let who = e.author.isYou ? "you" : e.author.shownName
            let words: String
            switch e.kind {
            case .resolved: words = "Resolved by \(who)"
            case .reopened: words = "Reopened by \(who)"
            case let .asked(_, name): words = "\(name) asked to look"
            case let .edited(added, removed):
                if case .manifold = e.author { words = "Changed on disk (+\(added) −\(removed))" } else { words = "Edited by \(who) (+\(added) −\(removed))" }
            case .gone: words = "Its lines were deleted"
            case .stopped(let why): words = why
            case let .context(added, _, title): words = added ? "\(title) added to its context by \(who)" : "\(title) taken out by \(who)"
            case .comment: words = ""
            }
            let label = NSTextField.label(words + " · " + when, font: UIType.footnote, color: Theme.secondaryText)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.toolTip = words
            let line = NSStackView(views: [label])
            line.edgeInsets = NSEdgeInsets(top: 0, left: CommentView.avatar + CommentView.gap, bottom: 0, right: 0)
            return line
        }
    }

    private func rule() -> NSView {
        let label = NSTextField.label("New", font: UIType.caption, color: Tints.accentText)
        let left = HairlineView(), right = HairlineView()
        let line = NSStackView(views: [left, label, right])
        line.spacing = 6
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        ruleView = line
        return line
    }

    private func fill(_ v: NSView) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async { [weak self, weak v] in
            guard let self, let v, v.superview === self.list else { return }
            v.widthAnchor.constraint(equalTo: self.list.widthAnchor).isActive = true
        }
        return v
    }

    // MARK: Choosing and writing

    /// A thread chosen to reply to (again: unchosen).
    func choose(_ id: BlockID?) {
        chosen = chosen == id ? nil : id
        show(model)
        if chosen != nil { window?.makeFirstResponder(composer) }
    }

    @objc private func unchoose() { choose(nil) }

    private func updateReplying() {
        if let c = chosen, let run = model.runs.first(where: { $0.thread.id == c }) {
            replyingTo.stringValue = "Replying to " + run.placeTitle
            clearReply.isHidden = false
            placeholder.stringValue = "Reply…"
        } else {
            replyingTo.stringValue = model.composesNew ? "A new thread" : "Choose a thread"
            clearReply.isHidden = true
            placeholder.stringValue = model.composesNew ? "Start a thread…" : "Reply…"
        }
        composer.isEditable = chosen != nil || model.composesNew
        placeholder.isHidden = !composer.string.isEmpty
    }

    private func send() {
        let text = composer.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, chosen != nil || model.composesNew else { return }
        composer.clear()
        placeholder.isHidden = false
        box.canSend = false
        sentPending = true
        delegate?.timeline(self, send: text, to: chosen)
    }

    /// Sent, and not yet come back: scrolled to when it does.
    private var sentPending = false
    private let newBelow = NewBelowButton(showsWhenAway: true)

    /// The view in words: whose (a project's, past the space's), which,
    /// and how — "Open · By State".
    private func updateViewButton() {
        var words: [String] = []
        if model.scopes.count > 1 { words.append(model.scopes[min(model.scope, model.scopes.count - 1)]) }
        words.append(["All", "Open", "Unread"][filter.rawValue])
        words.append(mode == .timeline ? "Timeline" : ["By State", "By Place", "By Agent"][grouping.rawValue])
        viewButton.title = words.joined(separator: " · ")
        needsLayout = true
    }

    /// The open threads it shows, each once.
    var openShown: [BlockID] {
        var seen = Set<BlockID>()
        return model.shown.filter { $0.thread?.resolved != true && seen.insert($0.id).inserted }.map(\.id)
    }

    /// Its open threads handed to an agent (the menu's, the tile's menu's).
    func handOver() {
        let open = openShown
        guard !open.isEmpty else { return }
        delegate?.timeline(self, address: open)
    }

    func markAllRead() { delegate?.timeline(self, seen: model.shown.map(\.id)) }

    /// The view's menu: each choice checked as it is.
    func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, on: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title, run)
            item.state = on ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if model.scopes.count > 1 {
            for (i, s) in model.scopes.enumerated() {
                add(i == 0 ? "This Space" : "Project “\(s)”", on: model.scope == i) { [weak self] in
                    guard let self else { return }
                    self.model.scope = i
                    self.chosen = nil
                    self.updateViewButton()
                    self.delegate?.timelineChanged(self)
                }
            }
            menu.addItem(.separator())
        }
        for (f, title) in [(Filter.all, "All Threads"), (.open, "Open"), (.unread, "Unread")] {
            add(title, on: filter == f) { [weak self] in
                guard let self else { return }
                self.filter = f
                self.delegate?.timelineChanged(self)
            }
        }
        menu.addItem(.separator())
        add("As a Timeline", on: mode == .timeline) { [weak self] in self?.setMode(.timeline, .state) }
        for (g, title) in [(Grouping.state, "As a List, by State"), (.place, "As a List, by Place"), (.agent, "As a List, by Agent")] {
            add(title, on: mode == .list && grouping == g) { [weak self] in self?.setMode(.list, g) }
        }
        menu.addItem(.separator())
        add(model.unseen > 0 ? "Mark All Read (\(model.unseen))" : "All Read", enabled: model.unseen > 0) { [weak self] in self?.markAllRead() }
        let open = openShown.count
        add(open > 0 ? "Hand \(open) Open Thread\(open == 1 ? "" : "s") to Agent" : "Hand to Agent", enabled: open > 0) { [weak self] in self?.handOver() }
        return menu
    }

    private func setMode(_ m: Mode, _ g: Grouping) {
        if m == .list { grouping = g }
        mode = m
        delegate?.timelineChanged(self)
    }

    private func popViewMenu() {
        viewButton.open = true
        viewMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: viewButton.bounds.height + 2), in: viewButton)
        viewButton.open = false
    }

    /// Debugging: a choice of the view menu made, by its title's start.
    func debugView(_ title: String) -> String {
        let menu = viewMenu()
        guard !title.isEmpty, let item = menu.items.first(where: { $0.title.lowercased().hasPrefix(title.lowercased()) }) as? ClosureMenuItem else {
            return menu.items.filter { !$0.isSeparatorItem }.map { ($0.state == .on ? "✓ " : "") + $0.title }.joined(separator: " | ")
        }
        item.perform()
        return viewButton.title
    }

    func focusComposer() { window?.makeFirstResponder(composer) }

    var debugLayout: String {
        func f(_ v: NSView) -> String { v.isHidden ? "hidden" : "\(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))" }
        return "view \(f(viewButton)) “\(viewButton.title)” scroll \(f(scroll)) doc \(Int(scroll.documentView?.frame.height ?? 0)) clip y \(Int(scroll.contentView.bounds.minY)) rows \(list.arrangedSubviews.count) box \(f(box))"
    }

    func debugScope(_ i: Int) {
        guard i >= 0, i < model.scopes.count else { return }
        setScope(i)
        delegate?.timelineChanged(self)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = bounds.width - pad * 2
        var y = bounds.height - pad
        let rowH: CGFloat = 22
        if compact {
            // Its controls in the sidebar's header: the runs from the top.
            y += pad - 2
        } else {
            // One line over the threads: the view, in words, its menu.
            let vw = min(viewButton.wantedWidth, w)
            viewButton.frame = NSRect(x: pad - 6, y: y - rowH + 2, width: vw, height: rowH)
            y -= rowH + 4
        }
        // A list has no composer: its threads are opened to be written in.
        let listed = mode == .list
        box.isHidden = listed
        replyingTo.isHidden = listed
        if listed { clearReply.isHidden = true }
        if box.frame.width != w { box.frame.size.width = w; box.layoutSubtreeIfNeeded() }
        box.frame = NSRect(x: pad, y: pad, width: w, height: listed ? 0 : box.wantedHeight)
        replyingTo.frame = NSRect(x: pad, y: box.frame.maxY + 4, width: w - 20, height: 16)
        clearReply.frame = NSRect(x: pad + min(w - 20, replyingTo.intrinsicContentSize.width) + 4, y: box.frame.maxY + 4, width: 16, height: 16)
        replyingTo.frame.size.width = max(0, w - 24)
        // A list to its foot: no composer under it.
        let bottom = listed ? pad : replyingTo.frame.maxY + 6
        scroll.frame = NSRect(x: pad, y: bottom, width: w, height: max(0, y - bottom))
        placeNewBelow()
        if arriving, mode == .timeline, scroll.frame.height > 40, !model.runs.isEmpty {
            arriving = false
            // After the runs' widths are set (a turn of the loop later).
            DispatchQueue.main.async { [weak self] in self?.arrive() }
        }
        empty.frame = NSRect(x: pad + 20, y: scroll.frame.midY - 30, width: w - 40, height: 60)
    }
}

/// A run's box: tinted when chosen, quieter when resolved; clicked, chosen.
final class RunBox: ClickView {
    private let chosen: Bool
    private let resolved: Bool

    init(_ content: NSView, chosen: Bool, resolved: Bool) {
        self.chosen = chosen
        self.resolved = resolved
        super.init(frame: .zero)
        firesOnDown = true
        tracking = .activeInActiveApp
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        alphaValue = resolved && !chosen ? 0.72 : 1
        themed { v in
            // A card a shade lighter than what it's on, an edge round it.
            v.layer?.backgroundColor = Theme.panel.cgColor
            // No edge at rest (spacing parts them); chosen, a grey one.
            v.layer?.borderColor = Theme.text.withAlphaComponent(0.3).cgColor
            v.layer?.borderWidth = v.chosen ? 1 : 0
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shown only with the pointer on it.
    var hoverViews: [NSView] = [] { didSet { for v in hoverViews { v.alphaValue = 0 } } }

    override func hoverChanged() {
        super.hoverChanged()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            for v in hoverViews { v.animator().alphaValue = hovering ? 1 : 0 }
        }
    }
}

/// Words that go somewhere, clicked: a symbol before them.
final class LinkLabel: ClickView {
    /// A heading's: semibold, in full ink.
    var strong = false {
        didSet {
            label.font = strong ? .systemFont(ofSize: 11, weight: .semibold) : UIType.caption
            label.textColor = strong ? Theme.text : Theme.secondaryText
        }
    }
    private let label = NSTextField.label(font: UIType.caption, color: Theme.secondaryText, cut: .byTruncatingMiddle)
    private let image = NSImageView()

    init(_ words: String, symbol: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        onClick = action
        firesOnDown = true
        label.stringValue = words
        image.image = Theme.symbol(symbol, size: 10, weight: .semibold)
        let s = NSStackView(views: [image, label])
        s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        themed { v in
            v.label.textColor = v.strong ? Theme.text : Theme.secondaryText
            v.image.contentTintColor = Theme.accent
        }
    }

    required init?(coder: NSCoder) { fatalError() }

}

/// Words that open a menu, quiet as a heading's: in grey, a small chevron
/// after them, a band under the pointer and while the menu's open.
final class MenuTitleButton: ClickView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } } }
    var open = false { didSet { needsDisplay = true } }
    private let font = UIType.detail
    var wantedWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font]).width) + 6 + 8 + 12 }
    override var intrinsicContentSize: NSSize { NSSize(width: wantedWidth, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || open {
            Flat.ground(open ? .pressed : .hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let ink = hovering || open ? Theme.text : Theme.secondaryText
        let s = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        let z = s.size()
        s.draw(at: NSPoint(x: 6, y: ((bounds.height - z.height) / 2).rounded()))
        if let image = Theme.symbol("chevron.down", size: 8, weight: .semibold, color: ink) {
            let iz = image.size
            image.draw(in: NSRect(x: 6 + ceil(z.width) + 4, y: ((bounds.height - iz.height) / 2).rounded(), width: iz.width, height: iz.height))
        }
    }
}
