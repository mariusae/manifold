import AppKit
import Collaboration
import ManifoldCore

/// What a thread's chat asks of whoever shows it.
protocol ThreadChatDelegate: AnyObject {
    /// A comment written: a reply, or the first of a new thread.
    func threadChat(_ view: ThreadChatView, send text: String)
    func threadChat(_ view: ThreadChatView, resolve: Bool)
    /// A link in it (a reference, a page) clicked, or its place.
    func threadChat(_ view: ThreadChatView, follow address: String)
    /// Shown as a tile of its own.
    func threadChatOpenTile(_ view: ThreadChatView)
    /// Its entries were on screen a moment: seen, up to the latest.
    func threadChatSeen(_ view: ThreadChatView)
    /// A comment of yours given new words.
    func threadChat(_ view: ThreadChatView, edit entry: String, text: String)
    /// Ask (the agent) switched for the thread shown: made the agent's, or not.
    func threadChat(_ view: ThreadChatView, asks: Bool)
    /// Its place (the place line, the text it was written against) clicked:
    /// gone back to, where the thread was made.
    func threadChatGoToPlace(_ view: ThreadChatView)
}

extension ThreadChatDelegate {
    func threadChatSeen(_ view: ThreadChatView) {}
    func threadChat(_ view: ThreadChatView, edit entry: String, text: String) {}
    func threadChat(_ view: ThreadChatView, asks: Bool) {}
    func threadChatGoToPlace(_ view: ThreadChatView) {}
}

/// What a chat shows: a thread, or — for one not made yet — what it will
/// be about; where its place is now; and how it stands.
struct ThreadChatModel {
    var thread: Block?
    var place: ThreadPlace?
    /// Where the place is now, said: "line 52", "now line 52 (written at
    /// 40)", "gone" — nil when it's as written.
    var drift: String?
    var gone = false
    /// Entries after this were not seen when the chat was shown: a New
    /// rule above the first.
    var seenMark: Stamp?
    /// Agents in it at work right now.
    var working: Set<BlockID> = []
    /// An agent's mark, by its block.
    var icon: (BlockID) -> NSImage? = { _ in nil }
    /// Its place's symbol and words, as a pill says them.
    var placeTitle: String = ""
    /// Shown in a tile, or in the overlay: no "open as tile" button.
    var inTile = false
    /// Its place as a card in the composer's box: its symbol (a page's
    /// own icon), its name, where it is.
    var placeSymbol = "doc"
    var placeImage: NSImage?
    var placeName = ""
    var placeWhere = ""
    /// The agent's thread (§3.12): every comment of yours asks it, untagged
    /// — its name, and its mark; nil, a thread like any.
    var asks: String?
    var asksIcon: NSImage?
    /// Who Ask would make it (Settings' agent): its name.
    var askName = "Claude"
}

/// A thread as a chat (§3.12): at its head what it's about, and the text
/// it was written against; its entries — each comment with its author's
/// pill, yours on the right, an agent's on the left, each event a
/// sentence — a New rule above what you hadn't seen; at its foot the
/// composer (↩ sends, ⇧↩ a new line, references dropped in) and Resolve.
final class ThreadChatView: NSView {
    weak var delegate: ThreadChatDelegate?
    private(set) var model = ThreadChatModel()
    /// The thread it shows; nil while it's the composer of a new one.
    var threadID: BlockID?
    /// A new thread's: what it'll be about, and the space it'll be in.
    var newPlace: ThreadPlace?
    var newSpace: BlockID?

