import AppKit
import ManifoldCore

// The outliner's look, as Weft's editor (prism's `BodyStyler`) dresses a
// note: the engine says what each line and run of the text *is*
// (`NoteEditor.layout`); this turns that into fonts, colours, and the
// marks the layout manager draws — links' icons, bullets, boxes. It knows
// no Markdown: a line is a row and holds only its words, and what the
// row is, is drawn in the margin beside it.

/// What a link in a note leads to: what a click follows.
enum OutlinerLink: Hashable {
    /// `[[A page]]`.
    case page(String)
    case tag(String)
    /// An address: the web's, mail's, or Manifold's own (`manifold:host/id`).
    case web(String)

    /// As the view hands it to be followed: an address as it is, a page
    /// as `[[name]]`, a tag as `#name`.
    var address: String {
        switch self {
        case .page(let name): return "[[\(name)]]"
        case .tag(let name): return "#\(name)"
        case .web(let url): return url
        }
    }

    /// Whether an address is Manifold's own: a block, or a place in one.
    static func isManifold(_ url: String) -> Bool { url.hasPrefix("manifold:") }
}

/// What a link shows in place of what is written: its block's title.
final class OutlinerLinkLabel: NSObject {
    let text: NSAttributedString
    /// How far in from its character the title is drawn: the room its icon takes first.
    let lead: CGFloat
    init(_ text: NSAttributedString, lead: CGFloat = 0) {
        self.text = text
        self.lead = lead
    }
}

/// A link's marks: an icon before its words, a ↗ after them.
final class OutlinerPill: NSObject {
    /// An icon before the words: a Manifold link's block's own.
    let symbol: String?
    let tint: NSColor
    let isMissing: Bool
    /// A small ↗ after the words: a link that leaves Manifold.
    let leaves: Bool
    /// Whether the room for the ↗ is on the link's own last character — an
    /// address written bare — and so inside what its words take.
    let roomInside: Bool
    /// Whether the icon's room is the link's own — drawn as its title, the
    /// icon first in it — rather than before it.
    let iconInside: Bool
    init(symbol: String?, tint: NSColor, isMissing: Bool, leaves: Bool = false, roomInside: Bool = false, iconInside: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.isMissing = isMissing
        self.leaves = leaves
        self.roomInside = roomInside
        self.iconInside = iconInside
    }
}

/// A task's box, drawn where its marker is written.
final class OutlinerTaskBox: NSObject {
    let isDone: Bool
    let isRound: Bool
    init(isDone: Bool, isRound: Bool) {
        self.isDone = isDone
        self.isRound = isRound
    }
}

/// The link under some words: what a click follows.
final class OutlinerLinkBox: NSObject {
    let target: OutlinerLink
    init(_ target: OutlinerLink) { self.target = target }
}

extension NSAttributedString.Key {
    static let outlinerPill = NSAttributedString.Key("manifold.outliner.pill")
    static let outlinerLink = NSAttributedString.Key("manifold.outliner.link")
    static let outlinerLabel = NSAttributedString.Key("manifold.outliner.label")
    /// A link shown as its words, whole: where it starts. The caret is never inside it.
    static let outlinerWhole = NSAttributedString.Key("manifold.outliner.whole")
    static let outlinerBullet = NSAttributedString.Key("manifold.outliner.bullet")
    static let outlinerTask = NSAttributedString.Key("manifold.outliner.task")
    static let outlinerQuote = NSAttributedString.Key("manifold.outliner.quote")
    /// Markdown that is never seen: the caret steps over it, Delete leaves it be.
    static let outlinerMarkup = NSAttributedString.Key("manifold.outliner.markup")
}

