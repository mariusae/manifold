import Foundation

// What an editor needs of a note's body while it is being written: the
// reading of lines and runs (`Editor.layout`), the commands it gives
// (`Command`), and what is being typed that could be finished
// (`Editor.completion`). Offsets are bytes of the body.

extension Markup {
    /// What a line of a body is.
    public enum LineKind: Equatable, Sendable {
        case blank
        case paragraph
        /// `## text`: the level, 1 to 6.
        case heading(Int)
        /// A list item's first line: its number (for `1.`), its checkbox
        /// (open, or done), and the bullet it is written with (`-`, `*`,
        /// `+`; `.` or `)` for a numbered one).
        case item(ordered: Int?, task: Bool?, bullet: Character)
        case quote
        /// A code fence's opening or closing line.
        case fence
        /// A line inside a code fence.
        case code
        case table
        case rule
    }

    /// One line of a body.
    public struct Line: Equatable, Sendable {
        /// The line, without its line break.
        public var range: Range<Int>
        public var kind: LineKind
        /// The spaces it is indented by.
        public var indent: Int
        /// Where its words begin: after the indentation and its marker.
        public var content: Int
        /// How many list items it is inside: 0 for a top-level line, 1 for a
        /// top-level item's own line, and so on.
        public var depth: Int
    }

    /// What a stretch of a line means.
    public enum RunKind: Equatable, Sendable {
        /// Markup with nothing to show. Hidden off the lines being written in.
        case markup
        case strong, emphasis, strikethrough, highlight, code
        /// A link to a page: its shown words. `embed` for `![[…]]`.
        case pageLink(target: String, embed: Bool)
        /// A link to the web: its shown words — or, for a bare address, the
        /// address itself.
        case webLink(url: String)
        case tag(name: String)
        /// A picture: the whole of its markup.
        case image(source: String, alt: String, width: Double?, height: Double?)
        /// A list item's bullet or number.
        case bullet
        /// A list item's checkbox: `[ ]` or `[x]`.
        case checkbox(done: Bool)
        /// A quote's `>`.
        case quoteMark
        /// A callout's `[!KIND]`.
        case callout(kind: String)
        /// A code fence's info string.
        case fenceInfo(info: String)
    }

    /// A stretch of a body, and what it means.
    public struct Run: Equatable, Sendable {
        public var range: Range<Int>
        public var kind: RunKind
    }

    /// A body, read for an editor.
    public struct TextLayout: Equatable, Sendable {
        public var lines: [Line] = []
        /// In the order of the text; a run inside another comes after it.
        public var runs: [Run] = []

        /// The index of the line an offset is on.
        public func line(at offset: Int) -> Int {
            var (low, high) = (0, lines.count)
            while low < high {
                let mid = (low + high) / 2
                let line = lines[mid]
                if offset < line.range.lowerBound { high = mid } else if offset > line.range.upperBound { low = mid + 1 } else { return mid }
            }
            return min(low, max(lines.count - 1, 0))
        }
    }

    /// Something an editor does to a body beyond typing a character.
    public enum Command: Equatable, Sendable {
        /// Return: a new line of the same sort.
        case newline
        /// Delete at the start of a line's words: an item's marker is taken off.
        case deleteBackward
        case indent, outdent, moveUp, moveDown, deleteRows, duplicateRows
        /// Emboldens the selection, or takes the emboldening off.
        case toggle(Style)
        case cycleChecklist, toggleTask, toggleCheckbox
        case heading(Int)
        case bullet, numbered, quote
        case moveToTop, moveToBottom
        case fold, unfold, toggleFold, toggleCard
        case foldCompletely, unfoldCompletely, foldAll, unfoldAll
        case markDone, moveDoneToBottom
        /// Made a row of this kind, whatever it was.
        case turn(RowKind)
        case insertBelow, insertAbove, insertChild
        case moveUpKeepingLevel, moveDownKeepingLevel
        case joinRows, promoteChildren, demoteSiblings, group
        case deleteRowOnly, indentRowOnly, outdentRowOnly
        case foldByLevel, unfoldByLevel, foldAllByLevel, unfoldAllByLevel
        case moveUpRowOnly, moveDownRowOnly
    }