    private let header = NSStackView()
    private let placeLabel = NSTextField.label(font: UIType.caption, color: Theme.secondaryText, cut: .byTruncatingMiddle)
    private let driftLabel = NSTextField(labelWithString: "")
    private let contextView = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let list = IssueList()
    let composer = ComposerTextView()
    private lazy var box = ChatBox(composer: composer)
    private var placeholder: NSTextField { box.placeholder }
    private let resolveButton = FlatButton("Resolve", symbol: "checkmark", font: UIType.detail)
    private let tileButton = IconButton("arrow.up.left.and.arrow.down.right", size: 10, tip: "Open as a Tile")
    /// Ask Claude: the thread the agent's, every comment asking it untagged.
    private let askButton = FlatButton("Ask Claude", symbol: "sparkle", toggles: true, font: UIType.detail)
    /// The agent's mark in its header, while it's the agent's thread.
    private let agentMark = NSImageView()
    /// A new thread's Ask, before it's made: on unless switched off — a
    /// thread asks the agent from its first comment.
    private(set) var asksNew = true
    /// Its own ↖↘ by the place (not where something round it has one: the overlay's header).
    var showsTileButton = true
    /// Its words' size in a tile of its own — read at length, as a
    /// document is — and its composer's; a card's and the overlay's, the
    /// interface's own.
    static let tileTextSize: CGFloat = 14
    /// A tile's comments' face: the editing one, at its own size — a thread
    /// in a tile read and written at length, as a note is — the interface's
    /// font kept for the chrome round them; code in the monospaced.
    static var tileFont: NSFont {
        let t = FontTheme.current
        return t.font(.proportional, size: t.editorSize(.proportional))
    }
    /// Debugging: whether its ↖↘ is shown.
    var debugTileButton: Bool { !tileButton.isHidden }
    /// The most it grows to, where it's fitted (a card).
    var maxHeight: CGFloat = 560
    /// Fitted to its content (a card), else filling what it's given (a tile).
    var fits = true
    private var seenTimer: Timer?
    /// The comment of yours being edited (its entry), while the composer
    /// holds its words: ↩ saves them, ⎋ leaves it as it was; and what was
    /// being written before, put back after.
    private(set) var editing: String?
    private var draft: NSAttributedString?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Clicked anywhere in it, or its composer taken: read — however
        // long it's been on screen, the window key or not when it was shown.
        let click = NSClickGestureRecognizer(target: self, action: #selector(interacted))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        composer.onFocus = { [weak self] in self?.interacted() }
        driftLabel.font = UIType.footnote
        driftLabel.textColor = Theme.tertiaryText
        contextView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        contextView.maximumNumberOfLines = 8
        contextView.lineBreakMode = .byTruncatingTail
        contextView.wantsLayer = true
        contextView.layer?.cornerRadius = 4
        agentMark.isHidden = true
        agentMark.translatesAutoresizingMaskIntoConstraints = false
        agentMark.widthAnchor.constraint(equalToConstant: 14).isActive = true
        agentMark.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let placeRow = NSStackView(views: [agentMark, placeLabel, driftLabel, NSView(), tileButton])
        placeRow.orientation = .horizontal
        placeRow.spacing = 6
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        header.addArrangedSubview(placeRow)
        header.addArrangedSubview(contextView)
        placeRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        contextView.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        tileButton.target = self
        tileButton.action = #selector(openTile)
        // Its place, and what it was written against: clicked, gone back to.
        for v in [placeLabel, contextView] as [NSView] {
            let click = NSClickGestureRecognizer(target: self, action: #selector(goToPlace))
            v.addGestureRecognizer(click)
        }
        placeLabel.toolTip = "Go to where it was written"
        contextView.toolTip = "Go to where it was written"

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        composer.font = UIType.body
        composer.isRichText = true
        composer.importsGraphics = false
        composer.allowsUndo = true
        composer.isVerticallyResizable = true
        composer.textContainer?.widthTracksTextView = true
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.composerChanged() }
        composer.onEscape = { [weak self] in
            guard let self, self.editing != nil else { return false }
            self.stopEditing()
            return true
        }
        // ↑ with nothing written: your last comment, to edit (as Slack's).
        composer.onUpWhenEmpty = { [weak self] in
            guard let self, let e = self.model.thread?.thread?.entries.last(where: { $0.author.isYou && $0.comment != nil }) else { return false }
            self.edit(e.id)
            return true
        }
        resolveButton.target = self
        resolveButton.action = #selector(toggleResolved)
        askButton.target = self
        askButton.action = #selector(toggleAsk)
        box.onSend = { [weak self] in self?.send() }
        box.leading = [resolveButton, askButton]
        for v in [header, scroll, box] as [NSView] { addSubview(v) }
        // Scrolled away from its end: a button at its foot back there; others'
        // comments come meanwhile: said on it, not scrolled to.
        addSubview(newBelow)
        newBelow.onClick = { [weak self] in self?.scrollToEnd() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.unchecked { self?.placeNewBelow() }
        }
        themed { v in
            v.contextView.layer?.backgroundColor = Theme.text.withAlphaComponent(0.05).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { seenTimer?.invalidate() }

    // MARK: Showing

    func show(_ m: ThreadChatModel) {
        let scrolledToEnd = isScrolledToEnd
        let firstShow = model.thread?.id != m.thread?.id || list.arrangedSubviews.isEmpty
        let before = model.thread?.thread?.entries.count ?? 0
        model = m
        let t = m.thread?.thread
        let place = t?.about ?? m.place
        placeLabel.stringValue = m.placeTitle
        driftLabel.stringValue = m.drift ?? ""
        driftLabel.textColor = m.gone ? NSColor.systemRed : Theme.tertiaryText
        tileButton.isHidden = !showsTileButton || m.inTile || m.thread == nil
        // Ask: the agent's thread, or (a new one) as switched; its mark in the header.
        askButton.title = "Ask \(m.asks ?? m.askName)"
        askButton.state = (m.thread == nil ? asksNew : m.asks != nil) ? .on : .off
        askButton.toolTip = "Every comment here asks \(m.asks ?? m.askName), without tagging it"
        agentMark.image = m.asksIcon
        agentMark.isHidden = m.asks == nil
        agentMark.toolTip = m.asks.map { "\($0)'s thread: your comments here ask it" }
        // Written in a tile at the size its comments are read at.
        let face = m.inTile ? Self.tileFont : UIType.body
        if composer.font != face { composer.font = face }
        if let context = place?.context, !context.isEmpty {
            contextView.isHidden = false
            contextView.attributedStringValue = Self.context(context, diff: place?.diff != nil)
        } else {
            contextView.isHidden = true
        }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        list.lineX = IssueLayout.lineX(inTile: m.inTile)
        list.spacing = m.inTile ? 14 : 10
        var ruled = false
        var previous: ThreadEntry?
        let entries = (t?.entries ?? []).filter { !$0.isEmptyComment }
        var i = 0
        while i < entries.count {
            let e = entries[i]
            if !ruled, let mark = m.seenMark, e.at > mark, e.isNotable {
                list.addArrangedSubview(fill(IssueNewView(inTile: m.inTile)))
                ruled = true
                previous = nil
            }
            // Agents asked again and again, nothing between: one row — who,
            // each once, and how many times if it's one asked more than once.
            if case let .asked(agent, _) = e.kind {
                var j = i + 1
                var names: [String] = []
                var agents: [BlockID] = []
                while j < entries.count, case .asked = entries[j].kind { j += 1 }
                for k in i..<j { if case let .asked(a, n) = entries[k].kind, !agents.contains(a) { agents.append(a); if !names.contains(n) { names.append(n) } } }
                if j - i > 1 {
                    let who = names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
                    let words = names.count == 1 ? "was asked to look \(j - i) times" : "were asked to look"
                    list.addArrangedSubview(event(who, words, at: entries[j - 1].at, symbol: "sparkle", icon: agents.count == 1 ? m.icon(agent) : nil))
                    previous = entries[j - 1]
                    i = j
                    continue
                }
            }
            list.addArrangedSubview(row(for: e, after: previous))
            previous = e
            i += 1
        }
        for agent in m.working {
            let name = t?.agents.first { $0.block == agent }?.name ?? "The agent"
            list.addArrangedSubview(event(name, "is working on it…", symbol: "ellipsis", icon: m.icon(agent)))
        }
        if t == nil {
            placeholder.stringValue = "Comment…"
        } else {
            placeholder.stringValue = t?.resolved == true ? "Reply to reopen…" : "Reply…"
        }
        resolveButton.isHidden = t == nil
        // The comment being edited gone (another Mac's undo, a log reset): left.
        if let id = editing, t?.entries.contains(where: { $0.id == id && $0.comment != nil }) != true { stopEditing() }
        updateBoxChips()
        resolveButton.title = t?.resolved == true ? "Reopen" : "Resolve"
        resolveButton.symbolName = t?.resolved == true ? "arrow.uturn.backward" : "checkmark"
        composerChanged()
        needsLayout = true
        layoutSubtreeIfNeeded()
        // To its end: first shown, followed there, or what you sent come in —
        // wherever it was scrolled. Others' come while scrolled up: said.
        let grew = !firstShow && (t?.entries.count ?? 0) > before
        let yoursCame = sentPending && grew && t?.entries.last(where: { $0.comment != nil })?.author.isYou == true
        if yoursCame { sentPending = false }
        if firstShow || scrolledToEnd || yoursCame {
            scrollToEnd()
        } else if grew {
            newBelow.announce("New comments")
        }
        placeNewBelow()
        refillOutline()
        window?.invalidateCursorRects(for: self)
        watchSeen()
    }

    private func placeNewBelow() { newBelow.place(over: scroll.frame, away: !isScrolledToEnd) }

    private var isScrolledToEnd: Bool {
        let clip = scroll.contentView
        return clip.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 4
    }

    func scrollToEnd() {
        guard let doc = scroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// ⌘ over its comments: their paths and addresses, to go to.
    private lazy var commandLinks = CommentCommandLinks(self)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        commandLinks.watch(window)
    }

    /// Used (clicked in, written in): its thread seen, up to the latest.
    @objc private func interacted() {
        guard model.thread != nil else { return }
        delegate?.threadChatSeen(self)
    }

    /// Seen once it's been on screen a moment, in a key window.
    private func watchSeen() {
        seenTimer?.invalidate()
        guard model.thread != nil else { return }
        seenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, let w = self.window, w.isVisible, w.isKeyWindow || w.isMainWindow || (w as? NSPanel) != nil else { return }
            self.delegate?.threadChatSeen(self)
        }
    }

    /// The text it was written against: monospaced; a diff's rows tinted
    /// as a diff tints them.
    private static func context(_ text: String, diff: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let out = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12)
        for (i, line) in lines.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.secondaryText]
            if diff, let c = line.first {
                if c == "+" { attrs[.backgroundColor] = DiffRowsView.addedBackground }
                if c == "-" { attrs[.backgroundColor] = DiffRowsView.removedBackground }
            }
            out.append(NSAttributedString(string: String(line) + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
        }
        return out
    }

