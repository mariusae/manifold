import AppKit
import ManifoldCore

/// A note edited as an outline, in the manner of Bike 2 — Weft's Mac
/// editor (prism's `NoteEditorView`), ported to plain AppKit.
///
/// The view is a view of a note the engine holds open — a `NoteEditor`,
/// which *is* the note. It shows what the engine projects of it (each
/// row's words, never Markdown), hands back every change made in it, and
/// does what the engine answers: what was typed goes to `replace`, what
/// was asked for (a key, a click on a handle) to `perform`, and the text,
/// the caret and the look are then made what the engine says. It keeps no
/// note of its own and knows no Markdown. The app gives it a face, says
/// what Manifold's links are called, and is told when the note changed,
/// when a link was followed, when rows were folded and when the row
/// focused on changed.
public final class OutlinerView: NSView, NSTextViewDelegate {
    /// The note.
    public private(set) var editor: NoteEditor
    /// The face, size and colours text is set in.
    public var theme: OutlinerTheme { didSet { restyle() } }
    /// Whether the note is shown as prose: its top-level rows as
    /// paragraphs — flush, apart, with no handle — what is under them as
    /// an outline still. Only the look, and how rows made at the top are
    /// written.
    public var isProse = false {
        didSet {
            guard isProse != oldValue else { return }
            editor.setProse(isProse)
            restyle()
        }
    }

    // MARK: What the app is told, and asked

    /// The note changed: its Markdown, as it now is.
    public var onChange: ((String) -> Void)?
    /// A link clicked: its address as written — Manifold's own
    /// (`manifold:host/id`) and the web's alike; a page's as `[[name]]`, a
    /// tag as `#name`.
    public var onFollow: ((String) -> Void)?
    /// The row focused on changed (⌥⌘→, ⌥⌘←, `focus`): `editor.focusTrail`
    /// and `focusLabel` say where the view now is.
    public var onFocusChanged: (() -> Void)?
    /// The caret came into the note (true) or left it.
    public var onEditingChanged: ((Bool) -> Void)?
    /// The rows folded changed: a row was folded or unfolded, or the note
    /// changed around one. The app keeps them; they are no part of the note.
    public var onFolds: (([FoldedRow]) -> Void)?
    /// A picture pasted or dropped, for the app to keep: its bytes, its
    /// kind (`png`, `jpeg`, …), and what to call with the Markdown that
    /// shows it once kept (`![](path)`), which is written on a row of its own.
    /// None, and pictures are pasted as the text view would.
    public var keepImage: ((Data, String, @escaping (String) -> Void) -> Void)?
    /// What a link's block (`manifold:…`) or page (`[[name]]`) is called:
    /// shown in place of an address written bare. nil where it isn't known.
    public var linkTitle: ((String) -> String?)? { didSet { refreshLinks() } }
    /// The symbol a link's block or page is shown with, before its words:
    /// an SF Symbol's name or one of Manifold's own (`Marks`).
    public var linkSymbol: ((String) -> String?)? { didSet { refreshLinks() } }
    /// Whether a page linked to (`[[name]]`) is there; not, its link is faint and slanted.
    public var pageExists: ((String) -> Bool)?
    /// A view the app draws in place of a block — a row of code, a line of
    /// pictures — while the caret isn't in it; nil to show it as written.
    public var blockView: ((OutlinerBlock) -> NSView?)? { didSet { restyle() } }

    // MARK: Its parts

    private let scroll = NSScrollView()
    let textView: OutlinerTextView
    /// What takes the keys: what the app makes first responder to write in the note.
    public var firstResponderView: NSView { textView }
    /// The scroll view the rows are in.
    public var scrollView: NSScrollView { scroll }

    /// The room around the rows.
    public var contentInset = NSSize(width: 22, height: 16) {
        didSet { textView.textContainerInset = contentInset }
    }

    public var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    /// What the view shows, as the view last agreed it with the engine.
    private(set) var shown = ""
    private(set) var bodyLayout = BodyLayout(lines: [], runs: [])
    private var revealed = Set<Int>()
    private var isApplying = false
    /// The rows folded, as the app last heard of them.
    private var knownFolds: [FoldedRow] = []
    /// The labels the engine was last given: what each link to a page is shown as.
    private var givenLabels: [String: String]?
    /// The Markdown the app was last told of, or that it gave: told again only when it is other.
    private var toldMarkdown: String?