    /// A kind a row can be turned into.
    public enum RowKind: Equatable, Sendable {
        case paragraph
        /// `- text`.
        case bullet
        /// `- [ ] text`: a checklist item.
        case checkbox
        /// `+ [ ] text`: a task.
        case task
        /// `1. text`.
        case numbered
        case heading(Int)
        case quote
    }

    /// What is being typed at the caret that an editor could finish.
    public enum CompletionKind: Equatable, Sendable { case link, embed, tag, mention }

    /// A name half-typed.
    public struct Completion: Equatable, Sendable {
        public var kind: CompletionKind
        /// What has been typed of it, after the `[[` or the `#`.
        public var typed: String
        /// All of it, markup included: what choosing a name replaces.
        public var range: Range<Int>
    }

    public enum Editor {
        /// A list marker at the start of a line's words: its bullet, its
        /// number, and the length of the marker with the spaces after it.
        static func listMarker(_ text: Bytes) -> (Character, Int?, Int)? {
            guard let first = text.first else { return nil }
            var bullet: Character
            var ordered: Int? = nil
            var width: Int
            if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
                bullet = Character(Unicode.Scalar(first))
                width = 1
            } else if first.isAsciiDigit {
                let digits = text.leadingDigits
                guard digits < text.count else { return nil }
                let delimiter = text[digits]
                if digits > 9 || !(delimiter == UInt8(ascii: ".") || delimiter == UInt8(ascii: ")")) { return nil }
                bullet = Character(Unicode.Scalar(delimiter))
                ordered = Int(text.string(0..<digits))
                width = digits + 1
            } else {
                return nil
            }
            let spaces = text.leading(.space, from: width)
            // A marker needs a space after it, unless the line ends there.
            return spaces > 0 || text.count == width ? (bullet, ordered, width + spaces) : nil
        }

        /// A checkbox at the start of an item's words: whether it is done,
        /// and its length with the space after it.
        static func checkbox(_ text: Bytes) -> (Bool, Int)? {
            guard text.count >= 3, text[0] == UInt8(ascii: "["), text[2] == UInt8(ascii: "]") else { return nil }
            let done: Bool
            switch text[1] {
            case .space: done = false
            case UInt8(ascii: "x"), UInt8(ascii: "X"): done = true
            default: return nil
            }
            if text.count == 3 { return (done, 3) }
            return text[3] == .space ? (done, 4) : nil
        }

        static func isRule(_ text: Bytes) -> Bool {
            let marks = text.scalars.map(\.1).filter { !$0.isWS }
            guard marks.count >= 3, marks[0] == "-" || marks[0] == "*" || marks[0] == "_" else { return false }
            return marks.allSatisfy { $0 == marks[0] }
        }

        static func fence(_ text: Bytes) -> (UInt8, Int)? {
            guard let mark = text.first, mark == UInt8(ascii: "`") || mark == UInt8(ascii: "~") else { return nil }
            let length = text.leading(mark)
            return length >= 3 ? (mark, length) : nil
        }