    // MARK: Rows

    private func row(for e: ThreadEntry, after previous: ThreadEntry? = nil) -> NSView {
        switch e.kind {
        case .comment(let text): return comment(e, text, continued: CommentView.continues(e, after: previous))
        case .resolved: return event(who(e), "resolved this", at: e.at, symbol: "checkmark", tone: Status.done)
        case .reopened: return event(who(e), "reopened this", at: e.at, symbol: "arrow.uturn.backward")
        case let .asked(agent, name): return event(name, "was asked to look", at: e.at, symbol: "sparkle", icon: model.icon(agent))
        case let .edited(added, removed):
            if case .manifold = e.author { return event(nil, "Changed on disk (+\(added) −\(removed))", at: e.at, symbol: "pencil") }
            return event(who(e), "edited it (+\(added) −\(removed))", at: e.at, symbol: "pencil", icon: e.author.agentBlock.flatMap(model.icon))
        case .gone: return event(nil, "Its lines were deleted", at: e.at, symbol: "trash", tone: .systemRed)
        case .stopped(let why): return event(nil, why, at: e.at, symbol: "pause", tone: .systemOrange)
        }
    }

    private func who(_ e: ThreadEntry) -> String { e.author.isYou ? "You" : e.author.name }

    /// Something that happened, on the conversation's line.
    private func event(_ who: String?, _ words: String, at: Stamp? = nil, symbol: String, icon: NSImage? = nil, tone: NSColor? = nil) -> NSView {
        fill(IssueEventView(who: who, words: words, at: at, symbol: symbol, icon: icon, tone: tone, inTile: model.inTile))
    }

    /// A comment, as an issue's: its author's picture, and a card — who
    /// and when in its band, its words below.
    private func comment(_ e: ThreadEntry, _ text: String, continued: Bool) -> NSView {
        let face = model.inTile ? Self.tileFont : nil
        let v = IssueCommentView(e, text: text, icon: e.author.agentBlock.flatMap(model.icon), inTile: model.inTile, continued: continued,
                                 size: face?.pointSize ?? UIType.body.pointSize, font: face,
                                 lineHeight: face.map { FontTheme.current.editorLineHeight(.proportional, font: $0) } ?? 0)
        // Its mark, dragged: a reference to this comment; Copy Link, the same as text.
        if let thread = model.thread?.id {
            let title = (e.author.isYou ? "Your" : e.author.name + "'s") + " comment"
            v.dragged = { Drags.place?(Place(block: thread, at: .comment(e.id), name: title), nil) }
            v.link = { MainWindowController.address(thread) + "#" + Locator.comment(e.id).fragment }
        }
        v.onQuote = { [weak self] words in self?.quote(words) }
        v.onAuthor = { [weak self] in
            guard let self, let b = e.author.agentBlock else { return }
            self.delegate?.threadChat(self, follow: MainWindowController.address(b))
        }
        v.onLink = { [weak self] url in
            guard let self else { return }
            self.delegate?.threadChat(self, follow: url.absoluteString)
        }
        v.onCommandLink = { [weak self] target, _ in
            guard let self else { return }
            self.delegate?.threadChat(self, follow: target)
        }
        if e.author.isYou { v.onEdit = { [weak self] in self?.edit(e.id) } }
        return fill(v)
    }

    private func eventRow(_ words: String, at: Stamp? = nil, icon: NSImage? = nil, tone: NSColor? = nil) -> NSView {
        let label = NSTextField.label(words + (at.flatMap { BlockSummary.ago($0, now: Date()) }.map { " · " + $0 } ?? ""), font: UIType.footnote, color: tone ?? Theme.tertiaryText)
        var views: [NSView] = [NSView()]
        if let icon {
            let image = NSImageView(image: icon)
            image.widthAnchor.constraint(equalToConstant: 12).isActive = true
            image.heightAnchor.constraint(equalToConstant: 12).isActive = true
            views.append(image)
        }
        views += [label, NSView()]
        let line = NSStackView(views: views)
        line.spacing = 4
        if let a = views.first, let b = views.last { a.widthAnchor.constraint(equalTo: b.widthAnchor).isActive = true }
        return fill(line)
    }