    /// - Parameters:
    ///   - editor: the note.
    ///   - theme: how it looks; Manifold's colours in the system's font at 14.5 if not said.
    ///   - foldedRows: the rows the app keeps folded.
    public init(editor: NoteEditor, theme: OutlinerTheme? = nil, foldedRows: [FoldedRow] = []) {
        self.editor = editor
        self.theme = theme ?? OutlinerTheme.manifold(FontTheme.current)
        textView = OutlinerTextView.make()
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.owner = self
        textView.delegate = self
        textView.textContainerInset = contentInset
        textView.insertionPointColor = Tints.caret
        textView.selectedTextAttributes = [.backgroundColor: Tints.textSelection]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        if !foldedRows.isEmpty { editor.setFoldedRows(foldedRows) }
        knownFolds = editor.foldedRows
        toldMarkdown = editor.markdown
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func layout() {
        super.layout()
        fitHeight()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textView.needsDisplay = true
    }

    /// The text at least as tall as what shows it — a click under the last
    /// row is the note's — and as tall as the app's views in it reach.
    private func fitHeight() {
        // As wide as the scroll view shows, its scroller aside: the rows wrap there.
        let width = scroll.contentSize.width
        if width > 0, abs(textView.frame.width - width) > 0.5 { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        let height = max(scroll.contentSize.height, textView.blocksBottom + contentInset.height)
        if abs(textView.minSize.height - height) > 0.5 {
            textView.minSize = NSSize(width: 0, height: height)
            textView.sizeToFit()
        }
    }

    // MARK: Loading

    /// Tells the engine what each link to a page is shown as, so that it
    /// shows them as words, which wrap. Whether that changed what it shows.
    @discardableResult
    private func giveLabels() -> Bool {
        var labels: [String: String] = [:]
        for target in editor.linkTargets { labels[target] = linkTitle?(target) ?? target }
        guard labels != givenLabels else { return false }
        givenLabels = labels
        editor.setLinkLabels(labels)
        return true
    }

    /// Shows the engine's note from scratch.
    func load() {
        guard let storage = textView.textStorage else { return }
        giveLabels()
        shown = editor.text
        if storage.string != shown {
            isApplying = true
            let caret = min(textView.selectedRange().location, (shown as NSString).length)
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: shown)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            isApplying = false
        }
        restyle()
    }

    /// The note as another wrote it — another client, `mani write` — shown
    /// in place of what is: its folds kept, the row focused on focused
    /// still, the caret on its row, as nearly as they can be found again.
    /// (Undo starts afresh.) Nothing, when it is what the note already is.
    public func load(markdown: String) {
        guard markdown != editor.markdown else { return }
        replaceEditor(NoteEditor(source: markdown))
    }

    /// Another engine shown in place of this one's — the note read again —
    /// keeping what `load(markdown:)` keeps.
    public func replaceEditor(_ next: NoteEditor) {
        let old = editor
        // Where the caret is: its row, its words, how far into them.
        let caret = textView.selectedRange().location
        let lines = bodyLayout.lines
        let caretLine = lines.lastIndex { $0.start <= caret }
        let caretWords = caretLine.map { words(of: lines[$0]) }
        let caretOffset = caretLine.map { max(caret - lines[$0].content, 0) } ?? 0
        let focus = old.isFocused ? (trail: old.focusTrail, label: old.focusLabel) : nil
        next.setProse(isProse)
        next.setFoldedRows(old.foldedRows)
        if let focus, let label = focus.label { refocus(next, trail: focus.trail, label: label) }
        editor = next
        toldMarkdown = next.markdown
        givenLabels = nil
        textView.leaveRows()
        load()
        // The caret on the row with its words nearest where it was; else on the row where it was.
        let now = bodyLayout.lines
        if let caretLine, !now.isEmpty {
            var at = min(caretLine, now.count - 1)
            if let caretWords, !caretWords.isEmpty,
               let found = now.indices.filter({ words(of: now[$0]) == caretWords }).min(by: { abs($0 - caretLine) < abs($1 - caretLine) }) {
                at = found
            }
            let line = now[at]
            isApplying = true
            textView.setSelectedRange(NSRange(location: min(line.content + caretOffset, line.end), length: 0))
            isApplying = false
            restyle()
        }
        tellFolds()
        if focus != nil || old.isFocused != next.isFocused { onFocusChanged?() }
    }

    /// Focuses an engine on the row with these words under rows with those: the one a note read again had.
    private func refocus(_ next: NoteEditor, trail: [String], label: String) {
        let outline = next.outline
        // Each row's ancestors' words, to tell rows of the same words apart.
        var path: [String] = []
        var best: Int?
        for row in outline {
            if path.count > row.depth { path.removeLast(path.count - row.depth) }
            if row.words == label, best == nil || path == trail { best = row.index; if path == trail { break } }
            while path.count < row.depth { path.append("") }
            path.append(row.words)
        }
        guard let best, let offset = next.revealRow(best),
              let line = next.layout.lines.lastIndex(where: { $0.start <= offset }) else { return }
        next.setFocus(row: line)
    }

    private func words(of line: BodyLine) -> String {
        let text = shown as NSString
        guard line.content <= line.end, line.end <= text.length else { return "" }
        return text.substring(with: NSRange(location: line.content, length: line.end - line.content))
    }

    /// Titles of what links lead to have changed: shown again.
    public func refreshLinks() {
        guard textView.textStorage != nil else { return }
        if giveLabels(), editor.text != shown { return load() }
        restyle()
    }

    // MARK: Folds

    /// The rows folded. Set, these and no others are.
    public var foldedRows: [FoldedRow] {
        get { editor.foldedRows }
        set {
            guard editor.setFoldedRows(newValue) else { return }
            knownFolds = editor.foldedRows
            load()
        }
    }

    /// Tells the app which rows are folded, when that is no longer what it knows.
    private func tellFolds() {
        let now = editor.foldedRows
        guard now != knownFolds else { return }
        knownFolds = now
        onFolds?(now)
    }

    // MARK: The look

    /// Whether the caret is here.
    var isWriting: Bool { window?.firstResponder === textView }

    /// Whether any of the app's views stand in the note.
    var hasBlocks: Bool { !hosts.isEmpty }
    /// The view's width when the app's views were last placed.
    var blocksPlacedFor: CGFloat = -1

    /// Dresses the text again, as the engine reads it.
    func restyle() {
        guard let storage = textView.textStorage, let manager = textView.outlinerLayout else { return }
        // A page linked to has another title now: the text that shows it is made again.
        if !isApplying, givenLabels != nil, giveLabels(), editor.text != shown { return load() }
        var styler = OutlinerStyler(theme: theme)
        styler.linkTitle = { [weak self] in self?.linkTitle?($0) }
        styler.linkSymbol = { [weak self] in self?.linkSymbol?($0) }
        if let pageExists { styler.pageExists = pageExists }
        bodyLayout = editor.layout
        let writing = isWriting
        revealed = writing ? OutlinerStyler.revealed(bodyLayout, selection: textView.selectedRange()) : []
        isApplying = true
        styler.prose = isProse
        styler.isWriting = writing
        manager.prose = isProse
        manager.theme = theme
        manager.lines = bodyLayout.lines
        manager.isWriting = writing
        styler.style(storage, layout: bodyLayout, revealed: revealed)
        let replaced = placeBlocks(storage: storage)
        // A row an app's view stands in place of has no mark of its own to draw;
        // nor a typed row with nothing in it, while the note is only read.
        manager.rows = bodyLayout.lines.enumerated().filter { !replaced.contains($0.offset) && (writing || !OutlinerStyler.isEmptyTyped($0.element)) }.map(\.element)
        textView.typingAttributes = typingAttributes(styler)
        isApplying = false
        textView.needsDisplay = true
        fitHeight()
    }

    /// What is typed next takes the look of the line it is typed on.
    private func typingAttributes(_ styler: OutlinerStyler) -> [NSAttributedString.Key: Any] {
        guard let storage = textView.textStorage else { return styler.baseAttributes }
        var attributes = styler.baseAttributes
        let caret = textView.selectedRange().location
        if let line = bodyLayout.lines.first(where: { $0.start <= caret && caret <= $0.end }) {
            let at = min(line.start, max(storage.length - 1, 0))
            if storage.length > 0, let style = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) { attributes[.paragraphStyle] = style }
            if storage.length == line.start || line.start == line.end {
                // An empty row has no character to carry its indentation: the caret after its mark.
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = OutlinerStyler.lineSpacing(for: line.kind, depth: line.depth, prose: isProse, font: theme.body)
                paragraph.firstLineHeadIndent = OutlinerStyler.wordsIndent(of: line, step: theme.step, prose: isProse)
                paragraph.headIndent = paragraph.firstLineHeadIndent
                attributes[.paragraphStyle] = paragraph
            }
        }
        return attributes
    }

