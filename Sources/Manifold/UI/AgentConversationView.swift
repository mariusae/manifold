import AppKit
import ManifoldCore

/// An agent's conversation (§3.8) — its "default thread", the other side of
/// its tile from its terminal (⌘↩): every turn, what you asked in the
/// technical face, what it did on the way folded to a line, what it said
/// rendered in the editing face as a preview renders — the latest last, kept in
/// view as it grows — and under it a composer, in the technical face too,
/// whose ↩ types what's written into the agent as its next prompt (when
/// it's free: waiting meanwhile, said at the end of the conversation).
final class AgentConversationView: NSView, PaneContent, KeepsViewState {
    let placement: PlacementID
    let block: BlockID
    /// The conversation, rendered (a preview's page).
    let page: MarkdownView
    let composer = ComposerTextView()
    private lazy var box = ChatBox(composer: composer)
    /// Stop: while it works, Esc typed into it, as in its terminal.
    private let stopButton = FlatButton("Stop", symbol: "stop.fill", font: UIType.detail)

    /// The agent's block, as it is now.
    var source: () -> Block? = { nil }
    /// What turns did, asked of their host; nil from one that can't say.
    var fetch: (_ turns: [Int], _ done: @escaping ([TurnContent]?) -> Void) -> Void = { _, done in done(nil) }
    /// What's been sent and waits for it to be free.
    var queued: () -> [String] = { [] }
    /// Whether it's running: an agent at its prompt, not a shell it left.
    var runs: (Block) -> Bool = { _ in true }
    /// Whether what's sent reaches it asleep — woken in its project — or
    /// it must be started in its terminal: said so before you write.
    var wakes: (Block) -> Bool = { _ in true }
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    /// Whether the end of the page, where what it's doing is said, is out
    /// of sight while it works: for its bar to say it instead.
    var onEndHidden: ((Bool) -> Void)?

    var focusView: NSView { composer }

    /// What each turn did, by its id, as last read.
    private var contents: [Int: [TurnTranscript.Part]] = [:]
    /// Turns read once they'd ended: not asked again.
    private var settled: Set<Int> = []
    private var asking = false
    private var document = ""
    private var version = 0
    private var poll: Timer?
    /// Scrolled up from its end: the way back, its working dots while it works.
    private let endPill = NewBelowButton(showsWhenAway: true)
    private var atEnd = true
    /// What the conversation held when last shown (turns, and how much of the last).
    private var contentKey = ""