        /// Reads a body for an editor.
        public static func layout(_ body: String) -> TextLayout {
            let b = body.u8
            var layout = TextLayout()
            // The indentation of each list item the line is inside, with where
            // that item's words begin: a line indented at least so far is in it.
            var items: [Int] = []
            var openFence: (UInt8, Int)? = nil
            var start = 0
            for raw in b.split(byte: .newline) {
                let text = raw.last == UInt8(ascii: "\r") ? Array(raw.dropLast()) : raw
                let range = start..<(start + text.count)
                start += raw.count + 1
                let indent = text.leading(.space)
                let words = text.sub(from: indent)
                let at = range.lowerBound + indent

                if let (mark, length) = openFence {
                    let closes = fence(words).map { $0.0 == mark && $0.1 >= length && words.sub(from: $0.1).isBlankWS } ?? false
                    if closes { openFence = nil }
                    layout.lines.append(Line(range: range, kind: closes ? .fence : .code, indent: indent, content: at, depth: items.count))
                    continue
                }
                if words.isEmpty {
                    layout.lines.append(Line(range: range, kind: .blank, indent: indent, content: at, depth: items.count))
                    continue
                }
                // A line indented less than an item's words is out of that item.
                while let content = items.last, indent < content { items.removeLast() }

                if let (mark, length) = fence(words) {
                    openFence = (mark, length)
                    let rest = words.sub(from: length)
                    let info = rest.trimmed
                    if !info.isEmpty {
                        let infoAt = at + length + (rest.count - rest.trimmedStart.count)
                        layout.runs.append(Run(range: infoAt..<(infoAt + info.count), kind: .fenceInfo(info: info.string)))
                    }
                    layout.lines.append(Line(range: range, kind: .fence, indent: indent, content: at, depth: items.count))
                    continue
                }
                if isRule(words) && (listMarker(words) == nil || words.scalars.filter({ !$0.1.isWS }).count >= 3) {
                    layout.lines.append(Line(range: range, kind: .rule, indent: indent, content: at, depth: items.count))
                    continue
                }
                if let (bullet, ordered, width) = listMarker(words) {
                    while let content = items.last, indent < content { items.removeLast() }
                    var content = at + width
                    layout.runs.append(Run(range: at..<(at + max(min(width, words.trimmedEnd.count), 1)), kind: .bullet))
                    var task: Bool? = nil
                    if let (done, length) = checkbox(text.sub(from: indent + width)) {
                        layout.runs.append(Run(range: content..<(content + 3), kind: .checkbox(done: done)))
                        content += length
                        task = done
                    }
                    let depth = items.count + 1
                    items.append(indent + width)
                    readInline(b, content..<range.upperBound, &layout.runs)
                    layout.lines.append(Line(range: range, kind: .item(ordered: ordered, task: task, bullet: bullet), indent: indent, content: content, depth: depth))
                    continue
                }
                let hashes = words.leading(UInt8(ascii: "#"))
                if (1...6).contains(hashes) && (words.count == hashes || words[hashes] == .space) {
                    let spaces = words.leading(.space, from: hashes)
                    let content = at + hashes + spaces
                    layout.runs.append(Run(range: at..<content, kind: .markup))
                    readInline(b, content..<range.upperBound, &layout.runs)
                    layout.lines.append(Line(range: range, kind: .heading(hashes), indent: indent, content: content, depth: items.count))
                    continue
                }
                if words.first == UInt8(ascii: ">") {
                    let content = at + 1 + (words.count > 1 && words[1] == .space ? 1 : 0)
                    layout.runs.append(Run(range: at..<(at + 1), kind: .quoteMark))
                    let quoted = b.sub(content..<range.upperBound)
                    var callout = false
                    if quoted.hasPrefix("[!".u8), let close = quoted.find(byte: UInt8(ascii: "]"), from: 2) {
                        let kind = quoted.sub(2..<close)
                        if !kind.isEmpty && kind.allSatisfy({ $0 < 0x80 && Unicode.Scalar($0).isAsciiAlpha }) && quoted.sub(from: close + 1).isBlankWS {
                            layout.runs.append(Run(range: content..<(content + kind.count + 3), kind: .callout(kind: kind.string)))
                            callout = true
                        }
                    }
                    if !callout { readInline(b, content..<range.upperBound, &layout.runs) }
                    layout.lines.append(Line(range: range, kind: .quote, indent: indent, content: content, depth: items.count))
                    continue
                }
                if words.first == UInt8(ascii: "|") {
                    readInline(b, at..<range.upperBound, &layout.runs)
                    layout.lines.append(Line(range: range, kind: .table, indent: indent, content: at, depth: items.count))
                    continue
                }
                readInline(b, at..<range.upperBound, &layout.runs)
                layout.lines.append(Line(range: range, kind: .paragraph, indent: indent, content: at, depth: items.count))
            }
            // `split` gives one line more than there are for a body ending in
            // a line break: the empty line the caret can stand on. It is kept.
            return layout
        }

