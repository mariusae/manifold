import AppKit
import ManifoldCore

/// The outliner lens (§7.9): a note — any Markdown text — edited as an
/// outline, as Prism's notes are. The Markdown is read into rows
/// (`NoteOutlineMarkdown`: list items and what nests in them, headings,
/// quotes, code, rules, paragraphs, checkboxes), the rows are what's edited
/// — Return makes a row, Tab and ⇧Tab move it in and out with its
/// children, ⌃⌘↑ and ⌃⌘↓ move it among its siblings, ⌘↩ gives it a
/// checkbox and checks it, a bullet clicked folds what's under it — and
/// each change is written back as the Markdown it says, only the bytes that
/// changed. A note read and written without being edited comes back byte
/// for byte; a change made elsewhere (its editor, another Mac, `mani
/// write`) is read in again, the caret staying on its row.
final class OutlineNoteView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    var source: () -> Block? = { nil }
    /// Edits to the block's text, as an editor makes them.
    var apply: ([TextEdit]) -> Void = { _ in }
    var theme: FontTheme { didSet { if theme != oldValue { text.metrics = Self.metrics(theme) } } }

    private let scroll = NSScrollView()
    private let text: NoteOutlineTextView
    /// What isn't rows — frontmatter, blank lines at the end, the line
    /// ending — kept to write the rows back with.
    private var shell = NoteOutline(rows: [])
    /// The Markdown last read or written: the block's, unless it changed
    /// elsewhere since.
    private var written: String?
    private let headings = Outline()

    var focusView: NSView { text }
    var isDead: Bool { false }
    var outline: Outline? { headings }

    init(placement: PlacementID, block: BlockID, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.theme = theme
        text = NoteOutlineTextView(metrics: Self.metrics(theme))
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.onRowsChanged = { [weak self] in self?.rowsChanged() }
        addSubview(scroll)
        headings.onPick = { [weak self] i in self?.goToHeading(i) }
        // An entry's place: its line in the Markdown, as the editor's are.
        headings.block = block
        headings.placeFor = { [weak self] i in
            guard let lines = self?.itemLines, lines.indices.contains(i) else { return nil }
            return "line=\(lines[i] + 1)"
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { markCurrent() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        text.frame.size.width = scroll.contentSize.width
    }

    static func metrics(_ theme: FontTheme) -> NoteOutlineMetrics {
        NoteOutlineMetrics(body: theme.font(.proportional, size: 14.5), code: theme.font(.monospaced, size: 12.5))
    }

    // MARK: The note, both ways

    /// The block moved: unless it's what was written from here, read again.
    func documentChanged() {
        guard let b = source(), let t = b.text, !b.needsRead else { return }
        let markdown = t.text.string
        guard markdown != written else { return }
        let first = written == nil
        var outline = NoteOutlineMarkdown.parse(markdown)
        let rows = outline.rows
        outline.rows = []
        shell = outline
        written = markdown
        text.load(rows, keepingCaret: !first)
        updateHeadings()
    }

    /// The rows changed here: written back, only what changed.
    private func rowsChanged() {
        var outline = shell
        outline.rows = text.rows
        let markdown = NoteOutlineMarkdown.serialize(outline)
        updateHeadings()
        guard markdown != written, let old = source()?.text?.text.string else { return }
        written = markdown
        apply([Self.edit(from: old, to: markdown)])
    }

    /// One edit turning `old` into `new`: what's between their common head
    /// and tail, cut at characters' edges (offsets in bytes, as a rope
    /// counts them).
    static func edit(from old: String, to new: String) -> TextEdit {
        let a = Array(old.utf8), b = Array(new.utf8)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        // Not inside a character: back to where one starts.
        while head > 0, head < a.count, a[head] & 0xC0 == 0x80 { head -= 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        while tail > 0, a.count - tail < a.count, a[a.count - tail] & 0xC0 == 0x80 { tail -= 1 }
        let inserted = String(decoding: b[head..<(b.count - tail)], as: UTF8.self)
        return TextEdit(TextRange(head, a.count - tail), inserted)
    }

    // MARK: The tile's outline

    /// The note's outline — its headings, and its top-level items each
    /// under the heading before it — as its editor and preview have it too
    /// (`NoteOutlineMarkdown.items`): the tile's ticks, its sidebar, ⌘P.
    private func updateHeadings() {
        var outline = shell
        outline.rows = text.rows
        let items = NoteOutlineMarkdown.items(of: outline)
        itemRows = items.map(\.row)
        itemLines = items.map(\.line)
        headings.set(items.map(Outline.Item.init))
        markCurrent()
    }

    private var itemRows: [Int] = []
    private var itemLines: [Int] = []

    private func goToHeading(_ i: Int) {
        guard itemRows.indices.contains(i) else { return }
        text.goTo(row: itemRows[i])
        window?.makeFirstResponder(text)
    }

    /// The item you're at: the last that begins at or above the top of
    /// what shows.
    private func markCurrent() {
        guard let layout = text.layoutManager, let container = text.textContainer, !itemRows.isEmpty else { return headings.current = nil }
        let top = NSPoint(x: 0, y: scroll.contentView.bounds.minY - text.textContainerOrigin.y + 4)
        let glyph = layout.glyphIndex(for: top, in: container)
        let row = text.rowIndex(at: layout.characterIndexForGlyph(at: glyph))
        headings.current = itemRows.lastIndex { $0 <= row } ?? 0
    }

    // MARK: Debugging

    /// The rows as they stand, a line each: depth, kind, checkbox, text.
    var debugRows: String {
        text.rows.map { row in
            let kind: String = switch row.kind {
            case .bullet: "-"
            case .ordered: "\(row.number)."
            case let .heading(l): String(repeating: "#", count: l)
            case .paragraph: "¶"
            case .quote: ">"
            case .code: "code"
            case .rule: "rule"
            }
            let box = row.task.map { $0.isDone ? "[x] " : "[ ] " } ?? ""
            return String(repeating: "  ", count: row.depth) + kind + " " + box + row.text.replacingOccurrences(of: "\n", with: "⏎")
                + (row.isFolded ? "  (folded \(row.folded.count))" : "")
        }.joined(separator: "\n")
    }

    /// Debugging: a command, as its key does it ("return", "tab", "backtab",
    /// "check", "up", "down", "fold <row>", "type <text>", "caret <row> <offset>").
    func debug(_ command: String) -> String {
        let words = command.split(separator: " ", maxSplits: 1).map(String.init)
        window?.makeFirstResponder(text)
        switch words.first {
        case "return": text.insertNewline(nil)
        case "tab": text.insertTab(nil)
        case "backtab": text.insertBacktab(nil)
        case "delete": text.deleteBackward(nil)
        case "check": text.cycleChecklist(nil)
        case "up": text.moveRowsUp(nil)
        case "down": text.moveRowsDown(nil)
        case "fold": if words.count > 1, let r = Int(words[1]) { text.clickHandle(ofRow: r) }
        case "type": if words.count > 1 { for ch in words[1] { text.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
        case "caret":
            let n = (words.count > 1 ? words[1] : "").split(separator: " ").compactMap { Int($0) }
            if n.count == 2 { text.restoreCaret(.init(row: n[0], offset: n[1])) }
        default: break
        }
        let c = text.caretPosition
        return "caret \(c.row):\(c.offset)\n" + debugRows
    }
}

// MARK: - Rows as paragraphs

extension NSAttributedString.Key {
    /// The row a paragraph is, as a `NoteRowStyle`: every character of a
    /// paragraph, its line break too, carries the same one.
    static let noteRow = NSAttributedString.Key("ManifoldNoteRow")
}

/// What a paragraph is: a row, less its text, which is the paragraph's.
/// Immutable, so undo can put an old one back.
final class NoteRowStyle: NSObject {
    let row: NoteRow

    init(_ row: NoteRow) {
        var row = row
        row.text = ""
        self.row = row
    }
}

/// The outline's text: a paragraph a row, each ending in a line break —
/// the last too, so every row has a character to carry its style. Lines
/// within a row are broken with U+2028.
enum NoteOutlineText {
    static let lineSeparator = "\u{2028}"

    static func attributed(_ rows: [NoteRow]) -> NSMutableAttributedString {
        let text = NSMutableAttributedString()
        for row in rows {
            text.append(NSAttributedString(string: row.text.replacingOccurrences(of: "\n", with: lineSeparator) + "\n",
                                           attributes: [.noteRow: NoteRowStyle(row)]))
        }
        return text
    }

    static func paragraphs(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while start < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: text.length - start))
            let end = found.location == NSNotFound ? text.length : found.location + 1
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        return ranges
    }

    static func style(_ text: NSAttributedString, at location: Int) -> NoteRowStyle {
        guard text.length > 0 else { return NoteRowStyle(.blank) }
        return text.attribute(.noteRow, at: min(location, text.length - 1), effectiveRange: nil) as? NoteRowStyle ?? NoteRowStyle(.blank)
    }

    static func rows(_ text: NSAttributedString) -> [NoteRow] {
        let string = text.string as NSString
        return paragraphs(string).map { range in
            var row = style(text, at: range.location).row
            var body = string.substring(with: range)
            if body.hasSuffix("\n") { body.removeLast() }
            row.text = body.replacingOccurrences(of: lineSeparator, with: "\n")
            return row
        }
    }
}

// MARK: - Type and measures

struct NoteOutlineMetrics: Equatable {
    var body: NSFont
    var code: NSFont
    var fontSize: CGFloat { body.pointSize }
    /// How far each level is in.
    var indent: CGFloat { round(fontSize * 1.45) }
    var lineHeightMultiple: CGFloat { 1.18 }
    var rowSpacing: CGFloat { round(fontSize * 0.28) }

    func heading(_ level: Int) -> NSFont {
        let (factor, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (1.45, .bold)
        case 2: (1.22, .bold)
        case 3: (1.08, .semibold)
        default: (1, .semibold)
        }
        let size = round(fontSize * factor)
        return NSFontManager.shared.convert(NSFont(descriptor: body.fontDescriptor, size: size) ?? .systemFont(ofSize: size), toHaveTrait: .boldFontMask)
            .withWeight(weight)
    }

    func font(for row: NoteRow) -> NSFont {
        switch row.kind {
        case let .heading(level): heading(level)
        case .code: code
        default: body
        }
    }

    /// Where a row's text starts: a step in for each level, bullet or
    /// none — a list item's marker hangs in the room before it.
    func textIndent(for row: NoteRow) -> CGFloat { indent * CGFloat(row.depth + 1) }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

// MARK: - Styling

/// Styles each paragraph from its row as the text changes — only
/// attributes, never characters — and keeps each paragraph one row: when an
/// edit joins two, the row that was there first wins.
final class NoteOutlineStyler: NSObject, NSTextStorageDelegate {
    var metrics: NoteOutlineMetrics
    /// Rows folded inside a row an edit swallowed, and where they belong.
    var orphans: [(location: Int, rows: [NoteRow])] = []

    init(metrics: NoteOutlineMetrics) { self.metrics = metrics }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range edited: NSRange, changeInLength delta: Int) {
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        var range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: min(edited.length, text.length - min(edited.location, text.length))))
        // The rows on each side are spaced by this one: styled again too.
        if NSMaxRange(range) < text.length { range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))) }
        if range.location > 0 { range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: range.location - 1, length: 0))) }
        if mask.contains(.editedCharacters) { unify(storage, in: range, inserted: edited) }
        style(storage, in: range)
    }

    func styleAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        style(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    private func unify(_ storage: NSTextStorage, in range: NSRange, inserted: NSRange) {
        let text = storage.string as NSString
        for p in NoteOutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: p.location + range.location, length: p.length)
            var styles: [NoteRowStyle] = []
            var winner: NoteRowStyle?
            storage.enumerateAttribute(.noteRow, in: paragraph) { value, run, _ in
                guard let style = value as? NoteRowStyle else { return }
                if !styles.contains(where: { $0 === style }) { styles.append(style) }
                // What was typed takes the row it was typed into.
                let typed = inserted.length > 0 && NSIntersectionRange(run, inserted).length == run.length
                if winner == nil, !typed { winner = style }
            }
            let style = winner ?? styles.last ?? NoteRowStyle(.blank)
            guard styles.count > 1 || styles.first !== style else { continue }
            storage.addAttribute(.noteRow, value: style, range: paragraph)
            for lost in styles where lost !== style && lost.row.isFolded {
                orphans.append((paragraph.location, lost.row.folded.map { var c = $0; c.depth += lost.row.depth; return c }))
            }
        }
    }

    private func style(_ storage: NSTextStorage, in range: NSRange) {
        let text = storage.string as NSString
        for p in NoteOutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: p.location + range.location, length: p.length)
            var row = NoteOutlineText.style(storage, at: paragraph.location).row
            row.text = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let previous = paragraph.location > 0 ? NoteOutlineText.style(storage, at: paragraph.location - 1).row : nil
            let style = storage.attribute(.noteRow, at: paragraph.location, effectiveRange: nil) as Any
            storage.setAttributes(attributes(for: row, after: previous), range: paragraph)
            storage.addAttribute(.noteRow, value: style, range: paragraph)
            // A code block's fences: there to be edited, not read.
            if row.kind == .code { dimFences(storage, in: paragraph) }
            storage.fixAttributes(in: paragraph)
        }
    }

    private func dimFences(_ storage: NSTextStorage, in paragraph: NSRange) {
        let text = storage.string as NSString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        let first = text.range(of: NoteOutlineText.lineSeparator, options: .literal, range: body)
        let last = text.range(of: NoteOutlineText.lineSeparator, options: [.literal, .backwards], range: body)
        let opening = first.location == NSNotFound ? body : NSRange(location: body.location, length: first.location - body.location)
        storage.addAttribute(.foregroundColor, value: Theme.tertiaryText, range: opening)
        if last.location != NSNotFound {
            let closing = NSRange(location: NSMaxRange(last), length: NSMaxRange(body) - NSMaxRange(last))
            let line = text.substring(with: closing).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { storage.addAttribute(.foregroundColor, value: Theme.tertiaryText, range: closing) }
        }
    }

    /// How a row looks, and how far it stands from the one before: rows
    /// evenly, whatever blank lines the Markdown has (in an outline they
    /// say nothing); a heading with room above it.
    func attributes(for row: NoteRow, after previous: NoteRow?) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let indent = metrics.textIndent(for: row)
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineHeightMultiple = metrics.lineHeightMultiple
        paragraph.paragraphSpacing = metrics.rowSpacing
        var before: CGFloat = 0
        if case .heading = row.kind { before = round(metrics.fontSize * 0.8) }
        else if row.kind == .paragraph, previous?.kind == .paragraph, !row.gap.isEmpty { before = round(metrics.fontSize * 0.45) }
        else if row.startsGroup(after: previous) { before = round(metrics.fontSize * 0.5) }
        paragraph.paragraphSpacingBefore = previous == nil ? 0 : before
        var a: [NSAttributedString.Key: Any] = [.font: metrics.font(for: row), .paragraphStyle: paragraph, .foregroundColor: Theme.bodyText]
        switch row.kind {
        case .quote: a[.foregroundColor] = Theme.secondaryText
        case .rule: a[.foregroundColor] = NSColor.clear  // drawn; its dashes are there to be edited
        default: break
        }
        if row.task?.isDone == true { a[.foregroundColor] = Theme.secondaryText }
        if row.isStruck {
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            a[.strikethroughColor] = Theme.tertiaryText
        }
        return a
    }
}