/// Dresses what a note's editor shows as what it means (see the top of this file).
struct OutlinerStyler {
    var theme: OutlinerTheme
    /// Whether a page of this name is there, for a link's look.
    var pageExists: (String) -> Bool = { _ in true }
    /// What a link's block or page is shown as called — its title — when
    /// that is not what the link already says: nil where it does.
    var linkTitle: (String) -> String? = { _ in nil }
    /// The icon a link's block or page was given: an SF Symbol's name.
    var linkSymbol: (String) -> String? = { _ in nil }
    /// Whether the note is being written in. Not, an empty typed row — a box,
    /// a number with nothing by it — is put away: there for writing, not reading.
    var isWriting = true
    /// Whether the note is shown as prose: every row a step further out,
    /// so its top-level rows stand at the margin, as paragraphs, apart.
    var prose = false

    static let hiddenFont = NSFont.systemFont(ofSize: 0.1)

    /// How far in a row's words begin. A row stands in from the margin by its
    /// depth, what it is drawn in the step before it; a typed row — a task, a
    /// number, a bulleted row — and a quote have their mark a step further in,
    /// after the handle, as Bike's list marks are. As prose, a step less: a
    /// top-level row is a paragraph, at the margin. An empty row's caret
    /// stands here too, with no character to carry it.
    static func wordsIndent(of line: BodyLine, step: CGFloat, prose: Bool) -> CGFloat {
        var steps = line.depth - (prose ? 1 : 0)
        switch line.kind {
        case .item(let number, let done, let bullet) where done != nil || number != nil || bullet != "-": steps += 1
        case .quote: steps += 1
        default: break
        }
        return CGFloat(steps) * step
    }

    /// A note's first heading is its own; those under it are structure, and read
    /// as a section's name — at the body's size, set apart by weight and room.
    static let headingScales: [CGFloat] = [1.3, 1.02, 1, 1, 0.95, 0.95]

    static func headingScale(_ level: Int) -> CGFloat { headingScales[min(max(level, 1), 6) - 1] }

    var size: CGFloat { theme.size }
    var iconSide: CGFloat { (size * 0.72).rounded() }
    /// The room before a link's words for its icon.
    var leadWidth: CGFloat { iconSide + 5 }
    /// The room a ↗ after a link takes, with the space before it.
    var arrowRoom: CGFloat { (size * 0.7).rounded() + 3 }
    var taskRoom: CGFloat { (size * 1.5).rounded(.up) }

    /// The room under each of a row's lines, for the line height a row of its
    /// kind is set to: an outline compact, for scanning a list (1.4); what is
    /// read as prose — a paragraph shown as prose, a quote — more open (1.6),
    /// a heading tight (1.15), code between. As the font's own height differs
    /// from face to face, the room is what is left to the height asked for.
    static func lineSpacing(for kind: BodyLineKind, depth: Int, prose: Bool, font: NSFont) -> CGFloat {
        let height: CGFloat = switch kind {
        case .heading: 1.15
        case .quote: 1.6
        case .code, .fence: 1.3
        default: prose && depth <= 1 ? 1.6 : outlineHeight
        }
        let natural = font.ascender - font.descender + font.leading
        return max((font.pointSize * height - natural).rounded(), 0)
    }

    static let outlineHeight: CGFloat = 1.4
    /// The room after an outline's row, before the next, as a share of the size.
    static let outlineGap: CGFloat = 0.05

    /// What a row is, for the room between rows: rows of one kind stand
    /// together, and where the kind changes — a note's properties to its
    /// words, words to a quote — a little more room sets the groups apart.
    enum Group { case property, quote, other }

    /// The properties a note is given as rows — a link kept, an article —
    /// whose names are said as what they are: about the note, not of it.
    static let propertyNames: Set<String> = ["url", "type", "description", "author", "source", "date"]

    /// Where a row's property name is — `URL:`, to its colon — if the row
    /// begins with one of them.
    static func propertyName(in text: NSString, range: NSRange) -> NSRange? {
        guard range.length > 2, NSMaxRange(range) <= text.length else { return nil }
        let words = text.substring(with: range)
        guard let colon = words.firstIndex(of: ":"), words.distance(from: words.startIndex, to: colon) <= 12 else { return nil }
        guard propertyNames.contains(words[..<colon].lowercased()) else { return nil }
        return NSRange(location: range.location, length: (String(words[...colon]) as NSString).length)
    }

