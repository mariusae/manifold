import AppKit
import ManifoldCore

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
    /// ⌘-click on a place in the text.
    func textView(_ view: TextView, commandClickAt offset: Int)
    /// ⌃Space.
    func textViewRequestsCompletion(_ view: TextView)
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
    var textColor = Theme.text
    var showsLineNumbers = true { didSet { invalidateAll() } }
    var wraps = true { didSet { invalidateAll() } }
    var tabWidth = 4
    var isEditable = true
    static let insets = NSEdgeInsets(top: 20, left: 8, bottom: 40, right: 20)
    var gutterWidth: CGFloat { showsLineNumbers ? 52 : 0 }

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
    private var rowStartsValid = false
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
    private var applyingOurs = false

    // Caret.
    private var caretVisible = true
    private var caretTimer: Timer?
    private var dragAnchor: Selection?
    private var dragMode = 0 // 1 char, 2 word, 3 line

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fontChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
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

    private func invalidateAll() {
        layouts = [:]
        rowCounts = Array(repeating: 1, count: text.lineCount)
        rowStartsValid = false
        resizeToFit()
        needsDisplay = true
    }

    private func fontChanged() {
        let a = CTFontGetAscent(font), d = CTFontGetDescent(font), l = CTFontGetLeading(font)
        lineHeight = ceil((a + d + l) * lineHeightMultiple)
        ascent = ceil(a + (lineHeight - (a + d + l)) / 2)
        invalidateAll()
    }

    // MARK: Geometry

    private var textLeft: CGFloat { Self.insets.left + gutterWidth }
    private var wrapWidth: CGFloat { max(40, bounds.width - textLeft - Self.insets.right) }

    private func ensureRowStarts() {
        guard !rowStartsValid else { return }
        if rowCounts.count != text.lineCount { rowCounts = Array(repeating: 1, count: text.lineCount) }
        rowStarts = [0]
        rowStarts.reserveCapacity(rowCounts.count + 1)
        var n = 0
        for c in rowCounts {
            n += c
            rowStarts.append(n)
        }
        rowStartsValid = true
    }

    private var totalRows: Int {
        ensureRowStarts()
        return rowStarts.last ?? 0
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
            rowCounts = Array(repeating: 1, count: text.lineCount)
            rowStartsValid = false
            needsDisplay = true
            DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
        }
    }

    /// The layout of a logical line, made if need be (and the row counts
    /// corrected, which moves everything after it).
    private func layout(line n: Int) -> LineLayout {
        if let l = layouts[n] { return l }
        let string = text.lineText(n)
        let attributed = NSAttributedString(string: string.isEmpty ? " " : string, attributes: attributes())
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var rows: [CTLine] = []
        var starts: [Int] = []
        let length = (attributed.string as NSString).length
        var i = 0
        if wraps {
            while i < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, i, Double(wrapWidth))
                let take = max(count, 1)
                rows.append(CTTypesetterCreateLine(typesetter, CFRange(location: i, length: take)))
                starts.append(i)
                i += take
                if rows.count > 2000 { break }
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
        if n < rowCounts.count, rowCounts[n] != rows.count {
            rowCounts[n] = rows.count
            rowStartsValid = false
            DispatchQueue.main.async { [weak self] in
                self?.resizeToFit()
                self?.needsDisplay = true
            }
        }
        return l
    }

    private func attributes() -> [NSAttributedString.Key: Any] {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = space * CGFloat(tabWidth)
        style.lineBreakMode = .byCharWrapping
        return [.font: font, .foregroundColor: textColor, .paragraphStyle: style]
    }

    /// The y of a logical line's first row.
    private func top(ofLine n: Int) -> CGFloat {
        ensureRowStarts()
        let row = n < rowStarts.count ? rowStarts[n] : (rowStarts.last ?? 0)
        return Self.insets.top + CGFloat(row) * lineHeight
    }

    /// The logical line at a y.
    private func line(atY y: CGFloat) -> Int {
        ensureRowStarts()
        let row = Int((y - Self.insets.top) / lineHeight)
        guard row >= 0 else { return 0 }
        var lo = 0, hi = max(rowCounts.count - 1, 0)
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

    // MARK: Drawing

    static let selectionColor = NSColor.dynamic(NSColor(srgbRed: 0.81, green: 0.886, blue: 0.984, alpha: 1),
                                                NSColor(srgbRed: 0.149, green: 0.31, blue: 0.47, alpha: 1))
    static let caretColor = NSColor.dynamic(NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1),
                                            NSColor(srgbRed: 0.04, green: 0.518, blue: 1, alpha: 1))
    static let lineHighlight = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.95, blue: 0.72, alpha: 1),
                                               NSColor(srgbRed: 0.32, green: 0.28, blue: 0.12, alpha: 1))
    static let gutterText = NSColor.dynamic(NSColor(white: 0.62, alpha: 1), NSColor(white: 0.42, alpha: 1))
    static let matchColor = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 0.7),
                                            NSColor(srgbRed: 0.5, green: 0.42, blue: 0.1, alpha: 0.8))

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

        // Matches, then selections' backgrounds.
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

        // Text.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize * 0.78), weight: .regular)
        for n in first...last {
            let l = layout(line: n)
            let lineTop = top(ofLine: n)
            if showsLineNumbers {
                let s = NSAttributedString(string: "\(n + 1)", attributes: [.font: gutterFont, .foregroundColor: Self.gutterText])
                let size = s.size()
                ctx.restoreGState()
                s.draw(at: NSPoint(x: textLeft - 14 - size.width, y: lineTop + (lineHeight - size.height) / 2))
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            }
            guard !l.text.isEmpty else { continue }
            for (r, row) in l.rows.enumerated() {
                ctx.textPosition = CGPoint(x: textLeft, y: lineTop + CGFloat(r) * lineHeight + ascent)
                CTLineDraw(row, ctx)
            }
        }
        ctx.restoreGState()

        // The git gutter: a bar beside added and changed lines, a wedge
        // where lines were taken out.
        if showsLineNumbers, !gutterMarks.isEmpty {
            let x = Self.insets.left + 2
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

    static let addedColor = NSColor.dynamic(NSColor(srgbRed: 0.3, green: 0.72, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.4, green: 0.8, blue: 0.5, alpha: 1))
    static let modifiedColor = NSColor.dynamic(NSColor(srgbRed: 0.35, green: 0.6, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.45, green: 0.65, blue: 1, alpha: 1))
    static let deletedColor = NSColor.dynamic(NSColor(srgbRed: 0.9, green: 0.35, blue: 0.35, alpha: 1), NSColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 1))

    static func diagnosticColor(_ severity: Int) -> NSColor {
        switch severity {
        case 1: return NSColor.systemRed
        case 2: return NSColor.systemOrange
        default: return NSColor.systemBlue.withAlphaComponent(0.6)
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
        for n in startLine...endLine {
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
        for n in startLine...endLine {
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
        if let h = highlightedLine, !selections.contains(where: { text.line(at: $0.head) == h }) { highlightedLine = nil }
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
            self.caretVisible.toggle()
            self.needsDisplay = true
        }
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
            if undoStack.count > 2000 { undoStack.removeFirst() }
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
            rowStartsValid = false
            knownLineCount = newCount
        } else if let e = edits.first {
            let n = text.line(at: e.start)
            layouts.removeValue(forKey: n)
        }
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
        if delegate?.textView(self, handle: event) == true { return }
        if handleShortcut(event) { return }
        inputContext?.handleEvent(event)
    }

    /// Shortcuts the standard selectors don't cover.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers ?? ""
        switch (flags, chars) {
        case ([.command], "d"): selectNextOccurrence(); return true
        case ([.command, .shift], "d"): duplicateLines(); return true
        case ([.control, .shift], "k"): deleteLines(); return true
        case ([.command], "/"): toggleComment(); return true
        case ([.control], "j"): joinLines(); return true
        case ([.control], " "): delegate?.textViewRequestsCompletion(self); return true
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
                row = layout(line: line).rows.count - 1
            } else if row >= l.rows.count {
                guard line + 1 < text.lineCount else { out.append(extend ? Selection(s.anchor, text.count) : Selection(at: text.count)); continue }
                line += 1
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

    private func page(_ direction: Int, extend: Bool) {
        let visible = enclosingScrollView?.contentSize.height ?? bounds.height
        let rows = max(1, Int(visible / lineHeight) - 2)
        for _ in 0..<rows { moveVertically(direction, extend: extend) }
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

    /// ⌘D: with a word under the caret, selects it; with a selection, adds
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let offset = self.offset(at: p)
        let flags = event.modifierFlags
        dragMode = min(event.clickCount, 3)
        if flags.contains(.command), event.clickCount == 1 {
            setSelections([Selection(at: offset)])
            dragAnchor = nil
            delegate?.textView(self, commandClickAt: offset)
            return
        }
        if flags.contains(.shift), let last = selections.last {
            setSelections(selections.dropLast() + [Selection(last.anchor, offset)])
            dragAnchor = Selection(last.anchor, offset)
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

    override func mouseDragged(with event: NSEvent) {
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

    override func mouseUp(with event: NSEvent) { dragAnchor = nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Pasteboard

    var selectedText: String {
        selections.filter { !$0.isCaret }.map { text[$0.range] }.joined(separator: "\n")
    }

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

    @objc func paste(_ sender: Any?) {
        guard isEditable, let s = NSPasteboard.general.string(forType: .string) else { return }
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
        if sendType == .string, !selectedText.isEmpty { return self }
        if returnType == .string, isEditable { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        pboard.clearContents()
        return pboard.setString(selectedText, forType: .string)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
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
