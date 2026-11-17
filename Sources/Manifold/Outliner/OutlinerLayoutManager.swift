import AppKit
import ManifoldCore

/// Draws what the styler marks — icons before links, a dot for a bullet,
/// a box for a task, a bar beside a quote — and, for an outline, what each
/// row is, in the margin beside it, as Bike 2 does: every row its handle, a
/// triangle (turned down when its rows are shown, dark when they're folded
/// away), a guide line down from an open row, a typed row's own mark in the
/// step after the handle. TextKit 1, so that it can.
final class OutlinerLayoutManager: NSLayoutManager {
    var theme = OutlinerTheme(font: .systemFont(ofSize: 14))
    /// The rows whose marks are drawn beside them: every row but those an
    /// app's view stands in place of.
    var rows: [BodyLine] = []
    /// Every row of the outline, as the note's layout counts them: what a
    /// click finds a row by, and where a folded row's pill is drawn.
    var lines: [BodyLine] = []
    /// The rows chosen whole, as the characters they cover: marked across the note's width.
    var chosen: ClosedRange<Int>?
    /// Words found, marked; and the one gone to now, marked more.
    var found: [NSRange] = []
    var foundAt: NSRange?
    /// Where rows being carried would be put down: a line across the
    /// note at a height, from how far in they would lie.
    var dropLine: (y: CGFloat, x: CGFloat)?
    /// Whether the note is shown as prose: rows a step further out, and
    /// the top-level ones — paragraphs — with no handle and no guide.
    var prose = false
    /// Whether the note is being written in: an empty one being written in
    /// shows the bullet its first row will have.
    var isWriting = false

    private var size: CGFloat { theme.size }

    /// Whether a row is drawn with its handle: as prose, a paragraph is not.
    private func hasHandle(_ row: BodyLine) -> Bool {
        !(prose && row.depth <= 1)
    }

    /// The row whose handle is at a point: its place among the lines.
    func mark(at point: CGPoint) -> Int? {
        for (index, row) in lines.enumerated() {
            guard hasHandle(row), let line = firstLine(of: row) else { continue }
            if markBox(of: row, on: line).contains(point) { return index }
        }
        return nil
    }

    /// Draws the mark of an outline's only row when nothing is written in
    /// it yet: the text system draws nothing for no text — not even what
    /// stands beside it — so the bullet would come only with the first word.
    func drawEmptyRow(at origin: CGPoint) {
        guard textStorage?.length == 0, !prose else { return }
        if !rows.isEmpty { return drawBackground(forGlyphRange: NSRange(location: 0, length: 0), at: origin) }
        guard isWriting else { return }
        let rect = extraLineFragmentRect.height > 0 ? extraLineFragmentRect : CGRect(x: 0, y: 0, width: 0, height: (theme.body.ascender - theme.body.descender).rounded(.up))
        let baseline = rect.minY + wordsBaseline
        let box = CGRect(x: 0, y: rect.minY, width: theme.step, height: rect.height)
        let diameter = max(4.5, (size * 0.3).rounded())
        theme.secondary.setFill()
        NSBezierPath(ovalIn: CGRect(x: box.midX - diameter / 2, y: baseline - theme.body.xHeight / 2 - diameter / 2, width: diameter, height: diameter).offsetBy(dx: origin.x, dy: origin.y)).fill()
    }

    /// How far under a line's top words of the body stand: where an empty row's mark is to stand too.
    private var wordsBaseline: CGFloat { defaultBaselineOffset(for: theme.body) }

    /// Where a row's first line is: its line's box, and its baseline.
    private func firstLine(of row: BodyLine) -> (rect: CGRect, baseline: CGFloat)? {
        guard let storage = textStorage else { return nil }
        if row.start < storage.length {
            let glyph = glyphIndexForCharacter(at: row.start)
            let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // A row with nothing in it has only its line's end to ask, which
            // sits lower than words would: its mark stands where words will.
            if row.end <= row.start { return (rect, rect.minY + wordsBaseline) }
            return (rect, rect.minY + location(forGlyphAt: glyph).y)
        }
        // The last row, with nothing in it yet: the line the caret waits on.
        let rect = extraLineFragmentRect
        guard rect.height > 0 else { return nil }
        return (rect, rect.minY + wordsBaseline)
    }

