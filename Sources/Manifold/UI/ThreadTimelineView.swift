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
    /// A link in a comment, or an agent's pill, followed.
    func timeline(_ view: ThreadTimelineView, follow address: String)
    /// The scope or filter changed: shown again.
    func timelineChanged(_ view: ThreadTimelineView)
    /// What it shows was on screen a moment: seen.
    func timeline(_ view: ThreadTimelineView, seen threads: [BlockID])
    func timeline(_ view: ThreadTimelineView, dropped: Dragged, done: @escaping (String?) -> Void)
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

/// What a timeline shows.
struct TimelineModel {
    var title = ""
    /// The scopes there are (a space, its project), and which is shown.
    var scopes: [String] = ["Space"]
    var scope = 0
    var runs: [TimelineRun] = []
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
    enum Filter: Int { case all, open, unread }
    weak var delegate: ThreadTimelineDelegate?
    private(set) var model = TimelineModel()
    var filter: Filter = .all
    /// The thread the composer replies to.
    private(set) var chosen: BlockID?
    /// What had been seen of each thread when it was first shown: the New
    /// rule stays where it was while it's open, as Quip's does.
    var marksWhenOpened: [BlockID: Stamp]?
    /// The space it's of.
    var space: BlockID?

    private let titleLabel = NSTextField(labelWithString: "")
    private let scopeControl = NSSegmentedControl()
    private let filterControl = NSSegmentedControl(labels: ["All", "Open", "Unread"], trackingMode: .selectOne, target: nil, action: nil)
    private let readAll = FlatButton("Mark All Read", font: UIType.detail)
    private let handOver = FlatButton("Hand to Agent", symbol: "sparkle", font: UIType.detail)
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let replyingTo = NSTextField(labelWithString: "")
    private let clearReply = IconButton(symbol: "xmark", size: 9, target: nil, action: nil)
    private let composerScroll = NSScrollView()
    let composer = ComposerTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private var seenTimer: Timer?
    private var runViews: [BlockID: NSView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = UIType.title
        titleLabel.lineBreakMode = .byTruncatingTail
        scopeControl.segmentStyle = .rounded
        scopeControl.controlSize = .small
        scopeControl.target = self
        scopeControl.action = #selector(scopeChosen)
        filterControl.segmentStyle = .rounded
        filterControl.controlSize = .small
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChosen)
        readAll.target = self
        readAll.action = #selector(markAllRead)
        handOver.toolTip = "Ask an agent to address the open threads shown"
        handOver.onClick = { [weak self] in
            guard let self else { return }
            var seen = Set<BlockID>()
            let open = self.model.runs.map(\.thread).filter { $0.thread?.resolved != true && seen.insert($0.id).inserted }.map(\.id)
            self.delegate?.timeline(self, address: open)
        }
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
        replyingTo.font = UIType.footnote
        replyingTo.textColor = Theme.secondaryText
        replyingTo.lineBreakMode = .byTruncatingTail
        clearReply.target = self
        clearReply.action = #selector(unchoose)
        composer.font = UIType.body
        composer.isRichText = false
        composer.allowsUndo = true
        composer.drawsBackground = false
        composer.textContainerInset = NSSize(width: 4, height: 5)
        composer.isVerticallyResizable = true
        composer.textContainer?.widthTracksTextView = true
        composer.onSend = { [weak self] in self?.send() }
        composer.onChange = { [weak self] in self?.placeholder.isHidden = !(self?.composer.string.isEmpty ?? true) }
        composer.onDrop = { [weak self] dragged, done in
            guard let self, let d = self.delegate else { return done(nil) }
            d.timeline(self, dropped: dragged, done: done)
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
        for v in [titleLabel, scopeControl, filterControl, readAll, handOver, scroll, empty, replyingTo, clearReply, composerScroll, placeholder] as [NSView] { addSubview(v) }
        themed { v in
            v.composerScroll.layer?.borderColor = Theme.divider.cgColor
            v.composerScroll.layer?.backgroundColor = Theme.windowBackground.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { seenTimer?.invalidate() }

    // MARK: Showing

    func show(_ m: TimelineModel) {
        let atEnd = scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 4
        let first = model.runs.isEmpty
        model = m
        titleLabel.stringValue = m.title
        scopeControl.segmentCount = m.scopes.count
        for (i, s) in m.scopes.enumerated() {
            scopeControl.setLabel(s, forSegment: i)
            scopeControl.setWidth(0, forSegment: i)
        }
        scopeControl.selectedSegment = m.scope
        scopeControl.isHidden = m.scopes.count < 2
        handOver.isEnabled = m.runs.contains { $0.thread.thread?.resolved != true }
        readAll.isEnabled = m.unseen > 0
        readAll.title = m.unseen > 0 ? "Mark All Read (\(m.unseen))" : "All Read"
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runViews = [:]
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
        empty.stringValue = filter == .unread ? "Nothing unread." : "No threads yet. Select something and press ⌥⌘M to start one, or write below to start one about the space."
        if let c = chosen, !m.runs.contains(where: { $0.thread.id == c }) { chosen = nil }
        updateReplying()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if first || atEnd { scrollToEnd() }
        watchSeen()
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
            guard let self, let w = self.window, w.isVisible, !self.isHiddenOrHasHiddenAncestor else { return }
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
        let reply = FlatButton(chosen == run.thread.id ? "Replying" : "Reply", font: UIType.footnote)
        let resolve = FlatButton(resolved ? "Reopen" : "Resolve", font: UIType.footnote)
        let head = NSStackView(views: [place, NSView(), reply, resolve])
        head.spacing = 6
        let id = run.thread.id
        reply.onClick = { [weak self] in self?.choose(id) }
        resolve.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.timeline(self, resolve: !resolved, id)
        }
        let column = NSStackView(views: [head])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        head.translatesAutoresizingMaskIntoConstraints = false
        for (i, e) in run.entries.enumerated() {
            if i == ruleAt { column.addArrangedSubview(rule()) }
            column.addArrangedSubview(entryView(e))
        }
        let box = RunBox(column, chosen: chosen == id, resolved: resolved)
        box.onClick = { [weak self] in self?.choose(id) }
        return box
    }

    private func entryView(_ e: ThreadEntry) -> NSView {
        let when = BlockSummary.ago(e.at, now: Date()) ?? ""
        switch e.kind {
        case .comment(let text):
            let pill = AuthorPill(e.author, icon: e.author.agentBlock.flatMap(model.icon))
            pill.onClick = { [weak self] in
                guard let self, let b = e.author.agentBlock else { return }
                self.delegate?.timeline(self, follow: MainWindowController.address(b))
            }
            let time = NSTextField(labelWithString: when)
            time.font = UIType.footnote
            time.textColor = Theme.tertiaryText
            let body = BubbleText(markdown: text, mine: e.author.isYou)
            body.limit = max(200, (scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width) - 60)
            body.onLink = { [weak self] url in
                guard let self else { return }
                self.delegate?.timeline(self, follow: url.absoluteString)
            }
            let meta = NSStackView(views: [pill, time])
            meta.spacing = 6
            let v = NSStackView(views: [meta, body])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 3
            return v
        default:
            let who = e.author.isYou ? "you" : e.author.name
            let words: String
            switch e.kind {
            case .resolved: words = "Resolved by \(who)"
            case .reopened: words = "Reopened by \(who)"
            case let .asked(_, name): words = "\(name) asked to look"
            case let .edited(added, removed): words = "Edited by \(who) (+\(added) −\(removed))"
            case .gone: words = "Its lines were deleted"
            case .stopped(let why): words = why
            case .comment: words = ""
            }
            let label = NSTextField(labelWithString: words + " · " + when)
            label.font = UIType.footnote
            label.textColor = Theme.tertiaryText
            return label
        }
    }

    private func rule() -> NSView {
        let label = NSTextField(labelWithString: "New")
        label.font = UIType.caption
        label.textColor = Theme.accent
        let left = HairlineView(), right = HairlineView()
        let line = NSStackView(views: [left, label, right])
        line.spacing = 6
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
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
            replyingTo.stringValue = model.composesNew ? "A new thread about the space" : "Choose a thread to reply to"
            clearReply.isHidden = true
            placeholder.stringValue = model.composesNew ? "Start a thread… (@claude asks an agent)" : "Reply…"
        }
        composer.isEditable = chosen != nil || model.composesNew
        placeholder.isHidden = !composer.string.isEmpty
    }