    init(placement: PlacementID, block: BlockID, page: MarkdownView) {
        self.placement = placement
        self.block = block
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        page.source = { [weak self] in self.map { ($0.document, $0.version) } }
        // Its outline a turn each, as its terminal's: what was asked, how
        // long it took and when; the strip's card, what it said.
        page.ownOutline = { [weak self] in self?.turnEntries() ?? [] }
        page.ownPreview = { [weak self] i in self?.turnPreview(i) ?? [] }
        addSubview(page)
        addSubview(endPill, positioned: .above, relativeTo: page)
        page.onAtEnd = { [weak self] end in
            guard let self else { return }
            self.atEnd = end
            self.endPill.place(over: self.page.frame, away: !end)
        }
        endPill.onClick = { [weak self] in self?.page.scrollToEnd() }
        // Dropped anywhere on it, into what's written to the agent, as the
        // agent takes things (a reference first) — not linked to the tile.
        composer.dropsFor = .agent
        registerForDraggedTypes(Dragged.types)
        page.dropsElsewhere = (forms: { [weak self] d in self?.composer.dropForms(d, at: .zero) ?? [] },
                               put: { [weak self] d, form in self?.composer.dropPut(d, as: form, at: nil) })
        composer.font = Self.inputFont
        composer.isRichText = true
        composer.importsGraphics = false
        composer.allowsUndo = true
        composer.isVerticallyResizable = true
        composer.textContainer?.widthTracksTextView = true
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.composerChanged() }
        box.onSend = { [weak self] in self?.send() }
        box.placeholder.font = Self.inputFont
        stopButton.onClick = { [weak self] in self?.onStop?() }
        stopButton.toolTip = "Stop it (⎋ in its terminal)"
        addSubview(box)
        // What was being written, as it was left: the tile turned to its
        // terminal and back is a view made afresh.
        if let draft = Self.drafts[block] { composer.textStorage?.setAttributedString(draft) }
        composerChanged()
    }

    /// What's being written to each agent, kept past its view.
    private static var drafts: [BlockID: NSAttributedString] = [:]

    required init?(coder: NSCoder) { fatalError() }

    /// What you write: the technical face, as what you asked shows.
    static var inputFont: NSFont { FontTheme.current.technicalFont(size: 13) }

    func destroy() {
        poll?.invalidate()
        poll = nil
        page.destroy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    // MARK: What it shows

    /// The agent's block changed (or might have): what's new read, the
    /// conversation made again if it says something else.
    func refresh() {
        guard let b = source() else { return }
        let turns = b.terminal?.turns ?? []
        let shown = turns.suffix(40)
        // A reopened turn (e.g. agy waking on a background task) needs a fresh
        // final read once it ends again.
        for t in shown where t.isRunning { settled.remove(t.id) }
        // Read: what hasn't been, what's running, what ended since it was read.
        let wanted = shown.filter { t in contents[t.id] == nil || t.isRunning || (t.ended != nil && !settled.contains(t.id)) }.map(\.id)
        if !wanted.isEmpty, !asking, window != nil {
            asking = true
            let ended = Set(shown.filter { !$0.isRunning }.map(\.id))
            fetch(wanted) { [weak self] got in
                guard let self else { return }
                self.asking = false
                for c in got ?? [] { self.contents[c.turn] = c.parts }
                // Read as it ended, or not readable at all: not asked again.
                self.settled.formUnion(wanted.filter { ended.contains($0) })
                self.rebuild()
            }
        }
        rebuild()
        // While a turn runs and it's in sight, asked again every second.
        let live = shown.contains(where: \.isRunning) && window != nil
        if live, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        } else if !live {
            poll?.invalidate()
            poll = nil
        }
    }

    private func rebuild() {
        guard let b = source() else { return }
        let standing: AgentConversation.Standing = !runs(b) ? .asleep : b.statusState == .blocked ? .needsYou : b.statusState == .working ? .working : .idle
        let md = AgentConversation.markdown(turns: b.terminal?.turns ?? [], contents: contents, standing: standing, queued: queued(), doing: b.agentDoing)
        let name = AgentLook.name(of: b)
        box.placeholder.stringValue = standing == .asleep
            ? (wakes(b) ? "Wake \(name) with a prompt…" : "\(name) is asleep — start it in its terminal (⌘↩)")
            : (b.terminal?.turns?.isEmpty ?? true) ? "Ask \(name)…" : "Reply to \(name)…"
        box.leading = standing == .working ? [stopButton] : []
        tellEnd(working: standing == .working)
        endPill.working = standing == .working
        guard md != document else { return }
        // Something new below (a turn, or more of one — not the working
        // line's words changing), while it's scrolled up: said on the pill.
        let turns = b.terminal?.turns ?? []
        let grown = "\(turns.count)|\(turns.last.flatMap { contents[$0.id]?.count } ?? 0)|\(turns.last?.message?.count ?? 0)|\(queued().count)"
        if !atEnd, !document.isEmpty, grown != contentKey { endPill.announce("More below") }
        contentKey = grown
        document = md
        version &+= 1
        page.textChanged()
    }

    /// Whether the working line at the page's end is out of sight, told
    /// (asked of the page: it may be scrolled up); not at work, it isn't.
    private func tellEnd(working: Bool) {
        guard working else { return (onEndHidden?(false)) ?? () }
        let js = "(function(){var e=document.querySelector('.mf-working');if(!e)return true;var r=e.getBoundingClientRect();return r.top>=0&&r.bottom<=window.innerHeight;})()"
        page.page.evaluateJavaScript(js) { [weak self] result, _ in
            self?.onEndHidden?(!((result as? Bool) ?? true))
        }
    }

    /// A turn scrolled to the top of what shows — once it's on the page
    /// (a conversation just made renders a moment later), and again after
    /// it settles, as the page keeps to its end when first shown.
    func reveal(turn: Int, tries: Int = 20) {
        let js = "(function(){var e=document.getElementById('turn-\(turn)');if(!e)return false;e.scrollIntoView({block:'start'});window.scrollBy(0,-12);return true;})()"
        page.page.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true {
                if tries >= 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reveal(turn: turn, tries: -1) } }
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.reveal(turn: turn, tries: tries - 1) }
            }
        }
    }

    // MARK: Its outline

    private var shownTurns: [AgentTurn] { Array((source()?.terminal?.turns ?? []).suffix(40)) }

    private func turnEntries() -> [(item: Outline.Item, anchor: String)] {
        let turns = shownTurns
        return turns.map { t in
            let title = AgentConversation.promptTitle(t.prompt)
            // When it began, then how long it took: "18m ago › took 2m 52s".
            let detail = t.isRunning ? "running" : BlockSummary.ran(from: t.began, to: t.ended, status: 0, now: Date(), least: 1)
            return (Outline.Item(title: String(title.prefix(200)), detail: detail, running: t.isRunning), "turn-\(t.id)")
        }
    }

    /// What a turn said, its first lines, plain.
    private func turnPreview(_ i: Int) -> [String] {
        let turns = shownTurns
        guard turns.indices.contains(i) else { return [] }
        return Array(turns[i].saidLines(contents[turns[i].id]).prefix(4))
    }

    /// Its page's: where it's scrolled, whether its outline shows — kept with the tile.
    var keeper: ViewStateKeeper { page.keeper }
    var outline: Outline? { page.outline }
    var hasSidebar: Bool { true }
    var sidebarShown: Bool { page.sidebarShown }
    func toggleSidebar() { page.toggleSidebar() }

    // MARK: Writing

    private func composerChanged() {
        Self.drafts[block] = composer.string.isEmpty ? nil : NSAttributedString(attributedString: composer.attributedString())
        box.placeholder.isHidden = !composer.string.isEmpty
        box.canSend = !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        box.updateMentions()
        needsLayout = true
    }

    private func send() {
        let text = composer.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.clear()
        composerChanged()
        onSend?(text)
        rebuild()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = max(0, bounds.width - pad * 2)
        if box.frame.width != w { box.frame.size.width = w; box.layoutSubtreeIfNeeded() }
        let bh = min(box.wantedHeight, max(56, bounds.height / 2))
        box.frame = NSRect(x: pad, y: pad, width: w, height: bh)
        page.frame = NSRect(x: 0, y: box.frame.maxY + 8, width: bounds.width, height: max(0, bounds.height - box.frame.maxY - 8))
        endPill.place(over: page.frame, away: !atEnd)
    }

    // MARK: As a tile's content

    var pillItems: [NSMenuItem] { page.pillItems }
    func maniText(_ options: ManiReadOptions) async -> String? { document }
}

/// Dropped on it anywhere — its page, the room round its composer — into
/// what's written to the agent, as its composer takes it (a reference first).
extension AgentConversationView: DropTaking {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { Dropping.updated(self, sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { Dropping.updated(self, sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { Dropping.exited(self, sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { Dropping.perform(self, sender) }

    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] { composer.dropForms(d, at: .zero) }
    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) { composer.dropPut(d, as: form, at: nil) }
}
