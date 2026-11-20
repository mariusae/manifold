import AppKit
import ManifoldCore

/// An agent's conversation (§3.8) — its "default thread", the other side of
/// its tile from its terminal (⌘↩): every turn, what you asked in the
/// technical face, what it did on the way folded to a line, what it said
/// rendered in the reading face as a preview is — the latest last, kept in
/// view as it grows — and under it a composer, in the technical face too,
/// whose ↩ types what's written into the agent as its next prompt (when
/// it's free: waiting meanwhile, said at the end of the conversation).
final class AgentConversationView: NSView, PaneContent {
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
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    var focusView: NSView { composer }

    /// What each turn did, by its id, as last read.
    private var contents: [Int: [TurnTranscript.Part]] = [:]
    /// Turns read once they'd ended: not asked again.
    private var settled: Set<Int> = []
    private var asking = false
    private var document = ""
    private var version = 0
    private var poll: Timer?

    init(placement: PlacementID, block: BlockID, page: MarkdownView) {
        self.placement = placement
        self.block = block
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        page.source = { [weak self] in self.map { ($0.document, $0.version) } }
        addSubview(page)
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
        composerChanged()
    }

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
        let md = AgentConversation.markdown(turns: b.terminal?.turns ?? [], contents: contents, standing: standing, queued: queued())
        let name = AgentLook.name(of: b)
        box.placeholder.stringValue = standing == .asleep ? "Wake \(name) with a prompt…" : (b.terminal?.turns?.isEmpty ?? true) ? "Ask \(name)…" : "Reply to \(name)…"
        box.leading = standing == .working ? [stopButton] : []
        guard md != document else { return }
        document = md
        version &+= 1
        page.textChanged()
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

    // MARK: Writing

    private func composerChanged() {
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
    }

    // MARK: As a tile's content

    var pillItems: [NSMenuItem] { page.pillItems }
    func maniText(_ options: ManiReadOptions) async -> String? { document }
}