    private func fill(_ v: NSView) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async { [weak self, weak v] in
            guard let self, let v, v.superview === self.list else { return }
            v.widthAnchor.constraint(equalTo: self.list.widthAnchor).isActive = true
        }
        return v
    }

    /// Its rows let go of, to be made again (in new fonts) at the next show.
    func clearRows() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let inTile = model.inTile
        model = ThreadChatModel()
        model.inTile = inTile
    }

    /// A comment gone to (a link to it followed): scrolled to the middle
    /// and ringed, as the focused tile is, a few seconds.
    func reveal(entry id: String) {
        guard let v = list.arrangedSubviews.compactMap({ $0 as? IssueCommentView }).first(where: { $0.entryID == id }) else { return }
        list.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let y = max(0, min(v.frame.midY - clip.bounds.height / 2, list.frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        list.arrangedSubviews.compactMap { $0 as? IssueCommentView }.forEach { $0.ringed = false }
        v.ringed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak v] in v?.ringed = false }
    }

    /// Quote Reply: the words quoted (`> `) into the composer, and the
    /// keyboard there, after them.
    private func quote(_ words: String) {
        let quoted = words.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        window?.makeFirstResponder(composer)
        composer.insertReferences(quoted, at: (composer.string as NSString).length)
        composerChanged()
    }

    // MARK: Editing a comment

    /// A comment of yours, its words in the composer to change; what was
    /// being written kept aside until it's done.
    func edit(_ id: String) {
        guard let e = model.thread?.thread?.entries.first(where: { $0.id == id }), e.author.isYou, let text = e.comment else { return }
        if editing == nil, !composer.string.isEmpty, let s = composer.textStorage { draft = NSAttributedString(attributedString: s) }
        editing = id
        composer.fill(markdown: text)
        updateBoxChips()
        composerChanged()
        focusComposer()
    }

    /// Done editing (saved, or ⎋): what was being written before, back.
    private func stopEditing() {
        editing = nil
        composer.clear()
        if let draft {
            composer.textStorage?.setAttributedString(draft)
            composer.setSelectedRange(NSRange(location: draft.length, length: 0))
            self.draft = nil
        }
        updateBoxChips()
        composerChanged()
    }

    /// The box's card: the comment being edited; a new thread's place.
    private func updateBoxChips() {
        if editing != nil {
            box.chips = [ChatBox.Chip(symbol: "pencil", image: nil, title: "Editing your comment", detail: "↩ to save · ⎋ to leave it as it was")]
            return
        }
        let m = model
        box.chips = m.thread == nil && !m.placeName.isEmpty
            ? [ChatBox.Chip(symbol: m.placeSymbol, image: m.placeImage, title: m.placeName, detail: m.placeWhere, block: m.place?.block)] : []
    }

    var debugEditing: String {
        editing.map { "editing \($0.suffix(6)): “\(composer.message.prefix(60))”" } ?? "not editing"
    }

    // MARK: The composer

    private func composerChanged() {
        let empty = composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !composer.string.isEmpty
        box.canSend = !empty
        box.updateMentions()
        needsLayout = true
    }

    private func send() {
        let text = composer.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = editing {
            stopEditing()
            return delegate?.threadChat(self, edit: id, text: text) ?? ()
        }
        composer.clear()
        composerChanged()
        // Where it lands, scrolled to as it comes, wherever this was scrolled.
        sentPending = true
        delegate?.threadChat(self, send: text)
    }

    /// Sent, and not yet come back: shown at the end when it does.
    private var sentPending = false
    private let newBelow = NewBelowButton(showsWhenAway: true)

    /// Ask switched: a new thread's kept till it's made; a thread's, said.
    @objc private func toggleAsk() {
        if model.thread == nil {
            asksNew = askButton.state == .on
        } else {
            delegate?.threadChat(self, asks: askButton.state == .on)
        }
    }

    /// Made: the next new one's Ask on again, as they start.
    func madeAsking() { asksNew = true }

    /// Debugging: Ask switched, as clicked; and how it stands.
    func debugAsk(_ on: Bool?) -> String {
        if let on, (askButton.state == .on) != on { askButton.performClick(nil) }
        return "ask \(askButton.state == .on ? "on" : "off") · \(askButton.title) · mark \(agentMark.isHidden ? "hidden" : "shown")"
    }

    @objc private func toggleResolved() {
        delegate?.threadChat(self, resolve: model.thread?.thread?.resolved != true)
    }

    @objc private func openTile() { delegate?.threadChatOpenTile(self) }

    @objc private func goToPlace() {
        guard model.thread != nil else { return }
        delegate?.threadChatGoToPlace(self)
    }

    /// The place and the text under it take the pointing hand: they go somewhere.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard model.thread != nil else { return }
        for v in [placeLabel, contextView] as [NSView] where !v.isHidden && v.window != nil {
            addCursorRect(convert(v.bounds, from: v), cursor: .pointingHand)
        }
    }

    /// The keyboard to the composer.
    func focusComposer() { window?.makeFirstResponder(composer) }

    // MARK: Layout

    private var boxHeight: CGFloat {
        if box.frame.width != bounds.width - 24 { box.frame.size.width = bounds.width - 24; box.layoutSubtreeIfNeeded() }
        return box.wantedHeight
    }

    private var headerHeight: CGFloat {
        header.layoutSubtreeIfNeeded()
        return header.fittingSize.height
    }

    /// The height it wants, for a card.
    var wantedHeight: CGFloat {
        list.layoutSubtreeIfNeeded()
        let content = list.fittingSize.height
        return min(maxHeight, 12 + headerHeight + 8 + content + 8 + boxHeight + 12)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = bounds.width - pad * 2
        var y = bounds.height - pad
        let hh = headerHeight
        header.frame = NSRect(x: pad, y: y - hh, width: w, height: hh)
        y -= hh + 8
        let bh = boxHeight
        box.frame = NSRect(x: pad, y: pad, width: w, height: bh)
        let listBottom = box.frame.maxY + 10
        scroll.frame = NSRect(x: pad, y: listBottom, width: w, height: max(0, y - listBottom))
        finder.layout(in: bounds)
        strip.place(scroll.frame)
        placeNewBelow()
    }

    // MARK: Its outline: a tick for each comment, down its right (as a page's headings)

    /// The comments, in order: who said each and how it begins; chosen,
    /// scrolled to.
    private(set) lazy var commentsOutline: Outline = {
        let o = Outline()
        o.onPick = { [weak self] i in
            guard let self, let v = self.commentView(i) else { return }
            self.scroll(to: v)
        }
        return o
    }()
    private lazy var strip: ScrollStrip = {
        let s = ScrollStrip(outline: commentsOutline, scroll: scroll, ownsScrollBar: false)
        s.tops = { [weak self] in self?.commentViews.map { (y: $0.frame.minY, level: 0) } ?? [] }
        s.strip.preview = { [weak self] i in
            guard let v = self?.commentView(i) else { return [] }
            return v.markdown.split(separator: "\n").prefix(4).map(String.init)
        }
        addSubview(s.strip)
        return s
    }()
    private var commentViews: [IssueCommentView] { list.arrangedSubviews.compactMap { $0 as? IssueCommentView } }
    private func commentView(_ i: Int) -> IssueCommentView? {
        let all = commentViews
        return all.indices.contains(i) ? all[i] : nil
    }

    /// The outline made again from the comments shown.
    private func refillOutline() {
        let items = commentViews.map { v -> Outline.Item in
            let words = v.markdown.split(whereSeparator: \.isNewline).first.map { Block.plainWords(String($0)) } ?? ""
            return Outline.Item(title: v.authorName + ": " + String(words.prefix(70)))
        }
        commentsOutline.set(items)
        commentsOutline.block = model.thread?.id
        commentsOutline.placeFor = { [weak self] i in self?.commentView(i).map { .comment($0.entryID) } }
        list.layoutSubtreeIfNeeded()
        strip.refill()
    }

    /// A comment scrolled into the middle of what shows.
    private func scroll(to v: NSView) {
        list.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let y = max(0, min(v.frame.midY - clip.bounds.height / 2, list.frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Find (⌘F): over every comment's words

    private lazy var finder: FindHost = FindHost(view: self, target: self)
    /// The matches, comment by comment in order, and the one gone to.
    private var matches: [(text: PillTextView, range: NSRange)] = []
    private var currentMatch: Int?

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    /// Every comment's words, top to bottom.
    private var commentTexts: [PillTextView] {
        func all(_ v: NSView) -> [PillTextView] { (v as? PillTextView).map { [$0] } ?? v.subviews.flatMap(all) }
        return all(list)
    }

    private func clearMatches() {
        for t in commentTexts {
            t.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (t.string as NSString).length))
        }
    }

    private func goToMatch() {
        for (t, r) in matches { t.layoutManager?.addTemporaryAttribute(.backgroundColor, value: TextView.matchColor, forCharacterRange: r) }
        guard let i = currentMatch, matches.indices.contains(i) else { return }
        let (t, r) = matches[i]
        t.layoutManager?.addTemporaryAttribute(.backgroundColor, value: SearchPreviewView.currentMatch, forCharacterRange: r)
        if let lm = t.layoutManager, let tc = t.textContainer {
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
            t.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
        }
        t.showFindIndicator(for: r)
    }

    override var isFlipped: Bool { false }
}

/// A stack laid out from the top, for a scroll view's document.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A line, the divider's colour.
final class HairlineView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }
}

