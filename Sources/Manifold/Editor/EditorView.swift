import AppKit
import ManifoldCore

protocol EditorViewDelegate: AnyObject {
    /// The editor appends to its block's log.
    func editor(_ view: EditorView, append events: [Event])
    /// A line was gone to and is in view (the pointer may follow).
    func editorDidReveal(_ view: EditorView)
    /// The editor asks the host for something (a save, a reload).
    func editor(_ view: EditorView, propose proposal: Proposal)
    /// An image put in the text (pasted, dropped, from an iPhone): kept as
    /// an image block, and shown where the caret is.
    func editor(_ view: EditorView, image data: Data, kind: String)
    /// A web address was ⌘-clicked.
    func editor(_ view: EditorView, open url: URL, over: Bool)
    /// A block was ⇧-dragged in as a link: linked to this one.
    func editor(_ view: EditorView, linkedFrom block: BlockID)
    /// A link in the text was clicked: a block's pill, or an address;
    /// with ⌥ (`over`), what opens goes over this tile.
    func editor(_ view: EditorView, follow target: String, over: Bool)
    /// The block's text, as the replica has it.
    func editorText(_ view: EditorView) -> TextState?
    /// The editor's text now differs from the file's, or no longer does.
    func editorEditedChanged(_ view: EditorView)
    /// What the block's language server says about it.
    func editorDiagnostics(_ view: EditorView) -> [Diagnostic]
    /// How the block's lines stand against what's committed.
    func editorGutter(_ view: EditorView) -> [GutterMark]
    /// The editor asks the block's language server something.
    func editor(_ view: EditorView, lsp request: LSPRequest, done: @escaping (LSPResult) -> Void)
    /// Opens another file at a line and column (from 1), beside this one.
    func editor(_ view: EditorView, open path: String, line: Int, column: Int, over: Bool)
    /// The places the language server says use `word`, as a block of them.
    func editor(_ view: EditorView, references places: [LSPLocation], of word: String)
    /// Applies a server's edits to files other than this one.
    func editor(_ view: EditorView, apply edits: [LSPFileEdit])
}

/// The editor lens on a text block: Manifold's own text view over the
/// block's rope (§7.1), in the theme's proportional or fixed-width font,
/// with a find bar, and a banner when the file changed on disk. Every edit
/// is an entry in the block's log, so unsaved changes, the selection and
/// the scroll position are all there again after a quit, and undo is more
/// entries.
final class EditorView: NSView, PaneContent, TextViewDocument, TextViewDelegate, NSMenuItemValidation {
    let placement: PlacementID
    let block: BlockID
    private(set) var path: String
    weak var delegate: EditorViewDelegate?

    let scroll = ClippingScrollView()
    let textView = TextView()
    private var banner: EditorBanner?
    private lazy var finder = FindHost(view: self, target: self)
    private var matches: [TextRange] = []
    private var isEdited = false
    private var stateWork: DispatchWorkItem?
    private var restored = false
    private var lastVersion = -1
    var completion: CompletionPopup?
    var hover: NSPopover?
    let status = NSTextField(labelWithString: "")
    let statusBox = NSView()
    var statusMessage: String? { didSet { if statusMessage != oldValue { layoutStatus() } } }
    /// Something the server is doing for us, shown while it lasts.
    var busyMessage: String? { didSet { if busyMessage != oldValue { layoutStatus() } } }
    /// The file's text not in yet: said so, over anything else.
    var loadingMessage: String? { didSet { if loadingMessage != oldValue { layoutStatus() } } }

    /// Whether the text is the file's (or a note's own): until it is,
    /// there's nothing to edit or save — typing into the empty page and
    /// saving would write it over the file.
    var isLoaded: Bool {
        guard let doc = document else { return false }
        return path.isEmpty || doc.diskFingerprint != nil || doc.unreadable || doc.version > 0
    }

    var font: EditorFont { didSet { if font != oldValue { applyFont() } } }
    var undoLimit = 0 { didSet { textView.undoLimit = undoLimit } }
    var theme: FontTheme { didSet { if theme != oldValue { applyFont() } } }
    private var sizeAdjust: CGFloat = 0

