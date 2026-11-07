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
}

extension ThreadChatDelegate {
    func threadChatSeen(_ view: ThreadChatView) {}
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
    private let placeLabel = NSTextField(labelWithString: "")
    private let driftLabel = NSTextField(labelWithString: "")
    private let contextView = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private let composerScroll = NSScrollView()
    let composer = ComposerTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let resolveButton = FlatButton("Resolve", symbol: "checkmark", font: UIType.detail)
    private let tileButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 10, target: nil, action: nil)
    private let sendButton = FlatButton("Send", style: .primary, font: UIType.detail)
    /// The most it grows to, where it's fitted (a card).
    var maxHeight: CGFloat = 560
    /// Fitted to its content (a card), else filling what it's given (a tile).
    var fits = true
    private var seenTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeLabel.font = UIType.caption
        placeLabel.textColor = Theme.secondaryText
        placeLabel.lineBreakMode = .byTruncatingMiddle
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
        tileButton.toolTip = "Open the thread as a tile"
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
        composer.isRichText = false
        composer.allowsUndo = true
        composer.drawsBackground = false
        composer.textContainerInset = NSSize(width: 4, height: 5)
        composer.isVerticallyResizable = true
        composer.textContainer?.widthTracksTextView = true
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.composerChanged() }
        composer.onDrop = { [weak self] dragged, done in
            guard let self, let delegate = self.delegate else { return done(nil) }
            delegate.threadChat(self, dropped: dragged, done: done)
        }
        composerScroll.documentView = composer
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.wantsLayer = true
        composerScroll.layer?.cornerRadius = 6
        composerScroll.layer?.borderWidth = 1
        placeholder.font = UIType.body
        placeholder.textColor = Theme.tertiaryText
        resolveButton.target = self
        resolveButton.action = #selector(toggleResolved)
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        for v in [header, scroll, composerScroll, placeholder, resolveButton, sendButton] as [NSView] { addSubview(v) }
        themed { v in
            v.contextView.layer?.backgroundColor = Theme.text.withAlphaComponent(0.05).cgColor
            v.composerScroll.layer?.borderColor = Theme.divider.cgColor
            v.composerScroll.layer?.backgroundColor = Theme.windowBackground.cgColor
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
        tileButton.isHidden = m.inTile || m.thread == nil
        if let context = place?.context, !context.isEmpty {
            contextView.isHidden = false
            contextView.attributedStringValue = Self.context(context, diff: place?.diff != nil)
        } else {
            contextView.isHidden = true
        }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var ruled = false
        for e in t?.entries ?? [] {
            if !ruled, let mark = m.seenMark, e.at > mark, e.isNotable {
                list.addArrangedSubview(rule("New"))
                ruled = true
            }
            list.addArrangedSubview(row(for: e))
        }
        for agent in m.working {
            let name = t?.agents.first { $0.block == agent }?.name ?? "The agent"
            list.addArrangedSubview(eventRow("\(name) is working on it…", icon: m.icon(agent)))
        }
        if t == nil {
            placeholder.stringValue = "Comment… (↩ sends, @claude asks an agent)"
        } else {
            placeholder.stringValue = t?.resolved == true ? "Reply to reopen…" : "Reply…"
        }
        resolveButton.isHidden = t == nil
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

    private func row(for e: ThreadEntry) -> NSView {
        switch e.kind {
        case .comment(let text): return bubble(e, text)
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

    /// A comment: its author's pill and when, over its words in a bubble —
    /// yours at the right, tinted with the accent; others' at the left.
    private func bubble(_ e: ThreadEntry, _ text: String) -> NSView {
        let mine = e.author.isYou
        let pill = AuthorPill(e.author, icon: e.author.agentBlock.flatMap(model.icon))
        pill.onClick = { [weak self] in
            guard let self, let b = e.author.agentBlock else { return }
            self.delegate?.threadChat(self, follow: MainWindowController.address(b))
        }
        if case let .you(machine) = e.author { pill.toolTip = machine.map { "From \($0)" } }
        let when = NSTextField(labelWithString: BlockSummary.ago(e.at, now: Date()) ?? "")
        when.font = UIType.footnote
        when.textColor = Theme.tertiaryText
        when.toolTip = DateFormatter.localizedString(from: e.at.date, dateStyle: .medium, timeStyle: .short)
        let meta = NSStackView(views: mine ? [when, pill] : [pill, when])
        meta.spacing = 6
        let body = BubbleText(markdown: text, mine: mine)
        body.onLink = { [weak self] url in
            guard let self else { return }
            self.delegate?.threadChat(self, follow: url.absoluteString)
        }
        let column = NSStackView(views: [meta, body])
        column.orientation = .vertical
        column.alignment = mine ? .trailing : .leading
        column.spacing = 3
        let line = NSStackView()
        line.orientation = .horizontal
        if mine { line.addArrangedSubview(NSView()) }
        line.addArrangedSubview(column)
        if !mine { line.addArrangedSubview(NSView()) }
        // At most most of the chat's width.
        let width = scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width - 24
        body.limit = max(160, floor(width * 0.86))
        return fill(line)
    }

    private func eventRow(_ words: String, at: Stamp? = nil, icon: NSImage? = nil, tone: NSColor? = nil) -> NSView {
        let label = NSTextField(labelWithString: words + (at.flatMap { BlockSummary.ago($0, now: Date()) }.map { " · " + $0 } ?? ""))
        label.font = UIType.footnote
        label.textColor = tone ?? Theme.tertiaryText
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
        let label = NSTextField(labelWithString: words)
        label.font = UIType.caption
        label.textColor = Theme.accent
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

    // MARK: The composer

    private func composerChanged() {
        let empty = composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !composer.string.isEmpty
        sendButton.isEnabled = !empty
        needsLayout = true
    }

    @objc private func sendClicked() { send() }

    private func send() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.string = ""
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

    private var composerHeight: CGFloat {
        guard let lm = composer.layoutManager, let tc = composer.textContainer else { return 30 }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + composer.textContainerInset.height * 2
        return min(max(30, ceil(h)), 120)
    }

    private var headerHeight: CGFloat {
        header.layoutSubtreeIfNeeded()
        return header.fittingSize.height
    }

    /// The height it wants, for a card.
    var wantedHeight: CGFloat {
        list.layoutSubtreeIfNeeded()
        let content = list.fittingSize.height
        return min(maxHeight, 12 + headerHeight + 8 + content + 8 + composerHeight + 8 + Flat.buttonHeight + 12)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = bounds.width - pad * 2
        var y = bounds.height - pad
        let hh = headerHeight
        header.frame = NSRect(x: pad, y: y - hh, width: w, height: hh)
        y -= hh + 8
        let buttons: CGFloat = Flat.buttonHeight
        sendButton.sizeToFit()
        resolveButton.sizeToFit()
        sendButton.frame = NSRect(x: bounds.width - pad - sendButton.frame.width, y: pad, width: sendButton.frame.width, height: buttons)
        resolveButton.frame = NSRect(x: pad, y: pad, width: resolveButton.frame.width, height: buttons)
        let ch = composerHeight
        composerScroll.frame = NSRect(x: pad, y: pad + buttons + 8, width: w, height: ch)
        composer.minSize = NSSize(width: w, height: ch)
        composer.frame.size.width = composerScroll.contentSize.width
        placeholder.sizeToFit()
        placeholder.frame.origin = NSPoint(x: pad + 9, y: composerScroll.frame.maxY - placeholder.frame.height - 6)
        let listBottom = composerScroll.frame.maxY + 8
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

/// Who wrote an entry, as a pill: You in plain ink; an agent with its mark
/// and its name, in the accent. Clicked (an agent's), its terminal.
final class AuthorPill: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let image = NSImageView()
    private let author: ThreadAuthor

    init(_ author: ThreadAuthor, icon: NSImage?) {
        self.author = author
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = UIType.caption
        label.stringValue = author.name
        image.image = icon ?? (author.agentBlock != nil ? NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) : nil)
        image.isHidden = image.image == nil
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        addSubview(label)
        themed { v in
            switch v.author {
            case .agent:
                v.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.16).cgColor
                v.label.textColor = Theme.accent
                v.image.contentTintColor = Theme.accent
            case .you:
                v.layer?.backgroundColor = Theme.text.withAlphaComponent(0.08).cgColor
                v.label.textColor = Theme.text
            case .manifold:
                v.layer?.backgroundColor = NSColor.clear.cgColor
                v.label.textColor = Theme.tertiaryText
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = label.intrinsicContentSize.width + 14 + (image.isHidden ? 0 : 14)
        return NSSize(width: ceil(w), height: 16)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 7
        if !image.isHidden {
            image.frame = NSRect(x: x, y: 2, width: 12, height: 12)
            x += 14
        }
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        if author.agentBlock != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// A comment's words, rendered as Markdown in a bubble; links clicked go
/// where they say.
final class BubbleText: NSView, NSTextViewDelegate {
    var onLink: ((URL) -> Void)?
    private let text = NSTextView()
    private let mine: Bool
    private let attributed: NSAttributedString

    init(markdown: String, mine: Bool) {
        self.mine = mine
        attributed = MarkdownText.attributed(markdown, font: UIType.body, code: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: Theme.text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textStorage?.setAttributedString(attributed)
        text.delegate = self
        text.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        addSubview(text)
        translatesAutoresizingMaskIntoConstraints = false
        themed { v in
            v.layer?.backgroundColor = (v.mine ? Theme.accent.withAlphaComponent(0.13) : Theme.text.withAlphaComponent(0.06)).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let pad = NSSize(width: 10, height: 6)

    /// Its size for a width at most `limit`: as narrow as its longest line.
    private func size(limit: CGFloat) -> NSSize {
        let inner = max(40, limit - Self.pad.width * 2)
        let r = attributed.boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(min(inner, r.width)) + Self.pad.width * 2 + 2, height: ceil(r.height) + Self.pad.height * 2)
    }

    var limit: CGFloat = 340 { didSet { if limit != oldValue { invalidateIntrinsicContentSize() } } }

    override var intrinsicContentSize: NSSize { size(limit: limit) }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        invalidateIntrinsicContentSize()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if let list = enclosingScrollView?.documentView, list.bounds.width > 0 { limit = floor(list.bounds.width * 0.86) }
    }

    override func layout() {
        super.layout()
        text.frame = bounds.insetBy(dx: Self.pad.width, dy: Self.pad.height)
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

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        let returnKey = event.keyCode == 36 || event.keyCode == 76
        if returnKey, event.modifierFlags.intersection([.shift, .option, .control]).isEmpty, !hasMarkedText() {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
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