extension ThreadEntry {
    /// A comment with no words (an agent's reply that said nothing): not shown.
    var isEmptyComment: Bool {
        if case .comment(let t) = kind { return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

/// A comment, as a conversation shows one (Quip's): who wrote it, a round
/// mark at the left — your initial on the accent, an agent's own mark —
/// their name in bold and when beside it, the words under the name in
/// full ink, no bubble. One more from the same author just after, its
/// words alone under theirs (`continued`).
final class CommentView: NSView {
    static let avatar: CGFloat = 22
    static let gap: CGFloat = 8
    var onAuthor: (() -> Void)?
    var onLink: ((URL) -> Void)? { didSet { body.onLink = onLink } }
    /// Yours: Edit Comment in its menu.
    var onEdit: (() -> Void)? { didSet { body.onEdit = onEdit } }
    let body: CommentText

    /// `size`: its words' (a tile's are bigger, for reading at length);
    /// `font`: their face, if not the interface's (a tile's, the technical).
    init(_ e: ThreadEntry, text: String, icon: NSImage?, continued: Bool, width: CGFloat, size: CGFloat = UIType.body.pointSize, font: NSFont? = nil) {
        body = CommentText(markdown: text, size: size, font: font)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let indent = Self.avatar + Self.gap
        body.limit = max(120, width - indent)
        var views: [NSView] = []
        if !continued {
            let name = NSTextField.label(e.author.isYou ? "You" : e.author.name, font: .systemFont(ofSize: size, weight: .semibold))
            let ago = BlockSummary.ago(e.at, now: Date()) ?? ""
            let when = NSTextField.label(e.edited == nil ? ago : ago + " · edited", font: UIType.footnote, color: Theme.tertiaryText)
            when.toolTip = DateFormatter.localizedString(from: e.at.date, dateStyle: .medium, timeStyle: .short)
                + (e.edited.map { "\nEdited " + DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .short) } ?? "")
            if case let .you(machine) = e.author { name.toolTip = machine.map { "From \($0)" } }
            let head = NSStackView(views: [name, when])
            head.spacing = 6
            head.alignment = .firstBaseline
            views.append(head)
            let mark = Avatar(e.author, icon: icon)
            mark.onClick = { [weak self] in self?.onAuthor?() }
            mark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mark)
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: leadingAnchor), mark.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                mark.widthAnchor.constraint(equalToConstant: Self.avatar), mark.heightAnchor.constraint(equalToConstant: Self.avatar),
            ])
        }
        views.append(body)
        // One more of the same author's, edited: said under its words.
        if continued, let edited = e.edited {
            let mark = NSTextField.label("edited", font: UIType.footnote, color: Theme.tertiaryText)
            mark.toolTip = "Edited " + DateFormatter.localizedString(from: edited.date, dateStyle: .medium, timeStyle: .short)
            views.append(mark)
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: continued ? 0 : Self.avatar + 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Yours: Edit Comment, right-clicked beside its words (on them, their
    /// own menu has it).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onEdit else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Edit Comment", symbol: "pencil") { onEdit() })
        return menu
    }

    /// Its words as wide as it is, once it's laid out at its width.
    override func layout() {
        super.layout()
        let l = max(120, bounds.width - Self.avatar - Self.gap)
        if bounds.width > 0, abs(body.limit - l) > 0.5 { body.limit = l }
    }

    /// Whether `e` follows `previous` as more of the same: a comment by the
    /// same author, a few minutes on.
    static func continues(_ e: ThreadEntry, after previous: ThreadEntry?) -> Bool {
        guard let p = previous, case .comment = p.kind, case .comment = e.kind,
              (p.author.isYou && e.author.isYou) || (p.author.agentBlock != nil && p.author.agentBlock == e.author.agentBlock) else { return false }
        return e.at.date.timeIntervalSince(p.at.date) < 5 * 60
    }
}

/// An author's round mark: your initial, white on the accent; an agent's
/// own mark on a pale ground; clicked (an agent's), its terminal.
final class Avatar: NSView {
    var onClick: (() -> Void)?
    private let author: ThreadAuthor
    private let icon: NSImage?

    init(_ author: ThreadAuthor, icon: NSImage?) {
        self.author = author
        self.icon = icon ?? (author.agentBlock != nil ? NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) : nil)
        super.init(frame: .zero)
        toolTip = author.isYou ? nil : author.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        // Yours: this Mac's picture of you (your account's), round.
        if author.isYou, let picture = UserPicture.image {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            picture.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            Theme.text.withAlphaComponent(0.12).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return
        }
        if author.isYou {
            Theme.accent.setFill()
            circle.fill()
            let initial = String((NSFullUserName().first ?? "Y").uppercased())
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: bounds.height * 0.5, weight: .semibold), .foregroundColor: NSColor.white]
            let size = initial.size(withAttributes: a)
            initial.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: a)
            return
        }
        Theme.text.withAlphaComponent(0.07).setFill()
        circle.fill()
        Theme.text.withAlphaComponent(0.16).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        guard let icon else { return }
        let side = bounds.height * 0.6
        let r = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        if icon.isTemplate {
            let tinted = NSImage(size: r.size, flipped: false) { rect in
                icon.draw(in: rect)
                Theme.accent.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: r)
        } else {
            icon.draw(in: r)
        }
    }

    /// Dragged (moved a few points while pressed): what it stands for
    /// carried out — a comment's mark, the comment.
    var onDrag: ((NSEvent) -> Void)?
    private var pressedAt: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard onDrag != nil else { return onClick?() ?? () }
        pressedAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pressedAt, let onDrag, hypot(event.locationInWindow.x - p.x, event.locationInWindow.y - p.y) > 3 else { return }
        pressedAt = nil
        onDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        // Let go without dragging: a click (an agent's, its terminal).
        if pressedAt != nil { onClick?() }
        pressedAt = nil
    }

    override func resetCursorRects() {
        // A handle: taken hold of; an agent's, clicked, its terminal.
        if onDrag != nil { addCursorRect(bounds, cursor: .openHand) }
        else if author.agentBlock != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// A comment's words, rendered as Markdown, as wide as they want up to
/// `limit`; links clicked go where they say.
final class CommentText: NSView, NSTextViewDelegate {
    var onLink: ((URL) -> Void)?
    /// Yours: Edit Comment, first in its words' menu.
    var onEdit: (() -> Void)?

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let onEdit else { return menu }
        menu.insertItem(ClosureMenuItem("Edit Comment", symbol: "pencil") { onEdit() }, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
    let text = PillTextView()
    private let attributed: NSAttributedString

    /// A block's pill's look (the window's: its name, symbol, status), for
    /// the references in comments.
    static var look: ((BlockID) -> PillLook?)?

    init(markdown: String, size: CGFloat = UIType.body.pointSize, font: NSFont? = nil, boxes: Bool = false, lineHeight: CGFloat = 0) {
        self.markdown = markdown
        // In a face of its own (the editing one, a tile's), code in the theme's monospaced, as notes have it.
        let code = font == nil ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : FontTheme.current.font(.monospaced, size: size - 1)
        let tracking = font.map { FontTheme.current.tracking(.proportional, font: $0) } ?? 0
        attributed = Self.pilled(MarkdownText.attributed(markdown, font: font ?? .systemFont(ofSize: size), code: code, color: Theme.text,
                                                         lineHeight: lineHeight, tracking: tracking, boxes: boxes, breaks: true))
        super.init(frame: .zero)
        // TextKit 1: a code block's box (an NSTextBlock) is laid out only
        // there — by one that draws inline code's ground round its letters.
        text.textContainer?.replaceLayoutManager(CodeGroundLayoutManager())
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textStorage?.setAttributedString(attributed)
        text.delegate = self
        text.linkTextAttributes = [.foregroundColor: Tints.accentText, .cursor: NSCursor.pointingHand]
        addSubview(text)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its size for a width at most `limit`: as narrow as its longest line.
    private func size(limit: CGFloat) -> NSSize {
        let inner = max(40, limit)
        let r = attributed.boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(min(inner, r.width)) + 2, height: ceil(r.height))
    }

    var limit: CGFloat = 340 { didSet { if limit != oldValue { invalidateIntrinsicContentSize() } } }

    /// Its height laid out at a width, as a text view lays it out (its
    /// code blocks' boxes and all); the last asked kept.
    func height(forWidth w: CGFloat) -> CGFloat {
        if let last = measured, abs(last.width - w) < 0.5 { return last.height }
        let storage = NSTextStorage(attributedString: attributed)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: max(40, w), height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height)
        measured = (w, h)
        return h
    }
    private var measured: (width: CGFloat, height: CGFloat)?

    /// Its words as Markdown, as written.
    let markdown: String

    override var intrinsicContentSize: NSSize { size(limit: limit) }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        text.frame = bounds
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let u = link as? URL { onLink?(u); return true }
        if let s = link as? String, let u = URL(string: s) { onLink?(u); return true }
        return false
    }


    /// References in a comment as their blocks' pills (§7), as the editor
    /// draws them: a link to a block (its words naming a place in it, if
    /// it's to one), and a reference written bare. Each still its link.
    static func pilled(_ s: NSAttributedString) -> NSAttributedString {
        guard let look else { return s }
        let out = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: out.length)
        var found: [(NSRange, String, PillLook)] = []
        out.enumerateAttribute(.link, in: all) { value, range, _ in
            let address = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
            guard address.hasPrefix("manifold:"), let (id, place) = BlockID.link(address), var l = look(id) else { return }
            let words = (out.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
            if place != nil, !words.isEmpty, words != address { l.title = words }
            found.append((range, address, l))
        }
        let linked = found.map(\.0)
        for m in TextLinks.bareReference.matches(in: out.string, range: all) where !linked.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let address = (out.string as NSString).substring(with: m.range)
            guard let (id, place) = BlockID.link(address), var l = look(id) else { continue }
            if let place {
                let at = Locator(fragment: place)
                if let anchor = at?.anchorID, let name = MarkdownStyle.placeName?(id, anchor) { l.title = name } else { l.title += " · " + (at?.words ?? place) }
            }
            found.append((m.range, address, l))
        }
        // From the end, so the ranges before stay where they were.
        for (range, address, l) in found.sorted(by: { $0.0.location > $1.0.location }) {
            var attrs = out.attributes(at: range.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont ?? UIType.body
            let h = ceil(font.ascender - font.descender) + 3
            let a = NSTextAttachment()
            a.image = LinkCapsule.pillImage(l, height: h)
            // Centred on the text's middle: its lowercase letters'.
            a.bounds = NSRect(x: 0, y: (font.xHeight - h) / 2, width: a.image!.size.width, height: h)
            attrs[.link] = URL(string: address) ?? address
            attrs[.attachment] = a
            out.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: attrs))
        }
        return out
    }
}