    var focusView: NSView { textView }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID, path: String, font: EditorFont, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.path = path
        self.font = font
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = ($0.viewing ? Theme.codePage : Theme.windowBackground).cgColor }

        scroll.drawsBackground = false
        // No room kept for the (hidden) title bar.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // The scroll bar is a scrubber (§3.1): down the right, outside
        // the text.
        scroll.hasVerticalScroller = false
        scroll.documentView = textView
        addSubview(scroll)
        scrubber.onScroll = { [weak self] f in
            guard let self else { return }
            let span = max(self.textView.frame.height - self.scroll.contentSize.height, 0)
            self.scroll(toY: f * span)
        }
        addSubview(scrubber)
        addSubview(note)
        // A heading chosen in the outline: the text there, the caret at it.
        headingsOutline.onPick = { [weak self] i in
            guard let self, self.headingLines.indices.contains(i) else { return }
            let line = self.headingLines[i]
            NavJumps.willJump?(self)
            self.scroll(toY: self.textView.top(ofLine: line) - 8)
            self.textView.setSelections([Selection(at: self.textView.text.offset(ofLine: line))], scroll: false)
            self.window?.makeFirstResponder(self.textView)
            self.headingsOutline.current = i
        }
        headingsOutline.block = block
        headingsOutline.placeFor = { [weak self] i in
            guard let self, self.headingLines.indices.contains(i) else { return nil }
            return "line=\(self.headingLines[i] + 1)"
        }
        headingsOutline.menuFor = { [weak self] i in
            guard let self, self.headingLines.indices.contains(i) else { return nil }
            return Drags.linkMenu("Copy Link to This Heading", self.block, "line=\(self.headingLines[i] + 1)")
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        textView.document = self
        textView.delegate = self
        textView.menuHost = block.host
        textView.menuPlacement = placement
        textView.autoresizingMask = [.width]
        textView.commentLeader = Self.commentLeader(for: path)
        textView.acceptsBlockLinks = path.isEmpty || Lens.isMarkdown(path)
        textView.markdown = hasOutline
        if hasOutline {
            textView.onImage = { [weak self] data, kind in
                guard let self else { return }
                self.delegate?.editor(self, image: data, kind: kind)
            }
        }
        textView.showsLineNumbers = !hasOutline
        textView.pillLook = { [weak self] id in self?.blockLook?(id) }
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = Theme.text
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        statusBox.wantsLayer = true
        statusBox.isHidden = true
        statusBox.addSubview(status)
        addSubview(statusBox)
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        documentChanged()
        watchCommandKey(window != nil)
    }

    // MARK: ⌘ links

    private var commandMonitor: Any?
    private var commandDown = false
    /// What the language server last said there's somewhere to go to, for
    /// a version of the text (nil ranges: it can't say).
    private var navigable: (version: Int, ranges: [TextRange]?)?
    private var askingNavigable = false
    /// When the server last couldn't say (not ready yet, say): asked again
    /// a moment later, not at every ⌘.
    private var navigableFailedAt: Date?

    /// While ⌘ is held over the editor, the names there's somewhere to go
    /// to (as the language server says) show as links, as go.dev's docs
    /// set them; the one under the pointer underlined. ⌘-click goes.
    private func watchCommandKey(_ on: Bool) {
        if let commandMonitor { NSEvent.removeMonitor(commandMonitor) }
        commandMonitor = nil
        guard on else { return }
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let down = event.modifierFlags.contains(.command) && self.pointerInside
            if down != self.commandDown {
                self.commandDown = down
                if down { self.showLinks() } else { self.textView.linkRanges = []; self.textView.hoveredLink = nil }
            } else if down {
                self.updateHoveredLink()
            }
            return event
        }
    }

    /// Debugging: ⌘ held over the editor (without the pointer), and the
    /// names shown as links once the server has answered.
    func debugLinks(keep: Bool = false) -> String {
        commandDown = true
        navigableFailedAt = nil
        showLinks()
        let deadline = Date().addingTimeInterval(8)
        while askingNavigable, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        let names = textView.linkRanges.map { String(textView.text[$0]) }
        if keep {
            // As if the pointer rested on the second link — with no server,
            // on a word, as the pointer's is taken then.
            if textView.linkRanges.count > 1 {
                textView.hoveredLink = textView.linkRanges[1]
            } else if textView.linkRanges.isEmpty {
                let word = textView.wordRange(at: 9)
                textView.linkRanges = word.isEmpty ? [] : [word]
                textView.hoveredLink = word.isEmpty ? nil : word
            }
        } else {
            commandDown = false
            textView.linkRanges = []
            textView.hoveredLink = nil
        }
        return navigable?.ranges == nil ? "no semantic tokens" : "\(names.count) links: " + names.prefix(30).joined(separator: " ")
    }

    private var pointerInside: Bool {
        guard let window, !path.isEmpty else { return false }
        return scroll.frame.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func showLinks() {
        guard let doc = document else { return }
        if let n = navigable, n.version == doc.version {
            textView.linkRanges = n.ranges ?? []
            updateHoveredLink()
            return
        }
        updateHoveredLink()
        guard !askingNavigable, navigableFailedAt.map({ Date().timeIntervalSince($0) > 2 }) ?? true else { return }
        askingNavigable = true
        let version = doc.version
        delegate?.editor(self, lsp: .navigable(block)) { [weak self] result in
            guard let self else { return }
            self.askingNavigable = false
            if case let .ranges(r) = result {
                self.navigable = (version, r.sorted { $0.start < $1.start })
                self.navigableFailedAt = nil
                if self.commandDown { self.showLinks() }
            } else {
                // Not cached: the server may be ready next time — asked
                // again in a moment if ⌘ is still held (a server just
                // started, still reading the project).
                self.navigableFailedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                    if let self, self.commandDown { self.showLinks() }
                }
            }
        }
    }

    /// The link under the pointer; with no word from the server, the word
    /// there (⌘-click asks the server where it goes).
    private func updateHoveredLink() {
        guard let window else { return }
        let p = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let offset = textView.offset(at: p)
        if let ranges = navigable?.ranges, navigable?.version == document?.version {
            textView.hoveredLink = ranges.first { $0.start <= offset && offset < $0.end }
        } else {
            let word = textView.wordRange(at: offset)
            textView.hoveredLink = word.isEmpty ? nil : word
            textView.linkRanges = word.isEmpty ? [] : [word]
        }
    }

    override func layout() {
        super.layout()
        var top = bounds.height
        if let banner {
            banner.frame = NSRect(x: 0, y: top - 34, width: bounds.width, height: 34)
            top -= 34
        }
        var bottom: CGFloat = 0
        if !statusBox.isHidden {
            statusBox.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.statusHeight)
            status.frame = NSRect(x: 10, y: 3, width: bounds.width - 20, height: Self.statusHeight - 6)
            bottom = Self.statusHeight
        }
        // The outline at the left, a third of the tile at most.
        var left: CGFloat = 0
        if let sidebar, !sidebar.isHidden {
            left = min(TileSidebar.width, (bounds.width / 3).rounded())
            sidebar.frame = NSRect(x: 0, y: bottom, width: left, height: top - bottom)
        }
        scroll.frame = NSRect(x: left, y: bottom, width: bounds.width - ScrubberView.width - left, height: top - bottom)
        note.frame = scroll.frame
        textView.frame.size.width = scroll.contentSize.width
        scrubber.frame = NSRect(x: bounds.width - ScrubberView.width, y: bottom, width: ScrubberView.width, height: top - bottom)
        updateScrubber()
        finder.layout(in: bounds)
        if let reveal = pendingReveal, window != nil, scroll.contentSize.height >= 1 {
            pendingReveal = nil
            DispatchQueue.main.async { [weak self] in self?.select(line: reveal.line, column: reveal.column) }
        }
    }

    static let statusHeight: CGFloat = 24

    // MARK: The scrubber (§3.1)

    private let scrubber = ScrubberView(frame: .zero)
    /// "Reading…" over the page until the file's text is in, so the empty
    /// page isn't taken for an empty file.
    private let note = BusyNote()
    /// Each heading's line (0-based), in the outline's order.
    private var headingLines: [Int] = []
    private var headingsWork: DispatchWorkItem?
    /// Whether the text has an outline: Markdown, or a note (its headings);
    /// a source file whose language server says what it declares.
    fileprivate var hasOutline: Bool { isMarkdownOutline || hasSymbols }
    private var isMarkdownOutline: Bool { path.isEmpty || Lens.isMarkdown(path) }
    /// The language server has answered with the file's symbols.
    private var hasSymbols = false

    @objc private func scrolled() {
        updateScrubber()
        markCurrentHeading()
    }

    // MARK: The outline (§7.5)

    /// A Markdown text's (a note's) headings — or a source file's types and
    /// functions, as its language server says — the one you're in marked:
    /// as ticks at the tile's upper right, and in the sidebar at its left.
    private let headingsOutline = Outline()
    var outline: Outline? { hasOutline ? headingsOutline : nil }
    private var sidebar: TileSidebar?
    /// Shown or put away: kept with the tile.
    var onToggleSidebar: ((Bool) -> Void)?
    var hasSidebar: Bool { hasOutline }
    var sidebarShown: Bool { sidebar?.isHidden == false }

    func toggleSidebar() {
        setSidebar(!sidebarShown)
        onToggleSidebar?(sidebarShown)
    }

    func setSidebar(_ shown: Bool) {
        guard hasOutline, shown != sidebarShown else { return }
        if shown, sidebar == nil {
            let s = TileSidebar(outline: headingsOutline)
            addSubview(s)
            sidebar = s
        }
        sidebar?.isHidden = !shown
        needsLayout = true
    }

    /// The last heading at or above the top of what shows.
    private func markCurrentHeading() {
        guard hasOutline else { return }
        let y = scroll.contentView.bounds.minY + 12
        headingsOutline.current = headingLines.lastIndex { textView.top(ofLine: $0) <= y } ?? (headingLines.isEmpty ? nil : 0)
    }

    var debugSidebar: String { sidebar.map { $0.isHidden ? "hidden" : $0.debugEntries } ?? "none" }
    func debugSidebarPick(_ i: Int) -> String { sidebar?.debugPick(i) ?? "none" }

    func debugType(_ text: String) { textView.insert(text) }
    func debugDrop(_ pb: NSPasteboard) -> Bool {
        textView.drop(pb, at: textView.convert(textView.caretRectInWindow(textView.primarySelection.head), from: nil).origin)
    }

    func debugScrub(_ what: String, _ arg: String) -> String {
        switch what {
        case "pick": headingsOutline.pick(Int(arg) ?? 0); return "picked"
        case "text": return String(textView.text.string.suffix(300))
        default: return "headings \(headingLines.count) offset \(Int(scroll.contentView.bounds.minY)) of \(Int(textView.frame.height))"
        }
    }

    private func scroll(toY y: CGFloat) {
        let most = max(textView.frame.height - scroll.contentSize.height, 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(y, 0), most)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The headings again, a moment after the text changed.
    private var headingsVersion = -2

    private func scheduleHeadings() {
        guard isMarkdownOutline || !path.isEmpty else { return }
        headingsWork?.cancel()
        // A language server is asked less often than headings are parsed.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isMarkdownOutline { self.findHeadings() } else { self.findSymbols() }
        }
        headingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isMarkdownOutline ? 0.3 : 0.8), execute: work)
    }

    /// A source file's symbols, as its language server says, once per
    /// version: its outline. No server (or none that answers), no outline.
    private func findSymbols() {
        let version = document?.version ?? -1
        guard isLoaded, version >= 0 else { return }
        guard version != headingsVersion else { return markCurrentHeading() }
        headingsVersion = version
        delegate?.editor(self, lsp: .symbols(block)) { [weak self] result in
            guard let self, self.document?.version == version else { return }
            guard case .symbols(let symbols) = result else { return }
            self.headingLines = symbols.map(\.line)
            self.headingsOutline.set(symbols.map { Outline.Item(title: $0.name, level: $0.level, detail: LSPSymbol.word($0.kind), code: true) })
            if !self.hasSymbols {
                // An outline now: its ticks and the sidebar's button.
                self.hasSymbols = true
                self.delegate?.editorEditedChanged(self)
            }
            self.markCurrentHeading()
        }
    }

    private func findHeadings() {
        // Not again for a text as it was (every render came here, and a
        // selection's change: the whole text parsed each time).
        let version = document?.version ?? -1
        guard version != headingsVersion || version < 0 else { return markCurrentHeading() }
        headingsVersion = version
        let found = MarkdownOutline.headings(in: textView.text.string)
        headingLines = found.map(\.line)
        headingsOutline.set(Outline.headings(found.map { (title: $0.text, level: $0.level) }))
        markCurrentHeading()
    }

    private func updateScrubber() {
        scrubber.update(total: Double(textView.frame.height), offset: Double(scroll.contentView.bounds.minY),
                        shown: Double(scroll.contentSize.height))
    }

    func destroy() {
        watchCommandKey(false)
        // Where it was left, kept as the tile goes, for when it's made again.
        if restored { saveState() }
        stateWork?.cancel()
        completion?.close()
        hover?.close()
    }

    // MARK: TextViewDocument

    private var document: TextState? { delegate?.editorText(self) }

    var rope: Rope { document?.text ?? Rope() }
    var version: Int { document?.version ?? 0 }

    func apply(_ edits: [TextEdit]) {
        delegate?.editor(self, append: [.edit(edits)])
    }

    /// The block's log moved: the view catches up, and the first time, the
    /// selection and scroll position come back.
    func documentChanged() {
        guard let doc = document else { return }
        let external = doc.version != lastVersion && doc.version != textView.undoKnownVersion
        let versionChanged = doc.version != lastVersion
        lastVersion = doc.version
        textView.documentChanged()
        scheduleHeadings()
        if !restored, doc.version > 0 || doc.unreadable {
            restored = true
            // This tile's own, else where the text was last left in any editor.
            if let ranges = doc.selections[placement] ?? doc.selections[Self.lastPlacement], !ranges.isEmpty {
                textView.setSelections(ranges.map { Selection($0.start, $0.end) }, scroll: false)
            }
            if let y = doc.scroll[placement] ?? doc.scroll[Self.lastPlacement] {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            }
            // A line asked for before the text was in (the other mode's top).
            if let line = pendingTopLine {
                pendingTopLine = nil
                DispatchQueue.main.async { [weak self] in self?.scroll(toTopLine: line) }
            }
        }
        if external { textView.savedUndoDepth = textView.undoDepth }
        textView.isEditable = !doc.unreadable && !offline && !viewing && isLoaded
        loadingMessage = isLoaded ? nil : "Reading the file…"
        note.set(isLoaded ? .idle : .busy("Reading…"))
        if doc.stale, banner == nil { showBanner() }
        if !doc.stale, banner != nil { hideBanner() }
        if doc.isDirty != isEdited {
            isEdited = doc.isDirty
            delegate?.editorEditedChanged(self)
        }
        // The find pill's matches again only when the text changed (every
        // render came here, a keystroke's too).
        if versionChanged { scheduleMatchRefresh() }
        diagnosticsChanged()
        gutterChanged()
    }

    /// The host redid the block's git gutter.
    func gutterChanged() {
        let marks = delegate?.editorGutter(self) ?? []
        if marks != textView.gutterMarks { textView.gutterMarks = marks }
    }

    /// The language server said something new about the block.
    func diagnosticsChanged() {
        let items = delegate?.editorDiagnostics(self) ?? []
        if items != textView.diagnostics { textView.diagnostics = items }
        updateStatus()
    }

    var isDirty: Bool { document?.isDirty == true }

    /// Where a text's selection and scroll were last left in any editor,
    /// kept beside each tile's own (as a placement of its own).
    static let lastPlacement: PlacementID = "last:text"

    /// View mode (⌘↩ to edit): the text as it is, not taken in, on the
    /// grey of a page of code.
    var viewing = false {
        didSet {
            guard viewing != oldValue else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = (viewing ? Theme.codePage : Theme.windowBackground).cgColor
            }
            // As go.dev sets its code: its text and line numbers' colors.
            textView.textColor = viewing ? Theme.codeText : Theme.text
            textView.gutterColor = viewing ? Theme.codeLineNumber : TextView.gutterText
            applyFont()
            documentChanged()
        }
    }

    /// The line at the top of the view (from 0, a fraction into it).
    var topLine: Double {
        isLoaded ? textView.fractionalLine(atY: scroll.contentView.bounds.minY) : pendingTopLine ?? 0
    }

    /// The view scrolled so `line` (as `topLine` gives) is at the top: at
    /// once, or once the text is in.
    func scroll(toTopLine line: Double) {
        guard isLoaded, restored else { pendingTopLine = line; return }
        scroll(toY: textView.y(ofFractionalLine: line))
    }

    private var pendingTopLine: Double?
    /// The caret's line, trimmed: what a link made from here was made on.
    /// Markdown shown richly (notes, .md files) — or as written, as the
    /// pill's menu chooses; kept with the placement's view state.
    var richMarkdown = true {
        didSet {
            textView.markdown = hasOutline && richMarkdown
            // Rich, a note has no line numbers: it's prose.
            textView.showsLineNumbers = !(hasOutline && richMarkdown)
        }
    }
    /// A block's look for its pill in the text, from whoever knows blocks.
    var blockLook: ((BlockID) -> PillLook?)?
    /// The blocks' looks may have changed: pills drawn with old ones are redrawn.
    func refreshPills() { textView.refreshPills() }
    var onToggleMarkdown: ((_ rich: Bool) -> Void)?

    /// The font switched from the pill's menu: this tile's, kept with its view state.
    var onToggleFont: ((EditorFont) -> Void)?

    var pillItems: [NSMenuItem] {
        var items: [NSMenuItem] = []
        if hasOutline {
            items.append(ClosureMenuItem(richMarkdown ? "Show Raw Markdown" : "Show Formatted", symbol: richMarkdown ? "textformat.abc" : "text.alignleft") { [weak self] in
                guard let self else { return }
                self.richMarkdown.toggle()
                self.onToggleMarkdown?(self.richMarkdown)
            })
        }
        // The other kind of font than the one in use, for this tile.
        let other: EditorFont = font == .monospaced ? .proportional : .monospaced
        items.append(ClosureMenuItem(other == .monospaced ? "Fixed-Width Font" : "Variable-Width Font", symbol: other == .monospaced ? "textformat.123" : "textformat") { [weak self] in
            guard let self else { return }
            self.font = other
            self.onToggleFont?(other)
        })
        return items
    }

    /// The block's host can't be reached (§8): read, not written.
    var offline = false {
        didSet { if offline != oldValue { textView.isEditable = !offline && document?.unreadable != true } }
    }

    var lineAtCaret: String {
        let text = textView.text
        guard text.lineCount > 0 else { return "" }
        return String(text.lineText(text.line(at: textView.primarySelection.head)).trimmingCharacters(in: .whitespaces).prefix(200))
    }

    // MARK: TextViewDelegate

    func textViewDidChangeSelection(_ view: TextView) {
        if view.selections.contains(where: { !$0.isCaret }) { NotificationCenter.default.post(name: .manifoldSelectionMade, object: self) }
        scheduleHeadings()
        scheduleStateSave()
        updateStatus()
        hover?.close()
    }

    func textViewDidScroll(_ view: TextView) {
        scheduleStateSave()
        completion?.close()
        hover?.close()
    }

    func textViewDidEdit(_ view: TextView) {
        // Undone back to what was saved: clean again, as the log sees it.
        if let doc = document, doc.isDirty, textView.undoDepth == textView.savedUndoDepth, !path.isEmpty, doc.cleanVersion > 0 {
            delegate?.editor(self, append: [.clean(version: doc.version, fingerprint: nil)])
        }
        scheduleStateSave()
        scheduleMatchRefresh()
        completionTextChanged()
    }

    /// The find pill's matches found again after an edit — a moment after
    /// typing stops, not at each key (the whole text gone through), and
    /// the caret left where it is (it was thrown onto a match).
    private func scheduleMatchRefresh() {
        matchRefresh?.cancel()
        guard !matches.isEmpty || textView.highlights.count > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rehighlighting = true
            self.finder.refresh()
            self.rehighlighting = false
        }
        matchRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private var matchRefresh: DispatchWorkItem?
    private var rehighlighting = false

    // MARK: Fonts

    private var textFont: NSFont {
        // Viewed, set as go.dev sets code — at its 0.83rem — in the theme's code face.
        if viewing { return theme.font(.monospaced, size: max(8, 13.3 + sizeAdjust)) }
        return theme.font(font, size: max(8, theme.editorSize(font) + sizeAdjust))
    }

    private func applyFont() {
        textView.font = textFont
        textView.codeFont = theme.font(.monospaced, size: max(8, theme.editorSize(.monospaced) + sizeAdjust - 1))
        // Viewed, set as go.dev sets code: lines at 1.4.
        textView.lineHeightMultiple = viewing ? 1.4 : font == .proportional ? 1.25 : 1.2
    }

    @objc func increaseFontSize(_ sender: Any?) { sizeAdjust += 1; applyFont() }
    @objc func decreaseFontSize(_ sender: Any?) { sizeAdjust -= 1; applyFont() }
    @objc func resetFontSize(_ sender: Any?) { sizeAdjust = 0; applyFont() }

    static func commentLeader(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "sh", "zsh", "bash", "rb", "yaml", "yml", "toml", "pl", "r", "conf", "cfg", "ini", "zig", "nix", "make", "mk", "dockerfile", "gitignore": "#"
        case "lua", "sql", "hs", "elm": "--"
        case "lisp", "el", "clj", "scm": ";"
        case "tex": "%"
        case "vim": "\""
        default: "//"
        }
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = document, !doc.unreadable else { return }
        if path.isEmpty { return saveAs() }
        // Never a text that isn't the file's over the file.
        guard isLoaded else { return NSSound.beep() }
        textView.savedUndoDepth = textView.undoDepth
        delegate?.editor(self, propose: .writeFile(block, version: doc.version))
    }

    /// Where the block lives (its folder): where a note is saved by default.
    var home: String?
    /// A note's name, if it has been given one: what it's saved as.
    var noteName: String?
    private var saveName: String {
        guard let n = noteName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "Note.md" }
        let safe = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (safe as NSString).pathExtension.isEmpty ? safe + ".md" : safe
    }
    /// On another host: the Mac's save panel can't browse there, so a
    /// note is saved by naming a path on the host.
    var isRemote = false

    /// The line the caret is on, from 1.
    var caretLine: Int { textView.text.line(at: textView.primarySelection.head) + 1 }

    /// The caret, while the editor has the keyboard.
    var caretRectInWindow: NSRect? {
        guard window?.firstResponder === textView else { return nil }
        return textView.caretRectInWindow(textView.primarySelection.head)
    }

    /// A note, saved: it becomes a file.
    private func saveAs() {
        guard let window else { return }
        if isRemote {
            let alert = NSAlert()
            alert.messageText = "Save the note on its host"
            alert.informativeText = "The path to save it at, on the host it's on."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.stringValue = (home ?? "~").appendingPathComponent(saveName)
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn, let doc = self.document else { return }
                let path = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return }
                self.path = path
                self.textView.commentLeader = Self.commentLeader(for: path)
                // Its file's name names it now.
                self.delegate?.editor(self, append: [.path(path)] + (self.noteName == nil ? [] : [.title(nil)]))
                self.delegate?.editor(self, propose: .writeFile(self.block, version: doc.version))
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = saveName
        if let home { panel.directoryURL = URL(fileURLWithPath: home) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let doc = self.document else { return }
            self.path = url.path
            self.textView.commentLeader = Self.commentLeader(for: url.path)
            self.delegate?.editor(self, append: [.path(url.path)] + (self.noteName == nil ? [] : [.title(nil)]))
            self.delegate?.editor(self, propose: .writeFile(self.block, version: doc.version))
        }
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard !path.isEmpty else { return }
        delegate?.editor(self, propose: .readFile(block))
    }

    private func showBanner() {
        guard banner == nil else { return }
        let b = EditorBanner(message: "This file changed on disk.")
        b.onReload = { [weak self] in self?.revertDocumentToSaved(nil) }
        b.onKeep = { [weak self] in
            guard let self else { return }
            // Keep the edits, against what's on disk now.
            self.delegate?.editor(self, append: [.stale(false)])
        }
        addSubview(b)
        banner = b
        needsLayout = true
    }

    private func hideBanner() {
        banner?.removeFromSuperview()
        banner = nil
        needsLayout = true
    }

    // MARK: Kept state

    private func scheduleStateSave() {
        guard restored else { return }
        stateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        stateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveState() {
        stateWork?.cancel()
        guard let doc = document else { return }
        let ranges = textView.selections.map { $0.range }
        var events: [Event] = []
        // This tile's, and the text's last, for a tile made for it again.
        for p in [placement, Self.lastPlacement] where doc.selections[p] != ranges { events.append(.selection(placement: p, ranges: ranges)) }
        let y = Double(scroll.contentView.bounds.origin.y)
        for p in [placement, Self.lastPlacement] where abs((doc.scroll[p] ?? -1) - y) > 0.5 { events.append(.scroll(placement: p, y: y)) }
        if !events.isEmpty { delegate?.editor(self, append: events) }
    }

    // MARK: Find

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    private func hideFind() { finder.hide() }

    /// Debugging: the find pill shown, its field typed in, for `query`.
    func debugFind(_ query: String) {
        finder.show(fromSelection: false)
        finder.pill?.query = query
    }

    // MARK: Go to line

    @objc func goToLine(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), line > 0 else { return }
            self.select(line: line)
        }
    }

    /// Goes to a line (from 1): selects it, or, given a column (from 1),
    /// puts the caret there.
    /// A line gone to, selected and scrolled into view; before the editor
    /// is laid out, kept until it is.
    func select(line: Int, column: Int? = nil) {
        NavJumps.willJump?(self)
        let r = textView.offset(line: line, column: column)
        textView.setSelections([Selection(r.start, r.end)])
        textView.highlightedLine = line - 1
        window?.makeFirstResponder(textView)
        if window == nil || scroll.contentSize.height < 1 {
            pendingReveal = (line, column)
        } else {
            pendingReveal = nil
            delegate?.editorDidReveal(self)
        }
    }

    private var pendingReveal: (line: Int, column: Int?)?

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)):
            return isDirty || path.isEmpty
        case #selector(revertDocumentToSaved(_:)):
            return (isDirty || banner != nil) && !path.isEmpty
        case #selector(goToDefinition(_:)), #selector(findReferences(_:)), #selector(showDocumentation(_:)),
             #selector(renameSymbol(_:)), #selector(formatDocument(_:)), #selector(completeSymbol(_:)):
            return !path.isEmpty
        default:
            return true
        }
    }
}

