import AppKit
import ManifoldCore
import ManifoldSyntax

/// What the text view edits: the block's text, through its log.
protocol TextViewDocument: AnyObject {
    /// The text as the replica has it.
    var rope: Rope { get }
    var version: Int { get }
    /// Makes edits, as one entry (one undo step as the log sees it).
    func apply(_ edits: [TextEdit])
}

protocol TextViewDelegate: AnyObject {
    func textViewDidChangeSelection(_ view: TextView)
    func textViewDidEdit(_ view: TextView)
    func textViewDidScroll(_ view: TextView)
    /// A key, before the view sees it: true if it was taken (a popup's).
    func textView(_ view: TextView, handle event: NSEvent) -> Bool
    /// A block was dropped in as a link to it (a note about it, a mention).
    func textView(_ view: TextView, mentioned block: BlockID)
    /// ⌘-click on a place in the text.
    /// `over`: ⌥ held too — what it opens goes over this tile, stacked.
    func textView(_ view: TextView, commandClickAt offset: Int, over: Bool)
    /// A link in Markdown clicked: a block's pill (manifold:id), or an
    /// address; `over`: ⌥ was held, for what opens to go over this tile.
    func textView(_ view: TextView, follow target: String, over: Bool)
    /// ⌃Space.
    func textViewRequestsCompletion(_ view: TextView)
    /// The selection dragged: what it carries — its words, and a reference
    /// to its place (§2.5); nil for its words alone.
    func textView(_ view: TextView, dragSelection range: TextRange, text: String) -> NSPasteboardWriting?
    /// The pointer has rested on a name in code (`word`, in the window at
    /// `rect`): what it is, shown under it, if anything's known (peek).
    func textView(_ view: TextView, peekAt word: TextRange, in rect: NSRect)
    /// A line (from 0) dragged from the gutter: what it carries — a
    /// reference to the declaration or heading there, else the line (§2.5).
    func textView(_ view: TextView, dragLine line: Int) -> NSPasteboardWriting?
    /// The uses in the text of the symbol at `offset` — that one, not
    /// every name spelled the same — as its language server says; nil if
    /// it can't (none, or no answer), for the text's own whole words.
    func textView(_ view: TextView, usesAt offset: Int, _ done: @escaping ([TextRange]?) -> Void)
}

/// A selection: from its anchor to its head (the end that moves), in bytes.
struct Selection: Equatable {
    var anchor: Int
    var head: Int

    init(_ anchor: Int, _ head: Int) {
        self.anchor = anchor
        self.head = head
    }

    init(at offset: Int) { self.init(offset, offset) }

    var isCaret: Bool { anchor == head }
    var range: TextRange { TextRange(anchor, head) }
    var min: Int { Swift.min(anchor, head) }
    var max: Int { Swift.max(anchor, head) }

    /// The column the caret aims at as it moves up and down, in points.
    var goalX: CGFloat? = nil
}

/// Manifold's own text view: the block's rope laid out a visible line at a
/// time with Core Text, several cursors, undo as entries in the log, and
/// the Mac text system (keys through `NSTextInputClient`, marked text,
/// services) on top.
final class TextView: NSView, NSTextInputClient {
    weak var document: TextViewDocument?
    weak var delegate: TextViewDelegate?