/// The composer: ↩ sends, ⇧↩ (or ⌥↩) a new line; things dropped on it put
/// in as their links.
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    /// Made the first responder: clicked in, tabbed to, its tile focused.
    var onFocus: (() -> Void)?

    // The pointer resting on a pill: its block's card (`ReferenceCards`).
    private var hoverArea: NSTrackingArea?
    private var hovering: BlockID?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hovering = ReferenceCards.track(self, at: convert(event.locationInWindow, from: nil), was: hovering)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hovering != nil { ReferenceCards.hide?() }
        hovering = nil
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }

    // ⌘F and the rest of Find: the chat's (its comments'), not this field's.
    override func performTextFinderAction(_ sender: Any?) {
        guard let chat = enclosing(ThreadChatView.self) else { return super.performTextFinderAction(sender) }
        chat.performTextFinderAction(sender)
    }
    var onChange: (() -> Void)?
    /// ⎋: what it closes (a card, the overlay).
    var onCancel: (() -> Void)?
    /// ⎋, asked first: true if it took it (an edit left as it was).
    var onEscape: (() -> Bool)?
    /// ↑ with nothing written: true if it took it (your last comment, to edit).
    var onUpWhenEmpty: (() -> Bool)?
    /// What `@` offers (ThreadMentions.swift): asked for as its list opens.
    var mentionSource: (() -> (String) -> [MentionChoice])?
    private var mentionRanker: ((String) -> [MentionChoice])?
    let mentions = MentionPopover()
    /// The `@` whose list ⎋ put away: not offered again until another.
    private var mentionDismissedAt: Int?

    override func cancelOperation(_ sender: Any?) {
        if mentions.isShown { return dismissMentions() }
        if onEscape?() == true { return }
        // Nothing of its own to close (a tile's): up the chain — NSTextView
        // has no cancelOperation of its own, and super's is no method at all.
        if let onCancel { onCancel() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    override func keyDown(with event: NSEvent) {
        let returnKey = event.isReturn
        let plain = event.keyMods.isEmpty
        if mentions.isShown, plain {
            switch event.keyCode {
            case 125: return mentions.move(1)
            case 126: return mentions.move(-1)
            case 36, 76, 48: return acceptMention()
            case 53: return dismissMentions()
            default: break
            }
        }
        if returnKey, event.modifierFlags.intersection([.shift, .option, .control]).isEmpty, !hasMarkedText() {
            mentions.hide()
            onSend?()
            return
        }
        if event.keyCode == 126, plain, string.isEmpty, onUpWhenEmpty?() == true { return }
        super.keyDown(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        if unpillBeforeCaret() { return }
        super.deleteBackward(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
        updateMentions()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { updateMentions() }
    }

    override func resignFirstResponder() -> Bool {
        mentions.hide()
        return super.resignFirstResponder()
    }

    /// The list for the `@word` at the caret, if there is one.
    func updateMentions() {
        guard let token = mentionToken, let window else {
            mentionDismissedAt = nil
            mentionRanker = nil
            return mentions.hide()
        }
        guard mentionDismissedAt != token.range.location, let source = mentionSource else { return mentions.hide() }
        if mentionRanker == nil { mentionRanker = source() }
        let choices = mentionRanker?(token.query) ?? []
        let caret = firstRect(forCharacterRange: token.range, actualRange: nil)
        mentions.onChoose = { [weak self] c in self?.choose(c) }
        mentions.show(choices, at: caret, in: window)
    }

    /// Debugging: typed in, as at the keyboard; the list's choice taken.
    func debugType(_ text: String) {
        window?.makeFirstResponder(self)
        insertText(text, replacementRange: selectedRange())
    }
    func debugAccept() { acceptMention() }

    private func acceptMention() {
        guard let c = mentions.selected else { return mentions.hide() }
        choose(c)
    }

    private func choose(_ c: MentionChoice) {
        guard let token = mentionToken else { return mentions.hide() }
        mentions.hide()
        mentionRanker = nil
        insertMention(c, for: token)
        window?.makeFirstResponder(self)
    }

    private func dismissMentions() {
        mentionDismissedAt = mentionToken?.range.location
        mentions.hide()
    }

    /// Cleared, as after sending: no pill's look left for what's typed next.
    func clear() {
        string = ""
        typingAttributes = plainAttributes
        mentions.hide()
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.manifoldThing] + super.readablePasteboardTypes }

    // Drops, as a note takes them (§3.11): a block's link — a pill here,
    // its card over the composer, as `@` makes one — else the palette's
    // other forms (a bare reference, its path, its words…); words dragged
    // in plain, in the composer's look, not the look they had.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource as? NSView === self ? super.draggingEntered(sender) : Dropping.updated(self, sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource as? NSView === self ? super.draggingUpdated(sender) : Dropping.updated(self, sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        Dropping.exited(self, sender)
        super.draggingExited(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource as? NSView === self ? super.performDragOperation(sender) : Dropping.perform(self, sender)
    }

    /// Pasted: plain, in the composer's look; references in it pills.
    override func paste(_ sender: Any?) {
        guard let words = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        let r = selectedRange()
        if r.length > 0, shouldChangeText(in: r, replacementString: "") {
            textStorage?.replaceCharacters(in: r, with: "")
            didChangeText()
        }
        insertReferences(words, at: r.location)
    }
}

extension ComposerTextView: DropTaking {
    /// As a note takes things, less pictures shown inline (a comment
    /// keeps none).
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] {
        Dropping.noteForms(d).filter { $0 != .inline }
    }

    func dropTrack(_ d: Dragged, at p: NSPoint) {
        let at = characterIndexForInsertion(at: p)
        if selectedRange() != NSRange(location: at, length: 0) { setSelectedRange(NSRange(location: at, length: 0)) }
    }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        window?.makeFirstResponder(self)
        let at = p.map { characterIndexForInsertion(at: $0) } ?? selectedRange().location
        d.text(form, separator: " ") { [weak self] text, _ in
            guard let self, let text else { return }
            let all = self.string as NSString
            let i = min(at, all.length)
            let char = { (k: Int) -> Character? in k >= 0 && k < all.length ? Character(all.substring(with: NSRange(location: k, length: 1))) : nil }
            let put = [.link, .reference, .path].contains(form) ? Dropping.spaced(text, after: char(i - 1), before: char(i)) : text
            self.insertReferences(put, at: i)
        }
    }
}