// MARK: - Drawing what isn't typed

/// Draws a row's bullet, number or checkbox in the room before its text,
/// a quote's bar, a rule, the ground under code, and a fold's mark.
final class NoteOutlineLayoutManager: NSLayoutManager {
    weak var view: NoteOutlineTextView?

    enum Handle { case none, bullet(folded: Bool), task(done: Bool, round: Bool), number(String) }

    static func handle(for row: NoteRow) -> Handle {
        if let task = row.task, row.kind.isListItem { return .task(done: task.isDone, round: row.marker == "+") }
        switch row.kind {
        case .bullet: return .bullet(folded: row.isFolded)
        case .ordered: return .number("\(row.number)\(row.marker)")
        default: return row.isFolded ? .bullet(folded: true) : .none
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let view, storage.length > 0 else { return }
        let covered = (storage.string as NSString).paragraphRange(for: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil))
        let metrics = view.metrics
        let width = view.textContainer?.size.width ?? view.bounds.width
        for paragraph in view.paragraphRanges where NSIntersectionRange(paragraph, covered).length > 0 || paragraph.location == covered.location {
            let row = NoteOutlineText.style(storage, at: paragraph.location).row
            guard let frame = frame(of: paragraph, origin: origin) else { continue }
            let indent = origin.x + metrics.textIndent(for: row)
            switch row.kind {
            case .code:
                NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: indent - 6, y: frame.minY - 2, width: origin.x + width - indent + 6, height: frame.height + 4), xRadius: 5, yRadius: 5).fill()
            case .quote:
                Theme.tertiaryText.setFill()
                NSBezierPath(roundedRect: NSRect(x: indent - metrics.indent / 2 - 1.5, y: frame.minY, width: 3, height: frame.height), xRadius: 1.5, yRadius: 1.5).fill()
            case .rule:
                NSColor.separatorColor.setFill()
                NSRect(x: indent, y: frame.midY.rounded(), width: origin.x + width - indent, height: 1).fill()
            default: break
            }
            drawHandle(Self.handle(for: row), row: row, paragraph: paragraph, origin: origin, indent: indent)
        }
    }

    /// Where a row's handle is drawn: its middle, in the room before the
    /// text, on the first line.
    func handleCenter(of paragraph: NSRange, row: NoteRow, origin: NSPoint) -> NSPoint? {
        guard let view else { return nil }
        let glyph = glyphIndexForCharacter(at: paragraph.location)
        guard glyph < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = view.metrics.font(for: row)
        let baseline = origin.y + line.minY + location(forGlyphAt: glyph).y
        return NSPoint(x: origin.x + view.metrics.textIndent(for: row) - view.metrics.indent / 2, y: baseline - font.xHeight / 2)
    }

    private func drawHandle(_ handle: Handle, row: NoteRow, paragraph: NSRange, origin: NSPoint, indent: CGFloat) {
        guard let view, let center = handleCenter(of: paragraph, row: row, origin: origin) else { return }
        let font = view.metrics.font(for: row)
        switch handle {
        case .none: break
        case let .bullet(folded):
            let dot = max(4, (font.pointSize * 0.34).rounded())
            Theme.secondaryText.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
            if folded {
                // Folded: a ring round it, its children inside.
                let ring = dot + 7
                let path = NSBezierPath(ovalIn: NSRect(x: center.x - ring / 2, y: center.y - ring / 2, width: ring, height: ring))
                path.lineWidth = 1
                Theme.tertiaryText.setStroke()
                path.stroke()
            }
        case let .task(done, round):
            let name = round ? (done ? "checkmark.circle.fill" : "circle") : (done ? "checkmark.square.fill" : "square")
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.95, weight: .regular)
                .applying(.init(paletteColors: done ? [.white, Theme.accent] : [Theme.secondaryText]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: done ? "Done" : "To do")?.withSymbolConfiguration(config) else { return }
            let size = image.size
            let middle = center.y + font.xHeight / 2 - font.capHeight / 2
            image.draw(in: NSRect(x: center.x - size.width / 2, y: middle - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case let .number(label):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                                                             .foregroundColor: Theme.secondaryText]
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let ascent = (attributes[.font] as! NSFont).ascender
            text.draw(at: NSPoint(x: indent - 6 - size.width, y: center.y + font.xHeight / 2 - ascent))
        }
    }

    /// The rectangle a paragraph's lines take.
    private func frame(of paragraph: NSRange, origin: NSPoint) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: NSRange(location: paragraph.location, length: max(1, paragraph.length - 1)), actualCharacterRange: nil)
        guard glyphs.length > 0, glyphs.location < numberOfGlyphs else { return nil }
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in rect = rect.union(used) }
        guard !rect.isNull else { return nil }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The row whose handle is at a point in the view, if any.
    func handleHit(at point: NSPoint, origin: NSPoint) -> Int? {
        guard let view, let storage = textStorage else { return nil }
        for (index, paragraph) in view.paragraphRanges.enumerated() {
            let row = NoteOutlineText.style(storage, at: paragraph.location).row
            if case .none = Self.handle(for: row) { continue }
            guard let c = handleCenter(of: paragraph, row: row, origin: origin) else { continue }
            let r = view.metrics.indent / 2 + 2
            if abs(point.x - c.x) <= r, abs(point.y - c.y) <= r { return index }
        }
        return nil
    }
}