    /// Marks words found — a find's — and brings the one gone to into sight.
    public func showFound(_ ranges: [NSRange], current: Int?) {
        guard let manager = textView.outlinerLayout else { return }
        let length = textView.textStorage?.length ?? 0
        manager.found = ranges.filter { NSMaxRange($0) <= length }
        manager.foundAt = current.flatMap { ranges.indices.contains($0) ? ranges[$0] : nil }
        textView.needsDisplay = true
        if let at = manager.foundAt { textView.scrollRangeToVisible(at) }
    }

    // MARK: Blocks drawn by the app

    private var hosts: [String: OutlinerBlockHost] = [:]
    /// The lines with pictures among their words, and where in the text
    /// each picture is written.
    private var among: [Int: [NSRange]] = [:]

    /// The blocks in what is shown: each with the lines it takes.
    private func blocks(in text: NSString) -> [(block: OutlinerBlock, lines: ClosedRange<Int>, range: NSRange)] {
        var found: [(OutlinerBlock, ClosedRange<Int>, NSRange)] = []
        among = [:]
        let part = { (range: NSRange) in text.substring(with: range) }
        // A block of code is one row: the view shows its code, its lines parted by U+2028;
        // what it is written in — its fence's info — is in its Markdown.
        for (index, line) in bodyLayout.lines.enumerated() where line.kind == .code {
            let range = NSRange(location: line.start, length: line.end - line.start)
            guard NSMaxRange(range) <= text.length else { continue }
            let fence = (editor.rowMarkdown(index) ?? "").split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let info = fence.trimmingCharacters(in: CharacterSet(charactersIn: "`~ "))
            found.append((OutlinerBlock(info: info, source: part(range).replacingOccurrences(of: "\u{2028}", with: "\n")), index...index, range))
        }
        // A row that is only pictures — one, or several.
        for (index, line) in bodyLayout.lines.enumerated() where line.kind != .fence && line.kind != .code {
            let range = NSRange(location: line.content, length: max(line.end - line.content, 0))
            guard range.length > 0, NSMaxRange(range) <= text.length else { continue }
            let words = editor.rowMarkdown(index) ?? ""
            guard words.contains("![") else { continue }
            let whole = NSRange(location: line.start, length: line.end - line.start)
            guard OutlinerPicture.all(line: words) != nil else {
                // Pictures among words: the words stay, and the pictures are shown under them.
                let pictures = OutlinerPicture.among(line: words)
                guard !pictures.isEmpty else { continue }
                among[index] = bodyLayout.runs.filter { run in
                    guard case .image = run.kind else { return false }
                    return run.start >= range.location && run.end <= NSMaxRange(range)
                }.map { NSRange(location: $0.start, length: $0.end - $0.start) }
                found.append((OutlinerBlock(info: OutlinerBlock.picture, source: pictures.map(\.picture.line).joined(separator: " ")), index...index, whole))
                continue
            }
            let block = OutlinerBlock(info: OutlinerBlock.picture, source: words) { [weak self] rewritten in self?.rewrite(line: index, as: rewritten) }
            found.append((block, index...index, whole))
        }
        return found
    }

