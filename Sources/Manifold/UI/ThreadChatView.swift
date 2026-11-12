import AppKit
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
    /// Things dropped on the composer, as the text they put in (a
    /// reference's link), or nil.
    func threadChat(_ view: ThreadChatView, dropped: Dragged, done: @escaping (String?) -> Void)
    /// Its entries were on screen a moment: seen, up to the latest.
    func threadChatSeen(_ view: ThreadChatView)
    /// A comment of yours given new words.
    func threadChat(_ view: ThreadChatView, edit entry: String, text: String)
}

extension ThreadChatDelegate {
    func threadChatSeen(_ view: ThreadChatView) {}
    func threadChat(_ view: ThreadChatView, edit entry: String, text: String) {}
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
    private let list = FlippedStack()
    let composer = ComposerTextView()
    private lazy var box = ChatBox(composer: composer)
    private var placeholder: NSTextField { box.placeholder }
    private let resolveButton = FlatButton("Resolve", symbol: "checkmark", font: UIType.detail)
    private let tileButton = IconButton("arrow.up.left.and.arrow.down.right", size: 10, tip: "Open as a Tile")
    /// Its own ↖↘ by the place (not where something round it has one: the overlay's header).
    var showsTileButton = true
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
        driftLabel.font = UIType.footnote
        driftLabel.textColor = Theme.tertiaryText
        contextView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        contextView.maximumNumberOfLines = 8
        contextView.lineBreakMode = .byTruncatingTail
        contextView.wantsLayer = true
        contextView.layer?.cornerRadius = 4
        let placeRow = NSStackView(views: [placeLabel, driftLabel, NSView(), tileButton])
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
        composer.onDrop = { [weak self] dragged, done in
            guard let self, let delegate = self.delegate else { return done(nil) }
            delegate.threadChat(self, dropped: dragged, done: done)
        }
        resolveButton.target = self
        resolveButton.action = #selector(toggleResolved)
        box.onSend = { [weak self] in self?.send() }
        box.leading = [resolveButton]
        for v in [header, scroll, box] as [NSView] { addSubview(v) }
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
        model = m
        let t = m.thread?.thread
        let place = t?.about ?? m.place
        placeLabel.stringValue = m.placeTitle
        driftLabel.stringValue = m.drift ?? ""
        driftLabel.textColor = m.gone ? NSColor.systemRed : Theme.tertiaryText
        tileButton.isHidden = !showsTileButton || m.inTile || m.thread == nil
        if let context = place?.context, !context.isEmpty {
            contextView.isHidden = false
            contextView.attributedStringValue = Self.context(context, diff: place?.diff != nil)
        } else {
            contextView.isHidden = true
        }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var ruled = false
        var previous: ThreadEntry?
        for e in t?.entries ?? [] where !e.isEmptyComment {
            if !ruled, let mark = m.seenMark, e.at > mark, e.isNotable {
                list.addArrangedSubview(rule("New"))
                ruled = true
                previous = nil
            }
            list.addArrangedSubview(row(for: e, after: previous))
            previous = e
        }
        for agent in m.working {
            let name = t?.agents.first { $0.block == agent }?.name ?? "The agent"
            list.addArrangedSubview(eventRow("\(name) is working on it…", icon: m.icon(agent)))
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
        if firstShow || scrolledToEnd { scrollToEnd() }
        watchSeen()
    }

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
        case .resolved: return eventRow("Resolved by \(e.author.isYou ? "you" : e.author.name)", at: e.at)
        case .reopened: return eventRow("Reopened by \(e.author.isYou ? "you" : e.author.name)", at: e.at)
        case let .asked(agent, name): return eventRow("\(name) asked to look", at: e.at, icon: model.icon(agent))
        case let .edited(added, removed):
            if case .manifold = e.author { return eventRow("Changed on disk (+\(added) −\(removed))", at: e.at) }
            let who = e.author.isYou ? "You" : e.author.name
            return eventRow("\(who) edited it (+\(added) −\(removed))", at: e.at, icon: e.author.agentBlock.flatMap(model.icon))
        case .gone: return eventRow("Its lines were deleted", at: e.at, tone: .systemRed)
        case .stopped(let why): return eventRow(why, at: e.at, tone: .systemOrange)
        }
    }

    /// A comment: its author's mark, name and when, over its words.
    private func comment(_ e: ThreadEntry, _ text: String, continued: Bool) -> NSView {
        let width = scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width - 24
        let v = CommentView(e, text: text, icon: e.author.agentBlock.flatMap(model.icon), continued: continued, width: width - 4)
        v.onAuthor = { [weak self] in
            guard let self, let b = e.author.agentBlock else { return }
            self.delegate?.threadChat(self, follow: MainWindowController.address(b))
        }
        v.onLink = { [weak self] url in
            guard let self else { return }
            self.delegate?.threadChat(self, follow: url.absoluteString)
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

    private func rule(_ words: String) -> NSView {
        let label = NSTextField.label(words, font: UIType.caption, color: Tints.accentText)
        let left = HairlineView(), right = HairlineView()
        let line = NSStackView(views: [left, label, right])
        line.spacing = 6
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
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
        box.chips = m.thread == nil && !m.placeName.isEmpty ? [ChatBox.Chip(symbol: m.placeSymbol, image: m.placeImage, title: m.placeName, detail: m.placeWhere)] : []
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
        delegate?.threadChat(self, send: text)
    }

    @objc private func toggleResolved() {
        delegate?.threadChat(self, resolve: model.thread?.thread?.resolved != true)
    }

    @objc private func openTile() { delegate?.threadChatOpenTile(self) }

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

    init(_ e: ThreadEntry, text: String, icon: NSImage?, continued: Bool, width: CGFloat) {
        body = CommentText(markdown: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let indent = Self.avatar + Self.gap
        body.limit = max(120, width - indent)
        var views: [NSView] = []
        if !continued {
            let name = NSTextField.label(e.author.isYou ? "You" : e.author.name, font: .systemFont(ofSize: 12, weight: .semibold))
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

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { if author.agentBlock != nil { addCursorRect(bounds, cursor: .pointingHand) } }
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
    private let text = NSTextView()
    private let attributed: NSAttributedString

    init(markdown: String) {
        attributed = MarkdownText.attributed(markdown, font: UIType.body, code: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: Theme.text)
        super.init(frame: .zero)
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
}

/// The composer: ↩ sends, ⇧↩ (or ⌥↩) a new line; things dropped on it put
/// in as their links.
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onChange: (() -> Void)?
    var onDrop: ((Dragged, @escaping (String?) -> Void) -> Void)?
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
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
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

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

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

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dragged = Dragged(sender.draggingPasteboard), dragged.things.contains(where: { $0.block != nil || $0.url != nil }), let onDrop else {
            return super.performDragOperation(sender)
        }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        onDrop(dragged) { [weak self] text in
            guard let self, let text else { return }
            let range = NSRange(location: min(at, (self.string as NSString).length), length: 0)
            let spaced = (range.location > 0 && !(self.string as NSString).substring(to: range.location).hasSuffix(" ") ? " " : "") + text + " "
            if self.shouldChangeText(in: range, replacementString: spaced) {
                self.replaceCharacters(in: range, with: spaced)
                self.didChangeText()
            }
            self.window?.makeFirstResponder(self)
        }
        return true
    }
}