        /// The inline runs of a line's words.
        static func readInline(_ body: Bytes, _ range: Range<Int>, _ runs: inout [Run]) {
            let text = body.sub(range)
            let base = range.lowerBound
            func visit(_ spans: [Span]) {
                for span in spans {
                    let whole = (base + span.range.lowerBound)..<(base + span.range.upperBound)
                    let shown = (base + span.content.lowerBound)..<(base + span.content.upperBound)
                    let kind: RunKind
                    switch span.kind {
                    case .strong: kind = .strong
                    case .emphasis: kind = .emphasis
                    case .strikethrough: kind = .strikethrough
                    case .highlight: kind = .highlight
                    case .code: kind = .code
                    case .link(let target, _): kind = .webLink(url: target)
                    case .autolink(let url): kind = .webLink(url: url)
                    case .wikiLink(let target, _, let embed): kind = .pageLink(target: target, embed: embed)
                    case .url:
                        runs.append(Run(range: whole, kind: .webLink(url: text.string(span.range))))
                        continue
                    case .tag(let name):
                        runs.append(Run(range: whole, kind: .tag(name: name)))
                        continue
                    case .image(let source, let alt, let width, let height):
                        runs.append(Run(range: whole, kind: .image(source: source, alt: alt, width: width, height: height)))
                        continue
                    case .comment:
                        runs.append(Run(range: whole, kind: .markup))
                        continue
                    case .escape:
                        // The backslash is markup; the character is itself.
                        runs.append(Run(range: whole.lowerBound..<(whole.lowerBound + 1), kind: .markup))
                        continue
                    }
                    runs.append(Run(range: shown, kind: kind))
                    if whole.lowerBound < shown.lowerBound { runs.append(Run(range: whole.lowerBound..<shown.lowerBound, kind: .markup)) }
                    if shown.upperBound < whole.upperBound { runs.append(Run(range: shown.upperBound..<whole.upperBound, kind: .markup)) }
                    visit(span.children)
                }
            }
            visit(Inline.parse(bytes: text))
        }

        /// What is being typed at the caret that could be finished, if anything.
        public static func completion(_ body: String, caret: Int) -> Completion? {
            let b = body.u8
            let caret = min(caret, b.count)
            let lineStart = (b.rfind([.newline], from: 0, to: caret)).map { $0 + 1 } ?? 0
            let before = b.sub(lineStart..<caret)
            // A link not yet closed: the last `[[` with no `]]` after it.
            if let open = before.rfind("[[".u8) {
                let typed = before.sub(from: open + 2)
                if !typed.contains("]]".u8) && !typed.contains(UInt8(ascii: "[")) && !typed.contains(UInt8(ascii: "|")) {
                    let embed = open > 0 && before[open - 1] == UInt8(ascii: "!")
                    let start = lineStart + open - (embed ? 1 : 0)
                    // A `]]` already after the caret is part of what is replaced.
                    let end = caret + (b.has("]]".u8, at: caret) ? 2 : 0)
                    return Completion(kind: embed ? .embed : .link, typed: typed.string, range: start..<end)
                }
            }
            func startsWord(_ at: Int) -> Bool {
                guard let c = before.scalar(before: at) else { return true }
                return c.isWS || c == "("
            }
            // A page looked for: `@` starting a word, then its words — spaces
            // and all, for a name is often two — to the caret. Not in code.
            if let at = before.rfind("@".u8) {
                let typed = before.sub(from: at + 1)
                let chars = typed.scalars.map(\.1)
                let isWords = chars.count <= 60 && typed.first != .space && !typed.contains("  ".u8)
                    && chars.allSatisfy { $0.isAlnum || " -_'’./".unicodeScalars.contains($0) }
                if startsWord(at) && isWords && before[0..<at].filter({ $0 == UInt8(ascii: "`") }).count % 2 == 0 {
                    return Completion(kind: .mention, typed: typed.string, range: (lineStart + at)..<caret)
                }
            }
            // A tag: `#` starting a word, then letters, to the caret.
            guard let hash = before.rfind("#".u8) else { return nil }
            let typed = before.sub(from: hash + 1)
            let isName = !typed.isEmpty && typed.scalars.allSatisfy({ $0.1.isAlnum || $0.1 == "_" || $0.1 == "-" || $0.1 == "/" }) && !(typed.first?.isAsciiDigit ?? false)
            // A heading's hashes are no tag.
            let heading = before.sub(0..<hash).isBlankWS && (typed.isEmpty || typed.first == UInt8(ascii: "#"))
            return startsWord(hash) && isName && !heading ? Completion(kind: .tag, typed: typed.string, range: (lineStart + hash)..<caret) : nil
        }
    }
}