extension TextView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo
        case #selector(redo(_:)): return canRedo
        case #selector(cut(_:)), #selector(copy(_:)): return hasSelectedText
        // Whether there's text to paste, not the text itself read out.
        case #selector(paste(_:)): return isEditable && NSPasteboard.general.availableType(from: [.string]) != nil
        default: return true
        }
    }
}

/// The find bar: a field, the next and previous matches, and, shown with
/// ⌥⌘F, a field to replace them with.
extension EditorView: Replaceable {
    /// Every match highlighted, the first from the selection's start
    /// selected.
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        matches = query.isEmpty ? [] : textView.text.findAll(query, caseInsensitive: !caseSensitive, limit: 20_000)
        textView.highlights = matches
        if !matches.isEmpty, !rehighlighting {
            let from = textView.primarySelection.min
            if let m = matches.first(where: { $0.start >= from }) ?? matches.first { textView.setSelections([Selection(m.start, m.end)]) }
        }
        done(query.isEmpty ? nil : matches.count)
    }

    /// The next (or previous) match from the selection, around the ends.
    func findNext(forward: Bool) {
        guard !matches.isEmpty else { return }
        let sel = textView.primarySelection
        let match: TextRange?
        if forward {
            match = matches.first { $0.start >= sel.max && !($0.start == sel.min && $0.end == sel.max) } ?? matches.first
        } else {
            match = matches.last { $0.start < sel.min } ?? matches.last
        }
        if let match { textView.setSelections([Selection(match.start, match.end)]) }
    }

    func endSearch() {
        matches = []
        textView.highlights = []
        needsLayout = true
        window?.makeFirstResponder(textView)
    }

    /// The selection, or the word at the caret.
    func textForFind(_ done: @escaping (String?) -> Void) {
        let sel = textView.selectedText
        if !sel.isEmpty { return done(sel) }
        let r = textView.wordRange(at: textView.primarySelection.min)
        done(r.end > r.start ? textView.text[r] : nil)
    }

    func replaceCurrent(with text: String) {
        let sel = textView.primarySelection
        if matches.contains(where: { $0.start == sel.min && $0.end == sel.max }) {
            textView.replace([(sel.range, text)])
        }
        findNext(forward: true)
    }

    func replaceAll(with text: String) {
        guard !matches.isEmpty else { return }
        textView.replace(matches.map { ($0, text) })
    }
}