    /// The box a row's mark is drawn in: the step before its words.
    private func markBox(of row: BodyLine, on line: (rect: CGRect, baseline: CGFloat)) -> CGRect {
        let step = theme.step
        return CGRect(x: CGFloat(row.depth - 1 - (prose ? 1 : 0)) * step, y: line.rect.minY, width: step, height: line.rect.height)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let font = theme.body

        if let chosen {
            // Each row chosen, a band the width of the note — as Bike's: from where
            // its words begin to the note's edge, meeting the next.
            theme.accent.withAlphaComponent(0.18).setFill()
            for row in lines where row.start <= chosen.upperBound && row.end >= chosen.lowerBound && row.start >= chosen.lowerBound {
                let glyphs = glyphRange(forCharacterRange: NSRange(location: row.start, length: max(row.end - row.start, 0)), actualCharacterRange: nil)
                var rect = glyphs.length > 0 ? boundingRect(forGlyphRange: glyphs, in: container) : (firstLine(of: row)?.rect ?? .null)
                guard !rect.isNull else { continue }
                let left = max(CGFloat(row.depth - (prose ? 1 : 0)) * theme.step - 3, 0)
                rect.origin.x = left
                rect.size.width = container.size.width - left
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 3, yRadius: 3).fill()
            }
        }
        // What a find found: a highlighter's yellow behind each, the one gone to brighter.
        for range in found where range.location <= NSMaxRange(characters) && NSMaxRange(range) >= characters.location {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let current = range == foundAt
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                NSColor.systemYellow.withAlphaComponent(current ? 0.75 : 0.32).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: 0).offsetBy(dx: origin.x, dy: origin.y), xRadius: 3, yRadius: 3).fill()
            }
        }
        if let dropLine {
            theme.accent.setFill()
            let line = CGRect(x: dropLine.x + origin.x, y: dropLine.y + origin.y - 1, width: max(container.size.width - dropLine.x, 20), height: 2)
            NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(ovalIn: CGRect(x: line.minX - 3, y: line.midY - 3, width: 6, height: 6)).fill()
        }
        for (index, line) in lines.enumerated() where line.isFolded && line.start <= NSMaxRange(characters) && line.end >= characters.location {
            if let pill = foldPill(ofRow: index) { drawFoldPill(in: pill.offsetBy(dx: origin.x, dy: origin.y)) }
        }

        // An outline's marks, beside the rows being drawn — as Bike 2's: every row
        // its handle, a triangle in the step before it; a typed row its own mark too,
        // in the step after the handle — the box, the number, the dot.
        for row in rows where row.start <= NSMaxRange(characters) && row.end >= characters.location {
            guard let line = firstLine(of: row) else { continue }
            let box = markBox(of: row, on: line).offsetBy(dx: origin.x, dy: origin.y)
            let baseline = line.baseline + origin.y
            var number: Int?, done: Bool?, bullet = "-"
            if case .item(let n, let d, let b) = row.kind { (number, done, bullet) = (n, d, b) }
            // A plain row with nothing in it and nothing under it has no handle, as Bike's.
            let bare = row.end <= row.start && !row.hasChildren && done == nil && number == nil && bullet == "-"
            if !bare, hasHandle(row) { drawHandle(midX: box.midX, midY: baseline - font.xHeight / 2, expanded: row.hasChildren && !row.isFolded, dark: row.hasChildren && row.isFolded) }
            let mark = box.offsetBy(dx: theme.step, dy: 0)
            if let done {
                let side = (size * 0.95).rounded()
                let name = bullet == "+" ? (done ? "checkmark.circle.fill" : "circle") : (done ? "checkmark.square.fill" : "square")
                Self.draw(symbol: name, in: CGRect(x: mark.midX - side / 2, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side), pointSize: side, weight: .regular, colors: done ? [.white, theme.secondary] : [theme.secondary])
            } else if let number {
                let label = "\(number)\(bullet)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.9, weight: .regular), .foregroundColor: theme.text]
                let width = label.size(withAttributes: attributes).width
                label.draw(at: CGPoint(x: mark.maxX - 6 - width, y: baseline - font.ascender * 0.9 - 1), withAttributes: attributes)
            } else if bullet != "-", case .item = row.kind {
                let diameter = max(4.5, (size * 0.3).rounded())
                theme.text.setFill()
                NSBezierPath(ovalIn: CGRect(x: mark.midX - diameter / 2, y: baseline - font.xHeight / 2 - diameter / 2, width: diameter, height: diameter)).fill()
            }
        }
        // Guide lines, as Bike's: down from an expanded row's handle, the height of what it shows.
        for (index, row) in rows.enumerated() where row.hasChildren && !row.isFolded && hasHandle(row) {
            guard let first = firstLine(of: row) else { continue }
            var last = index
            while last + 1 < rows.count, rows[last + 1].depth > row.depth { last += 1 }
            guard last > index, let end = lastLine(of: rows[last]) else { continue }
            let x = markBox(of: row, on: first).midX + origin.x
            let top = first.rect.maxY + origin.y
            let bottom = end.rect.maxY + origin.y
            guard top < bottom else { continue }
            theme.text.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: CGRect(x: (x - 0.5).rounded(), y: top, width: 1, height: bottom - top)).fill()
        }

        storage.enumerateAttribute(.outlinerPill, in: characters) { value, range, _ in
            guard let pill = value as? OutlinerPill else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let side = (size * 0.72).rounded()
            var first = true
            var last: (rect: CGRect, baseline: CGFloat)?
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { whole, _ in
                var rect = whole
                // What of a link's hidden name fell onto another line is nothing to draw around.
                guard rect.width > 2 else { return }
                let glyph = self.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container)
                let fragment = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                // Where a link runs on to another line, its marks are by its words there and
                // no more: not out into the margin the line is set in from, nor on to the edge.
                let used = self.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let (left, right) = (max(rect.minX, used.minX), min(rect.maxX, used.maxX))
                guard right - left > 2 else { return }
                rect.origin.x = left
                rect.size.width = right - left
                let baseline = fragment.minY + self.location(forGlyphAt: glyphs.location).y
                // Nothing behind a link: its colour says it is one. Its block's icon before it…
                if first, let symbol = pill.symbol {
                    let x = pill.iconInside ? rect.minX : rect.minX - side - 5
                    let icon = CGRect(x: x, y: baseline - font.xHeight / 2 - side / 2, width: side, height: side).offsetBy(dx: origin.x, dy: origin.y)
                    Self.draw(symbol: symbol, in: icon, pointSize: side * 0.9, weight: .regular, colors: [pill.tint.withAlphaComponent(0.85)])
                }
                last = (rect, baseline)
                first = false
            }
            // …and after one that leaves Manifold, a small ↗, faint.
            if pill.leaves, let last {
                let side = (size * 0.7).rounded()
                let x = (pill.roomInside ? last.rect.maxX - (side + 3) : last.rect.maxX) + 2
                // Its middle a little over the words' middle: raised, as a mark after a word is.
                let mark = CGRect(x: x, y: last.baseline - font.xHeight * 0.75 - side / 2, width: side, height: side).offsetBy(dx: origin.x, dy: origin.y)
                Self.draw(symbol: "arrow.up.right", in: mark, pointSize: side * 0.8, weight: .regular, colors: [pill.tint.withAlphaComponent(0.7)])
            }
        }

        // A link's title, in the room left for it after what is written.
        storage.enumerateAttribute(.outlinerLabel, in: characters) { value, range, _ in
            guard let label = value as? OutlinerLinkLabel else { return }
            let glyph = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyph.length > 0 else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let at = location(forGlyphAt: glyph.location)
            // On the line's own baseline: drawn from a corner, a face with leading of its own
            // would sit below its neighbours by it.
            let baseline = CGPoint(x: fragment.minX + at.x + label.lead + origin.x, y: fragment.minY + at.y + origin.y)
            // Past the text's edge, the title ends in "…" where the edge is — not cut through a letter.
            let room = container.size.width - container.lineFragmentPadding - (fragment.minX + at.x + label.lead)
            Self.fitted(label.text, to: room).draw(with: CGRect(origin: baseline, size: CGSize(width: 10_000, height: 0)), options: [], context: nil)
        }

        storage.enumerateAttribute(.outlinerBullet, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyph = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyph, in: container)
            let baseline = lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil).minY + location(forGlyphAt: glyph.location).y
            let diameter = max(4.5, (size * 0.3).rounded())
            let dot = CGRect(x: rect.midX - diameter / 2, y: baseline - font.xHeight / 2 - diameter / 2, width: diameter, height: diameter).offsetBy(dx: origin.x, dy: origin.y)
            theme.secondary.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        storage.enumerateAttribute(.outlinerTask, in: characters) { value, range, _ in
            guard let task = value as? OutlinerTaskBox else { return }
            let glyph = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let start = location(forGlyphAt: glyph.location)
            let fragment = lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let side = (size * 0.95).rounded()
            let baseline = fragment.minY + start.y
            let box = CGRect(x: fragment.minX + start.x, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side).offsetBy(dx: origin.x, dy: origin.y)
            let name = task.isRound ? (task.isDone ? "checkmark.circle.fill" : "circle") : (task.isDone ? "checkmark.square.fill" : "square")
            Self.draw(symbol: name, in: box, pointSize: side, weight: .regular, colors: task.isDone ? [.white, theme.secondary] : [theme.secondary])
        }

        // A quote's bar beside it: one for quotes that follow one another, as one quote is.
        var bars: [CGRect] = []
        storage.enumerateAttribute(.outlinerQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var whole = CGRect.null
            var left = CGFloat.greatestFiniteMagnitude
            var bottom = CGFloat.zero
            var top = CGFloat?.none
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, lineGlyphs, _ in
                whole = whole.union(CGRect(x: used.minX, y: fragment.minY, width: used.width, height: fragment.height))
                left = min(left, used.minX)
                // Where the line's words end below: its baseline and the font's descent — not the room under the line.
                let baseline = fragment.minY + self.location(forGlyphAt: lineGlyphs.location).y
                if top == nil { top = baseline - font.ascender }
                bottom = baseline - font.descender
            }
            guard !whole.isNull else { return }
            // A rule a little longer than the words, at both ends.
            let reach = (size * 0.2).rounded()
            let start = max((top ?? whole.minY) - reach, whole.minY)
            let bar = CGRect(x: max(left - theme.step / 2 - 2, 0), y: start, width: 4, height: bottom + reach - start)
            if let last = bars.last, abs(last.minX - bar.minX) < 1, bar.minY - last.maxY < size * 1.2 {
                bars[bars.count - 1] = last.union(bar)
            } else {
                bars.append(bar)
            }
        }
        for bar in bars {
            // A quote: a thin rule at its left, and nothing behind it.
            theme.faint.setFill()
            let drawn = CGRect(x: bar.minX + 1, y: bar.minY, width: 2, height: max(bar.height, 2)).offsetBy(dx: origin.x, dy: origin.y)
            NSBezierPath(roundedRect: drawn, xRadius: 1, yRadius: 1).fill()
        }
    }

    /// Words as wide as `room` at most: cut where they must be, with "…" after.
    static func fitted(_ text: NSAttributedString, to room: CGFloat) -> NSAttributedString {
        guard room > 0, text.size().width > room, text.length > 1 else { return text }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        let words = text.string
        var count = words.count
        var cut = text
        while count > 1 {
            count -= 1
            let kept = String(words.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
            cut = NSAttributedString(string: kept, attributes: attributes)
            if cut.size().width <= room { break }
        }
        return cut
    }

    /// A row's handle: a small triangle pointing at its words — down when its rows are shown.
    private func drawHandle(midX: CGFloat, midY: CGFloat, expanded: Bool, dark: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = (size * 0.42).rounded()
        let (x, y) = (midX.rounded(), midY.rounded())
        let points: [CGPoint] = expanded
            ? [CGPoint(x: x - side / 2, y: y - side * 0.3), CGPoint(x: x + side / 2, y: y - side * 0.3), CGPoint(x: x, y: y + side * 0.45)]
            : [CGPoint(x: x - side * 0.3, y: y - side / 2), CGPoint(x: x + side * 0.45, y: y), CGPoint(x: x - side * 0.3, y: y + side / 2)]
        context.saveGState()
        context.setFillColor((dark ? theme.secondary : theme.text.withAlphaComponent(0.3)).cgColor)
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// Weft's pill on a folded row, with how many it hides: not drawn, as Bike shows a fold by its handle.
    static let drawsFoldPills = false

    /// Where a row's last line is.
    private func lastLine(of row: BodyLine) -> (rect: CGRect, baseline: CGFloat)? {
        guard let storage = textStorage, row.end > row.start, row.end <= storage.length else { return firstLine(of: row) }
        let glyph = glyphIndexForCharacter(at: row.end - 1)
        let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return (rect, rect.minY + location(forGlyphAt: glyph).y)
    }

    // MARK: An outline's rows, where a click finds them

    /// How many rows a row is under: what its mark is set in by.
    func level(of row: BodyLine) -> Int {
        row.depth - 1 - (prose ? 1 : 0)
    }

    /// The row at a point of the container: its place among the note's lines. nil between rows.
    func row(at point: CGPoint, in container: NSTextContainer) -> Int? {
        guard !lines.isEmpty, let storage = textStorage else { return nil }
        // The last row, with nothing in it yet: the line the caret waits on.
        let extra = extraLineFragmentRect
        if extra.height > 0, point.y >= extra.minY, point.y <= extra.maxY + 4 { return lines.count - 1 }
        guard storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= fragment.minY - 4, point.y <= fragment.maxY + 4 else { return nil }
        let character = characterIndexForGlyph(at: glyph)
        return lines.lastIndex { $0.start <= character }
    }

    /// All the lines a row takes, in the container.
    func rect(ofRow index: Int) -> CGRect {
        guard lines.indices.contains(index), let storage = textStorage else { return .null }
        let line = lines[index]
        guard line.start < storage.length else { return extraLineFragmentRect }
        // With its line break, which is all an empty row has.
        let range = NSRange(location: line.start, length: max(min(line.end + 1, storage.length) - line.start, 1))
        var rect = CGRect.null
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, _, _ in rect = rect.union(fragment) }
        return rect
    }

    /// Where a row's handle is drawn, in the container: its middle.
    func handleCenter(ofRow index: Int) -> CGPoint? {
        guard lines.indices.contains(index), let line = firstLine(of: lines[index]) else { return nil }
        let box = markBox(of: lines[index], on: line)
        return CGPoint(x: box.midX, y: line.baseline - theme.body.xHeight / 2)
    }

    /// Where a folded row's pill is, in the container: after the words of
    /// its last line, on the middle of their capitals. Only a paragraph's
    /// as prose, which has no handle to show its fold.
    func foldPill(ofRow index: Int) -> CGRect? {
        guard lines.indices.contains(index), Self.drawsFoldPills || !hasHandle(lines[index]), lines[index].isFolded, let storage = textStorage else { return nil }
        let line = lines[index]
        let font = theme.body
        let height = (font.capHeight + 9).rounded()
        let size = CGSize(width: (height * 1.7).rounded(), height: height)
        guard line.end > line.start, line.end <= storage.length else {
            guard let first = firstLine(of: line) else { return nil }
            return CGRect(origin: CGPoint(x: CGFloat(line.depth - (prose ? 1 : 0)) * theme.step, y: (first.baseline - font.capHeight / 2 - height / 2).rounded()), size: size)
        }
        let last = glyphIndexForCharacter(at: line.end - 1)
        let fragment = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let used = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let baseline = fragment.minY + location(forGlyphAt: last).y
        return CGRect(origin: CGPoint(x: used.maxX + 6, y: (baseline - font.capHeight / 2 - height / 2).rounded()), size: size)
    }

    /// The folded row whose pill is at a point, if one is.
    func foldPill(at point: CGPoint) -> Int? {
        lines.indices.first { lines[$0].isFolded && foldPill(ofRow: $0)?.insetBy(dx: -8, dy: -8).contains(point) == true }
    }

    /// A pill with three dots in it, on their middle.
    private func drawFoldPill(in rect: CGRect) {
        theme.text.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        theme.secondary.setFill()
        let dot = max(2.5, (rect.height * 0.16).rounded())
        let gap = dot * 1.1
        let total = 3 * dot + 2 * gap
        for index in 0..<3 {
            NSBezierPath(ovalIn: CGRect(x: rect.midX - total / 2 + CGFloat(index) * (dot + gap), y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        }
    }

    /// The link at a point of the text container, if a link's words are there.
    func link(at point: CGPoint, in container: NSTextContainer) -> OutlinerLink? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -3)
        guard rect.contains(point) else { return nil }
        let character = characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return (storage.attribute(.outlinerLink, at: character, effectiveRange: nil) as? OutlinerLinkBox)?.target
    }

    /// The place in the text of the task whose box is at a point, if one is.
    func task(at point: CGPoint, in container: NSTextContainer) -> Int? {
        // An outline's box is in the step after its row's handle.
        for row in rows {
            guard case .item(_, let done, _) = row.kind, done != nil, let line = firstLine(of: row) else { continue }
            if markBox(of: row, on: line).offsetBy(dx: theme.step, dy: 0).contains(point) { return row.start }
        }
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container)
        let character = characterIndexForGlyph(at: glyph)
        guard character < storage.length, storage.attribute(.outlinerTask, at: character, effectiveRange: nil) != nil else { return nil }
        let start = location(forGlyphAt: glyph)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let room = CGRect(x: fragment.minX + start.x - 3, y: fragment.minY, width: (size * 1.5).rounded(.up) + 3, height: fragment.height)
        return room.contains(point) ? character : nil
    }

    static func draw(symbol: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor]) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: colors))
        // The system's symbol; else one of Manifold's own (a note's, a terminal's, an agent's), in the first colour.
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? Theme.symbol(symbol, size: pointSize, weight: weight, color: colors.last ?? .labelColor) else { return }
        let fitted = CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