// MARK: - The editor

/// An outline edited as text, a row a paragraph (Prism's, after Bike): a
/// row always takes its children along — indented, outdented, moved.
final class NoteOutlineTextView: NSTextView {
    var metrics: NoteOutlineMetrics {
        didSet {
            guard metrics != oldValue else { return }
            styler.metrics = metrics
            styler.styleAll(textStorage!)
        }
    }
    let styler: NoteOutlineStyler
    /// Told when the rows changed, by typing or a command.
    var onRowsChanged: (() -> Void)?
    /// Set while the view changes its own text.
    private var adjusting = false
    private var loading = false
    /// Its own: ⌘Z in an outline undoes the outline's edits, not the
    /// desk's (whose undo the window's chain reaches first).
    private let undo = UndoManager()
    override var undoManager: UndoManager? { undo }

    init(metrics: NoteOutlineMetrics) {
        self.metrics = metrics
        styler = NoteOutlineStyler(metrics: metrics)
        let storage = NSTextStorage()
        let layout = NoteOutlineLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 40), textContainer: container)
        layout.view = self
        storage.delegate = styler
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        drawsBackground = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        insertionPointColor = Theme.accent
        load([.blank], keepingCaret: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rows

    /// Rows on screen, in place of what was there: the caret kept on its
    /// row and place if asked (a change from elsewhere), else at the top.
    func load(_ rows: [NoteRow], keepingCaret: Bool) {
        let caret = keepingCaret ? caretPosition : CaretPosition(row: 0, offset: 0)
        adjusting = true
        loading = true
        textStorage!.setAttributedString(NoteOutlineText.attributed(rows.isEmpty ? [.blank] : rows))
        styler.styleAll(textStorage!)
        loading = false
        adjusting = false
        paragraphCache = nil
        restoreCaret(caret)
        // Read anew (a change from elsewhere): what was done here before
        // can't be undone over it.
        undo.removeAllActions()
    }

    @objc func undo(_ sender: Any?) { if undo.canUndo { undo.undo() } else { NSSound.beep() } }
    @objc func redo(_ sender: Any?) { if undo.canRedo { undo.redo() } else { NSSound.beep() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undo.canUndo }
        if item.action == #selector(redo(_:)) { return undo.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    var rows: [NoteRow] { NoteOutlineText.rows(textStorage!) }

    private var paragraphCache: [NSRange]?
    var paragraphRanges: [NSRange] {
        if let paragraphCache { return paragraphCache }
        let r = NoteOutlineText.paragraphs(textStorage!.string as NSString)
        paragraphCache = r
        return r
    }

    func rowIndex(at location: Int) -> Int {
        let ranges = paragraphRanges
        var low = 0, high = max(0, ranges.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].location <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func row(at index: Int) -> NoteRow { NoteOutlineText.style(textStorage!, at: paragraphRanges[index].location).row }

    /// The last place a caret can be: before the last line break.
    private var lastLocation: Int { max(0, textStorage!.length - 1) }

    override func didChangeText() {
        paragraphCache = nil
        if !adjusting { tidy() }
        super.didChangeText()
        needsDisplay = true
        if !loading { onRowsChanged?() }
    }

    /// What an edit can leave wrong put right: the text ends in a line
    /// break, rows an edit swallowed come back, every row at a depth
    /// Markdown can write.
    private func tidy() {
        adjusting = true
        defer { adjusting = false }
        let storage = textStorage!
        if storage.length == 0 || !storage.string.hasSuffix("\n") {
            let style = storage.length > 0 ? NoteOutlineText.style(storage, at: storage.length - 1) : NoteRowStyle(.blank)
            let selection = selectedRange()
            if shouldChangeText(in: NSRange(location: storage.length, length: 0), replacementString: "\n") {
                storage.append(NSAttributedString(string: "\n", attributes: [.noteRow: style]))
                super.didChangeText()
            }
            setSelectedRange(selection)
        }
        paragraphCache = nil
        let orphans = styler.orphans
        styler.orphans = []
        let before = rows
        var after = before
        for orphan in orphans.reversed() { after.insert(contentsOf: orphan.rows, at: rowIndex(at: min(orphan.location, lastLocation)) + 1) }
        NoteOutlineEditing.normalize(&after)
        if after != before {
            let caret = caretPosition
            replace(before, with: after, actionName: nil)
            restoreCaret(caret)
        }
    }

    /// The rows on screen replaced, only the paragraphs that differ, as one
    /// step to undo.
    func replace(_ before: [NoteRow], with after: [NoteRow], actionName: String?) {
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let ranges = paragraphRanges
        let start = prefix < ranges.count ? ranges[prefix].location : textStorage!.length
        let end = before.count - suffix > prefix ? NSMaxRange(ranges[before.count - suffix - 1]) : start
        let range = NSRange(location: start, length: end - start)
        let replacement = NoteOutlineText.attributed(Array(after[prefix..<(after.count - suffix)]))
        guard range.length > 0 || replacement.length > 0 else { return }
        let was = adjusting
        adjusting = true
        breakUndoCoalescing()
        if shouldChangeText(in: range, replacementString: replacement.string) {
            textStorage!.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        adjusting = was
        if let actionName { undoManager?.setActionName(actionName) }
    }

    func replaceRow(_ index: Int, with row: NoteRow, actionName: String?) {
        var after = rows
        let before = after
        after[index] = row
        replace(before, with: after, actionName: actionName)
    }

    struct CaretPosition { var row: Int; var offset: Int }

    var caretPosition: CaretPosition {
        let location = selectedRange().location
        let row = rowIndex(at: location)
        return CaretPosition(row: row, offset: location - (paragraphRanges.indices.contains(row) ? paragraphRanges[row].location : 0))
    }

    func restoreCaret(_ position: CaretPosition) {
        let ranges = paragraphRanges
        guard !ranges.isEmpty else { return }
        let row = min(max(position.row, 0), ranges.count - 1)
        let offset = min(max(position.offset, 0), ranges[row].length - 1)
        setSelectedRange(NSRange(location: ranges[row].location + offset, length: 0))
    }

    func goTo(row index: Int) {
        restoreCaret(CaretPosition(row: index, offset: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// The rows a command applies to: those the selection spans.
    var targetRows: Range<Int> {
        let range = selectedRange()
        return rowIndex(at: range.location)..<(rowIndex(at: max(range.location, NSMaxRange(range) - 1)) + 1)
    }

    /// An outline operation on the targeted rows, as one step to undo, the
    /// caret kept on the rows it was on.
    @discardableResult
    func perform(_ name: String, on selection: Range<Int>? = nil, followingCaret: Bool = true,
                 _ transform: (inout [NoteRow], Range<Int>) -> Range<Int>?) -> Bool {
        let before = rows
        let target = selection ?? targetRows
        let caret = caretPosition
        var after = before
        guard let result = transform(&after, target) else { NSSound.beep(); return false }
        replace(before, with: after, actionName: name)
        if followingCaret {
            restoreCaret(CaretPosition(row: min(result.lowerBound + (caret.row - target.lowerBound), paragraphRanges.count - 1), offset: caret.offset))
        } else {
            restoreCaret(CaretPosition(row: caret.row < target.upperBound ? caret.row : caret.row + after.count - before.count, offset: caret.offset))
        }
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard let storage = textStorage, storage.length > 0, let first = ranges.first?.rangeValue else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        // Never past the last line break: there's no row there.
        var range = ranges.map(\.rangeValue).reduce(first, NSUnionRange)
        let end = min(NSMaxRange(range), lastLocation)
        range.location = min(range.location, lastLocation)
        range.length = max(0, end - range.location)
        super.setSelectedRanges([NSValue(range: range)], affinity: affinity, stillSelecting: stillSelecting)
        typingAttributes = storage.attributes(at: min(paragraphRanges[rowIndex(at: range.location)].location, storage.length - 1), effectiveRange: nil)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        // ⇧Return: the row goes on, on a line of its own.
        if [36, 76].contains(event.keyCode), mods == .shift { return insertLineBreak(nil) }
        // ⌃⌘↑ ⌃⌘↓ (an editor's line moves): the row among its siblings.
        if mods == [.command, .control], event.keyCode == 126 { return moveRowsUp(nil) }
        if mods == [.command, .control], event.keyCode == 125 { return moveRowsDown(nil) }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Return, as Prism has it: a checkbox — open, checked, then a bullet again.
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if [36, 76].contains(event.keyCode), mods == .command { cycleChecklist(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if typed == " ", replacementRange.location == NSNotFound, selectedRange().length == 0, applySmartRowType() { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertTab(_ sender: Any?) {
        // In code, a tab is spaces, not a deeper row.
        if case .code = row(at: rowIndex(at: selectedRange().location)).kind {
            return insertText("    ", replacementRange: selectedRange())
        }
        indentRows(sender)
    }

    override func insertBacktab(_ sender: Any?) { outdentRows(sender) }

    override func insertNewline(_ sender: Any?) {
        let index = rowIndex(at: selectedRange().location)
        let current = row(at: index)
        // `---` alone on a row, then Return: a line across.
        if selectedRange().length == 0, current.task == nil, current.kind == .bullet || current.kind == .paragraph,
           ["---", "***", "___"].contains(current.text.trimmingCharacters(in: .whitespaces)) {
            return makeRule(at: index)
        }
        splitRow()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func insertLineBreak(_ sender: Any?) {
        if case .heading = row(at: rowIndex(at: selectedRange().location)).kind { return splitRow() }
        insertText(NoteOutlineText.lineSeparator, replacementRange: selectedRange())
    }

    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 {
            let index = rowIndex(at: range.location)
            if range.location == paragraphRanges[index].location {
                var row = row(at: index)
                // At the start of a row of some kind, it's a plain row first.
                if row.task != nil || !(row.kind == .bullet || row.kind == .paragraph) {
                    if row.task != nil { row.task = nil; row.marker = "-" } else { row.kind = .bullet; row.marker = "-"; row.spacing = 1 }
                    row.text = rows[index].text
                    replaceRow(index, with: row, actionName: "Change Row Type")
                    setSelectedRange(NSRange(location: paragraphRanges[index].location, length: 0))
                    return
                }
                // An empty row deeper in: out a level first.
                if row.depth > 0, row.text.isEmpty, rows[index].text.isEmpty {
                    outdentRows(sender)
                    return
                }
                if index == 0 { return }
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: Commands

    /// Return: the text after the caret a new row. On an empty list item
    /// deeper in, out a level instead; at the end of a row whose children
    /// show, its first child.
    func splitRow() {
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
        let location = selectedRange().location
        let index = rowIndex(at: location)
        let paragraph = paragraphRanges[index]
        var all = rows
        let before = all
        let row = all[index]
        if row.kind == .code { return insertText(NoteOutlineText.lineSeparator, replacementRange: selectedRange()) }
        // An empty item: out a level, as lists do; at the top, a plain row.
        if row.text.isEmpty, row.kind.isListItem, !row.isFolded {
            if row.depth > 0 { return outdentRows(nil) }
            if row.task != nil {
                all[index].task = nil
                replace(before, with: all, actionName: "Change Row Type")
                return restoreCaret(CaretPosition(row: index, offset: 0))
            }
        }
        let offset = location - paragraph.location
        let length = paragraph.length - 1
        var next = row
        next.text = ""
        next.folded = []
        next.continuationIndents = nil
        let siblingAbove = NoteOutlineEditing.previousSibling(all, before: index, depth: row.depth).map { all[$0].kind.isListItem } ?? false
        next.gap = !row.gap.isEmpty && siblingAbove ? [""] : []
        if next.task != nil { next.task = .open }
        if next.kind == .ordered { next.number += 1 }
        switch next.kind {
        case .heading, .rule: next = NoteRow(kind: .bullet, depth: row.depth, gap: [""])
        case .quote, .paragraph: break
        default: break
        }
        if offset == 0, length > 0 {
            // At a row's start: a new row above, the text staying with its children.
            all.insert(next, at: index)
            replace(before, with: all, actionName: "New Row")
            restoreCaret(CaretPosition(row: index + 1, offset: 0))
        } else {
            let text = row.text as NSString
            all[index].text = text.substring(to: min(offset, text.length))
            next.text = text.substring(from: min(offset, text.length))
            if offset == length, NoteOutlineEditing.subtreeEnd(all, index) > index + 1 {
                let child = all[index + 1]
                next.depth = child.depth
                if child.kind.isListItem, row.kind.isListItem {
                    next.kind = child.kind
                    next.marker = child.marker
                    next.number = 1
                    next.task = child.task == nil ? nil : .open
                }
                next.gap = child.gap
            }
            all.insert(next, at: index + 1)
            replace(before, with: all, actionName: "New Row")
            restoreCaret(CaretPosition(row: index + 1, offset: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    /// Markdown typed at a row's start, then a space, sets its kind: `#`s a
    /// heading, `>` a quote, `[ ]` or `[x]` a checkbox, `-` `*` `+` a
    /// bullet, `1.` a numbered item.
    func applySmartRowType() -> Bool {
        let location = selectedRange().location
        let index = rowIndex(at: location)
        let paragraph = paragraphRanges[index]
        let prefix = (textStorage!.string as NSString).substring(with: NSRange(location: paragraph.location, length: location - paragraph.location))
        var row = rows[index]
        guard row.task == nil, row.kind == .bullet || row.kind == .paragraph, !prefix.isEmpty, prefix.count <= 6 else { return false }
        let rest = String(row.text.dropFirst(prefix.count))
        switch prefix {
        case _ where prefix.allSatisfy({ $0 == "#" }): row.kind = .heading(prefix.count)
        case ">": row.kind = .quote
        case "[]", "[ ]", "[x]", "[X]", "-[]", "-[ ]":
            row.kind = .bullet
            row.marker = row.marker == "*" ? "*" : "-"
            row.task = prefix.lowercased().contains("x") ? .done(prefix.contains("X") ? "X" : "x") : .open
        case _ where ["-", "*", "+"].contains(prefix) && row.kind == .paragraph:
            row.kind = .bullet
            row.marker = prefix.first!
        default:
            let digits = prefix.dropLast()
            guard let delimiter = prefix.last, delimiter == "." || delimiter == ")", !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let number = Int(digits) else { return false }
            row.kind = .ordered
            row.marker = delimiter
            row.number = number
        }
        row.spacing = 1
        row.text = rest
        replaceRow(index, with: row, actionName: "Change Row Type")
        restoreCaret(CaretPosition(row: index, offset: 0))
        return true
    }

    private func makeRule(at index: Int) {
        var all = rows
        let before = all
        all[index] = NoteRow(kind: .rule, depth: all[index].depth, text: "---", gap: all[index].gap)
        all.insert(NoteRow(kind: .bullet, depth: all[index].depth, gap: [""]), at: index + 1)
        NoteOutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "Horizontal Line")
        restoreCaret(CaretPosition(row: index + 1, offset: 0))
    }

    @objc func indentRows(_ sender: Any?) { perform("Indent") { NoteOutlineEditing.indent(&$0, $1) } }
    @objc func outdentRows(_ sender: Any?) { perform("Outdent") { NoteOutlineEditing.outdent(&$0, $1) } }
    @objc func moveRowsUp(_ sender: Any?) { perform("Move Up") { NoteOutlineEditing.moveUp(&$0, $1) } }
    @objc func moveRowsDown(_ sender: Any?) { perform("Move Down") { NoteOutlineEditing.moveDown(&$0, $1) } }

    /// ⌘Return: a checkbox — open, checked, then a bullet again.
    @objc func cycleChecklist(_ sender: Any?) {
        perform("Checklist Item") { rows, selection in
            NoteOutlineEditing.cycle(.checklist, &rows, selection)
            return selection
        }
    }

    /// A checkbox checks; a bullet with children folds them, or unfolds.
    func clickHandle(ofRow index: Int) {
        let all = rows
        guard all.indices.contains(index) else { return }
        let row = all[index]
        let one = index..<(index + 1)
        if row.task != nil {
            perform("Toggle Done", on: one, followingCaret: false) { rows, s in NoteOutlineEditing.toggleDone(&rows, s); return s }
        } else if row.isFolded {
            perform("Expand", on: one, followingCaret: false) { rows, s in NoteOutlineEditing.unfold(&rows, at: s.lowerBound); return s }
        } else if NoteOutlineEditing.hasChildren(all, index) {
            perform("Collapse", on: one, followingCaret: false) { rows, s in NoteOutlineEditing.fold(&rows, at: s.lowerBound); return s }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = (layoutManager as? NoteOutlineLayoutManager)?.handleHit(at: point, origin: textContainerOrigin) {
            window?.makeFirstResponder(self)
            return clickHandle(ofRow: index)
        }
        super.mouseDown(with: event)
    }

    // MARK: Pasteboard

    /// Rows copied as the Markdown they say; within one row, its text.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let target = targetRows
        guard target.count > 1 else { return super.writeSelection(to: pboard, type: type) }
        let all = rows
        let block = NoteOutlineEditing.block(all, target)
        var picked = Array(all[block])
        let base = picked.map(\.depth).min() ?? 0
        for i in picked.indices { picked[i].depth -= base }
        picked[0].gap = []
        pboard.clearContents()
        return pboard.setString(NoteOutlineMarkdown.serialize(NoteOutline(rows: picked)), forType: .string)
    }

    /// Markdown of more than a line comes in as rows: in place of an empty
    /// row, or after the rows it was pasted onto.
    override func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string), s.contains("\n") else { return super.paste(sender) }
        let pasted = NoteOutlineMarkdown.parse(s).rows
        guard !pasted.isEmpty else { return super.paste(sender) }
        var all = rows
        let before = all
        let target = targetRows
        let current = all[target.lowerBound]
        let at: Int
        if target.count == 1, current.text.isEmpty, !current.isFolded {
            all.remove(at: target.lowerBound)
            at = target.lowerBound
        } else {
            at = NoteOutlineEditing.block(all, target).upperBound
        }
        let base = pasted.map(\.depth).min() ?? 0
        var incoming = pasted.map { r -> NoteRow in var r = r; r.depth = r.depth - base + current.depth; return r }
        incoming[0].gap = []
        all.insert(contentsOf: incoming, at: at)
        NoteOutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "Paste")
        restoreCaret(CaretPosition(row: at + incoming.count - 1, offset: Int.max))
    }
}