    private func send() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, chosen != nil || model.composesNew else { return }
        composer.string = ""
        placeholder.isHidden = false
        delegate?.timeline(self, send: text, to: chosen)
    }

    @objc private func scopeChosen() {
        model.scope = scopeControl.selectedSegment
        chosen = nil
        delegate?.timelineChanged(self)
    }

    @objc private func filterChosen() {
        filter = Filter(rawValue: filterControl.selectedSegment) ?? .all
        delegate?.timelineChanged(self)
    }

    @objc private func markAllRead() {
        delegate?.timeline(self, seen: model.runs.map(\.thread.id))
    }

    func focusComposer() { window?.makeFirstResponder(composer) }

    func debugScope(_ i: Int) {
        guard i >= 0, i < scopeControl.segmentCount else { return }
        scopeControl.selectedSegment = i
        scopeChosen()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = bounds.width - pad * 2
        var y = bounds.height - pad
        let rowH: CGFloat = 22
        readAll.sizeToFit()
        filterControl.sizeToFit()
        scopeControl.sizeToFit()
        readAll.frame = NSRect(x: bounds.width - pad - readAll.frame.width, y: y - rowH, width: readAll.frame.width, height: rowH)
        filterControl.frame = NSRect(x: readAll.frame.minX - 8 - filterControl.frame.width, y: y - rowH, width: filterControl.frame.width, height: rowH)
        let scopeW = scopeControl.isHidden ? 0 : scopeControl.frame.width
        scopeControl.frame = NSRect(x: filterControl.frame.minX - 8 - scopeW, y: y - rowH, width: scopeW, height: rowH)
        let titleRight = (scopeControl.isHidden ? filterControl.frame.minX : scopeControl.frame.minX) - 8
        titleLabel.frame = NSRect(x: pad, y: y - rowH + 2, width: max(0, titleRight - pad), height: 18)
        y -= rowH + 8
        let ch: CGFloat = {
            guard let lm = composer.layoutManager, let tc = composer.textContainer else { return 30 }
            lm.ensureLayout(for: tc)
            return min(max(30, ceil(lm.usedRect(for: tc).height + 10)), 120)
        }()
        composerScroll.frame = NSRect(x: pad, y: pad, width: w, height: ch)
        composer.minSize = NSSize(width: w, height: ch)
        composer.frame.size.width = composerScroll.contentSize.width
        placeholder.sizeToFit()
        placeholder.frame.origin = NSPoint(x: pad + 9, y: composerScroll.frame.maxY - placeholder.frame.height - 6)
        replyingTo.frame = NSRect(x: pad, y: composerScroll.frame.maxY + 4, width: w - 20, height: 16)
        clearReply.frame = NSRect(x: pad + min(w - 20, replyingTo.intrinsicContentSize.width) + 4, y: composerScroll.frame.maxY + 4, width: 16, height: 16)
        handOver.sizeToFit()
        handOver.frame = NSRect(x: bounds.width - pad - handOver.frame.width, y: composerScroll.frame.maxY + 2, width: handOver.frame.width, height: 20)
        replyingTo.frame.size.width = max(0, handOver.frame.minX - pad - 8)
        let bottom = replyingTo.frame.maxY + 6
        scroll.frame = NSRect(x: pad, y: bottom, width: w, height: max(0, y - bottom))
        empty.frame = NSRect(x: pad + 20, y: scroll.frame.midY - 30, width: w - 40, height: 60)
    }
}

/// A run's box: tinted when chosen, quieter when resolved; clicked, chosen.
final class RunBox: NSView {
    var onClick: (() -> Void)?
    private let chosen: Bool
    private let resolved: Bool

    init(_ content: NSView, chosen: Bool, resolved: Bool) {
        self.chosen = chosen
        self.resolved = resolved
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        alphaValue = resolved && !chosen ? 0.72 : 1
        themed { v in
            v.layer?.backgroundColor = (v.chosen ? Theme.accent.withAlphaComponent(0.12) : Theme.text.withAlphaComponent(0.035)).cgColor
            v.layer?.borderColor = (v.chosen ? Theme.accent.withAlphaComponent(0.6) : NSColor.clear).cgColor
            v.layer?.borderWidth = v.chosen ? 1 : 0
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Words that go somewhere, clicked: a symbol before them.
final class LinkLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let image = NSImageView()
    private let action: () -> Void

    init(_ words: String, symbol: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        label.stringValue = words
        label.font = UIType.caption
        label.lineBreakMode = .byTruncatingMiddle
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
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
            v.label.textColor = Theme.secondaryText
            v.image.contentTintColor = Theme.accent
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