    // Appearance.
    var font: NSFont = .systemFont(ofSize: 14) { didSet { fontChanged() } }
    var lineHeightMultiple: CGFloat = 1.2 { didSet { fontChanged() } }
    /// Letter spacing, in points (custom typography's).
    var tracking: CGFloat = 0 { didSet { if tracking != oldValue { fontChanged() } } }
    var textColor = Theme.bodyText { didSet { if textColor != oldValue { layouts = [:]; needsDisplay = true } } }
    /// What ⌘ shows as links: byte ranges of names there's somewhere to go
    /// to, in the link color go.dev's docs have.
    var linkRanges: [TextRange] = [] { didSet { if linkRanges != oldValue { layouts = [:]; needsDisplay = true } } }
    /// The link under the pointer, on a band (`linkHover`).
    var hoveredLink: TextRange? {
        didSet {
            guard hoveredLink != oldValue else { return }
            needsDisplay = true
            updateCursor()
        }
    }
    /// Behind the link under the pointer (⌘ held): a band a step lighter
    /// in the dark, darker in the light — a lightness, not a hue, as a
    /// chosen row's, so every eye sees it. A terminal's links have it too.
    /// A run that glows in its color (a link ⌘ shows), drawn under it.
    static let glows = NSAttributedString.Key("ManifoldGlows")
    static let linkHover = NSColor.themed { $0.code.linkHover }
    static let linkColor = NSColor.themed { $0.code.link }
    /// The line numbers' color (go.dev's for its listings, in view mode).
    var gutterColor = TextView.gutterText { didSet { if gutterColor != oldValue { needsDisplay = true } } }
    var showsLineNumbers = true { didSet { if showsLineNumbers != oldValue { invalidateAll() } } }
    var wraps = true { didSet { invalidateAll() } }
    /// Markdown shown richly (MarkdownStyle): the attributes of a line say
    /// what it means; the caret's line shows as written.
    var markdown = false { didSet { if markdown != oldValue { invalidateAll() } } }
    var codeFont: NSFont = .systemMono(ofSize: 13, weight: .regular) { didSet { if markdown { invalidateAll() } } }
    var markdownPalette = MarkdownStyle.Palette(text: Theme.bodyText, strong: Theme.strongText, dim: Theme.secondaryText, accent: Theme.accent,
                                                codeTint: Theme.hover, chipTint: Theme.accent.withAlphaComponent(0.16))
    /// The line the caret is on, whose Markdown shows raw.
    private var rawLine: Int?
    /// A block's look for its pill in the text, from whoever knows blocks.
    var pillLook: ((BlockID) -> PillLook?)?
    /// The pills each laid-out line drew, with the looks they were drawn
    /// with: when a look changes, the line is laid out again.
    private var pillLines: [Int: [(BlockID, PillLook)]] = [:]
    /// A block's summary card (a place's in it), from whoever knows blocks:
    /// what a line that's only `![name](manifold:…)` shows instead.
    var cardFor: ((BlockID, String?) -> SummaryCardContent?)?
    /// The cards laid-out lines show (in the line's place), the rows each
    /// takes, and where they go clicked.
    private var cardLines: [Int: (block: BlockID, place: String?, target: String, content: SummaryCardContent, rows: Int)] = [:]
    /// A line that's a block's card: `![name](manifold:…)` alone on it.
    private static let embedLine = try! NSRegularExpression(pattern: #"^\s*!\[[^\]\n]*\]\((manifold:[^)\s]+)\)\s*$"#)
    /// The lines that are code fences, found once per text.
    /// The lines that are fences, in order (counted below a line by halving).
    private var fenceLines: [Int]?
    /// The text's language, where there's a grammar for it (§7.1): its
    /// syntax tree, kept as the text changes.
    var syntaxLanguage: SyntaxLanguage? {
        didSet {
            guard syntaxLanguage !== oldValue else { return }
            syntax = syntaxLanguage.map { SyntaxTree($0, text: text) }
            syntax?.onChange = { [weak self] in self?.syntaxChanged($0) }
            invalidateAll()
        }
    }
    private(set) var syntax: SyntaxTree?
    /// Code's doc comments set apart: the font (the technical) and letter
    /// spacing their words are set in — their leaders and delimiters left
    /// in the text's own. Nil: not set apart.
    var docFont: NSFont? { didSet { if docFont != oldValue, syntax != nil { invalidateAll() } } }
    var docTracking: CGFloat = 0 { didSet { if docTracking != oldValue, syntax != nil { invalidateAll() } } }
    /// For pills of blocks that are running: the dots' travel, redrawn by a timer.
    private var pillPhase: Double { Date.timeIntervalSinceReferenceDate }
    private var pillTimer: Timer?
    var tabWidth = 4
    var isEditable = true
    static let insets = NSEdgeInsets(top: 10, left: 8, bottom: 40, right: 20)
    /// The gutter: room for the line count's digits, the numbers set at
    /// its left, then the git marks' lane, then a place's link mark or a
    /// diagnostic's dot, so the text has the rest.
    var gutterWidth: CGFloat {
        guard showsLineNumbers else { return 0 }
        let digits = max(2, String(max(text.lineCount, 1)).count)
        return CGFloat(digits) * gutterDigitWidth + 26
    }
    /// Where the git marks are: between the line numbers and the text, as
    /// Xcode and VS Code have them — beside the lines they mark, not at
    /// the tile's edge (where, an outline shown, a file's bar read as a
    /// border) — 5 points after the widest number, clear of a digit and of
    /// the marks by the text.
    private var markX: CGFloat { textLeft - 19 }
    /// A digit's width in the gutter's font: read at every layout and
    /// draw, so measured once a size.
    private var gutterDigitWidth: CGFloat {
        let size = max(9, font.pointSize * 0.78)
        if let w = Self.digitWidths[size] { return w }
        let w = ceil(("0" as NSString).size(withAttributes: [.font: NSFont.systemDigits(ofSize: size)]).width)
        Self.digitWidths[size] = w
        return w
    }
    private static var digitWidths: [CGFloat: CGFloat] = [:]

    // Selection.
    private(set) var selections: [Selection] = [Selection(at: 0)]
    private var marked: TextRange?
    /// A line gone to, marked with a band until the caret leaves it.
    var highlightedLine: Int? { didSet { if highlightedLine != oldValue { needsDisplay = true } } }
    /// Ranges marked (the find bar's matches).
    var highlights: [TextRange] = [] { didSet { needsDisplay = true } }
    /// What the language server says, underlined.
    var diagnostics: [Diagnostic] = [] { didSet { needsDisplay = true } }
    /// How lines stand against what's committed: bars in the gutter.
    var gutterMarks: [GutterMark] = [] { didSet { needsDisplay = true } }
    /// The document version the view last made or saw.
    var undoKnownVersion: Int { knownVersion }

    // Layout.
    private struct LineLayout {
        var rows: [CTLine]
        var text: String
        /// Each row's first UTF-16 index within the line.
        var rowStarts: [Int]
    }
    private var layouts: [Int: LineLayout] = [:]
    /// Visual rows per logical line, estimated as 1 until laid out.
    private var rowCounts: [Int] = []
    private var rowStarts: [Int] = []
    /// `rowStarts` is right up to this index (-1: none): a line laid out
    /// that wraps moves only what's after it, and what's looked up (the
    /// lines being drawn) is summed only as far as it's needed — every
    /// line that wrapped made the whole file be summed again, once for each
    /// line drawn.
    private var rowStartsValidThrough = -1
    private var lineHeight: CGFloat = 20
    private var ascent: CGFloat = 14
    private var layoutWidth: CGFloat = 0
    private var knownVersion = -1
    private var knownLineCount = 0

    // Undo.
    private struct UndoGroup {
        var inverse: [TextEdit]
        var redo: [TextEdit]
        var selectionsBefore: [Selection]
        var selectionsAfter: [Selection]
        var at: Date
        var typing: Bool
    }
    private var undoStack: [UndoGroup] = []
    private var redoStack: [UndoGroup] = []
    /// The undo depth when the text was last saved: back there, it's clean.
    var savedUndoDepth = 0
    /// How many undo steps are kept; 0 for as many as there are.
    var undoLimit = 0
    private var applyingOurs = false

    // Caret.
    private var caretVisible = true
    private var caretTimer: Timer?
    private var dragAnchor: Selection?
    private var dragMode = 0 // 1 char, 2 word, 3 line

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Dragged.types)
        wantsLayer = true
        fontChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { pillTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click in a window not yet key counts: it places the caret, or follows a link.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    var text: Rope { document?.rope ?? Rope() }

    // MARK: Document changes

    /// The document's text may have changed under us (an edit from
    /// elsewhere, a reload): the layout and selections are brought up to
    /// date.
    func documentChanged() {
        guard let document else { return }
        if document.version != knownVersion {
            if !applyingOurs {
                // Not ours: nothing is known about what moved.
                syntax?.update(to: document.rope)
                foldsFollowText()
                pinnedChanged(nil)
                invalidateAll()
                if document.rope.lineCount != knownLineCount { undoStack = []; redoStack = [] }
            }
            knownVersion = document.version
            knownLineCount = document.rope.lineCount
            let n = document.rope.count
            selections = selections.map { Selection(min($0.anchor, n), min($0.head, n)) }
            normalizeSelections()
            resizeToFit()
            needsDisplay = true
        }
    }

    /// The tree brought to the text as it is now (parsed again in the
    /// background, `syntaxChanged` told when it's in).
    private func syntaxEdited(_ edits: [TextEdit] = []) {
        // One edit: where it was, said (the tree's text the one it was made to).
        let one = edits.count == 1 ? edits.first.map { (start: $0.start, oldEnd: $0.end, newEnd: $0.start + $0.text.utf8.count) } : nil
        if let changed = syntax?.update(to: text, edited: one) { syntaxChanged(changed) }
    }

    /// The syntax of these ranges changed (a block comment opened above
    /// them): their lines laid out again, where it shows — their doc
    /// comments set apart.
    /// Every function's body folded once the text's first parsed (a tile
    /// that opens folded).
    var foldWhenParsed = false

    private func syntaxChanged(_ changed: [TextRange]) {
        if foldWhenParsed, syntax?.isParsed == true, !text.isEmpty {
            foldWhenParsed = false
            let keep = selections
            collapseAll(nil)
            if folds.isEmpty { setSelections(keep, scroll: false) }
        }
        guard docFont != nil, !changed.isEmpty else { return }
        for r in changed {
            let first = text.line(at: r.start), last = text.line(at: r.end)
            for k in layouts.keys where k >= first && k <= last { layouts.removeValue(forKey: k) }
        }
        needsDisplay = true
    }

    /// Whether a line is inside a fenced code block: an odd number of
    /// fences before it.
    private func inCodeBlock(_ n: Int) -> Bool {
        if fenceLines == nil {
            var f: [Int] = []
            for i in 0..<text.lineCount where MarkdownStyle.isFence(text.lineText(i)) { f.append(i) }
            fenceLines = f
        }
        return Self.countBelow(n, in: fenceLines!) % 2 == 1
    }

    /// How many of the sorted `lines` are before `n`.
    private static func countBelow(_ n: Int, in lines: [Int]) -> Int {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid] < n { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The blocks' pills, as their looks are now: lines drawn with a
    /// look since changed are laid out again.
    func refreshPills() {
        updatePillTimer()
        guard markdown else { return }
        var stale = pillLook.map { look in pillLines.filter { $0.value.contains { look($0.0) != $0.1 } }.map(\.key) } ?? []
        // And cards whose summaries changed.
        stale += cardLines.filter { n, c in
            guard let now = cardFor?(c.block, c.place) else { return true }
            return now.summary != c.content.summary || now.symbol != c.content.symbol || (now.thumbnail == nil) != (c.content.thumbnail == nil)
        }.map(\.key)
        guard !stale.isEmpty else { return }
        for n in stale {
            layouts.removeValue(forKey: n)
            pillLines.removeValue(forKey: n)
        }
        needsDisplay = true
    }

    /// Where line `n`'s card is drawn, if it shows one.
    private func cardRect(ofLine n: Int) -> NSRect? {
        guard let c = cardLines[n], layouts[n] != nil else { return nil }
        return NSRect(x: textLeft, y: top(ofLine: n) + 3, width: min(wrapWidth, 460), height: SummaryCard.height(for: c.content))
    }

    /// A line's card, as its block's summary says it now (§3.11).
    private func drawCard(ofLine n: Int) {
        guard let c = cardLines[n], let r = cardRect(ofLine: n) else { return }
        let card = Self.cardPainter
        card.content = c.content
        card.frame = NSRect(origin: .zero, size: r.size)
        NSGraphicsContext.saveGraphicsState()
        let move = NSAffineTransform()
        move.translateX(by: r.minX, yBy: r.minY)
        move.concat()
        card.draw(card.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Debugging: the lines showing cards, and the rows each takes.
    var debugCards: String {
        cardLines.isEmpty ? "" : " cards " + cardLines.keys.sorted().map { "\($0 + 1):\(cardLines[$0]!.rows)" }.joined(separator: " ")
    }

    /// One card, drawn wherever a line shows one.
    private static let cardPainter = SummaryCard(SummaryCardContent(id: "", symbol: "doc", summary: BlockSummary(title: "")))

    /// A pill running (the ring turning) keeps its lines redrawn.
    private func updatePillTimer() {
        let running = markdown && pillLines.values.contains { $0.contains { if case .working(nil) = $0.1.status { return true } else { return false } } }
        if running, pillTimer == nil {
            let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let self else { return }
                for n in self.pillLines.keys where n < self.text.lineCount {
                    self.setNeedsDisplay(NSRect(x: 0, y: self.top(ofLine: n), width: self.bounds.width, height: CGFloat(self.layout(line: n).rows.count) * self.lineHeight))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pillTimer = t
        } else if !running, let t = pillTimer {
            t.invalidate()
            pillTimer = nil
        }
    }

    private func invalidateAll() {
        layouts = [:]
        pillLines = [:]
        fenceLines = nil
        rowCounts = estimatedRowCounts()
        rowStartsValidThrough = -1
        resizeToFit()
        needsDisplay = true
    }

    /// Rows for the lines not yet laid out, guessed from their lengths at
    /// the font's average width — not one each: a long line wraps to
    /// several, and taking them for one put the end of a file of long
    /// lines a third of the way down (and moved everything as they were
    /// laid out).
    private func estimatedRowCounts() -> [Int] {
        var counts: [Int]
        if wraps {
            if lineLengthsFor?.version != knownVersion || lineLengthsFor?.lengths.count != text.lineCount {
                lineLengthsFor = (knownVersion, text.lineLengths())
            }
            let perRow = max(1, Double(wrapWidth) / max(averageAdvance, 1))
            counts = (lineLengthsFor?.lengths ?? []).map { max(1, Int((Double($0) / perRow).rounded(.up))) }
        } else {
            counts = Array(repeating: 1, count: text.lineCount)
        }
        // Folded lines take no rows.
        for n in hiddenLines where n < counts.count { counts[n] = 0 }
        return counts
    }
    private var lineLengthsFor: (version: Int, lengths: [Int])?
    /// A character's width, on the average (for guessing rows).
    private var averageAdvance: CGFloat = 8

    private func fontChanged() {
        let a = CTFontGetAscent(font), d = CTFontGetDescent(font), l = CTFontGetLeading(font)
        lineHeight = ceil((a + d + l) * lineHeightMultiple)
        averageAdvance = ("abcdefghijklmnopqrstuvwxyz " as NSString).size(withAttributes: [.font: font]).width / 27
        ascent = ceil(a + (lineHeight - (a + d + l)) / 2)
        invalidateAll()
    }

    // MARK: Geometry

    private var textLeft: CGFloat { Self.insets.left + gutterWidth }
    private var wrapWidth: CGFloat { max(40, bounds.width - textLeft - Self.insets.right) }

    /// `rowStarts` made right up to index `k` (the row line `k` starts at).
    private func ensureRowStarts(through k: Int) {
        if rowCounts.count != text.lineCount {
            rowCounts = estimatedRowCounts()
            rowStartsValidThrough = -1
        }
        let n = rowCounts.count
        if rowStarts.count < n + 1 {
            rowStarts.append(contentsOf: repeatElement(0, count: n + 1 - rowStarts.count))
        } else if rowStarts.count > n + 1 {
            rowStarts.removeLast(rowStarts.count - n - 1)
        }
        rowStartsValidThrough = min(rowStartsValidThrough, n)
        if rowStartsValidThrough < 0 {
            rowStarts[0] = 0
            rowStartsValidThrough = 0
        }
        let want = min(max(k, 0), n)
        var i = rowStartsValidThrough
        while i < want {
            rowStarts[i + 1] = rowStarts[i] + rowCounts[i]
            i += 1
        }
        rowStartsValidThrough = max(rowStartsValidThrough, want)
    }

    /// The rows after line `n` moved (its own count changed, or lines came
    /// or went there).
    private func invalidateRowStarts(after n: Int) {
        rowStartsValidThrough = min(rowStartsValidThrough, max(n, 0))
    }

    private var totalRows: Int {
        ensureRowStarts(through: rowCounts.count)
        return rowStarts[min(rowCounts.count, rowStarts.count - 1)]
    }

    private func resizeToFit() {
        let h = Self.insets.top + CGFloat(totalRows) * lineHeight + Self.insets.bottom
        let visible = enclosingScrollView?.contentSize.height ?? 0
        let height = max(h, visible)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if wraps, abs(layoutWidth - wrapWidth) > 0.5 {
            layoutWidth = wrapWidth
            layouts = [:]
            rowCounts = estimatedRowCounts()
            rowStartsValidThrough = -1
            needsDisplay = true
            DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
        }
    }

    /// The layout of a logical line, made if need be (and the row counts
    /// corrected, which moves everything after it).
    private func layout(line n: Int) -> LineLayout {
        if let l = layouts[n] { return l }
        let string = text.lineText(n)
        let attributed = NSMutableAttributedString(string: string.isEmpty ? " " : string, attributes: attributes())
        // A block's card in place of the line (not the caret's, which shows
        // it as written): the line's words out of sight under it.
        cardLines.removeValue(forKey: n)
        var card: (block: BlockID, place: String?, target: String, content: SummaryCardContent)?
        if markdown, rawLine != n, string.contains("](manifold:"), let cardFor, !inCodeBlock(n),
           let m = Self.embedLine.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
            let target = (string as NSString).substring(with: m.range(at: 1))
            if let (id, place) = BlockID.link(target), let content = cardFor(id, place) {
                card = (id, place, target, content)
                attributed.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: 0, length: attributed.length))
            }
        }
        if markdown, !string.isEmpty, card == nil {
            var drawn: [(BlockID, PillLook)] = []
            MarkdownStyle.apply(to: attributed, base: font, code: codeFont, palette: markdownPalette, reveal: rawLine == n, inCodeBlock: inCodeBlock(n)) { [weak self] id in
                guard let look = self?.pillLook?(id) else { return nil }
                drawn.append((id, look))
                return look
            }
            if drawn.isEmpty { pillLines.removeValue(forKey: n) } else { pillLines[n] = drawn }
            updatePillTimer()
        }
        // Its doc comments' words in the technical font (not Markdown's).
        if !markdown, !string.isEmpty, let syntax, let docFont {
            let start = text.offset(ofLine: n)
            for r in syntax.docWords(in: TextRange(start, start + string.utf8.count)) {
                let a = utf16Index(in: string, byteOffset: r.start - start), b = utf16Index(in: string, byteOffset: r.end - start)
                guard b > a else { continue }
                attributed.addAttributes([.font: docFont, .kern: docTracking], range: NSRange(location: a, length: b - a))
            }
        }
        // The names ⌘ shows as links, on this line.
        if !linkRanges.isEmpty, !string.isEmpty {
            let start = text.offset(ofLine: n), end = start + string.utf8.count
            for r in linkRanges where r.end > start && r.start < end {
                let a = utf16Index(in: string, byteOffset: max(r.start, start) - start)
                let b = utf16Index(in: string, byteOffset: min(r.end, end) - start)
                if b > a { attributed.addAttributes([.foregroundColor: Self.linkColor, Self.glows: true], range: NSRange(location: a, length: b - a)) }
            }
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var rows: [CTLine] = []
        var starts: [Int] = []
        let length = (attributed.string as NSString).length
        var i = 0
        if wraps {
            while i < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, i, Double(wrapWidth))
                let take = max(count, 1)
                // Past 2,000 rows, the rest of the line on one row: it went
                // undrawn (a minified file's one line).
                let rest = rows.count >= 2000
                let n = rest ? length - i : take
                rows.append(CTTypesetterCreateLine(typesetter, CFRange(location: i, length: n)))
                starts.append(i)
                i += n
            }
        } else {
            rows.append(CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length)))
            starts.append(0)
        }
        if rows.isEmpty {
            rows.append(CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length)))
            starts.append(0)
        }
        let l = LineLayout(rows: rows, text: string, rowStarts: starts)
        layouts[n] = l
        // Rows enough for its card; and for a note about it (§2.5) under it.
        var total = rows.count
        if let card {
            total = max(rows.count, Int(ceil((SummaryCard.height(for: card.content) + 6) / lineHeight)))
            cardLines[n] = (card.block, card.place, card.target, card.content, total)
        }
        if let h = noteHeight(ofLine: n) { total = rows.count + Int(ceil((h + 4) / lineHeight)) }
        // Folded away: no rows at all.
        if hiddenLines.contains(n) { total = 0 }
        if n < rowCounts.count, rowCounts[n] != total {
            rowCounts[n] = total
            invalidateRowStarts(after: n)
            DispatchQueue.main.async { [weak self] in
                self?.resizeToFit()
                self?.needsDisplay = true
            }
        }
        return l
    }

    /// The tints behind a row's chips (code spans, blocks' links): drawn
    /// under the text, around each such run.
    private func drawChips(in row: CTLine, at rowTop: CGFloat, _ ctx: CGContext) {
        guard let runs = CTLineGetGlyphRuns(row) as? [CTRun] else { return }
        ctx.restoreGState()
        var x0: CGFloat?, x1: CGFloat = 0
        var color: NSColor?
        func flush() {
            if let a = x0, let c = color, x1 > a {
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: textLeft + a - 2, y: rowTop + 1, width: x1 - a + 4, height: lineHeight - 2), xRadius: 4, yRadius: 4).fill()
            }
            x0 = nil
            color = nil
        }
        if let first = runs.first, (CTRunGetAttributes(first) as NSDictionary)[MarkdownStyle.codeBlock] != nil {
            markdownPalette.codeTint.setFill()
            NSRect(x: textLeft - 6, y: rowTop, width: max(0, bounds.width - Self.insets.right - textLeft + 12), height: lineHeight).fill()
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            return
        }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let range = CTRunGetStringRange(run)
            let start = CTLineGetOffsetForStringIndex(row, range.location, nil)
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            if let tint = attrs[MarkdownStyle.chip] as? NSColor, attrs[MarkdownStyle.hidden] == nil {
                if x0 == nil || tint !== color { flush(); x0 = start; color = tint }
                x1 = start + width
            } else if attrs[MarkdownStyle.hidden] == nil {
                flush()
            }
        }
        flush()
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    private func attributes() -> [NSAttributedString.Key: Any] {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = space * CGFloat(tabWidth)
        style.lineBreakMode = .byCharWrapping
        var out: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: style]
        if tracking != 0 { out[.kern] = tracking }
        return out
    }

    /// The y of a logical line's first row.
    /// The top of a logical line, in the view (the scrubber's marks too).
    /// The line at `y` (from 0), and how far down it `y` is, as a fraction.
    func fractionalLine(atY y: CGFloat) -> Double {
        guard !text.isEmpty else { return 0 }
        let n = line(atY: y)
        let t = top(ofLine: n)
        let b = n + 1 < text.lineCount ? top(ofLine: n + 1) : frame.height
        return Double(n) + Double(min(max((y - t) / max(b - t, 1), 0), 1))
    }

    /// Where a fractional line (as `fractionalLine` gives) begins.
    func y(ofFractionalLine l: Double) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let n = min(max(Int(l), 0), text.lineCount - 1)
        let t = top(ofLine: n)
        let b = n + 1 < text.lineCount ? top(ofLine: n + 1) : frame.height
        return t + CGFloat(min(max(l - Double(n), 0), 1)) * (b - t)
    }

    func top(ofLine n: Int) -> CGFloat {
        ensureRowStarts(through: n)
        let row = rowStarts[min(max(n, 0), rowStarts.count - 1)]
        return Self.insets.top + CGFloat(row) * lineHeight
    }

    /// The logical line at a y.
    private func line(atY y: CGFloat) -> Int {
        ensureRowStarts(through: 0)
        let row = Int((y - Self.insets.top) / lineHeight)
        guard row >= 0 else { return 0 }
        // Summed only until past the row.
        while rowStartsValidThrough < rowCounts.count, rowStarts[rowStartsValidThrough] <= row {
            ensureRowStarts(through: rowStartsValidThrough + 512)
        }
        var lo = 0, hi = max(min(rowStartsValidThrough, rowCounts.count - 1), 0)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowStarts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return min(lo, max(text.lineCount - 1, 0))
    }

    /// Where a byte offset is: its line, row within the line, and x.
    private func position(of offset: Int) -> (line: Int, row: Int, x: CGFloat) {
        let n = text.line(at: offset)
        let l = layout(line: n)
        let lineStart = text.offset(ofLine: n)
        let u16 = utf16Index(in: l.text, byteOffset: offset - lineStart)
        var row = 0
        for (i, s) in l.rowStarts.enumerated() where s <= u16 { row = i }
        // A caret at the very end of a wrapped row belongs to the next row.
        if row + 1 < l.rowStarts.count, l.rowStarts[row + 1] == u16 { row += 1 }
        let x = CTLineGetOffsetForStringIndex(l.rows[row], u16, nil)
        return (n, row, x)
    }

    private func caretRect(_ offset: Int) -> NSRect {
        let p = position(of: offset)
        let y = top(ofLine: p.line) + CGFloat(p.row) * lineHeight
        return NSRect(x: textLeft + p.x, y: y, width: 2, height: lineHeight)
    }

    /// The byte offset at a point.
    func offset(at point: NSPoint) -> Int {
        guard !text.isEmpty else { return 0 }
        let n = line(atY: point.y)
        let l = layout(line: n)
        let lineTop = top(ofLine: n)
        var row = Int((point.y - lineTop) / lineHeight)
        row = min(max(row, 0), l.rows.count - 1)
        let x = point.x - textLeft
        var u16 = CTLineGetStringIndexForPosition(l.rows[row], CGPoint(x: max(0, x), y: 0))
        if u16 == kCFNotFound { u16 = 0 }
        let rowEnd = row + 1 < l.rowStarts.count ? l.rowStarts[row + 1] : (l.text as NSString).length
        // Past a wrapped row's end stays on that row.
        if u16 > rowEnd || (u16 == rowEnd && row + 1 < l.rows.count) { u16 = max(rowEnd - (row + 1 < l.rows.count ? 1 : 0), l.rowStarts[row]) }
        return text.offset(ofLine: n) + byteOffset(in: l.text, utf16Index: min(u16, (l.text as NSString).length))
    }

    private func utf16Index(in s: String, byteOffset: Int) -> Int {
        let utf8 = s.utf8
        guard let i = utf8.index(utf8.startIndex, offsetBy: byteOffset, limitedBy: utf8.endIndex) else { return s.utf16.count }
        return s.utf16.distance(from: s.utf16.startIndex, to: i)
    }

    private func byteOffset(in s: String, utf16Index: Int) -> Int {
        let utf16 = s.utf16
        guard let i = utf16.index(utf16.startIndex, offsetBy: utf16Index, limitedBy: utf16.endIndex) else { return s.utf8.count }
        return s.utf8.distance(from: s.utf8.startIndex, to: i)
    }

    // MARK: Folds and places (§2.5)

    /// A place in the text something is said about: its line, what links
    /// to it (and from it), and a note that describes or annotates it —
    /// shown under the line, in the technical font, where `showsNotes`.
    struct Place: Equatable {
        struct Link: Equatable {
            var title: String
            var relation: String?
            /// Where it goes followed: the other end's reference.
            var target: String
            /// To the place (else from it).
            var inbound: Bool
        }
        struct Note: Equatable {
            var title: String
            var text: String
            var relation: String
            var target: String
        }
        var line: Int
        var links: [Link]
        var note: Note?
    }

    var places: [Place] = [] {
        didSet {
            guard places != oldValue else { return }
            for n in Set(oldValue.map(\.line)).union(places.map(\.line)) {
                layouts.removeValue(forKey: n)
                noteLayouts.removeValue(forKey: n)
            }
            placeByLine = Dictionary(places.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
            needsDisplay = true
        }
    }
    private var placeByLine: [Int: Place] = [:]
    /// Its sections fold by its Markdown headings (a note, a Markdown file).
    var markdownHeadings = false
    /// Notes about places shown under their lines (else only marked).
    var showsNotes = true { didSet { if showsNotes != oldValue { noteLayouts = [:]; invalidateAll() } } }
    /// The notes' font: the technical (§7.1), else the text's own.
    var noteFont: NSFont? { didSet { if noteFont != oldValue { noteLayouts = [:]; invalidateAll() } } }
    /// Each note shown: its words laid out for the width, and their height.
    private var noteLayouts: [Int: (text: NSAttributedString, height: CGFloat, width: CGFloat)] = [:]

    /// The height of the note under line `n`, laid out for the width now;
    /// nil if it has none shown.
    private func noteHeight(ofLine n: Int) -> CGFloat? {
        guard showsNotes, let note = placeByLine[n]?.note else { return nil }
        let width = min(wrapWidth, 680) - 14
        if let l = noteLayouts[n], l.width == width { return l.height }
        let body = noteFont ?? font
        let out = NSMutableAttributedString(string: note.relation + " · " + note.title + "\n",
                                            attributes: [.font: UIType.detail, .foregroundColor: Theme.tertiaryText])
        out.append(MarkdownText.attributed(note.text, font: body, code: font, color: Theme.secondaryText))
        let h = ceil(out.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        noteLayouts[n] = (out, h, width)
        return h
    }

    /// Where line `n`'s note is drawn: under its rows.
    private func noteRect(ofLine n: Int) -> NSRect? {
        guard let l = noteLayouts[n], let lineLayout = layouts[n], !hiddenLines.contains(n) else { return nil }
        let y = top(ofLine: n) + CGFloat(lineLayout.rows.count) * lineHeight + 4
        return NSRect(x: textLeft, y: y, width: l.width + 14, height: l.height + 2)
    }

    /// What's drawn at a place: its note under it (a rule at its left),
    /// a fold's chip after its text, a mark in the gutter for its links.
    private func drawPlace(ofLine n: Int, layout l: LineLayout, top lineTop: CGFloat) {
        if let r = noteRect(ofLine: n), let note = noteLayouts[n] {
            Theme.accent.withAlphaComponent(0.55).setFill()
            NSRect(x: r.minX, y: r.minY, width: 2, height: r.height).fill()
            note.text.draw(with: NSRect(x: r.minX + 12, y: r.minY, width: note.width, height: r.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        if let i = foldStarts[n], let last = l.rows.last {
            let w = CGFloat(CTLineGetTypographicBounds(last, nil, nil, nil))
            let label = NSAttributedString(string: "⋯", attributes: [.font: font, .foregroundColor: Theme.secondaryText])
            let size = label.size()
            let rowTop = lineTop + CGFloat(l.rows.count - 1) * lineHeight
            let chip = NSRect(x: textLeft + w + 8, y: rowTop + 2, width: size.width + 12, height: lineHeight - 4)
            Theme.hover.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: chip.minX + 6, y: rowTop + (lineHeight - size.height) / 2))
            foldChips[n] = (chip, i)
        }
        if showsLineNumbers, placeByLine[n]?.links.isEmpty == false {
            let mark = NSRect(x: textLeft - 12, y: lineTop + lineHeight / 2 - 3.5, width: 7, height: 7)
            Theme.accent.setStroke()
            let path = NSBezierPath(roundedRect: mark, xRadius: 2, yRadius: 2)
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    /// A place's links, as a menu at the gutter: each followed chosen.
    private func showLinks(of place: Place, at p: NSPoint) {
        let menu = NSMenu()
        for l in place.links {
            let words = (l.inbound ? "← " : "→ ") + l.title + (l.relation.map { "  (\($0))" } ?? "")
            menu.addItem(ClosureMenuItem(words, symbol: nil) { [weak self] in
                guard let self else { return }
                self.delegate?.textView(self, follow: l.target, over: false)
            })
        }
        menu.popUp(positioning: nil, at: p, in: self)
    }

    /// Folded lines: each fold the bytes of the lines it hides, from the
    /// first's start to the last's end, moved as the text is edited.
    private var folds: [TextRange] = [] { didSet { if folds != oldValue { foldsChanged() } } }
    /// The text the folds were last put right for (an edit from elsewhere
    /// is found by comparing).
    private var foldsText = Rope()
    private var hiddenLines = IndexSet()
    /// The line each fold is under, and which fold.
    private var foldStarts: [Int: Int] = [:]
    /// Each fold's chip as last drawn, for a click to open it.
    private var foldChips: [Int: (rect: NSRect, fold: Int)] = [:]

    private func foldsChanged() {
        var hidden = IndexSet()
        var starts: [Int: Int] = [:]
        for (i, f) in folds.enumerated() where f.end <= text.count {
            let a = text.line(at: f.start), b = text.line(at: max(f.end - 1, f.start))
            guard a > 0, b >= a else { continue }
            hidden.insert(integersIn: a...b)
            starts[a - 1] = i
        }
        foldsText = text
        foldStarts = starts
        guard hidden != hiddenLines else { return needsDisplay = true }
        hiddenLines = hidden
        invalidateAll()
    }

    /// The folds moved through edits made here; one an edit falls inside
    /// is opened.
    private func foldsEdited(_ edits: [TextEdit]) {
        guard !folds.isEmpty else { return }
        folds = folds.compactMap { f in
            var r = f
            for e in edits {
                if e.start < r.end, e.end > r.start { return nil }
                r = r.moved(by: e)
            }
            return r
        }
    }

    /// The text changed where we didn't say: the folds moved by what changed.
    private func foldsFollowText() {
        guard !folds.isEmpty, let (start, oldEnd, newEnd) = text.changed(from: foldsText) else { return }
        foldsEdited([TextEdit(start: start, end: oldEnd, text: String(repeating: " ", count: newEnd - start))])
        foldsText = text
    }

    /// What can be folded, as lines (the first hidden, the last): each
    /// declaration's body (its closing line left, where that's only
    /// closers), each Markdown heading's section. `leaves`: only those with
    /// nothing foldable inside (functions, not their types).
    private func foldables(leaves: Bool = false) -> [ClosedRange<Int>] {
        var spans: [ClosedRange<Int>] = []
        if let decls = syntax?.declarations() {
            for d in decls {
                let a = text.line(at: d.range.start), b = text.line(at: max(d.range.end - 1, d.range.start))
                let closing = text.lineText(b).trimmingCharacters(in: .whitespaces)
                let last = !closing.isEmpty && closing.allSatisfy({ "})]>;,".contains($0) }) ? b - 1 : b
                if last >= a + 1 { spans.append((a + 1)...last) }
            }
        } else if markdownHeadings {
            let items = NoteOutlineMarkdown.items(in: text.string).filter(\.isHeading)
            for (i, h) in items.enumerated() {
                let next = items[(i + 1)...].first { $0.level <= h.level }?.line ?? text.lineCount
                var last = next - 1
                while last > h.line, text.lineText(last).trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
                if last >= h.line + 1 { spans.append((h.line + 1)...last) }
            }
        }
        guard leaves else { return spans }
        return spans.filter { s in !spans.contains { $0 != s && s.contains($0.lowerBound) && s.contains($0.upperBound) } }
    }

    private func fold(_ lines: ClosedRange<Int>) -> TextRange {
        TextRange(text.offset(ofLine: lines.lowerBound), text.lineRange(lines.upperBound).end)
    }

    /// Collapse (⌃⌘9): the innermost declaration or section the caret is
    /// in, folded under its first line.
    @objc func collapse(_ sender: Any?) {
        let line = text.line(at: primarySelection.head)
        let open = foldables().filter { ($0.lowerBound - 1)...$0.upperBound ~= line && !folds.contains(fold($0)) }
        guard let inner = open.min(by: { $0.count < $1.count }) else { return NSSound.beep() }
        // The caret out of what's folded first, at the end of its first line.
        setSelections([Selection(at: text.lineRange(inner.lowerBound - 1).end)])
        folds.append(fold(inner))
    }

    /// Expand (⌃⌘0): the folds at the caret's line opened.
    @objc func expand(_ sender: Any?) {
        let line = text.line(at: primarySelection.head)
        let before = folds.count
        folds.removeAll { f in
            let a = text.line(at: f.start) - 1, b = text.line(at: max(f.end - 1, f.start))
            return (a...b).contains(line)
        }
        if folds.count == before { NSSound.beep() }
    }

    /// Collapse All (⌥⌘9): every function's body (every section without
    /// sections in it), the caret's line kept in view.
    @objc func collapseAll(_ sender: Any?) {
        let all = foldables(leaves: true).map(fold)
        guard !all.isEmpty else { return NSSound.beep() }
        let line = text.line(at: primarySelection.head)
        if let inner = foldables(leaves: true).first(where: { $0.contains(line) }) {
            setSelections([Selection(at: text.lineRange(inner.lowerBound - 1).end)])
        }
        folds = Array(Set(folds + all)).sorted()
    }

    /// Expand All (⌥⌘0).
    @objc func expandAll(_ sender: Any?) { folds = [] }

    /// Debugging: what's folded, and the places marked.
    var debugFolds: String {
        let f = folds.map { "\(text.line(at: $0.start) + 1)-\(text.line(at: max($0.end - 1, $0.start)) + 1)" }.joined(separator: ",")
        let p = places.map { "\($0.line + 1):\($0.links.count)\($0.note != nil ? "+note" : "")" }.joined(separator: ",")
        let uses = symbolUses.map { "\(text.line(at: $0.start) + 1):\($0.start - text.offset(ofLine: text.line(at: $0.start)))" }.joined(separator: ",")
        return "folds [\(f)] places [\(p)] hidden \(hiddenLines.count) uses [\(uses)] pinned [\(pinned.map { $0.word + ($0.uses == nil ? "" : "*") }.joined(separator: ","))] \(pinnedUses().count)"
    }

    // MARK: Drawing

    /// The runs of a row that glow (`glows`): a soft light around their
    /// letters in their color, under them — drawn with their shadow in a
    /// layer of their own, the letters then cleared from it, so only the
    /// light is left for the text to be drawn over.
    private func drawGlow(_ row: CTLine, at origin: CGPoint, _ ctx: CGContext) {
        let runs = (CTLineGetGlyphRuns(row) as? [CTRun] ?? []).filter { (CTRunGetAttributes($0) as NSDictionary)[Self.glows] != nil }
        guard !runs.isEmpty else { return }
        let dark = effectiveAppearance.isDark
        var color = Self.linkColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = Self.linkColor.cgColor }
        // The blur is in device pixels, not this view's points.
        let scale = abs(ctx.convertToDeviceSpace(CGSize(width: 1, height: 0)).width)
        ctx.saveGState()
        ctx.setBlendMode(dark ? .screen : .multiply)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setBlendMode(.normal)
        ctx.setShadow(offset: .zero, blur: max(3, font.pointSize * 0.4) * scale, color: color.copy(alpha: dark ? 0.9 : 0.6))
        for run in runs {
            ctx.textPosition = origin
            CTRunDraw(run, ctx, CFRange())
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setBlendMode(.clear)
        for run in runs {
            ctx.textPosition = origin
            CTRunDraw(run, ctx, CFRange())
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Selected text and the caret, in the app's tint.
    static let selectionColor = Tints.textSelection
    static let caretColor = Tints.caret
    static let lineHighlight = NSColor.themed { $0.code.lineHighlight }
    static let gutterText = NSColor.themed { $0.code.gutterText }
    /// The caret's symbol's other uses: a faint ground, under a match's.
    static let useColor = NSColor.themed { $0.code.use }
    static let matchColor = NSColor.themed { $0.code.match }

    /// A block's pill over its link's run (§7): the symbol, name and
    /// status its tile's pill shows, at the row's height.
    private func drawPills(in row: CTLine, at rowTop: CGFloat, _ ctx: CGContext) {
        guard let runs = CTLineGetGlyphRuns(row) as? [CTRun] else { return }
        var drew = false
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let look = attrs[MarkdownStyle.pill] as? PillLook else { continue }
            if !drew { ctx.restoreGState(); drew = true }
            let range = CTRunGetStringRange(run)
            let start = CTLineGetOffsetForStringIndex(row, range.location, nil)
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            let r = NSRect(x: textLeft + start, y: rowTop + 1.5, width: width, height: lineHeight - 3)
            let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            LinkCapsule.fill.setFill()
            capsule.fill()
            LinkCapsule.edge.setStroke()
            capsule.lineWidth = LinkCapsule.edgeWidth
            capsule.stroke()
            var x = r.minX + 8
            if let image = Self.tinted(look.symbol, size: LinkCapsule.symbolSize, color: Theme.secondaryText) {
                image.draw(in: NSRect(x: x, y: r.midY - 6, width: 13, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            x += 18
            let title = NSAttributedString(string: look.title, attributes: [.font: MarkdownStyle.pillFont, .foregroundColor: Theme.text])
            let size = title.size()
            title.draw(at: NSPoint(x: x, y: r.midY - size.height / 2))
            if let status = look.status {
                let g = NSRect(x: r.maxX - 8 - 11, y: r.midY - 5.5, width: 11, height: 11)
                // The glyph is drawn y up: the square flipped back for it.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: g.minY + g.maxY)
                ctx.scaleBy(x: 1, y: -1)
                StatusGlyph.draw(status, in: g, phase: pillPhase)
                ctx.restoreGState()
            }
        }
        if drew {
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        }
    }

    private static var tintedSymbols: [String: NSImage] = [:]
    /// A symbol in a colour, for drawing by hand.
    private static func tinted(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)/\(size)/\(color.description)"
        if let i = tintedSymbols[key] { return i }
        guard let symbol = Theme.symbol(name, size: size) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tintedSymbols[key] = image
        return image
    }

    /// What a link under a point goes to, if the point is on one.
    private func linkTarget(at p: NSPoint) -> String? {
        guard markdown, text.lineCount > 0 else { return nil }
        let n = line(atY: p.y)
        guard n < text.lineCount else { return nil }
        let l = layout(line: n)
        let r = min(max(Int((p.y - top(ofLine: n)) / lineHeight), 0), l.rows.count - 1)
        let row = l.rows[r]
        let x = p.x - textLeft
        guard x >= 0, let runs = CTLineGetGlyphRuns(row) as? [CTRun] else { return nil }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let target = attrs[MarkdownStyle.target] as? String else { continue }
            let range = CTRunGetStringRange(run)
            let start = CTLineGetOffsetForStringIndex(row, range.location, nil)
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            if x >= start, x <= start + width { return target }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = self.text
        guard text.lineCount > 0 else { return }
        let first = line(atY: dirtyRect.minY)
        let last = line(atY: dirtyRect.maxY)
        let focused = window?.firstResponder === self && window?.isKeyWindow == true

        if let h = highlightedLine, h >= first, h <= last, h < text.lineCount {
            Self.lineHighlight.setFill()
            NSRect(x: 0, y: top(ofLine: h), width: bounds.width, height: CGFloat(layout(line: h).rows.count) * lineHeight).fill()
        }

        // Pinned symbols' uses, each its colour; the caret's symbol's other
        // uses, faintly; matches, then selections' backgrounds.
        if !pinned.isEmpty {
            let firstOffset = text.offset(ofLine: first), lastOffset = text.lineRange(last).end
            for (h, color) in pinnedUses() where h.end >= firstOffset && h.start <= lastOffset {
                color.setFill()
                rows(of: h, from: first, to: last) { r in NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: lineHeight * 0.06), xRadius: 3, yRadius: 3).fill() }
            }
        }
        if !symbolUses.isEmpty {
            let firstOffset = text.offset(ofLine: first), lastOffset = text.lineRange(last).end
            Self.useColor.setFill()
            for h in symbolUses where h.end >= firstOffset && h.start <= lastOffset {
                rows(of: h, from: first, to: last) { r in NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: lineHeight * 0.08), xRadius: 3, yRadius: 3).fill() }
            }
        }
        if !highlights.isEmpty {
            let firstOffset = text.offset(ofLine: first), lastOffset = text.lineRange(last).end
            Self.matchColor.setFill()
            for h in highlights where h.end >= firstOffset && h.start <= lastOffset {
                drawSelection(h, from: first, to: last)
            }
        }
        Self.selectionColor.setFill()
        for s in selections where !s.isCaret {
            drawSelection(s.range, from: first, to: last)
        }
        // The link under the pointer (⌘ held), on its band.
        if let h = hoveredLink, !h.isEmpty {
            Self.linkHover.setFill()
            rows(of: h, from: first, to: last) { r in
                NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: lineHeight * 0.06), xRadius: 3, yRadius: 3).fill()
            }
        }

        // Text.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let gutterFont = NSFont.systemDigits(ofSize: max(9, font.pointSize * 0.78))
        foldChips = [:]
        for n in first...last {
            if hiddenLines.contains(n) { continue }
            let l = layout(line: n)
            let lineTop = top(ofLine: n)
            if showsLineNumbers {
                let s = NSAttributedString(string: "\(n + 1)", attributes: [.font: gutterFont, .foregroundColor: gutterColor])
                let size = s.size()
                ctx.restoreGState()
                s.draw(at: NSPoint(x: Self.insets.left + 2, y: lineTop + (lineHeight - size.height) / 2))
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            }
            guard !l.text.isEmpty else { continue }
            for (r, row) in l.rows.enumerated() {
                let rowTop = lineTop + CGFloat(r) * lineHeight
                if markdown { drawChips(in: row, at: rowTop, ctx) }
                let origin = CGPoint(x: textLeft, y: rowTop + ascent)
                // (The text position isn't part of the graphics state: set
                // again after the glow's.)
                if !linkRanges.isEmpty { drawGlow(row, at: origin, ctx) }
                ctx.textPosition = origin
                CTLineDraw(row, ctx)
                if markdown { drawPills(in: row, at: rowTop, ctx) }
            }
            if cardLines[n] != nil {
                ctx.restoreGState()
                drawCard(ofLine: n)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            }
            if noteLayouts[n] != nil || foldStarts[n] != nil || placeByLine[n]?.links.isEmpty == false {
                ctx.restoreGState()
                drawPlace(ofLine: n, layout: l, top: lineTop)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            }
        }
        ctx.restoreGState()

        // The git gutter: a bar beside added and changed lines, a wedge
        // where lines were taken out.
        if showsLineNumbers, !gutterMarks.isEmpty {
            let x = markX
            for m in gutterMarks where m.line <= last && m.line + max(m.count, 1) >= first {
                guard m.line < text.lineCount || m.kind == .deleted else { continue }
                switch m.kind {
                case .added, .modified:
                    (m.kind == .added ? Self.addedColor : Self.modifiedColor).setFill()
                    let end = min(m.line + m.count, text.lineCount) - 1
                    guard end >= m.line else { continue }
                    let y0 = top(ofLine: m.line)
                    let y1 = top(ofLine: end) + CGFloat(layout(line: end).rows.count) * lineHeight
                    NSRect(x: x, y: y0 + 1, width: 3, height: y1 - y0 - 2).fill()
                case .deleted:
                    Self.deletedColor.setFill()
                    let y = m.line < text.lineCount ? top(ofLine: m.line) : top(ofLine: text.lineCount - 1) + CGFloat(layout(line: text.lineCount - 1).rows.count) * lineHeight
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: x, y: y - 4))
                    p.line(to: NSPoint(x: x + 7, y: y))
                    p.line(to: NSPoint(x: x, y: y + 4))
                    p.close()
                    p.fill()
                }
            }
        }

        // Diagnostics: underlined, and a mark in the gutter.
        if !diagnostics.isEmpty {
            let firstOffset = text.offset(ofLine: first), lastOffset = text.lineRange(last).end
            for d in diagnostics where d.range.end >= firstOffset && d.range.start <= lastOffset {
                let color = Self.diagnosticColor(d.severity)
                let range = d.range.isEmpty ? TextRange(d.range.start, text.next(d.range.start)) : d.range
                color.setFill()
                underline(range, from: first, to: last)
                if showsLineNumbers {
                    let n = text.line(at: d.range.start)
                    NSBezierPath(ovalIn: NSRect(x: textLeft - 10, y: top(ofLine: n) + lineHeight / 2 - 2.5, width: 5, height: 5)).fill()
                }
            }
        }


        // Marked text (being composed) is underlined.
        if let m = marked, !m.isEmpty {
            NSColor.secondaryLabelColor.setFill()
            let a = caretRect(m.start), b = caretRect(m.end)
            if a.minY == b.minY { NSRect(x: a.minX, y: a.maxY - 2, width: b.minX - a.minX, height: 1).fill() }
        }

        // Carets.
        if focused && caretVisible || !focused {
            for s in selections {
                let r = caretRect(s.head)
                (focused ? Self.caretColor : Self.caretColor.withAlphaComponent(0.35)).setFill()
                r.fill()
            }
        }
    }

    static let addedColor = NSColor.themed { $0.code.added }
    static let modifiedColor = NSColor.themed { $0.code.modified }
    static let deletedColor = NSColor.themed { $0.code.deleted }

    static func diagnosticColor(_ severity: Int) -> NSColor {
        let code = Palette.current.code
        switch severity {
        case 1: return code.error.color
        case 2: return code.warning.color
        default: return code.hint.color
        }
    }

    /// A 2-pixel line under each row of a range.
    private func underline(_ range: TextRange, from first: Int, to last: Int) {
        rows(of: range, from: first, to: last) { r in
            NSRect(x: r.minX, y: r.maxY - 2, width: max(r.width, 4), height: 2).fill()
        }
    }

    /// The row rectangles a range covers, in the view.
    func rects(of range: TextRange) -> [NSRect] {
        var out: [NSRect] = []
        rows(of: range, from: text.line(at: range.start), to: text.line(at: range.end)) { out.append($0) }
        return out
    }

    /// Where a caret at an offset is, in the window.
    func caretRectInWindow(_ offset: Int) -> NSRect {
        convert(caretRect(offset), to: nil)
    }

    private func rows(of range: TextRange, from first: Int, to last: Int, _ each: (NSRect) -> Void) {
        let text = self.text
        let startLine = max(text.line(at: range.start), first)
        let endLine = min(text.line(at: range.end), last)
        guard startLine <= endLine else { return }
        for n in startLine...endLine where !hiddenLines.contains(n) {
            let l = layout(line: n)
            let lineStart = text.offset(ofLine: n)
            let lineEnd = lineStart + l.text.utf8.count
            let s = max(range.start, lineStart), e = min(range.end, lineEnd)
            let su = utf16Index(in: l.text, byteOffset: s - lineStart)
            let eu = utf16Index(in: l.text, byteOffset: e - lineStart)
            let lineTop = top(ofLine: n)
            for (r, row) in l.rows.enumerated() {
                let rs = l.rowStarts[r]
                let re = r + 1 < l.rowStarts.count ? l.rowStarts[r + 1] : (l.text as NSString).length
                let a = max(su, rs), b = min(eu, re)
                guard a <= b, su <= re, eu >= rs else { continue }
                let x1 = CTLineGetOffsetForStringIndex(row, a, nil)
                let x2 = CTLineGetOffsetForStringIndex(row, b, nil)
                each(NSRect(x: textLeft + x1, y: lineTop + CGFloat(r) * lineHeight, width: max(x2 - x1, 0), height: lineHeight))
            }
        }
    }

    private func drawSelection(_ range: TextRange, from first: Int, to last: Int) {
        let text = self.text
        let startLine = max(text.line(at: range.start), first)
        let endLine = min(text.line(at: range.end), last)
        guard startLine <= endLine else { return }
        for n in startLine...endLine where !hiddenLines.contains(n) {
            let l = layout(line: n)
            let lineStart = text.offset(ofLine: n)
            let lineEnd = lineStart + l.text.utf8.count
            let s = max(range.start, lineStart), e = min(range.end, lineEnd)
            let su = utf16Index(in: l.text, byteOffset: s - lineStart)
            let eu = utf16Index(in: l.text, byteOffset: e - lineStart)
            let lineTop = top(ofLine: n)
            for (r, row) in l.rows.enumerated() {
                let rs = l.rowStarts[r]
                let re = r + 1 < l.rowStarts.count ? l.rowStarts[r + 1] : (l.text as NSString).length
                let a = max(su, rs), b = min(eu, re)
                guard a <= b, su <= re, eu >= rs else { continue }
                let x1 = CTLineGetOffsetForStringIndex(row, a, nil)
                var x2 = CTLineGetOffsetForStringIndex(row, b, nil)
                // A selection over a line break shows to the end of the row.
                if range.end > lineEnd, b == re { x2 += 6 }
                if x2 <= x1 { x2 = x1 + (range.end > lineEnd && b == re ? 6 : 0) }
                NSRect(x: textLeft + x1, y: lineTop + CGFloat(r) * lineHeight, width: max(x2 - x1, 0), height: lineHeight).fill()
            }
        }
    }

    // MARK: Selections

    private func normalizeSelections() {
        let n = text.count
        var sorted = selections.map { Selection(text.floorBoundary(min($0.anchor, n)), text.floorBoundary(min($0.head, n))) }
            .sorted { $0.min < $1.min }
        // Overlapping ones merge.
        var out: [Selection] = []
        for s in sorted {
            if let last = out.last, s.min <= last.max, !(s.isCaret && last.isCaret && s.min != last.min) {
                if s.min < last.max || (s.isCaret && last.isCaret) || (!last.isCaret && s.min <= last.max && s.min != s.max) {
                    let merged = Selection(min(last.min, s.min), max(last.max, s.max))
                    out[out.count - 1] = merged.isCaret && !last.isCaret ? last : merged
                    continue
                }
            }
            out.append(s)
        }
        sorted = out.isEmpty ? [Selection(at: 0)] : out
        if sorted != selections {
            selections = sorted
        }
    }

    func setSelections(_ s: [Selection], scroll: Bool = true) {
        selections = s
        normalizeSelections()
        // A caret come into folded lines (gone to, found) opens them.
        if !hiddenLines.isEmpty, selections.contains(where: { hiddenLines.contains(text.line(at: $0.head)) }) {
            folds.removeAll { f in selections.contains { $0.head >= f.start && $0.head <= f.end } }
        }
        if markdown, !dropTracking {
            // The caret's line shows its Markdown as written: the line it
            // left and the one it came to are laid out again.
            let now = selections.last.map { text.line(at: $0.head) }
            if now != rawLine {
                for n in [rawLine, now].compactMap({ $0 }) { layouts.removeValue(forKey: n) }
                rawLine = now
            }
        }
        if let h = highlightedLine, !selections.contains(where: { text.line(at: $0.head) == h }) { highlightedLine = nil }
        scheduleSymbolUses()
        restartCaret()
        needsDisplay = true
        if scroll { scrollToCaret() }
        delegate?.textViewDidChangeSelection(self)
        inputContext?.invalidateCharacterCoordinates()
    }

    var primarySelection: Selection { selections.last ?? Selection(at: 0) }

    func select(_ range: TextRange) { setSelections([Selection(range.start, range.end)]) }

    func scrollToCaret() {
        guard let s = selections.last else { return }
        var r = caretRect(s.head)
        r.origin.y -= lineHeight
        r.size.height += lineHeight * 2
        r.origin.x -= 20
        r.size.width += 40
        scrollToVisible(r)
    }

    private func restartCaret() {
        caretVisible = true
        caretTimer?.invalidate()
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Not blinking where it's drawn steady (another window key, the
            // app in the back); blinking, only the carets drawn again — the
            // whole text was, every half second.
            guard self.window?.isKeyWindow == true, NSApp.isActive else {
                if !self.caretVisible { self.caretVisible = true; self.redrawCarets() }
                return
            }
            self.caretVisible.toggle()
            self.redrawCarets()
        }
    }

    private func redrawCarets() {
        for sel in selections { setNeedsDisplay(caretRect(sel.head).insetBy(dx: -2, dy: -1)) }
    }

    override func becomeFirstResponder() -> Bool {
        restartCaret()
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        caretTimer?.invalidate()
        caretTimer = nil
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: Editing

    /// Replaces each selection with `string` (or each with its own, given
    /// one per selection), as one undo step; carets land after the text.
    func insert(_ string: String, typing: Bool = true) {
        insert(selections.map { _ in string }, typing: typing)
    }

    func insert(_ strings: [String], typing: Bool) {
        guard isEditable, let document, strings.count == selections.count else { return }
        let before = selections
        var edits: [TextEdit] = []
        for (s, str) in zip(selections, strings) { edits.append(TextEdit(s.range, str)) }
        // Edits are applied last to first, so earlier offsets stand.
        let ordered = edits.sorted { $0.start > $1.start }
        var after: [Selection] = []
        var shift = 0
        for (s, str) in zip(selections, strings) {
            let caret = s.min + shift + str.utf8.count
            after.append(Selection(at: caret))
            shift += str.utf8.count - s.range.length
        }
        perform(ordered, selectionsBefore: before, selectionsAfter: after, typing: typing)
    }

    /// Applies edits (given from the end of the text backwards, so each
    /// one's offsets are in the text before it), records their undo, and
    /// moves the selections.
    private func perform(_ edits: [TextEdit], selectionsBefore: [Selection], selectionsAfter: [Selection], typing: Bool) {
        guard let document, !edits.isEmpty else { return }
        let text = document.rope
        // The inverse, in the same order (end first), against the text after.
        var inverse: [TextEdit] = []
        var shift = 0
        for e in edits.reversed() {
            let removed = text[e.range]
            let start = e.start + shift
            inverse.insert(TextEdit(start: start, end: start + e.text.utf8.count, text: removed), at: 0)
            shift += e.text.utf8.count - e.range.length
        }
        applyingOurs = true
        document.apply(edits)
        applyingOurs = false
        noteEdited(edits, document: document)
        let now = Date()
        if typing, var last = undoStack.last, last.typing, now.timeIntervalSince(last.at) < 1.2, redoStack.isEmpty,
           edits.count == 1, last.redo.count == 1, let lastRedo = last.redo.first,
           lastRedo.start + lastRedo.text.utf8.count == edits[0].start, edits[0].range.isEmpty, !edits[0].text.contains("\n") {
            // Typing runs on: one undo step.
            last.redo = [TextEdit(start: lastRedo.start, end: lastRedo.end, text: lastRedo.text + edits[0].text)]
            last.inverse = [TextEdit(start: lastRedo.start, end: lastRedo.start + last.redo[0].text.utf8.count, text: "")]
            last.selectionsAfter = selectionsAfter
            last.at = now
            undoStack[undoStack.count - 1] = last
        } else {
            undoStack.append(UndoGroup(inverse: inverse, redo: edits, selectionsBefore: selectionsBefore,
                                       selectionsAfter: selectionsAfter, at: now, typing: typing))
            let limit = undoLimit > 0 ? undoLimit : 2000
            if undoStack.count > limit {
                undoStack.removeFirst(undoStack.count - limit)
                savedUndoDepth = max(-1, savedUndoDepth - (undoStack.count - limit + 1))
            }
        }
        redoStack = []
        marked = nil
        highlightedLine = nil
        setSelections(selectionsAfter)
        delegate?.textViewDidEdit(self)
    }

    /// Keeps the layout in step with an edit of ours: lines after the
    /// change are shifted or dropped, rather than everything being laid
    /// out again.
    private func noteEdited(_ edits: [TextEdit], document: TextViewDocument) {
        let text = document.rope
        knownVersion = document.version
        let newCount = text.lineCount
        if newCount != knownLineCount || edits.count > 1 {
            // Lines came or went: the cache from the first change on is stale.
            let firstLine = edits.map { $0.start }.min().map { max(0, min(text.line(at: $0), knownLineCount - 1)) } ?? 0
            for k in layouts.keys where k >= firstLine { layouts.removeValue(forKey: k) }
            if newCount > knownLineCount {
                rowCounts.insert(contentsOf: Array(repeating: 1, count: newCount - knownLineCount), at: min(firstLine, rowCounts.count))
            } else if newCount < knownLineCount {
                let drop = min(knownLineCount - newCount, max(rowCounts.count - firstLine, 0))
                rowCounts.removeSubrange(firstLine..<firstLine + drop)
            }
            invalidateRowStarts(after: firstLine)
            knownLineCount = newCount
            fenceLines = nil
        } else if let e = edits.first {
            let n = text.line(at: e.start)
            layouts.removeValue(forKey: n)
            if markdown, let f = fenceLines, (Self.countBelow(n + 1, in: f) != Self.countBelow(n, in: f)) != MarkdownStyle.isFence(text.lineText(n)) {
                // A fence came or went: every line after it is in or out of a block.
                for k in layouts.keys where k > n { layouts.removeValue(forKey: k) }
                fenceLines = nil
            }
        }
        syntaxEdited(edits)
        foldsEdited(edits)
        foldsText = text
        pinnedChanged(edits)
        resizeToFit()
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        guard isEditable, let document, let group = undoStack.popLast() else { return }
        applyingOurs = true
        document.apply(group.inverse)
        applyingOurs = false
        noteEdited(group.inverse, document: document)
        redoStack.append(group)
        marked = nil
        setSelections(group.selectionsBefore)
        delegate?.textViewDidEdit(self)
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, let document, let group = redoStack.popLast() else { return }
        applyingOurs = true
        document.apply(group.redo)
        applyingOurs = false
        noteEdited(group.redo, document: document)
        undoStack.append(group)
        setSelections(group.selectionsAfter)
        delegate?.textViewDidEdit(self)
    }

    var undoDepth: Int { undoStack.count }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Replaces several ranges at once (a replace-all, a line operation):
    /// the ranges must not overlap. Carets go after each replacement.
    func replace(_ replacements: [(TextRange, String)], selectAfter: [Selection]? = nil) {
        guard isEditable, !replacements.isEmpty else { return }
        let before = selections
        let ordered = replacements.sorted { $0.0.start > $1.0.start }.map { TextEdit($0.0, $0.1) }
        var after: [Selection] = []
        var shift = 0
        for (r, s) in replacements.sorted(by: { $0.0.start < $1.0.start }) {
            after.append(Selection(at: r.start + shift + s.utf8.count))
            shift += s.utf8.count - r.length
        }
        perform(ordered, selectionsBefore: before, selectionsAfter: selectAfter ?? after, typing: false)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        endPeek()
        if delegate?.textView(self, handle: event) == true { return }
        if handleShortcut(event) { return }
        inputContext?.handleEvent(event)
    }

    /// Shortcuts the standard selectors don't cover.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers ?? ""
        switch (flags, chars) {
        case ([.command], "b") where acceptsBlockLinks: toggleWrap("**"); return true
        case ([.command], "i") where acceptsBlockLinks: toggleWrap("_"); return true
        case ([.command, .shift], "x") where acceptsBlockLinks: toggleWrap("~~"); return true
        case ([.command, .shift], "c") where acceptsBlockLinks: toggleWrap("`"); return true
        case ([.command], "d"): selectNextOccurrence(); return true
        case ([.command, .shift], "d"): duplicateLines(); return true
        case ([.control, .shift], "k"): deleteLines(); return true
        case ([.command], "/"): toggleComment(); return true
        case ([.control], "j"): joinLines(); return true
        // ⌃Space, or ⌥⎋ where ⌃Space switches the input source.
        case ([.control], " "), ([.option], "\u{1B}"): delegate?.textViewRequestsCompletion(self); return true
        case ([.command, .control], String(UnicodeScalar(NSUpArrowFunctionKey)!)): moveLines(up: true); return true
        case ([.command, .control], String(UnicodeScalar(NSDownArrowFunctionKey)!)): moveLines(up: false); return true
        case ([.control, .shift], String(UnicodeScalar(NSUpArrowFunctionKey)!)): addCaret(up: true); return true
        case ([.control, .shift], String(UnicodeScalar(NSDownArrowFunctionKey)!)): addCaret(up: false); return true
        case ([.option, .shift], String(UnicodeScalar(NSUpArrowFunctionKey)!)): addCaret(up: true); return true
        case ([.option, .shift], String(UnicodeScalar(NSDownArrowFunctionKey)!)): addCaret(up: false); return true
        default: return false
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(moveLeft(_:)): move { self.text.previous($0) }
        case #selector(moveRight(_:)): move { self.text.next($0) }
        case #selector(moveLeftAndModifySelection(_:)): extend { self.text.previous($0) }
        case #selector(moveRightAndModifySelection(_:)): extend { self.text.next($0) }
        case #selector(moveBackward(_:)): move { self.text.previous($0) }
        case #selector(moveForward(_:)): move { self.text.next($0) }
        case #selector(moveWordLeft(_:)), #selector(moveWordBackward(_:)): move(wordStart)
        case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)): move(wordEnd)
        case #selector(moveWordLeftAndModifySelection(_:)), #selector(moveWordBackwardAndModifySelection(_:)): extend(wordStart)
        case #selector(moveWordRightAndModifySelection(_:)), #selector(moveWordForwardAndModifySelection(_:)): extend(wordEnd)
        case #selector(moveUp(_:)): moveVertically(-1, extend: false)
        case #selector(moveDown(_:)): moveVertically(1, extend: false)
        case #selector(moveUpAndModifySelection(_:)): moveVertically(-1, extend: true)
        case #selector(moveDownAndModifySelection(_:)): moveVertically(1, extend: true)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): move(lineHome)
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): move(lineEnd)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)): extend(lineHome)
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)): extend(lineEnd)
        case #selector(moveToBeginningOfParagraph(_:)): move { self.text.offset(ofLine: self.text.line(at: $0)) }
        case #selector(moveToEndOfParagraph(_:)): move { self.text.lineRange(self.text.line(at: $0)).end }
        case #selector(moveToBeginningOfParagraphAndModifySelection(_:)): extend { self.text.offset(ofLine: self.text.line(at: $0)) }
        case #selector(moveToEndOfParagraphAndModifySelection(_:)): extend { self.text.lineRange(self.text.line(at: $0)).end }
        case #selector(moveToBeginningOfDocument(_:)): move { _ in 0 }
        case #selector(moveToEndOfDocument(_:)): move { _ in self.text.count }
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)): extend { _ in 0 }
        case #selector(moveToEndOfDocumentAndModifySelection(_:)): extend { _ in self.text.count }
        case #selector(pageUp(_:)), #selector(scrollPageUp(_:)): page(-1, extend: false)
        case #selector(pageDown(_:)), #selector(scrollPageDown(_:)): page(1, extend: false)
        case #selector(pageUpAndModifySelection(_:)): page(-1, extend: true)
        case #selector(pageDownAndModifySelection(_:)): page(1, extend: true)
        case #selector(scrollToBeginningOfDocument(_:)): scroll(NSPoint(x: 0, y: 0))
        case #selector(scrollToEndOfDocument(_:)): scroll(NSPoint(x: 0, y: max(0, frame.height - (enclosingScrollView?.contentSize.height ?? 0))))
        case #selector(deleteBackward(_:)): deleteBackward()
        case #selector(deleteForward(_:)): delete { Selection($0.head, self.text.next($0.head)) }
        case #selector(deleteWordBackward(_:)): delete { Selection(self.wordStart($0.head), $0.head) }
        case #selector(deleteWordForward(_:)): delete { Selection($0.head, self.wordEnd($0.head)) }
        case #selector(deleteToBeginningOfLine(_:)): delete { Selection(self.lineHome($0.head), $0.head) }
        case #selector(deleteToEndOfLine(_:)), #selector(deleteToEndOfParagraph(_:)):
            delete { s in
                let end = self.lineEnd(s.head)
                return Selection(s.head, end == s.head ? self.text.next(s.head) : end)
            }
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)): insertNewline()
        case #selector(insertTab(_:)), #selector(insertTabIgnoringFieldEditor(_:)): insertTab()
        case #selector(insertBacktab(_:)): outdent()
        case #selector(selectAll(_:)): setSelections([Selection(0, text.count)], scroll: false)
        case #selector(selectLine(_:)): selectLines()
        case #selector(selectWord(_:)): setSelections(selections.map { Selection(self.wordStart($0.head), self.wordEnd($0.head)) })
        case #selector(selectParagraph(_:)): selectLines()
        case #selector(cancelOperation(_:)):
            if selections.count > 1 { setSelections([primarySelection]) } else if !primarySelection.isCaret { setSelections([Selection(at: primarySelection.head)]) } else { nextResponder?.tryToPerform(selector, with: nil) }
        case #selector(transpose(_:)): transposeCharacters()
        case #selector(centerSelectionInVisibleArea(_:)): scrollToCaret()
        default:
            nextResponder?.tryToPerform(selector, with: nil)
        }
    }

    private func move(_ f: (Int) -> Int) {
        setSelections(selections.map { s in
            // A selection collapses to the end the move heads for.
            s.isCaret ? Selection(at: f(s.head)) : Selection(at: collapsed(s, f))
        })
    }

    /// Where a selection collapses to when moved: left to its start, right
    /// to its end, by what the move would do from its head.
    private func collapsed(_ s: Selection, _ f: (Int) -> Int) -> Int {
        let moved = f(s.head)
        return moved < s.head ? s.min : (moved > s.head ? s.max : s.head)
    }

    private func extend(_ f: (Int) -> Int) {
        setSelections(selections.map { Selection($0.anchor, f($0.head)) })
    }

    private func moveVertically(_ delta: Int, extend: Bool) {
        var out: [Selection] = []
        for s in selections {
            let p = position(of: s.head)
            let goalX = s.goalX ?? p.x
            let l = layout(line: p.line)
            var line = p.line, row = p.row + delta
            if row < 0 {
                guard line > 0 else { out.append(extend ? Selection(s.anchor, 0) : Selection(at: 0)); continue }
                line -= 1
                // Over folded lines, to the line they're folded under.
                while line > 0, hiddenLines.contains(line) { line -= 1 }
                row = layout(line: line).rows.count - 1
            } else if row >= l.rows.count {
                guard line + 1 < text.lineCount else { out.append(extend ? Selection(s.anchor, text.count) : Selection(at: text.count)); continue }
                line += 1
                while line + 1 < text.lineCount, hiddenLines.contains(line) { line += 1 }
                row = 0
            }
            let targetLayout = layout(line: line)
            let rowLine = targetLayout.rows[row]
            var u16 = CTLineGetStringIndexForPosition(rowLine, CGPoint(x: goalX, y: 0))
            if u16 == kCFNotFound { u16 = 0 }
            let rowEnd = row + 1 < targetLayout.rowStarts.count ? targetLayout.rowStarts[row + 1] : (targetLayout.text as NSString).length
            if u16 > rowEnd { u16 = rowEnd }
            if row + 1 < targetLayout.rows.count, u16 == rowEnd { u16 = max(rowEnd - 1, targetLayout.rowStarts[row]) }
            let offset = text.offset(ofLine: line) + byteOffset(in: targetLayout.text, utf16Index: u16)
            var moved = extend ? Selection(s.anchor, offset) : Selection(at: offset)
            moved.goalX = goalX
            out.append(moved)
        }
        setSelections(out)
    }

    /// Page Up and Down: the view a screenful on, two lines kept, and
    /// each caret along with it, where it was on the screen — or, at the
    /// end it's going to, to the start or end of the text.
    private func page(_ direction: Int, extend: Bool) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.height
        let step = max(lineHeight, visible - 2 * lineHeight) * CGFloat(direction)
        let top = min(max(0, clip.bounds.origin.y + step), max(0, frame.height - visible))
        var out: [Selection] = []
        let shown = clip.bounds
        for s in selections {
            let r = caretRect(s.head)
            let goalX = s.goalX ?? (r.minX - textLeft)
            // A caret scrolled out of sight pages from the view's edge, not
            // from where it is, so the view goes on rather than back.
            let y = min(max(r.midY, shown.minY + lineHeight / 2), shown.maxY - lineHeight / 2) + step
            let offset = y < 0 ? 0 : y > frame.height ? text.count : self.offset(at: NSPoint(x: textLeft + goalX, y: y))
            var moved = extend ? Selection(s.anchor, offset) : Selection(at: offset)
            moved.goalX = goalX
            out.append(moved)
        }
        scroll(NSPoint(x: clip.bounds.origin.x, y: top))
        setSelections(out)
    }

    private func lineHome(_ offset: Int) -> Int {
        // First to the indentation, then to the very beginning.
        let n = text.line(at: offset)
        let start = text.offset(ofLine: n)
        let line = text.lineText(n)
        let indent = line.prefix { $0 == " " || $0 == "\t" }.utf8.count
        return offset == start + indent || offset < start + indent ? start : start + indent
    }

    private func lineEnd(_ offset: Int) -> Int { text.lineRange(text.line(at: offset)).end }

    private func isWord(_ b: UInt8) -> Bool { b == 0x5F || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b >= 0x80 }

    // MARK: Peek

    /// The name the pointer rests on, waited on before it's peeked at.
    private var peekWord: TextRange?
    private var peekWork: DispatchWorkItem?

    /// The pointer moved: over a name in code, a peek at it a moment after
    /// it stops there; off it, any peek put away.
    private func notePeek(at p: NSPoint, event: NSEvent) {
        if Date() < debugPeekUntil { return }
        guard showsSymbolUses, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]), !text.isEmpty,
              p.x >= textLeft, let w = word(at: p) else { return endPeek() }
        guard w != peekWord else { return }
        endPeek()
        peekWord = w
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.peekWord == w, let window = self.window else { return }
            let r = self.rects(of: w).first ?? .zero
            self.delegate?.textView(self, peekAt: w, in: self.convert(r, to: nil))
            _ = window
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// The pointer's off the name (or a key went down, the text scrolled).
    func endPeek() {
        peekWork?.cancel()
        peekWork = nil
        peekWord = nil
        PeekTip.shared.hide()
    }

    /// Debugging: a peek at the name at a byte, as if the pointer rested there.
    private var debugPeekUntil = Date.distantPast

    func debugPeek(at offset: Int) {
        // (The pointer's own moves don't put it away meanwhile.)
        debugPeekUntil = Date().addingTimeInterval(4)
        let w = wordRange(at: offset)
        peekWord = w
        delegate?.textView(self, peekAt: w, in: convert(rects(of: w).first ?? .zero, to: nil))
    }

    /// Whether the name a peek was asked about is still the one rested on.
    func stillPeeking(at w: TextRange) -> Bool { peekWord == w }

    /// The name under a point: a word of code's, the point over its letters.
    private func word(at p: NSPoint) -> TextRange? {
        let o = offset(at: p)
        let w = wordRange(at: o)
        guard w.length >= 2, let first = text.byte(at: w.start), !(first >= 0x30 && first <= 0x39),
              let r = rects(of: w).first, r.insetBy(dx: -1, dy: 0).contains(p) else { return nil }
        if let syntax, let q = syntax.language.commentQuery, !syntax.captures(q, in: w).isEmpty { return nil }
        return w
    }

    // MARK: Pinned highlights

    /// Symbols whose uses stay tinted, each its own colour (⌃⌘E), until
    /// unpinned or cleared: several followed through the text at once.
    private var pinned: [Pin] = [] { didSet { pinnedRanges = nil; needsDisplay = true } }
    private var pinnedRanges: [(TextRange, NSColor)]?

    /// A pinned symbol: its name, its colour, where it was pinned (moved
    /// through edits), and its uses as its language server said (nil: its
    /// name's whole words, the server not knowing).
    private struct Pin {
        var word: String
        var color: NSColor
        var at: Int
        var uses: [TextRange]?
    }
    static let pinColors: [NSColor] = Palette.current.code.pins.indices.map { i in
        NSColor.themed { $0.code.pins[i % $0.code.pins.count] }
    }

    /// Highlight Uses (⌃⌘E): the caret's symbol's uses pinned in the next
    /// colour; again on a pinned one, unpinned.
    @objc func highlightUses(_ sender: Any?) {
        let w = wordRange(at: primarySelection.head)
        guard w.length >= 1 else { return NSSound.beep() }
        let word = text[w]
        // Again on one of a pinned symbol's uses: unpinned.
        if let i = pinned.firstIndex(where: { p in p.uses.map { $0.contains { $0.start <= w.start && $0.end >= w.end } } ?? (p.word == word) }) {
            pinned.remove(at: i)
            return
        }
        let used = Set(pinned.map { ObjectIdentifier($0.color) })
        let color = Self.pinColors.first { !used.contains(ObjectIdentifier($0)) } ?? Self.pinColors[pinned.count % Self.pinColors.count]
        if pinned.count >= Self.pinColors.count { pinned.removeFirst() }
        pinned.append(Pin(word: word, color: color, at: w.start, uses: nil))
        askPinnedUses()
    }

    /// The pinned symbols' uses asked of the language server (again after
    /// the text changes, a moment after the last change).
    private var pinWork: DispatchWorkItem?
    private func askPinnedUses() {
        for p in pinned {
            let at = p.at, version = document?.version
            delegate?.textView(self, usesAt: at) { [weak self] uses in
                guard let self, self.document?.version == version, let i = self.pinned.firstIndex(where: { $0.at == at }) else { return }
                self.pinned[i].uses = uses.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }

    /// The text changed (by `edits`, or, nil, by what's not known): pinned
    /// places moved through it, asked again a moment after.
    private func pinnedChanged(_ edits: [TextEdit]?) {
        pinnedRanges = nil
        guard !pinned.isEmpty else { return }
        for i in pinned.indices {
            guard let edits else { pinned[i].uses = nil; continue }
            for e in edits {
                pinned[i].at = TextRange(at: pinned[i].at).moved(by: e).start
                pinned[i].uses = pinned[i].uses?.compactMap { r in
                    e.start < r.end && e.end > r.start ? nil : r.moved(by: e)
                }
            }
        }
        // A pin whose name isn't where it was any more: by its name again.
        for i in pinned.indices where text[wordRange(at: min(pinned[i].at, text.count))] != pinned[i].word {
            if let hit = text.findAll(pinned[i].word, limit: 1).first { pinned[i].at = hit.start }
        }
        pinWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.askPinnedUses() }
        pinWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Clear Highlights: every pinned symbol unpinned.
    @objc func clearHighlights(_ sender: Any?) { pinned = [] }

    /// The pinned symbols' uses: the language server's, else their names'
    /// whole words not in comments (found once a text, again after it changes).
    private func pinnedUses() -> [(TextRange, NSColor)] {
        if let r = pinnedRanges { return r }
        var out: [(TextRange, NSColor)] = []
        for p in pinned {
            let (word, color) = (p.word, p.color)
            if let uses = p.uses {
                out += uses.filter { $0.end <= text.count }.map { ($0, color) }
                continue
            }
            for hit in text.findAll(word, limit: 5000) {
                let before = hit.start > 0 ? text.byte(at: hit.start - 1) : nil, after = text.byte(at: hit.end)
                guard before.map(isWord) != true, after.map(isWord) != true else { continue }
                if let syntax, let q = syntax.language.commentQuery, !syntax.captures(q, in: hit).isEmpty { continue }
                out.append((hit, color))
            }
        }
        pinnedRanges = out
        return out
    }

    /// The caret's symbol's other uses in the text (code, not Markdown):
    /// the same word, whole, elsewhere — a moment after the caret stops.
    private(set) var symbolUses: [TextRange] = [] { didSet { if symbolUses != oldValue { needsDisplay = true } } }
    var showsSymbolUses = false
    private var usesWork: DispatchWorkItem?

    private func scheduleSymbolUses() {
        usesWork?.cancel()
        guard showsSymbolUses, !markdown, selections.count == 1, let s = selections.first, s.isCaret, text.count < 4_000_000 else {
            symbolUses = []
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.findSymbolUses(at: s.head) }
        usesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func findSymbolUses(at offset: Int) {
        let w = wordRange(at: offset)
        guard w.length >= 2, let first = text.byte(at: w.start), !(first >= 0x30 && first <= 0x39) else { return symbolUses = [] }
        if let syntax, let q = syntax.language.commentQuery, !syntax.captures(q, in: w).isEmpty { return symbolUses = [] }
        // That symbol's uses, as its language server says; else the name's.
        let version = document?.version
        delegate?.textView(self, usesAt: w.start) { [weak self] uses in
            guard let self, self.document?.version == version, self.selections.count == 1,
                  self.wordRange(at: self.primarySelection.head) == w else { return }
            if let uses { self.symbolUses = uses.filter { $0 != w } } else { self.symbolUses = self.textualUses(of: w) }
        }
    }

    /// A name's other whole words in the text, not in comments.
    private func textualUses(of w: TextRange) -> [TextRange] {
        let word = text[w]
        var out: [TextRange] = []
        for hit in text.findAll(word, limit: 2000) where hit != w {
            // Whole words only.
            let before = hit.start > 0 ? text.byte(at: hit.start - 1) : nil, after = text.byte(at: hit.end)
            guard before.map(isWord) != true, after.map(isWord) != true else { continue }
            // Not words in a comment, which the grammar knows.
            if let syntax, let q = syntax.language.commentQuery, !syntax.captures(q, in: hit).isEmpty { continue }
            out.append(hit)
        }
        return out
    }

    /// The word around an offset, for the symbol under the caret.
    func wordRange(at offset: Int) -> TextRange {
        var a = offset, b = offset
        while a > 0, let c = text.byte(at: a - 1), isWord(c) { a -= 1 }
        while b < text.count, let c = text.byte(at: b), isWord(c) { b += 1 }
        return TextRange(a, b)
    }

    private func wordStart(_ offset: Int) -> Int {
        var o = offset
        while o > 0, let b = text.byte(at: o - 1), !isWord(b), b != 0x0A { o -= 1 }
        if o > 0, text.byte(at: o - 1) == 0x0A, o == offset { return o - 1 }
        while o > 0, let b = text.byte(at: o - 1), isWord(b) { o -= 1 }
        return o
    }

    private func wordEnd(_ offset: Int) -> Int {
        var o = offset
        let n = text.count
        while o < n, let b = text.byte(at: o), !isWord(b), b != 0x0A { o += 1 }
        if o < n, text.byte(at: o) == 0x0A, o == offset { return o + 1 }
        while o < n, let b = text.byte(at: o), isWord(b) { o += 1 }
        return o
    }

    private func delete(_ f: (Selection) -> Selection) {
        guard isEditable else { return }
        let ranges = selections.map { s -> Selection in s.isCaret ? f(s) : s }
        let before = selections
        selections = ranges
        normalizeSelections()
        insert(selections.map { _ in "" }, typing: false)
        _ = before
    }

    private func deleteBackward() {
        guard isEditable else { return }
        // A pair typed, deleted together; else one character.
        delete { s in
            if let a = self.text.byte(at: s.head - 1), let b = self.text.byte(at: s.head),
               let pair = Self.pairs[Character(UnicodeScalar(a))], pair == Character(UnicodeScalar(b)) {
                return Selection(self.text.previous(s.head), self.text.next(s.head))
            }
            return Selection(self.text.previous(s.head), s.head)
        }
    }

    private func insertNewline() {
        if markdown, markdownNewline() { return }
        // Indented as the line before, and a step more after an opening bracket.
        let strings = selections.map { s -> String in
            let n = text.line(at: s.min)
            let line = text.lineText(n)
            let lineStart = text.offset(ofLine: n)
            let head = String(decoding: Array(line.utf8.prefix(s.min - lineStart)), as: UTF8.self)
            var indent = String(head.prefix { $0 == " " || $0 == "\t" })
            if let last = head.last, "{[(".contains(last) { indent += indentUnit }
            return "\n" + indent
        }
        insert(strings, typing: false)
        // A closing bracket right after the caret goes to its own line.
        var extra: [(TextRange, String)] = []
        for s in selections {
            if let b = text.byte(at: s.head), "}])".utf8.contains(b) {
                let n = text.line(at: s.head)
                let line = text.lineText(n)
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let outdent = String(indent.dropLast(indentUnit.count))
                extra.append((TextRange(at: s.head), "\n" + outdent))
            }
        }
        if !extra.isEmpty {
            let keep = selections
            replace(extra, selectAfter: keep)
        }
    }

    private var indentUnit: String { String(repeating: " ", count: tabWidth) }

    // MARK: Markdown

    /// Return in a list or a quote carries it on (§7): the next item's
    /// marker (the next number, an empty box), the quote's mark; on an
    /// empty item, it ends instead, the marker taken away.
    private func markdownNewline() -> Bool {
        var inserts: [String] = []
        var clears: [(TextRange, String)] = []
        for s in selections {
            guard s.isCaret else { return false }
            let n = text.line(at: s.head)
            let start = text.offset(ofLine: n)
            guard let c = Self.continuation(of: text.lineText(n), caretAt: s.head - start) else { return false }
            switch c {
            case .insert(let str): inserts.append(str)
            case .clear(let length): clears.append((TextRange(start, start + length), ""))
            }
        }
        if !clears.isEmpty {
            guard inserts.isEmpty else { return false }
            replace(clears)
        } else {
            insert(inserts, typing: false)
        }
        return true
    }

    enum Continuation: Equatable {
        case insert(String)
        /// The line's marker, this many bytes from its start, goes.
        case clear(Int)
    }

    private static let listHead = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s*)?"#)
    private static let quoteHead = try! NSRegularExpression(pattern: #"^(\s*>\s?)+"#)

    /// What Return does at a caret on a line, if the line is a list item
    /// or a quote: nil for a plain newline.
    static func continuation(of line: String, caretAt col: Int) -> Continuation? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = listHead.firstMatch(in: line, range: all) {
            // The head is ASCII: its UTF-16 length is its byte length.
            guard col >= m.range.length else { return nil }
            let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return col == ns.length ? .clear(m.range.length) : nil }
            var marker = ns.substring(with: m.range(at: 2))
            if m.range(at: 3).location != NSNotFound, let number = Int(ns.substring(with: m.range(at: 3))) {
                marker = "\(number + 1)" + ns.substring(with: m.range(at: 4))
            }
            let box = m.range(at: 6).location == NSNotFound ? "" : "[ ] "
            return .insert("\n" + ns.substring(with: m.range(at: 1)) + marker + " " + box)
        }
        if let m = quoteHead.firstMatch(in: line, range: all) {
            guard col >= m.range.length else { return nil }
            let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return col == ns.length ? .clear(m.range.length) : nil }
            return .insert("\n" + ns.substring(with: m.range))
        }
        return nil
    }

    /// ⌘B, ⌘I, ⌘⇧X, ⌘⇧C: the selection wrapped in a marker — or, wrapped
    /// already, unwrapped; a caret gets the pair to type into.
    private func toggleWrap(_ m: String) {
        guard isEditable else { return }
        let ml = m.utf8.count
        var reps: [(TextRange, String)] = []
        var after: [Selection] = []
        var shift = 0
        for s in selections.sorted(by: { $0.min < $1.min }) {
            let inner = text[TextRange(s.min, s.max)]
            let before = s.min >= ml ? text[TextRange(s.min - ml, s.min)] : ""
            let following = s.max + ml <= text.count ? text[TextRange(s.max, s.max + ml)] : ""
            if before == m, following == m {
                reps.append((TextRange(s.min - ml, s.max + ml), inner))
                after.append(Selection(s.min - ml + shift, s.max - ml + shift))
                shift -= 2 * ml
            } else if inner.hasPrefix(m), inner.hasSuffix(m), inner.utf8.count >= 2 * ml {
                let stripped = String(inner.dropFirst(m.count).dropLast(m.count))
                reps.append((s.range, stripped))
                after.append(Selection(s.min + shift, s.min + shift + stripped.utf8.count))
                shift -= 2 * ml
            } else {
                reps.append((s.range, m + inner + m))
                after.append(Selection(s.min + ml + shift, s.max + ml + shift))
                shift += 2 * ml
            }
        }
        replace(reps, selectAfter: after)
    }

    private func insertTab() {
        if selections.contains(where: { !$0.isCaret && text.line(at: $0.min) != text.line(at: $0.max) }) {
            indent()
        } else {
            insert(indentUnit, typing: true)
        }
    }

    private func selectedLines() -> [Int] {
        var lines = Set<Int>()
        for s in selections {
            var end = s.max
            if !s.isCaret, end > s.min, text.byte(at: end - 1) == 0x0A { end -= 1 }
            for n in text.line(at: s.min)...text.line(at: end) { lines.insert(n) }
        }
        return lines.sorted()
    }

    private func indent() {
        let lines = selectedLines()
        let before = selections
        replace(lines.map { (TextRange(at: text.offset(ofLine: $0)), indentUnit) },
                selectAfter: before.map { Selection(shifted($0.anchor, by: lines, unit: indentUnit.utf8.count), shifted($0.head, by: lines, unit: indentUnit.utf8.count)) })
    }

    private func shifted(_ offset: Int, by lines: [Int], unit: Int) -> Int {
        let n = text.line(at: offset)
        return offset + unit * lines.filter { $0 <= n }.count
    }

    private func outdent() {
        var edits: [(TextRange, String)] = []
        for n in selectedLines() {
            let start = text.offset(ofLine: n)
            let line = text.lineText(n)
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            var take = 0
            if lead.first == "\t" { take = 1 } else { take = min(lead.count, tabWidth) }
            if take > 0 { edits.append((TextRange(start, start + take), "")) }
        }
        guard !edits.isEmpty else { return }
        let before = selections
        let text = self.text
        replace(edits, selectAfter: before.map { s in
            func shift(_ o: Int) -> Int {
                var o = o
                for (r, _) in edits.sorted(by: { $0.0.start > $1.0.start }) where r.start < o {
                    o -= min(r.length, o - r.start)
                }
                return max(o, 0)
            }
            _ = text
            return Selection(shift(s.anchor), shift(s.head))
        })
    }

    private func selectLines() {
        setSelections(selections.map { s in
            let start = text.offset(ofLine: text.line(at: s.min))
            let endLine = text.line(at: s.max)
            let end = endLine + 1 < text.lineCount ? text.offset(ofLine: endLine + 1) : text.count
            return Selection(start, end)
        })
    }

    private func transposeCharacters() {
        guard let s = selections.first, selections.count == 1, s.isCaret, s.head > 0, s.head < text.count else { return }
        let a = text.previous(s.head), b = text.next(s.head)
        let swapped = text[TextRange(s.head, b)] + text[TextRange(a, s.head)]
        replace([(TextRange(a, b), swapped)])
    }

    /// ⌥⌘E: with a word under the caret, selects it; with a selection, adds
    /// the next occurrence as another selection.
    private func selectNextOccurrence() {
        guard let last = selections.last else { return }
        if last.isCaret {
            setSelections(selections.dropLast() + [Selection(wordStart(last.head), wordEnd(last.head))])
            return
        }
        let needle = text[last.range]
        guard !needle.isEmpty else { return }
        let from = selections.map(\.max).max() ?? 0
        if let r = text.find(needle, from: from) ?? text.find(needle, from: 0) {
            if !selections.contains(where: { $0.range == r }) {
                setSelections(selections + [Selection(r.start, r.end)])
            }
        }
    }

    private func addCaret(up: Bool) {
        var out = selections
        for s in selections {
            let p = position(of: s.head)
            let line = p.line + (up ? -1 : 1)
            guard line >= 0, line < text.lineCount else { continue }
            let l = layout(line: line)
            let row = up ? l.rows.count - 1 : 0
            var u16 = CTLineGetStringIndexForPosition(l.rows[row], CGPoint(x: p.x, y: 0))
            if u16 == kCFNotFound { u16 = 0 }
            let offset = text.offset(ofLine: line) + byteOffset(in: l.text, utf16Index: min(u16, (l.text as NSString).length))
            out.append(Selection(at: offset))
        }
        setSelections(out)
    }

    private func duplicateLines() {
        let lines = selectedLines()
        guard let first = lines.first, let last = lines.last else { return }
        let start = text.offset(ofLine: first)
        let end = last + 1 < text.lineCount ? text.offset(ofLine: last + 1) : text.count
        var block = text[TextRange(start, end)]
        if !block.hasSuffix("\n") { block = "\n" + block }
        let before = selections
        let shift = block.utf8.count
        replace([(TextRange(at: end), block)], selectAfter: before.map { Selection($0.anchor + shift, $0.head + shift) })
    }

    /// ⇧⌘K (and ⌃⇧K): the lines the selections are on, gone.
    @objc func deleteLine(_ sender: Any?) { deleteLines() }

    // Edit ▸ Lines, Selection and Format: what handleShortcut's keys do,
    // there to be found in the menus.
    @objc func duplicateLine(_ sender: Any?) { duplicateLines() }
    @objc func moveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(up: false) }
    @objc func joinLine(_ sender: Any?) { joinLines() }
    @objc func toggleLineComment(_ sender: Any?) { toggleComment() }
    @objc func addNextOccurrence(_ sender: Any?) { selectNextOccurrence() }
    @objc func addCaretAbove(_ sender: Any?) { addCaret(up: true) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(up: false) }
    @objc func formatBold(_ sender: Any?) { toggleWrap("**") }
    @objc func formatItalic(_ sender: Any?) { toggleWrap("_") }
    @objc func formatStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func formatCode(_ sender: Any?) { toggleWrap("`") }

    private func deleteLines() {
        let lines = selectedLines()
        guard let first = lines.first, let last = lines.last else { return }
        let start = text.offset(ofLine: first)
        var end = last + 1 < text.lineCount ? text.offset(ofLine: last + 1) : text.count
        var s = start
        if end == text.count, start > 0, end > start { s = start - 1 } else if end == text.count { end = text.count }
        replace([(TextRange(s, end), "")], selectAfter: [Selection(at: min(s, max(0, text.count - (end - s))))])
    }

    private func joinLines() {
        var edits: [(TextRange, String)] = []
        for s in selections {
            let n = text.line(at: s.max)
            guard n + 1 < text.lineCount else { continue }
            let r = text.lineRange(n)
            let next = text.lineText(n + 1)
            let lead = next.prefix { $0 == " " || $0 == "\t" }.utf8.count
            edits.append((TextRange(r.end, r.end + 1 + lead), " "))
        }
        guard !edits.isEmpty else { return }
        replace(edits)
    }

    private func moveLines(up: Bool) {
        let lines = selectedLines()
        guard let first = lines.first, let last = lines.last else { return }
        if up, first == 0 { return }
        if !up, last + 1 >= text.lineCount { return }
        let start = text.offset(ofLine: first)
        let end = text.lineRange(last).end
        let block = text[TextRange(start, end)]
        let before = selections
        if up {
            let prevStart = text.offset(ofLine: first - 1)
            let prev = text[TextRange(prevStart, start - 1)]
            let delta = -(prev.utf8.count + 1)
            replace([(TextRange(prevStart, end), block + "\n" + prev)], selectAfter: before.map { Selection($0.anchor + delta, $0.head + delta) })
        } else {
            let nextEnd = text.lineRange(last + 1).end
            let next = text[TextRange(end + 1, nextEnd)]
            let delta = next.utf8.count + 1
            replace([(TextRange(start, nextEnd), next + "\n" + block)], selectAfter: before.map { Selection($0.anchor + delta, $0.head + delta) })
        }
    }

    /// The comment leader for the file, by its extension.
    var commentLeader = "//"

    private func toggleComment() {
        let lines = selectedLines()
        guard !lines.isEmpty else { return }
        let leader = commentLeader + " "
        let all = lines.allSatisfy { text.lineText($0).trimmingCharacters(in: .whitespaces).hasPrefix(commentLeader) || text.lineText($0).trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = lines.map { text.lineText($0).prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        var edits: [(TextRange, String)] = []
        for n in lines {
            let line = text.lineText(n)
            let start = text.offset(ofLine: n)
            if all {
                guard let r = line.range(of: commentLeader) else { continue }
                let lead = line.utf8.distance(from: line.utf8.startIndex, to: r.lowerBound.samePosition(in: line.utf8)!)
                var len = commentLeader.utf8.count
                if line[r.upperBound...].hasPrefix(" ") { len += 1 }
                edits.append((TextRange(start + lead, start + lead + len), ""))
            } else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                edits.append((TextRange(at: start + indent), leader))
            }
        }
        guard !edits.isEmpty else { return }
        let before = selections
        replace(edits, selectAfter: before.map { s in
            func shift(_ o: Int) -> Int {
                var o = o
                for (r, t) in edits where r.start <= o { o += t.utf8.count - r.length }
                return max(0, o)
            }
            return Selection(shift(s.anchor), shift(s.head))
        })
    }

    // MARK: Pairs

    static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]

    /// Typed text, with brackets and quotes paired: an opener gets its
    /// closer after the caret; a closer typed over one steps past it.
    private func insertTyped(_ string: String) {
        if string.count == 1, let ch = string.first, selections.allSatisfy(\.isCaret) {
            if let close = Self.pairs[ch] {
                let ahead = selections.allSatisfy { s in
                    guard let b = text.byte(at: s.head) else { return true }
                    return b == 0x0A || b == 0x20 || b == 0x09 || ")]}".utf8.contains(b)
                }
                let quote = ch == "\"" || ch == "'" || ch == "`"
                let behindWord = selections.contains { s in
                    guard let b = text.byte(at: s.head - 1) else { return false }
                    return isWord(b)
                }
                if ahead, !(quote && behindWord) {
                    let before = selections
                    insert(String(ch) + String(close), typing: false)
                    setSelections(zip(before, selections).map { _, s in Selection(at: s.head - String(close).utf8.count) })
                    return
                }
            }
            if ")]}\"'`".contains(ch), selections.allSatisfy({ s in text.byte(at: s.head).map { Character(UnicodeScalar($0)) } == ch }) {
                setSelections(selections.map { Selection(at: self.text.next($0.head)) })
                return
            }
        }
        insert(string, typing: true)
    }

    // MARK: Mouse

    // MARK: Drops

    /// Things dropped on the text go in where the pointer is (§3.11): in a
    /// note or Markdown, a block's (or a file's, a place's) link, a picture
    /// kept and shown, a page's link; in code a file's path; words as they
    /// are — ⌃ for the rest. A text that can't be edited takes none: the
    /// grid behind does (a tile of its own, a link to the tile).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { Dropping.updated(self, sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDropTracking()
        Dropping.exited(self, sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        endDropTracking()
        return Dropping.perform(self, sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { endDropTracking() }

    /// A drag over the text: the caret follows it, but the lines it passes
    /// stay as they read (a card stays a card), not shown as written.
    private var dropTracking = false

    private func endDropTracking() {
        guard dropTracking else { return }
        dropTracking = false
        setSelections(selections, scroll: false)
    }

    /// Whether it's a note or Markdown: a block lands as a link to it, a
    /// picture inline.
    var acceptsBlockLinks = false

    /// The block a `[title](manifold:host/ulid)` link names.
    static func blockID(inLink link: String) -> BlockID? {
        guard let r = link.range(of: "](manifold:"), let end = link[r.upperBound...].firstIndex(of: ")") else { return nil }
        return BlockID.link(String(link[r.upperBound..<end]))?.block
    }

    override func mouseDown(with event: NSEvent) {
        endPeek()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let offset = self.offset(at: p)
        let flags = event.modifierFlags
        dragMode = min(event.clickCount, 3)
        // A note about a place clicked: the note, followed as its link is;
        // a fold's chip, the lines opened.
        if event.clickCount == 1, let n = noteLayouts.keys.first(where: { noteRect(ofLine: $0)?.contains(p) == true }),
           let note = placeByLine[n]?.note {
            delegate?.textView(self, follow: note.target, over: flags.contains(.option))
            return
        }
        if event.clickCount == 1, let (_, i) = foldChips.first(where: { $0.value.rect.contains(p) }).map({ ($0.key, $0.value.fold) }), i < folds.count {
            folds.remove(at: i)
            return
        }
        // Pressed in the gutter: its line may be dragged out, as a
        // reference to what's there; let go without moving, a click.
        if event.clickCount == 1, gutterWidth > 0, p.x < textLeft, flags.isDisjoint(with: [.shift, .option, .command]) {
            pressedInGutter = (event.locationInWindow, text.line(at: offset))
        }
        // A block's card clicked: followed, as its link is.
        if event.clickCount == 1, let n = cardLines.keys.first(where: { cardRect(ofLine: $0)?.contains(p) == true }), let c = cardLines[n] {
            dragAnchor = nil
            delegate?.textView(self, follow: c.target, over: flags.contains(.option))
            return
        }
        if event.clickCount == 1, !flags.contains(.shift) || flags.contains(.command), let target = linkTarget(at: p) {
            // A link, clicked: followed by the one rule (⌘ beside, ⌥ over,
            // ⇧⌘ the system's app) — the caret stays, so the pill does.
            // ⌘-click is a link's before it's go-to-definition.
            dragAnchor = nil
            delegate?.textView(self, follow: target, over: flags.contains(.option))
            return
        }
        if flags.contains(.command), event.clickCount == 1 {
            setSelections([Selection(at: offset)])
            dragAnchor = nil
            delegate?.textView(self, commandClickAt: offset, over: flags.contains(.option))
            return
        }
        if flags.contains(.shift), let last = selections.last {
            setSelections(selections.dropLast() + [Selection(last.anchor, offset)])
            dragAnchor = Selection(last.anchor, offset)
            return
        }
        // Pressed in the selection: it may be dragged out (as a text view's
        // is); let go without moving, and it's a click.
        if event.clickCount == 1, flags.isDisjoint(with: [.option, .command]),
           selections.contains(where: { !$0.isCaret && $0.min <= offset && offset < $0.max }) {
            pressedInSelection = (event.locationInWindow, offset)
            dragAnchor = nil
            return
        }
        var sel: Selection
        switch dragMode {
        case 2: sel = Selection(wordStart(offset), wordEnd(offset))
        case 3:
            let n = text.line(at: offset)
            let end = n + 1 < text.lineCount ? text.offset(ofLine: n + 1) : text.count
            sel = Selection(text.offset(ofLine: n), end)
        default: sel = Selection(at: offset)
        }
        if flags.contains(.option) {
            setSelections(selections + [sel])
        } else {
            setSelections([sel])
        }
        dragAnchor = sel
    }

    /// Where the mouse went down in the selection, while it may yet drag it.
    private var pressedInSelection: (at: NSPoint, offset: Int)?
    /// Where it went down in the gutter, and on which line.
    private var pressedInGutter: (at: NSPoint, line: Int)?

    override func mouseDragged(with event: NSEvent) {
        if let pressed = pressedInGutter {
            let p = event.locationInWindow
            guard hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 4 else { return }
            pressedInGutter = nil
            if dragLine(pressed.line, event) { return }
        }
        if let pressed = pressedInSelection {
            let p = event.locationInWindow
            guard hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 4 else { return }
            pressedInSelection = nil
            dragSelection(event)
            return
        }
        guard let anchor = dragAnchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        let offset = self.offset(at: p)
        let s: Selection
        switch dragMode {
        case 2:
            s = offset < anchor.min ? Selection(anchor.max, wordStart(offset)) : Selection(anchor.min, wordEnd(offset))
        case 3:
            let n = text.line(at: offset)
            if offset < anchor.min {
                s = Selection(anchor.max, text.offset(ofLine: n))
            } else {
                s = Selection(anchor.min, n + 1 < text.lineCount ? text.offset(ofLine: n + 1) : text.count)
            }
        default:
            s = Selection(anchor.anchor, offset)
        }
        setSelections(selections.dropLast() + [s], scroll: false)
    }

    override func mouseUp(with event: NSEvent) {
        // Pressed in the selection and let go: a click there, the caret put down.
        if let pressed = pressedInSelection { setSelections([Selection(at: pressed.offset)]) }
        pressedInSelection = nil
        // A click on a place's mark in the gutter: what links to it, and from it.
        if let pressed = pressedInGutter, let place = placeByLine[pressed.line], !place.links.isEmpty {
            showLinks(of: place, at: convert(event.locationInWindow, from: nil))
        }
        pressedInGutter = nil
        dragAnchor = nil
    }

    /// A line dragged from the gutter: a reference to what's there (the
    /// delegate's), shown as the line's words; false if it carries nothing.
    private func dragLine(_ line: Int, _ event: NSEvent) -> Bool {
        guard let writer = delegate?.textView(self, dragLine: line) else { return false }
        let drag = NSDraggingItem(pasteboardWriter: writer)
        let words = text.lineText(line).trimmingCharacters(in: .whitespaces)
        let label = NSAttributedString(string: String(words.prefix(80)), attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let size = NSSize(width: min(ceil(label.size().width) + 16, 420), height: ceil(label.size().height) + 8)
        let image = NSImage(size: size, flipped: false) { r in
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            label.draw(in: r.insetBy(dx: 8, dy: 4))
            return true
        }
        let p = convert(event.locationInWindow, from: nil)
        drag.setDraggingFrame(NSRect(x: p.x - 8, y: p.y - size.height + 8, width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
        return true
    }

    /// The selected text, dragged: to another app, a terminal, a note, or
    /// elsewhere here (where it's put as a copy).
    private func dragSelection(_ event: NSEvent) {
        let s = selectedText
        guard !s.isEmpty else { return }
        // Its place too, where there's one to refer to (one selection).
        let one = selections.filter { !$0.isCaret }
        let writer: NSPasteboardWriting = one.count == 1 ? delegate?.textView(self, dragSelection: one[0].range, text: s) ?? Self.words(s) : Self.words(s)
        let drag = NSDraggingItem(pasteboardWriter: writer)
        let shown = String(s.prefix(200)).replacingOccurrences(of: "\t", with: "  ")
        let label = NSAttributedString(string: shown.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n"),
                                       attributes: [.font: UIType.body, .foregroundColor: NSColor.labelColor])
        let size = NSSize(width: min(ceil(label.size().width) + 12, 420), height: min(ceil(label.size().height) + 8, 140))
        let image = NSImage(size: size, flipped: false) { r in
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            label.draw(in: r.insetBy(dx: 6, dy: 4))
            return true
        }
        let p = convert(event.locationInWindow, from: nil)
        drag.setDraggingFrame(NSRect(x: p.x - 8, y: p.y - size.height + 8, width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    private static func words(_ s: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        return item
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    /// The pointer over a link, or a name ⌘ shows as one: the pointing hand.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isUnderPointer else { return }
        notePeek(at: convert(event.locationInWindow, from: nil), event: event)
        let target = linkTarget(at: convert(event.locationInWindow, from: nil))
        ReferenceTip.hover(target, in: self)
        let over = target != nil
        let chip = foldChips.values.contains { $0.rect.contains(convert(event.locationInWindow, from: nil)) }
        if over != overLink || chip != overChip {
            overLink = over
            overChip = chip
            updateCursor()
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private var overLink = false
    /// Over a fold's ⋯, a button: the arrow.
    private var overChip = false

    private func updateCursor() {
        guard isUnderPointer else { return }
        if overChip { return NSCursor.arrow.set() }
        (overLink || hoveredLink.map { !$0.isEmpty } == true ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        if hasSelectedText {
            menu.addItem(withTitle: "New Note from Selection", action: #selector(MainWindowController.newNoteFromSelection(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Copy Link to This Line", action: #selector(MainWindowController.copyLinkToLine(_:)), keyEquivalent: "")
        // An agent asked about the place (§2.5): what it makes comes back
        // into the graph, and shows here.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Describe with an Agent", action: #selector(MainWindowController.describeWithAgent(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Explain with an Agent", action: #selector(MainWindowController.explainWithAgent(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Walk Through with an Agent", action: #selector(MainWindowController.walkWithAgent(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        // Insert from iPhone or iPad (Continuity Camera): a photo, a scan,
        // a sketch, put in the text as an image.
        if onImage != nil, isEditable {
            menu.addItem(.separator())
            let item = NSMenuItem()
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            menu.addItem(item)
        }
        if let placement = menuPlacement {
            menu.addItem(.separator())
            menu.addItem(PinMenu.item(for: placement))
        }
        if let host = menuHost { HostMenu.append(for: host, to: menu) }
        return menu
    }

    /// In Markdown: an image pasted, dropped or brought from an iPhone,
    /// its bytes and their kind ("png", "jpeg"), to be kept as an image
    /// block and shown in the text.
    var onImage: ((Data, String) -> Void)?

    /// The image a pasteboard holds, as bytes to keep: a file's as it is
    /// (a photo stays a JPEG), else PNG.
    static func images(on pb: NSPasteboard) -> [(Data, String)] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { BlockKind.forFile($0.path) == .image }
            guard images.count == urls.count else { return [] }
            return images.compactMap { u in (try? Data(contentsOf: u)).map { ($0, u.pathExtension.lowercased()) } }
        }
        if let png = pb.data(forType: .png) { return [(png, "png")] }
        if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { return [(jpeg, "jpeg")] }
        if let heic = pb.data(forType: NSPasteboard.PasteboardType("public.heic")) { return [(heic, "heic")] }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return [(png, "png")]
        }
        return []
    }

    /// The host of the block shown, for its own items in the menu.
    var menuHost: HostID?
    /// The tile it's shown in, for its menu's Pin in Workspace.
    var menuPlacement: PlacementID?

    // MARK: Pasteboard

    var selectedText: String {
        selections.filter { !$0.isCaret }.map { text[$0.range] }.joined(separator: "\n")
    }

    /// Whether anything is selected — asked by menus and Services as they
    /// validate, which made the whole selection as text to see (all of a
    /// big file, after ⌘A, at every look at the menu bar).
    var hasSelectedText: Bool { selections.contains { !$0.isCaret } }

    @objc func copy(_ sender: Any?) {
        let s = selectedText
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard isEditable, selections.contains(where: { !$0.isCaret }) else { return }
        copy(sender)
        insert("", typing: false)
    }

    @objc func paste(_ sender: Any?) { paste(from: NSPasteboard.general) }

    /// What a paste does with a pasteboard: an image kept as an image block
    /// and shown (in Markdown), else its text in.
    func paste(from pb: NSPasteboard) {
        // An image (a screenshot copied, a picture from Preview, a browser's
        // or a chat's Copy Image): kept, and shown.
        if isEditable, let onImage, Self.prefersImage(pb) {
            let images = Self.images(on: pb)
            if !images.isEmpty { images.forEach(onImage); return }
        }
        guard isEditable, let s = pb.string(forType: .string) else { return }
        // In Markdown, an address pasted over words links them: [words](address).
        if acceptsBlockLinks, Self.isAddress(s), selections.contains(where: { !$0.isCaret }) {
            let address = s.trimmingCharacters(in: .whitespacesAndNewlines)
            var reps: [(TextRange, String)] = []
            var after: [Selection] = []
            var shift = 0
            for sel in selections.sorted(by: { $0.min < $1.min }) {
                let words = text[TextRange(sel.min, sel.max)]
                let made = sel.isCaret ? address : "[\(words)](\(address))"
                reps.append((sel.range, made))
                after.append(Selection(at: sel.min + shift + made.utf8.count))
                shift += made.utf8.count - sel.range.length
            }
            replace(reps, selectAfter: after)
            return
        }
        let lines = s.components(separatedBy: "\n")
        // One line per cursor, when they match up.
        if selections.count > 1, lines.count == selections.count {
            insert(lines, typing: false)
        } else {
            insert(s, typing: false)
        }
    }

    @objc override func selectAll(_ sender: Any?) { setSelections([Selection(0, text.count)], scroll: false) }

    @objc func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    /// Whether a paste is of the image a pasteboard holds rather than its
    /// text: there's no text, or files; or the text only says where the
    /// image is from (its address, its file's name — as a browser's Copy
    /// Image gives) or is listed after it (the source would rather the
    /// image were taken).
    static func prefersImage(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
        guard let image = types.firstIndex(where: imageTypes.contains) else { return types.contains(.fileURL) }
        guard let s = pb.string(forType: .string), let text = types.firstIndex(of: .string) else { return true }
        if types.contains(.fileURL) || isAddress(s) || image < text { return true }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(where: \.isWhitespace) && BlockKind.forFile(t) == .image
    }

    /// One address and nothing else: a web link, a file, or a block.
    static func isAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: { $0.isWhitespace }) else { return false }
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("file://") || t.hasPrefix("manifold:")
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if let m = marked {
            selections = [Selection(m.start, m.end)]
            marked = nil
            insert(s, typing: false)
            return
        }
        if replacementRange.location != NSNotFound {
            let r = TextRange(text.byteOffset(ofUTF16: replacementRange.location), text.byteOffset(ofUTF16: replacementRange.location + replacementRange.length))
            selections = [Selection(r.start, r.end)]
        }
        insertTyped(s)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if let m = marked {
            selections = [Selection(m.start, m.end)]
        } else if replacementRange.location != NSNotFound {
            let r = TextRange(text.byteOffset(ofUTF16: replacementRange.location), text.byteOffset(ofUTF16: replacementRange.location + replacementRange.length))
            selections = [Selection(r.start, r.end)]
        } else {
            selections = [primarySelection]
        }
        let start = selections[0].min
        insert(s, typing: false)
        if s.isEmpty {
            marked = nil
        } else {
            marked = TextRange(start, start + s.utf8.count)
            let selStart = start + (s as NSString).substring(to: min(selectedRange.location, (s as NSString).length)).utf8.count
            let selEnd = start + (s as NSString).substring(to: min(selectedRange.location + selectedRange.length, (s as NSString).length)).utf8.count
            setSelections([Selection(selStart, selEnd)])
        }
    }

    func unmarkText() {
        marked = nil
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        let s = primarySelection
        let a = text.utf16Offset(ofByte: s.min), b = text.utf16Offset(ofByte: s.max)
        return NSRange(location: a, length: b - a)
    }

    func markedRange() -> NSRange {
        guard let m = marked else { return NSRange(location: NSNotFound, length: 0) }
        let a = text.utf16Offset(ofByte: m.start), b = text.utf16Offset(ofByte: m.end)
        return NSRange(location: a, length: b - a)
    }

    func hasMarkedText() -> Bool { marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let a = text.byteOffset(ofUTF16: range.location), b = text.byteOffset(ofUTF16: range.location + range.length)
        return NSAttributedString(string: text[TextRange(a, b)], attributes: attributes())
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let offset = text.byteOffset(ofUTF16: range.location)
        let r = caretRect(offset)
        guard let window else { return r }
        return window.convertToScreen(convert(r, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let p = convert(window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
        return text.utf16Offset(ofByte: offset(at: p))
    }

    // MARK: Services

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == .string, hasSelectedText { return self }
        if returnType == .string, isEditable { return self }
        if let returnType, isEditable, onImage != nil, [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")].contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        pboard.clearContents()
        return pboard.setString(selectedText, forType: .string)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        // From an iPhone or iPad (Continuity Camera): an image.
        if let onImage, case let images = Self.images(on: pboard), !images.isEmpty {
            images.forEach(onImage)
            return true
        }
        guard let s = pboard.string(forType: .string) else { return false }
        insert(s, typing: false)
        return true
    }

    // MARK: Scrolling

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.delegate?.textViewDidScroll(self)
            }
        }
    }

    /// The byte offset of a line and column (from 1), for going to places.
    func offset(line: Int, column: Int?) -> TextRange {
        let n = min(max(line - 1, 0), text.lineCount - 1)
        let r = text.lineRange(n)
        if let column {
            let lineText = text.lineText(n)
            let o = r.start + byteOffset(in: lineText, utf16Index: min(column - 1, (lineText as NSString).length))
            return TextRange(at: o)
        }
        return r
    }

    /// The line (from 0) of the primary caret.
    var caretLine: Int { text.line(at: primarySelection.head) }

    /// The column (from 1, in UTF-16) of the primary caret.
    var caretColumn: Int {
        let n = caretLine
        let lineText = text.lineText(n)
        return utf16Index(in: lineText, byteOffset: primarySelection.head - text.offset(ofLine: n)) + 1
    }
}

extension TextView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { DragCursor.began() }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { DragCursor.moved() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { DragCursor.ended() }
}

extension TextView: DropTaking {
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] {
        guard isEditable else { return [] }
        return Dropping.forms(d, for: acceptsBlockLinks ? .note : .code)
    }

    /// The caret follows the pointer; only moved when it would move.
    func dropTrack(_ d: Dragged, at p: NSPoint) {
        dropTracking = true
        let at = offset(at: p)
        if selections.count != 1 || selections[0].anchor != at || selections[0].head != at {
            setSelections([Selection(at: at)], scroll: false)
        }
    }

    /// Put in where the caret is; a block named noted as a mention.
    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        window?.makeFirstResponder(self)
        if let p { setSelections([Selection(at: offset(at: p))], scroll: false) }
        let mentioned = { [weak self] (id: BlockID) in
            guard let self else { return }
            self.delegate?.textView(self, mentioned: id)
        }
        let words = [.link, .reference, .path].contains(form)
        let put = { [weak self] (text: String) in
            guard let self else { return }
            guard words, let head = self.selections.first?.head else { return self.insert(text) }
            let char = { (i: Int) in self.text.byte(at: i).map { Character(UnicodeScalar($0)) } }
            // Several (a line each): lines of their own, not run into the text about them.
            if text.contains("\n") {
                let before = head > 0 && char(head - 1) != "\n" ? "\n" : ""
                let after = char(head).map { $0 != "\n" } == true ? "\n" : ""
                return self.insert(before + text + after)
            }
            self.insert(Dropping.spaced(text, after: head > 0 ? char(head - 1) : nil, before: char(head)))
        }
        if acceptsBlockLinks {
            return Dropping.noteText(d, as: form, keep: onImage, insert: put, linked: mentioned)
        }
        d.text(form, separator: "\n") { [weak self] text, blocks in
            guard let self, let text, !text.isEmpty else { return NSSound.beep() }
            put(text)
            if form == .link || form == .reference { blocks.forEach(mentioned) }
        }
    }
}