    /// Writes other words on a line, in place of its own: a picture's new size.
    private func rewrite(line index: Int, as words: String) {
        guard bodyLayout.lines.indices.contains(index), !textView.hasMarkedText() else { return }
        let line = bodyLayout.lines[index]
        var edit = editor.replace(start: line.content, end: line.end, with: words)
        // The caret stays where it was: nothing was typed.
        let kept = textView.selectedRange()
        edit.selectionStart = kept.location
        edit.selectionEnd = NSMaxRange(kept)
        settle(edit)
    }

    /// Puts the app's views where the blocks they stand for are written,
    /// and folds those blocks' own lines away under them.
    @discardableResult
    private func placeBlocks(storage: NSTextStorage) -> Set<Int> {
        guard let blockView, let manager = textView.layoutManager, let container = textView.textContainer else {
            for (_, host) in hosts { host.remove() }
            hosts = [:]
            textView.blocksBottom = 0
            return []
        }
        var replaced = Set<Int>()
        var used = Set<String>()
        var placed: [(host: OutlinerBlockHost, range: NSRange, indent: CGFloat)] = []
        let width = max(textView.bounds.width - contentInset.width * 2, 120)
        blocksPlacedFor = textView.bounds.width
        for (index, found) in blocks(in: storage.string as NSString).enumerated() {
            var block = found.block
            // A block in a row stands in from the margin as the row's words do.
            let indent = found.range.location < storage.length ? ((storage.attribute(.paragraphStyle, at: found.range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0) : 0
            let width = max(width - indent, 120)
            block.room = width
            block.resized = { [weak self] in self?.restyle() }
            // Written in, code shows the words it is: a picture has none to show — it stays the picture.
            let reveals = found.block.info != OutlinerBlock.picture
            guard !(reveals && found.lines.contains(where: revealed.contains)), let content = blockView(block) else { continue }
            let key = "\(index)|\(found.block.info)|\(found.block.info == OutlinerBlock.picture ? found.block.source : "")"
            used.insert(key)
            let host = hosts[key] ?? {
                let host = OutlinerBlockHost(in: textView)
                hosts[key] = host
                return host
            }()
            let height = host.show(content, width: width)
            if let written = among[found.lines.lowerBound], found.range.length > 0 {
                // The line's words stay as they are; what writes its pictures is
                // not shown, and the room they take is left under the line.
                for range in written where NSMaxRange(range) <= storage.length {
                    storage.addAttributes([.font: OutlinerStyler.hiddenFont, .foregroundColor: NSColor.clear], range: range)
                }
                let whole = (storage.string as NSString).paragraphRange(for: NSRange(location: found.range.location, length: 0))
                let style = ((storage.attribute(.paragraphStyle, at: found.range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.paragraphSpacing += height + 10
                storage.addAttribute(.paragraphStyle, value: style, range: whole)
                placed.append((host, found.range, indent))
                continue
            }
            replaced.formUnion(found.lines)
            // The block's own lines are folded to nothing; the room it takes is left under them.
            let folded = NSMutableParagraphStyle()
            folded.maximumLineHeight = 0.5
            folded.minimumLineHeight = 0.5
            folded.lineSpacing = 0
            let last = NSMutableParagraphStyle()
            last.setParagraphStyle(folded)
            last.paragraphSpacing = height + 12
            storage.addAttributes([.font: OutlinerStyler.hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: folded], range: found.range)
            let text = storage.string as NSString
            let final = text.paragraphRange(for: NSRange(location: min(NSMaxRange(found.range), text.length), length: 0))
            storage.addAttribute(.paragraphStyle, value: last, range: final.length > 0 ? final : found.range)
            placed.append((host, found.range, indent))
        }
        for (key, host) in hosts where !used.contains(key) {
            host.remove()
            hosts[key] = nil
        }
        guard !placed.isEmpty else {
            textView.blocksBottom = 0
            return replaced
        }
        manager.ensureLayout(for: container)
        var bottom: CGFloat = 0
        for (host, range, indent) in placed {
            let glyph = manager.glyphIndexForCharacter(at: max(NSMaxRange(range) - 1, range.location))
            let line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            host.move(to: CGPoint(x: textView.textContainerOrigin.x + indent, y: textView.textContainerOrigin.y + line.maxY + 4))
            bottom = max(bottom, host.bottom)
        }
        textView.blocksBottom = bottom
        return replaced
    }

    // MARK: What was typed is the note's to take

    public func textDidChange(_ notification: Notification) { typed() }

    public func textViewDidChangeSelection(_ notification: Notification) { selectionChanged() }

    /// Takes what the view now shows that the note does not: called when
    /// the text view says its text changed.
    func typed() {
        guard !isApplying, !textView.hasMarkedText() else { return }
        let now = textView.string as NSString
        let was = shown as NSString
        guard !now.isEqual(to: shown) else { return }
        // What changed in the view, as one replacement of what was shown.
        var prefix = 0
        let limit = min(now.length, was.length)
        while prefix < limit, now.character(at: prefix) == was.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, now.character(at: now.length - 1 - suffix) == was.character(at: was.length - 1 - suffix) { suffix += 1 }
        // Not through the middle of a pair of surrogates.
        if prefix > 0, UTF16.isLeadSurrogate(was.character(at: prefix - 1)) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(was.character(at: was.length - suffix)) { suffix -= 1 }
        // Something put in where the same could have been put in a little earlier — a line break
        // after a line break: where the caret is says which, for it stands just after what was put in.
        let added = now.length - was.length
        let selection = textView.selectedRange()
        let caret = selection.location
        if added > 0, prefix + suffix == was.length, selection.length == 0, caret < prefix + added, caret >= added,
           was.isEqual(to: now.replacingCharacters(in: NSRange(location: caret - added, length: added), with: "")) {
            prefix = caret - added
            suffix = was.length - prefix
        }
        let typed = now.substring(with: NSRange(location: prefix, length: now.length - prefix - suffix))
        let edit = editor.replace(start: prefix, end: was.length - suffix, with: typed)
        settle(edit, typed: true)
    }

    /// After the engine took a change: the view is made to show what the
    /// engine now does, which is usually what it already shows.
    ///
    /// `typed`: the change was the view's own. Then, where the engine made
    /// no more of it, the caret is left where the view has it.
    func settle(_ edit: BodyEdit?, typed: Bool = false) {
        guard let storage = textView.textStorage else { return }
        let text = editor.text
        var edit = edit
        if typed, storage.string == text { edit = nil }
        if storage.string != text {
            // The engine made more of it than was typed — `- ` became a bullet.
            isApplying = true
            let now = storage.string as NSString
            let want = text as NSString
            var prefix = 0
            let limit = min(now.length, want.length)
            while prefix < limit, now.character(at: prefix) == want.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, now.character(at: now.length - 1 - suffix) == want.character(at: want.length - 1 - suffix) { suffix += 1 }
            storage.replaceCharacters(in: NSRange(location: prefix, length: now.length - prefix - suffix), with: want.substring(with: NSRange(location: prefix, length: want.length - prefix - suffix)))
            isApplying = false
        }
        shown = text
        if let edit {
            isApplying = true
            let length = (text as NSString).length
            let start = min(edit.selectionStart, length)
            textView.setSelectedRange(NSRange(location: start, length: max(min(edit.selectionEnd, length) - start, 0)))
            isApplying = false
        }
        restyle()
        textView.scrollRangeToVisible(textView.selectedRange())
        // A fold, a focus, a caret moved by a command: no change to the note, and nothing to tell.
        let markdown = editor.markdown
        if markdown != toldMarkdown {
            toldMarkdown = markdown
            onChange?(markdown)
        }
        tellFolds()
    }

    /// The caret moved: with the app's views in the note, the lines it is in
    /// show what they are written as.
    func selectionChanged() {
        guard !isApplying, isWriting, blockView != nil else { return }
        if OutlinerStyler.revealed(bodyLayout, selection: textView.selectedRange()) != revealed { restyle() }
    }

    func editingChanged(_ writing: Bool) {
        restyle()
        onEditingChanged?(writing)
    }

    // MARK: Commands

    /// Carries out one of the engine's commands — at the caret, or at a
    /// place (the caret then staying where it was). Says whether it had
    /// anything to do.
    @discardableResult
    func perform(_ command: EditCommand, at place: Int? = nil) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let selection = place.map { NSRange(location: $0, length: 0) } ?? textView.selectedRange()
        guard var edit = editor.perform(command, selectionStart: selection.location, selectionEnd: NSMaxRange(selection)) else { return false }
        if place != nil {
            let kept = textView.selectedRange()
            edit.selectionStart = kept.location
            edit.selectionEnd = NSMaxRange(kept)
        }
        settle(edit)
        return true
    }

    /// Carries out a command on some rows — lines of the outline, counted
    /// from the first — wherever the caret is, which stays with its words.
    @discardableResult
    func perform(_ command: EditCommand, onRows rows: [Int]) -> Bool {
        guard !textView.hasMarkedText(), !rows.isEmpty else { return false }
        let kept = textView.selectedRange()
        guard let edit = editor.perform(command, onRows: rows, selectionStart: kept.location, selectionEnd: NSMaxRange(kept)) else { return false }
        settle(edit)
        return true
    }

    /// Puts rows before another, at a depth: where they were carried to.
    @discardableResult
    func moveRows(_ rows: [Int], before: Int, depth: Int) -> Bool {
        guard !textView.hasMarkedText(), !rows.isEmpty else { return false }
        let kept = textView.selectedRange()
        guard let edit = editor.moveRows(rows, before: before, depth: depth, selectionStart: kept.location, selectionEnd: NSMaxRange(kept)) else { return false }
        settle(edit)
        return true
    }

    /// Puts rows written as Markdown — carried here from another note —
    /// before a row, at a depth.
    @discardableResult
    func insertRows(_ markdown: String, before: Int, depth: Int) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let kept = textView.selectedRange()
        guard let edit = editor.insertRows(markdown: markdown, before: before, depth: depth, selectionStart: kept.location, selectionEnd: NSMaxRange(kept)) else { return false }
        settle(edit)
        return true
    }

    /// Rows as they are written: their bullets and boxes with them.
    func markdown(ofRows rows: [Int]) -> String? {
        guard !rows.isEmpty else { return nil }
        let written = editor.markdownOf(rows: rows)
        return written.isEmpty ? nil : written
    }

    /// An address pasted onto the words selected: they link to it. Says
    /// whether it was an address, and words to link.
    func link(to pasted: String) -> Bool {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = textView.selectedRange()
        guard !textView.hasMarkedText(), selection.length > 0,
              let address = NoteEditor.webAddress(trimmed) ?? (OutlinerLink.isManifold(trimmed) && !trimmed.contains(where: \.isWhitespace) ? trimmed : nil),
              let edit = editor.link(selectionStart: selection.location, selectionEnd: NSMaxRange(selection), address: address) else { return false }
        settle(edit)
        return true
    }

    /// Pictures on a pasteboard, kept by the app and written on a row of
    /// their own — after the caret's row, or where they were let go. Says
    /// whether there were pictures to keep.
    func pastePictures(from board: NSPasteboard, at place: Int?) -> Bool {
        guard let keepImage, textView.isEditable, PasteboardImages.preferred(on: board) else { return false }
        let images = PasteboardImages.images(on: board)
        guard !images.isEmpty else { return false }
        for (data, kind) in images {
            keepImage(data, kind) { [weak self] markdown in self?.insertPicture(markdown, at: place) }
        }
        return true
    }

    /// A picture's Markdown written on a row of its own: the row at the
    /// place, if it's empty; else one after it.
    private func insertPicture(_ markdown: String, at place: Int?) {
        guard !textView.hasMarkedText() else { return }
        let text = shown as NSString
        let range = place.map { NSRange(location: min($0, text.length), length: 0) } ?? textView.selectedRange()
        let line = text.lineRange(for: NSRange(location: min(range.location, text.length), length: 0))
        let words = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            var end = NSMaxRange(line)
            if end > line.location, text.character(at: end - 1) == 10 { end -= 1 }
            return settle(editor.replace(start: end, end: end, with: "\n" + markdown))
        }
        settle(editor.replace(start: range.location, end: NSMaxRange(range), with: markdown))
    }

    /// A link clicked: the app follows it.
    func follow(_ link: OutlinerLink) { onFollow?(link.address) }

    func undo() { if let edit = editor.undo() { settle(edit) } }
    func redo() { if let edit = editor.redo() { settle(edit) } }

    // MARK: Focus: a row shown alone

    /// Shows only a row and what's under it — the caret's, if none is said
    /// (a line of the outline, from the first): Bike's focus in (⌥⌘→).
    /// Says whether there was such a row.
    @discardableResult
    public func focusIn(row: Int? = nil) -> Bool {
        guard !textView.hasMarkedText(), let row = row ?? caretRow, bodyLayout.lines.indices.contains(row), editor.setFocus(row: row) else { return false }
        textView.leaveRows()
        load()
        setCaret(bodyLayout.lines.first?.content ?? 0)
        tellFolds()
        onFocusChanged?()
        return true
    }

    /// Shows more again: the row the one focused on is under (⌥⌘←) — past
    /// the top, the whole note. Says whether it moved.
    @discardableResult
    public func focusOut(levels: Int = 1) -> Bool {
        guard editor.isFocused, !textView.hasMarkedText() else { return false }
        let was = editor.focusLabel
        guard editor.focusOut(levels: levels) else { return false }
        textView.leaveRows()
        load()
        // The caret on the row that was focused on, as near the top as it is.
        if let was, let line = bodyLayout.lines.first(where: { words(of: $0) == was }) { setCaret(line.content) }
        tellFolds()
        onFocusChanged?()
        return true
    }

    /// The whole note shown again.
    public func unfocus() {
        guard editor.isFocused else { return }
        _ = focusOut(levels: Int.max / 2)
    }

    // MARK: What the app asks of it

    /// Does a command, as its keys would — a menu's. Says whether there was anything to do.
    @discardableResult
    public func run(_ command: EditCommand) -> Bool {
        let done = textView.perform(keyed: command)
        if !done { NSSound.beep() }
        return done
    }

    /// The row the caret is in: its place among the outline's lines.
    public var caretRow: Int? {
        let caret = textView.selectedRange().location
        return bodyLayout.lines.lastIndex { $0.start <= caret } ?? (bodyLayout.lines.isEmpty ? nil : 0)
    }

    /// The rows chosen whole (Esc, ⇧↑ past a row's start, ⌘A), first to last.
    public var chosenRows: ClosedRange<Int>? { textView.chosenRows }

    /// What's here: the rows chosen, else the rows the selection is in —
    /// lines of the outline, from the first. nil for no rows.
    public var hereRows: ClosedRange<Int>? {
        if let chosen = chosenRows { return chosen }
        let selection = textView.selectedRange()
        let lines = bodyLayout.lines
        guard !lines.isEmpty else { return nil }
        let first = lines.lastIndex { $0.start <= selection.location } ?? 0
        let end = max(NSMaxRange(selection) - (selection.length > 0 ? 1 : 0), selection.location)
        let last = lines.lastIndex { $0.start <= end } ?? first
        return first...max(first, last)
    }

    /// The words of a row (a line of the outline), as shown.
    public func words(ofRow row: Int) -> String? {
        bodyLayout.lines.indices.contains(row) ? words(of: bodyLayout.lines[row]) : nil
    }

    /// The rows here as Markdown of their own, with what's under them.
    public var hereMarkdown: String? { hereRows.flatMap { markdown(ofRows: Array($0)) } }

    /// How many rows are shown.
    public var rowCount: Int { bodyLayout.lines.count }

    /// The selection, in the text shown.
    public var selectedRange: NSRange {
        get { textView.selectedRange() }
        set {
            textView.leaveRows()
            textView.setSelectedRange(NSRange(location: min(newValue.location, (shown as NSString).length), length: max(min(NSMaxRange(newValue), (shown as NSString).length) - min(newValue.location, (shown as NSString).length), 0)))
        }
    }

    /// The caret put at a place of the text shown, and brought into sight.
    public func setCaret(_ location: Int) {
        textView.leaveRows()
        let at = NSRange(location: min(max(location, 0), (shown as NSString).length), length: 0)
        textView.setSelectedRange(at)
        textView.scrollRangeToVisible(at)
    }

    /// A row of the note (its place in `editor.outline`) brought into sight —
    /// what it is under unfolded — and the caret put at its words. Says
    /// whether there was such a row.
    @discardableResult
    public func revealRow(_ index: Int) -> Bool {
        guard let at = editor.revealRow(index) else { return false }
        load()
        setCaret(at)
        tellFolds()
        return true
    }
}