    /// A property row with nothing after its name yet: as tall as a row of
    /// words, its name on their baseline — so that writing its value moves nothing.
    private func holdLine(of paragraph: NSMutableParagraphStyle, key: NSRange, in row: NSRange, storage: NSTextStorage) {
        let rest = (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(key), length: NSMaxRange(row) - NSMaxRange(key)))
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty, let label = storage.attribute(.font, at: key.location, effectiveRange: nil) as? NSFont else { return }
        let held = Self.heldLine(body: theme.body, label: label)
        paragraph.minimumLineHeight = held.height
        storage.addAttribute(.baselineOffset, value: held.raise, range: key)
    }

    /// A line of a name in the label face and words in the body face, as laid
    /// out: how tall it is, and how far the name alone, on a line held that
    /// tall, must be raised to stand on its baseline. Measured once a pair.
    private static var heldLines: [String: (height: CGFloat, raise: CGFloat)] = [:]

    static func heldLine(body: NSFont, label: NSFont) -> (height: CGFloat, raise: CGFloat) {
        let key = "\(body.fontName) \(body.pointSize) \(label.fontName) \(label.pointSize)"
        if let known = heldLines[key] { return known }
        func lay(_ text: NSAttributedString) -> (height: CGFloat, baseline: CGFloat) {
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: CGSize(width: 10_000, height: 10_000))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return (fragment.height, manager.location(forGlyphAt: 0).y)
        }
        let both = NSMutableAttributedString(string: "Name:", attributes: [.font: label])
        both.append(NSAttributedString(string: " words", attributes: [.font: body]))
        let mixed = lay(both)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = mixed.height
        let alone = lay(NSAttributedString(string: "Name:", attributes: [.font: label, .paragraphStyle: style]))
        let measured = (mixed.height, alone.baseline - mixed.baseline)
        heldLines[key] = measured
        return measured
    }

    /// Whether a row is typed — a box, a number, a bullet — with nothing written by it.
    static func isEmptyTyped(_ line: BodyLine) -> Bool {
        guard line.end <= line.content, case .item(let number, let done, let bullet) = line.kind else { return false }
        return done != nil || number != nil || bullet != "-"
    }

    /// How far a line of what is read as prose runs: about 75 characters,
    /// measured from where its words begin.
    func measure(from indent: CGFloat) -> CGFloat { indent + (size * 39).rounded() }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing(for: .paragraph, depth: 1, prose: false, font: theme.body)
        return [.font: theme.body, .foregroundColor: theme.text, .paragraphStyle: paragraph]
    }

    /// The lines a selection touches: the ones whose markup shows.
    static func revealed(_ layout: BodyLayout, selection: NSRange) -> Set<Int> {
        var lines = Set<Int>()
        for (index, line) in layout.lines.enumerated() {
            if line.start > NSMaxRange(selection) { break }
            if line.end >= selection.location { lines.insert(index) }
        }
        return lines
    }

    /// Dresses a storage as a layout says. `revealed` is the lines being
    /// written in; empty when the text is only read.
    func style(_ storage: NSTextStorage, layout: BodyLayout, revealed: Set<Int>) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)

        // Lines: indentation, and the fonts a whole line takes.
        var previousGroup: Group?
        for (index, line) in layout.lines.enumerated() {
            let range = NSRange(location: line.start, length: line.end - line.start)
            guard range.length >= 0, NSMaxRange(range) <= storage.length else { continue }
            let paragraph = NSMutableParagraphStyle()
            let indent = Self.wordsIndent(of: line, step: theme.step, prose: prose)
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.paragraphSpacing = (size * (prose && line.depth <= 1 ? 0.7 : Self.outlineGap)).rounded()
            switch line.kind {
            case .heading(let level):
                storage.addAttribute(.font, value: theme.display(size * Self.headingScale(level), weight: .semibold), range: range)
                paragraph.paragraphSpacingBefore += index == 0 ? 0 : (size * 0.5).rounded()
            case .item(_, let done, _):
                if done == true {
                    // Done, as Bike's: the row recedes as a whole — its words, its links, a light strike through them.
                    let words = NSRange(location: line.content, length: max(line.end - line.content, 0))
                    storage.addAttributes([.foregroundColor: theme.secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: theme.faint], range: words)
                }
            case .quote:
                // Its words a step in (see `wordsIndent`), a thin rule in that step; a little quieter than what is written.
                storage.addAttribute(.outlinerQuote, value: true, range: range)
                storage.addAttribute(.foregroundColor, value: theme.text.withAlphaComponent(0.82), range: range)
            case .code:
                // Only the code: its fences are Markdown, and never in the view. Room
                // above and below it, where its fences stood, sets it apart.
                storage.addAttribute(.font, value: theme.mono(size * 0.92), range: range)
                paragraph.paragraphSpacingBefore += (size * 0.5).rounded()
                paragraph.paragraphSpacing += (size * 0.3).rounded()
            case .rule:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            default:
                break
            }
            // A property, written as a row — `URL: …`, `Type: …` — says something about the note:
            // its name in the label face, small and quiet; a URL's address the same, smaller.
            var group: Group = if case .quote = line.kind { .quote } else { .other }
            if case .item(nil, nil, "-") = line.kind, let key = Self.propertyName(in: storage.string as NSString, range: range) {
                group = .property
                storage.addAttributes([.font: theme.label((size * 0.85).rounded(), weight: .regular), .foregroundColor: theme.secondary], range: key)
                holdLine(of: paragraph, key: key, in: range, storage: storage)
                if (storage.string as NSString).substring(with: key).lowercased().hasPrefix("url") {
                    // The address only — not the space before it, which keeps the line as it is.
                    let string = storage.string as NSString
                    var start = NSMaxRange(key)
                    while start < NSMaxRange(range), string.character(at: start) == 32 { start += 1 }
                    if start < NSMaxRange(range) {
                        storage.addAttribute(.font, value: theme.label((size * 0.9).rounded()), range: NSRange(location: start, length: NSMaxRange(range) - start))
                    }
                }
            } else if case .paragraph = line.kind, let key = Self.propertyName(in: storage.string as NSString, range: range) {
                group = .property
                storage.addAttributes([.font: theme.label((size * 0.85).rounded(), weight: .regular), .foregroundColor: theme.secondary], range: key)
                holdLine(of: paragraph, key: key, in: range, storage: storage)
            }
            // An empty typed row, while the note is only read: no room at all.
            if !isWriting, Self.isEmptyTyped(line) {
                paragraph.minimumLineHeight = 0.01
                paragraph.maximumLineHeight = 0.01
                paragraph.paragraphSpacing = 0
                let whole = NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))
                if whole.length > 0 { storage.addAttribute(.paragraphStyle, value: paragraph, range: whole) }
                continue
            }
            // Where the kind of row changes — properties to words, words to a quote — room sets the groups apart.
            // A heading has its own room before it already.
            if let previousGroup, previousGroup != group, previousGroup != .other || group != .other {
                if case .heading = line.kind {} else { paragraph.paragraphSpacingBefore += (size * 0.55).rounded() }
            }
            previousGroup = group
            // The room between its lines, by its kind and the font it is set in.
            let lineFont: NSFont = switch line.kind {
            case .heading(let level): theme.display(size * Self.headingScale(level))
            case .code, .fence: theme.mono(size * 0.92)
            default: theme.body
            }
            paragraph.lineSpacing = Self.lineSpacing(for: line.kind, depth: line.depth, prose: prose, font: lineFont)
            // What is read as prose — a paragraph shown as prose, a quote — runs no longer than a reader's measure.
            let readAsProse: Bool = switch line.kind {
            case .quote: true
            case .paragraph, .item: prose && line.depth <= 1
            default: false
            }
            if readAsProse { paragraph.tailIndent = measure(from: indent) }
            // The last row has nothing after it to be set apart from: no room after it.
            if index == layout.lines.count - 1 { paragraph.paragraphSpacing = 0 }
            // The paragraph's style covers its line break too.
            let paragraphRange = NSRange(location: range.location, length: min(range.length + 1, storage.length - range.location))
            if paragraphRange.length > 0 { storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange) }
        }

        // Runs: emphasis, links, tags, and the markup around them.
        var lineIndex = 0
        var markupEnd: [Int: Int] = [:]
        for run in layout.runs where run.kind == .markup { markupEnd[run.start] = run.end }
        for run in layout.runs {
            let range = NSRange(location: run.start, length: run.end - run.start)
            guard range.length > 0, NSMaxRange(range) <= storage.length, !layout.lines.isEmpty else { continue }
            while lineIndex + 1 < layout.lines.count, layout.lines[lineIndex + 1].start <= range.location { lineIndex += 1 }
            while lineIndex > 0, layout.lines[lineIndex].start > range.location { lineIndex -= 1 }
            let line = layout.lines[lineIndex]
            switch run.kind {
            case .markup:
                hide(storage, range)
            case .strong:
                restyle(storage, range) { theme.font($0.pointSize, weight: .semibold, italic: $0.outlinerIsItalic) }
            case .emphasis:
                restyle(storage, range) { theme.font($0.pointSize, weight: $0.outlinerIsBold ? .semibold : .regular, italic: true) }
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: theme.highlight, range: range)
            case .code:
                // Monospaced, and nothing behind it — as Bike's code in words.
                storage.addAttributes([.font: theme.mono(size * 0.92)], range: range)
            case .pageLink(let target, _):
                let missing = !pageExists(target)
                let symbol = linkSymbol(target)
                link(storage, range, to: .page(target), symbol: symbol, missing: missing, line: line, markupEnd: markupEnd)
                // A link written with its page's name shows the page's title.
                let words = (storage.string as NSString).substring(with: range)
                if range.length > 1, (storage.string as NSString).character(at: range.location) == 0xFFFC {
                    // Its atom, and then its words — the title — which wrap as words do:
                    // the atom is the room for its icon, and not seen; the whole is one thing to the caret.
                    storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear, .kern: symbol == nil ? 0 : leadWidth], range: NSRange(location: range.location, length: 1))
                    storage.addAttribute(.outlinerWhole, value: range.location, range: range)
                } else if words == "\u{FFFC}" {
                    // A link to a page is one character: drawn as its title, or its own name.
                    relabel(storage, range, as: linkTitle(target) ?? target, lead: symbol == nil ? 0 : leadWidth)
                } else if words == target, let label = linkTitle(target) {
                    relabel(storage, range, as: label)
                }
            case .webLink(let url):
                let written = (storage.string as NSString).substring(with: range)
                if OutlinerLink.isManifold(url) {
                    // Manifold's own: drawn as a page's link is — its block's icon before it, no ↗ —
                    // and, written bare, shown as its block's title.
                    let symbol = linkSymbol(url) ?? "doc.text"
                    let bare = written == url || (written.count >= 26 && url.hasSuffix(written))
                    link(storage, range, to: .web(url), symbol: symbol, missing: false, line: line, markupEnd: markupEnd, iconInside: bare)
                    if bare { relabel(storage, range, as: linkTitle(url) ?? String(url.dropFirst("manifold:".count)), lead: leadWidth) }
                } else {
                    // An address shown as itself is cut to what says where it leads.
                    link(storage, range, to: .web(url), symbol: nil, missing: false, line: line, markupEnd: markupEnd, leaves: true)
                    if written == url { shorten(storage, range, address: url as NSString) }
                }
            case .tag(let name):
                link(storage, range, to: .tag(name), symbol: nil, missing: false, line: line, markupEnd: markupEnd)
            case .image:
                if (storage.string as NSString).substring(with: range) == "\u{FFFC}" {
                    // A picture, one character among the words: it takes no room; the picture is shown under them.
                    storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: range)
                } else {
                    storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
                }
            case .bullet:
                if case .item(let number, let done, let bullet) = line.kind {
                    if number != nil {
                        storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
                    } else if let done {
                        // The box stands where the marker is written, in room of its own.
                        let first = NSRange(location: range.location, length: 1)
                        let glyph = width(of: storage, from: first.location, to: first.location + 1)
                        storage.addAttributes([.foregroundColor: NSColor.clear, .kern: max(taskRoom - glyph, 0), .outlinerTask: OutlinerTaskBox(isDone: done, isRound: bullet == "+")], range: first)
                        if range.length > 1 {
                            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: range.location + 1, length: range.length - 1))
                        }
                    } else {
                        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                        storage.addAttribute(.outlinerBullet, value: true, range: NSRange(location: range.location, length: 1))
                    }
                }
            case .checkbox:
                // With the space after it.
                let length = min(range.length + 1, line.content - range.location)
                storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear], range: NSRange(location: range.location, length: max(length, range.length)))
            case .quoteMark:
                let length = min(line.content - range.location, storage.length - range.location)
                hide(storage, NSRange(location: range.location, length: max(length, range.length)))
            case .callout:
                storage.addAttribute(.foregroundColor, value: theme.faint, range: range)
            case .fenceInfo:
                break
            }
        }
        storage.endEditing()
    }

    private func hide(_ storage: NSTextStorage, _ range: NSRange) {
        storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear, .outlinerMarkup: true], range: range)
    }

    private func link(_ storage: NSTextStorage, _ range: NSRange, to target: OutlinerLink, symbol: String?, missing: Bool, line: BodyLine, markupEnd: [Int: Int], leaves: Bool = false, iconInside: Bool = false) {
        // A link to a page not written yet — or in a row done: in the secondary ink.
        var done = false
        if case .item(_, let state, _) = line.kind { done = state == true }
        let tint = missing || done ? theme.secondary : theme.link
        storage.addAttributes([.foregroundColor: tint, .outlinerLink: OutlinerLinkBox(target)], range: range)
        if missing {
            restyle(storage, range) { theme.font($0.pointSize, weight: $0.outlinerIsBold ? .semibold : .regular, italic: true) }
        }
        // In a heading, a link is only coloured.
        if case .heading = line.kind { return }
        let closes = markupEnd[NSMaxRange(range)].map { $0 > NSMaxRange(range) } ?? false
        // A link shown as its title — one character, or relabelled — has its icon's room in it.
        let atom = iconInside || (range.length > 0 && (storage.string as NSString).character(at: range.location) == 0xFFFC)
        storage.addAttribute(.outlinerPill, value: OutlinerPill(symbol: symbol, tint: tint, isMissing: missing, leaves: leaves, roomInside: leaves && !closes, iconInside: atom), range: range)
        // Room for the icon, on the last character of the markup before the words…
        if symbol != nil, !atom, range.location > line.start {
            storage.addAttribute(.kern, value: leadWidth, range: NSRange(location: range.location - 1, length: 1))
        }
        // …and after them, for the ↗ of a link that leaves: on the last of the
        // markup that closes, or — an address written bare — its own last character.
        let after = leaves ? arrowRoom : 0
        if let end = markupEnd[NSMaxRange(range)], end > NSMaxRange(range) {
            storage.addAttribute(.kern, value: after, range: NSRange(location: end - 1, length: 1))
        } else if leaves, range.length > 0 {
            storage.addAttribute(.kern, value: after, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
    }

    /// A selection kept out of the inside of a link shown as its words: a
    /// caret there goes to its edge, the way it was going from `old`; a
    /// range that runs into one takes it in whole.
    static func outsideWholes(in storage: NSAttributedString, _ range: NSRange, from old: NSRange) -> NSRange {
        func whole(around at: Int) -> NSRange? {
            guard at > 0, at < storage.length else { return nil }
            var found = NSRange()
            guard let start = storage.attribute(.outlinerWhole, at: at, longestEffectiveRange: &found, in: NSRange(location: 0, length: storage.length)) as? Int,
                  storage.attribute(.outlinerWhole, at: at - 1, effectiveRange: nil) as? Int == start else { return nil }
            return found
        }
        var range = range
        if range.length == 0 {
            if let link = whole(around: range.location) { range.location = range.location > old.location ? NSMaxRange(link) : link.location }
        } else {
            if let link = whole(around: range.location) { range = NSRange(location: link.location, length: NSMaxRange(range) - link.location) }
            if let link = whole(around: NSMaxRange(range)) { range.length = NSMaxRange(link) - range.location }
        }
        return range
    }

    /// Shows other words in a link's place: what is written is hidden,
    /// and room for the words is left after it, where they are drawn
    /// (`OutlinerLayoutManager`). What is written is not touched.
    private func relabel(_ storage: NSTextStorage, _ range: NSRange, as label: String, lead: CGFloat = 0) {
        guard range.length > 0 else { return }
        // The words' own font. A link to a page is one object-replacement character, which a
        // face may have no glyph for — and is given another's: its neighbours say.
        let string = storage.string as NSString
        let atom = string.character(at: range.location) == 0xFFFC
        let beside = [range.location - 1, NSMaxRange(range)].first { at in
            at >= 0 && at < string.length && string.character(at: at) != 10 && string.character(at: at) != 0xFFFC
        }
        let font = ((atom ? beside : range.location).flatMap { storage.attribute(.font, at: $0, effectiveRange: nil) } as? NSFont).flatMap { $0.pointSize > 1 ? $0 : nil } ?? theme.body
        let color = (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) ?? theme.link
        // One line's worth: room left after a character cannot wrap.
        let words = label.count > 48 ? String(label.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : label
        let text = NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color])
        // The first character keeps its size — so the line keeps its height — and is not
        // seen: the words are drawn over it, and in the room left after it. The rest takes
        // no room: a line may break in it, and nothing shows that it did.
        let first = NSRange(location: range.location, length: 1)
        let character = string.character(at: first.location)
        let own = character == 0xFFFC ? 0 : string.substring(with: first).size(withAttributes: [.font: font]).width
        storage.addAttributes([.font: font, .foregroundColor: NSColor.clear, .kern: max(lead + text.size().width.rounded(.up) - own, 0), .outlinerLabel: OutlinerLinkLabel(text, lead: lead)], range: first)
        if range.length > 1 {
            storage.addAttributes([.font: Self.hiddenFont, .foregroundColor: NSColor.clear, .outlinerMarkup: true], range: NSRange(location: range.location + 1, length: range.length - 1))
        }
    }

    /// Hides what of a web address says nothing: its scheme, a leading
    /// `www.`, and everything from its query on. The address itself is not touched.
    private func shorten(_ storage: NSTextStorage, _ range: NSRange, address: NSString) {
        let hidden: [NSAttributedString.Key: Any] = [.font: Self.hiddenFont, .foregroundColor: NSColor.clear, .outlinerMarkup: true]
        var start = 0
        let scheme = address.range(of: "://")
        if scheme.location != NSNotFound, scheme.location < 8 { start = NSMaxRange(scheme) }
        if address.length >= start + 4, address.substring(with: NSRange(location: start, length: 4)).lowercased() == "www." { start += 4 }
        var end = address.length
        for mark in ["?", "#"] {
            let at = address.range(of: mark)
            if at.location != NSNotFound { end = min(end, at.location) }
        }
        while end > start + 1, address.character(at: end - 1) == 47 { end -= 1 }
        guard end > start else { return }
        if start > 0 { storage.addAttributes(hidden, range: NSRange(location: range.location, length: start)) }
        if end < address.length {
            storage.addAttributes(hidden, range: NSRange(location: range.location + end, length: address.length - end))
        }
    }

    private func restyle(_ storage: NSTextStorage, _ range: NSRange, _ change: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? NSFont, font.pointSize > 1 else { return }
            storage.addAttribute(.font, value: change(font), range: part)
        }
    }

    private func width(of storage: NSTextStorage, from: Int, to: Int) -> CGFloat {
        guard to > from, to <= storage.length else { return 0 }
        return (storage.string as NSString).substring(with: NSRange(location: from, length: to - from)).size(withAttributes: [.font: theme.body]).width
    }
}