/// A comment's words: a pill (an attachment with a link on it) clicked
/// goes where its link does — NSTextView takes a click on an attachment
/// for itself, not its link's.
final class PillTextView: NSTextView {
    /// ⌘-clicked on a path or an address in it: `over`, ⌥ held too.
    var onCommandLink: ((_ target: String, _ over: Bool) -> Void)?
    /// The link ⌘ marks: underlined, in the accent.
    private var marked: NSRange?
    /// Pressed with ⌘ on a link: followed as it's let go, dragged out if it moves.
    private var pressed: (target: String, at: NSPoint, over: Bool)?

    /// What ⌘ marks at a point (in this view): a link's (a pill's, a
    /// Markdown link's), else a path or an address written in the words,
    /// as a terminal finds them.
    func commandLink(at p: NSPoint) -> (target: String, range: NSRange)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let q = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let g = lm.glyphIndex(for: q, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).insetBy(dx: -1, dy: -1).contains(q) else { return nil }
        let i = lm.characterIndexForGlyph(at: g)
        guard i < storage.length else { return nil }
        var linkRange = NSRange()
        if let link = storage.attribute(.link, at: i, effectiveRange: &linkRange) {
            let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            if !target.isEmpty { return (target, linkRange) }
        }
        // The paragraph it's in, by Unicode scalar, as a terminal's line is.
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: i, length: 0))
        let line = ns.substring(with: para).trimmingCharacters(in: .newlines)
        let before = ns.substring(with: NSRange(location: para.location, length: i - para.location))
        let offset = before.unicodeScalars.count
        guard let l = TerminalLinks.link(at: offset, in: line), l.standing != .possible else { return nil }
        let scalars = Array(line.unicodeScalars)
        let start = String(String.UnicodeScalarView(scalars[0..<l.range.lowerBound])).utf16.count
        let length = String(String.UnicodeScalarView(scalars[l.range])).utf16.count
        return (l.target, NSRange(location: para.location + start, length: length))
    }

    /// ⌘'s mark on a link (nil: none), as the terminal's: underlined.
    func mark(_ range: NSRange?) {
        guard range != marked, let lm = layoutManager else { return }
        if let m = marked, NSMaxRange(m) <= (textStorage?.length ?? 0) {
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: m)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: m)
        }
        marked = range
        if let r = range {
            lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Tints.accentText], forCharacterRange: r)
        }
    }

    // ⌘F in a comment: the chat's search, over all of them.
    override func performTextFinderAction(_ sender: Any?) {
        guard let chat = enclosing(ThreadChatView.self) else { return super.performTextFinderAction(sender) }
        chat.performTextFinderAction(sender)
    }

    // The pointer resting on a pill: its block's card (`ReferenceCards`).
    private var hoverArea: NSTrackingArea?
    private var hovering: BlockID?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hovering = ReferenceCards.track(self, at: convert(event.locationInWindow, from: nil), was: hovering)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hovering != nil { ReferenceCards.hide?() }
        hovering = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        // ⌘-right-click on a link: its menu, as a terminal's.
        if event.modifierFlags.contains(.command), let (target, _) = commandLink(at: convert(event.locationInWindow, from: nil)),
           LinkMenus.popUp(target, from: nil, on: nil, with: event, for: self) { return }
        super.rightMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pressed else { return super.mouseDragged(with: event) }
        guard hypot(event.locationInWindow.x - p.at.x, event.locationInWindow.y - p.at.y) > 4 else { return }
        pressed = nil
        guard let writer = LinkMenus.drag?(p.target, nil, nil) else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let at = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 6, y: at.y - 6, width: 12, height: 12), contents: nil)
        draggingLink = true
        let session = beginDraggingSession(with: [item], event: event, source: self)
        DragPill.dress(session, from: self, at: NSEvent.mouseLocation)
    }

    /// A link's drag under way (not the text view's own, of its words).
    private var draggingLink = false

    override func mouseUp(with event: NSEvent) {
        if let p = pressed {
            pressed = nil
            onCommandLink?(p.target, p.over)
            return
        }
        super.mouseUp(with: event)
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard draggingLink else { return super.draggingSession(session, sourceOperationMaskFor: context) }
        return [.copy, .link, .generic]
    }
    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard draggingLink else { return super.draggingSession(session, willBeginAt: screenPoint) }
        DragCursor.began()
    }
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard draggingLink else { return super.draggingSession(session, movedTo: screenPoint) }
        DragCursor.moved()
    }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard draggingLink else { return super.draggingSession(session, endedAt: screenPoint, operation: operation) }
        draggingLink = false
        DragCursor.ended()
    }

    /// The pill's link under a point, if there's one there.
    func pillLink(at p: NSPoint) -> Any? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let q = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let g = lm.glyphIndex(for: q, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(q) else { return nil }
        let i = lm.characterIndexForGlyph(at: g)
        guard i < storage.length, storage.attribute(.attachment, at: i, effectiveRange: nil) != nil else { return nil }
        return storage.attribute(.link, at: i, effectiveRange: nil)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘ on a path or address: gone to as it's let go, or dragged out.
        if event.modifierFlags.contains(.command), let (target, _) = commandLink(at: convert(event.locationInWindow, from: nil)) {
            pressed = (target, event.locationInWindow, event.modifierFlags.contains(.option))
            return
        }
        if let link = pillLink(at: convert(event.locationInWindow, from: nil)) {
            _ = delegate?.textView?(self, clickedOnLink: link, at: 0)
            return
        }
        super.mouseDown(with: event)
    }
}