/// A bar across the top of an editor, for a file changed on disk.
final class EditorBanner: NSView {
    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?
    private let label: NSTextField
    private let reload: FlatButton
    private let keep: FlatButton

    init(message: String) {
        label = NSTextField(labelWithString: message)
        reload = FlatButton("Reload")
        keep = FlatButton("Keep Mine")
        super.init(frame: .zero)
        wantsLayer = true
        themed {
            $0.layer?.backgroundColor = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 1),
                                                        NSColor(srgbRed: 0.27, green: 0.24, blue: 0.13, alpha: 1)).cgColor
        }
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = Theme.text
        for b in [reload, keep] { b.target = self }
        reload.action = #selector(reloadClicked)
        keep.action = #selector(keepClicked)
        for v in [label, reload, keep] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        label.frame = NSRect(x: 26, y: (h - 16) / 2, width: bounds.width - 240, height: 16)
        keep.sizeToFit()
        reload.sizeToFit()
        keep.frame.origin = NSPoint(x: bounds.width - 16 - keep.frame.width, y: (h - keep.frame.height) / 2)
        reload.frame.origin = NSPoint(x: keep.frame.minX - 6 - reload.frame.width, y: (h - reload.frame.height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeep?() }
}

extension EditorView: Printable {
    /// The text as it is, in the code font (a note's too: its Markdown).
    func printOperation() -> NSPrintOperation? {
        TextPrint.operation(textView.text.string, title: path.isEmpty ? "Note" : path.abbreviatingHome, font: hasOutline ? .systemFont(ofSize: 10.5) : TextPrint.codeFont)
    }
}

extension EditorView {
    /// The caret's line (from 1).
    var navLocation: NavLocation? { .line(textView.text.line(at: textView.primarySelection.head) + 1) }

    func go(to location: NavLocation) {
        if case let .line(n) = location { select(line: n, column: nil) }
    }
}

extension EditorView {
    func maniSelection() async -> ManiSelected? {
        let text = textView.selectedText
        guard !text.isEmpty, let sel = textView.selections.first(where: { !$0.isCaret }) else { return nil }
        let rope = textView.text
        let first = rope.line(at: sel.min) + 1, last = rope.line(at: max(sel.max - 1, sel.min)) + 1
        return ManiSelected(text: text, lines: first...last)
    }
}