/// ⌘ held over a conversation's comments (a chat's, a timeline's): the
/// path or address under the pointer marked, as a terminal marks one, the
/// hand badged with what it goes to; ⌘-click goes, ⌘-right-click its menu,
/// ⌘-drag carries it (`PillTextView`).
final class CommentCommandLinks {
    private let watcher = CommandLinkWatcher()
    private weak var root: NSView?
    private weak var marked: PillTextView?

    init(_ root: NSView) {
        self.root = root
        watcher.inside = { [weak self] in self?.root?.isUnderPointer ?? false }
        watcher.show = { [weak self] in self?.update() }
        watcher.update = { [weak self] _ in self?.update() }
        watcher.hide = { [weak self] in self?.clear() }
    }

    func watch(_ window: NSWindow?) { watcher.watch(window) }

    private func update() {
        guard let root, let window = root.window, let content = window.contentView else { return clear() }
        let at = window.mouseLocationOutsideOfEventStream
        var v = content.superview?.hitTest(at) ?? content.hitTest(at)
        while let x = v, !(x is PillTextView) { v = x.superview }
        guard let text = v as? PillTextView, text.isDescendant(of: root),
              let (target, range) = text.commandLink(at: text.convert(at, from: nil)) else {
            clear()
            NSCursor.pointingHand.set()
            return
        }
        if marked !== text { marked?.mark(nil) }
        marked = text
        text.mark(range)
        let path = FileLocation.split(target)?.path ?? target
        let badge = LinkCursor.badge(for: target, isDirectory: path.hasPrefix("/") ? LinkCursor.isDirectory(path) : nil)
        LinkCursor.cursor(badge).set()
    }

    private func clear() {
        marked?.mark(nil)
        marked = nil
        NSCursor.arrow.set()
    }
}

extension ThreadChatView: Searchable {
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        clearMatches()
        matches = []
        currentMatch = nil
        guard !query.isEmpty else { return done(nil) }
        for t in commentTexts {
            for r in Matching.ranges(of: query, in: t.string as NSString, options: caseSensitive ? [] : [.caseInsensitive], limit: 10_000) {
                matches.append((t, r))
            }
        }
        // The newest first, as a conversation's read from its end.
        currentMatch = matches.isEmpty ? nil : matches.count - 1
        goToMatch()
        done(matches.count)
    }

    func findNext(forward: Bool) {
        guard !matches.isEmpty else { return }
        currentMatch = Matching.step(currentMatch, of: matches.count, forward: forward)
        goToMatch()
    }

    func endSearch() {
        clearMatches()
        matches = []
        currentMatch = nil
        window?.makeFirstResponder(composer)
    }

    func textForFind(_ done: @escaping (String?) -> Void) {
        let t = window?.firstResponder as? NSTextView
        done(t.flatMap { $0.selectedRange().length > 0 ? ($0.string as NSString).substring(with: $0.selectedRange()) : nil })
    }

    /// Debugging: words sent from its composer, as typed and ↩; and where
    /// it's scrolled, and whether New shows.
    func debugSend(_ text: String) {
        composer.string = text
        send()
    }
    func debugScrollTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    var debugScroll: String {
        "at end \(isScrolledToEnd) · top \(Int(scroll.contentView.bounds.minY)) of \(Int(list.frame.height)) · to end \(newBelow.debugState)"
    }

    /// Debugging: its strip — its items, its ticks (lit or not), its frame.
    var debugStrip: String {
        let s = strip.strip
        return "frame \(NSStringFromRect(s.frame)) items \(commentsOutline.items.map(\.title)) ticks \(s.ticks.map { $0.lit ? "●" : "○" }.joined())"
    }

    /// Debugging: the face its first comment's words are set in, and whether it's in a tile.
    var debugFont: String {
        let f = commentTexts.first?.textStorage.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
        return "\(f?.fontName ?? "none") \(f?.pointSize ?? 0) inTile \(model.inTile) theme \(FontTheme.current.rawValue)"
    }

    /// Debugging: the pointer resting on its first pill (a comment's): the block shown.
    func debugHoverPill() -> String {
        for t in commentTexts {
            guard let storage = t.textStorage, let lm = t.layoutManager, let tc = t.textContainer else { continue }
            var found: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
                if v != nil, storage.attribute(.link, at: r.location, effectiveRange: nil) != nil { found = r; stop.pointee = true }
            }
            guard let r = found else { continue }
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
            let p = NSPoint(x: rect.midX + t.textContainerOrigin.x, y: rect.midY + t.textContainerOrigin.y)
            return ReferenceCards.track(t, at: p, was: nil).map { "resting on \($0)" } ?? "no pill there"
        }
        return "no pills"
    }

    /// Debugging: "find <query>" or "find next": the matches, and which.
    func debugFind(_ q: String) -> String {
        if q == "next" { findNext(forward: true) } else { finder.show(query: q, fromSelection: false) }
        return "\(matches.count) matches, current \(currentMatch.map(String.init) ?? "none")"
    }
}

/// This Mac's picture of you: your account's (System Settings ▸ Users),
/// read once; nil, none — your initial on the accent instead.
enum UserPicture {
    static let image: NSImage? = CBIdentity(name: NSUserName(), authority: CBIdentityAuthority.local())?.image
}

/// Draws a text's ground colour (inline code's tint) as a small rounded box
/// round its letters — from a little above their tops to a little below
/// their tails — not the whole line's height, which with a reading face's
/// line spacing ran into the lines round it.
final class CodeGroundLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard rectCount > 0, let storage = textStorage, charRange.location < storage.length,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        // Its baseline, from its line's top: where the letters sit in each line.
        let g = glyphIndexForCharacter(at: charRange.location)
        let baseline = location(forGlyphAt: g).y
        var boxes: [NSRect] = []
        for i in 0..<rectCount {
            let r = rectArray[i]
            boxes.append(NSRect(x: r.minX - 1, y: r.minY + baseline - font.ascender - 1.5, width: r.width + 2, height: font.ascender - font.descender + 3))
        }
        boxes.withUnsafeBufferPointer { b in
            super.fillBackgroundRectArray(b.baseAddress!, count: b.count, forCharacterRange: charRange, color: color)
        }
    }
}
