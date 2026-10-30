import Foundation

/// Reading and writing an `NoteOutline` as Markdown.
///
/// This is not a Markdown parser: it knows the block structure an outline
/// needs (list items and what nests in them, headings, fences, quotes, rules,
/// paragraphs) and leaves everything inline — emphasis, links, images — as
/// text. Reading then writing gives back the same bytes for the shapes notes
/// are written in; `roundTrips` says whether a particular note is one of them.
public enum NoteOutlineMarkdown {

    // MARK: Reading

    public static func parse(_ source: String) -> NoteOutline {
        var body = source
        var lineEnding = "\n"
        if body.contains("\r\n") {
            lineEnding = "\r\n"
            body = body.replacingOccurrences(of: "\r\n", with: "\n")
        }

        var outline = NoteOutline(rows: [])
        outline.lineEnding = lineEnding
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        } else {
            outline.endsWithNewline = false
        }
        var index = 0
        if let front = frontmatterLength(lines) {
            outline.frontmatter = lines[0..<front].joined(separator: "\n")
            index = front
        }

        var parser = Parser()
        while index < lines.count {
            parser.read(lines[index])
            index += 1
        }
        outline.rows = parser.rows
        outline.trailingGap = parser.pendingGap
        if outline.rows.isEmpty && outline.trailingGap.isEmpty && outline.frontmatter == nil {
            outline.endsWithNewline = true
        }
        return outline
    }

    /// The number of lines a frontmatter block takes, fences included.
    private static func frontmatterLength(_ lines: [String]) -> Int? {
        guard lines.first == "---" else { return nil }
        for index in 1..<max(lines.count, 1) where lines[index] == "---" || lines[index] == "..." {
            return index + 1
        }
        return nil
    }

    /// Whether writing a note back gives exactly what was read.
    public static func roundTrips(_ source: String) -> Bool {
        serialize(parse(source)) == source
    }

    private struct Parser {
        var rows: [NoteRow] = []
        var pendingGap: [String] = []
        /// The content column of each open list item, outermost first.
        var open: [Int] = []
        /// The fence that opened the code row being read, and its indent.
        var fence: (marker: String, indent: Int)?
        /// The column continuation lines of the last row are measured from.
        var lastContentColumn = 0

        mutating func read(_ line: String) {
            if let fence {
                readFenced(line, fence: fence)
                return
            }
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                pendingGap.append(line)
                return
            }
            let indent = NoteOutlineMarkdown.indentation(line)
            let content = String(line.drop(while: { $0 == " " || $0 == "\t" }))

            // `>` straight after a quote, where it starts: the quote's next line.
            if pendingGap.isEmpty, let last = rows.last, last.kind == .quote, content.hasPrefix(">"),
               indent == lastContentColumn {
                appendQuoteLine(content)
                return
            }
            // A line straight after text, that starts nothing new, goes on
            // with that text — even when it is not indented to match.
            if pendingGap.isEmpty, let last = rows.last, last.continues,
               !NoteOutlineMarkdown.startsBlock(content, interruptingParagraph: indent >= lastContentColumn) {
                appendContinuation(line, indent: indent)
                return
            }

            while let column = open.last, indent < column { open.removeLast() }
            let depth = open.count
            let base = open.last ?? 0
            var row = NoteRow(kind: .paragraph, depth: depth, extraIndent: indent - base, gap: pendingGap)
            pendingGap = []

            if let item = NoteOutlineMarkdown.listItem(content) {
                row.kind = item.ordered ? .ordered : .bullet
                row.marker = item.marker
                row.number = item.number
                row.spacing = item.spacing
                row.task = item.task
                row.text = item.text
                let column = indent + item.width + max(item.spacing, 1)
                open.append(column)
                lastContentColumn = column
            } else if let heading = NoteOutlineMarkdown.heading(content) {
                row.kind = .heading(heading.level)
                row.spacing = heading.spacing
                row.text = heading.text
                lastContentColumn = indent
            } else if let marker = NoteOutlineMarkdown.fenceMarker(content) {
                row.kind = .code
                row.text = content
                fence = (marker, indent)
                lastContentColumn = indent
            } else if NoteOutlineMarkdown.isRule(content) {
                row.kind = .rule
                row.text = content
                lastContentColumn = indent
            } else if content.hasPrefix(">") {
                row.kind = .quote
                let rest = content.dropFirst()
                row.spacing = rest.hasPrefix(" ") ? 1 : 0
                row.text = String(rest.dropFirst(row.spacing))
                lastContentColumn = indent
            } else {
                row.text = content
                lastContentColumn = indent
            }
            rows.append(row)
        }

        private mutating func readFenced(_ line: String, fence: (marker: String, indent: Int)) {
            let indent = NoteOutlineMarkdown.indentation(line)
            let content = line.drop(while: { $0 == " " })
            // A fence inside a list item is indented with it; one that is
            // indented less has ended with the item.
            if !line.isEmpty, indent < lastContentColumn, !content.hasPrefix(fence.marker) {
                self.fence = nil
                read(line)
                return
            }
            appendContinuation(line, indent: indent)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.marker), trimmed.allSatisfy({ $0 == fence.marker.first }) {
                self.fence = nil
            }
        }

        /// A quote's next line, written with its `>`: in the text without
        /// it. How it was written is kept — `> ` the usual, nil; a `>` with
        /// no space after, `quoteBare` — and a line without one, lazily
        /// going on, by its indent, as `appendContinuation` keeps it.
        private mutating func appendQuoteLine(_ content: String) {
            var row = rows.removeLast()
            var indents = row.continuationIndents ?? Array(repeating: nil, count: row.lineCount - 1)
            let rest = content.dropFirst()
            if rest.hasPrefix(" ") {
                row.text += "\n" + rest.dropFirst()
                indents.append(nil)
            } else {
                row.text += "\n" + rest
                indents.append(NoteOutlineMarkdown.quoteBare)
            }
            row.continuationIndents = indents.allSatisfy({ $0 == nil }) ? nil : indents
            rows.append(row)
        }

        private mutating func appendContinuation(_ line: String, indent: Int) {
            var row = rows.removeLast()
            var indents = row.continuationIndents ?? Array(repeating: nil, count: row.lineCount - 1)
            let isBlank = line.allSatisfy { $0 == " " || $0 == "\t" }
            if isBlank {
                // A blank line is kept as it was, spaces and all.
                row.text += "\n" + line
                indents.append(line.isEmpty ? nil : 0)
            } else {
                let strip = min(indent, lastContentColumn)
                row.text += "\n" + line.dropFirst(NoteOutlineMarkdown.prefixLength(line, columns: strip))
                // Indented less than usual (a lazy continuation) is recorded;
                // more than usual keeps the extra in the text. A quote's line
                // without its `>` is always recorded: its usual has one.
                indents.append(indent < lastContentColumn || row.kind == .quote ? strip : nil)
            }
            row.continuationIndents = indents.allSatisfy({ $0 == nil }) ? nil : indents
            rows.append(row)
        }
    }

    // MARK: Writing

    /// A quote's line written `>` with no space after it, among a row's
    /// `continuationIndents`.
    static let quoteBare = -1

    public static func serialize(_ outline: NoteOutline) -> String {
        var lines: [String] = []
        if let frontmatter = outline.frontmatter {
            lines.append(contentsOf: frontmatter.components(separatedBy: "\n"))
        }
        // The content column of the list item open at each depth.
        var columns: [Int] = []
        // The row before, when a line straight after it would go on with its
        // text, and the column its text is measured from.
        var continuing: Int?
        for row in outline.unfoldedRows {
            lines.append(contentsOf: row.gap)
            let depth = min(row.depth, columns.count)
            columns.removeLast(columns.count - depth)
            let base = columns.last ?? 0
            let indent = base + row.extraIndent
            let pad = String(repeating: " ", count: indent)
            var first: String
            var continuation = indent
            switch row.kind {
            case .bullet, .ordered:
                let marker = row.kind == .ordered ? "\(row.number)\(row.marker)" : String(row.marker)
                var head = pad + marker + String(repeating: " ", count: row.spacing)
                switch row.task {
                case nil: break
                case .open: head += "[ ]"
                case .done(let letter): head += "[\(letter)]"
                }
                if row.task != nil && !row.text.isEmpty { head += " " }
                first = head + firstLine(row.text)
                continuation = indent + marker.count + max(row.spacing, 1)
                columns.append(continuation)
            case .heading(let level):
                first = pad + String(repeating: "#", count: level) + String(repeating: " ", count: row.spacing) + firstLine(row.text)
            case .quote:
                first = pad + ">" + String(repeating: " ", count: row.spacing) + firstLine(row.text)
            case .paragraph, .code, .rule:
                first = pad + firstLine(row.text)
            }
            // A row made in the editor can sit straight after text it would
            // be read back as part of; a blank line keeps it a row.
            if row.gap.isEmpty, let column = continuing {
                let content = String(first.drop(while: { $0 == " " }))
                if !startsBlock(content, interruptingParagraph: indentation(first) >= column) {
                    lines.append("")
                }
            }
            lines.append(first)
            continuing = row.continues ? continuation : nil
            let rest = row.text.components(separatedBy: "\n").dropFirst()
            let written = row.continuationIndents ?? []
            for (offset, line) in rest.enumerated() {
                // A quote's lines each with its `>`, as they were written.
                if row.kind == .quote, offset >= written.count || written[offset] == nil || written[offset] == Self.quoteBare {
                    let bare = offset < written.count && written[offset] == Self.quoteBare
                    lines.append(pad + ">" + (bare || line.isEmpty ? "" : " ") + line)
                    continue
                }
                if offset < written.count, let written = written[offset] {
                    lines.append(String(repeating: " ", count: written) + line)
                } else if line.isEmpty {
                    lines.append("")
                } else {
                    lines.append(String(repeating: " ", count: continuation) + line)
                }
            }
        }
        lines.append(contentsOf: outline.trailingGap)
        var text = lines.joined(separator: "\n")
        if outline.endsWithNewline && !lines.isEmpty { text += "\n" }
        if outline.lineEnding != "\n" { text = text.replacingOccurrences(of: "\n", with: outline.lineEnding) }
        return text
    }

    private static func firstLine(_ text: String) -> Substring {
        text.prefix(while: { $0 != "\n" })
    }

    // MARK: Lines

    /// Columns of leading whitespace, a tab reaching the next stop of four.
    static func indentation(_ line: some StringProtocol) -> Int {
        var column = 0
        for character in line {
            if character == " " { column += 1 }
            else if character == "\t" { column += 4 - column % 4 }
            else { break }
        }
        return column
    }

    /// How many characters of `line` make up its first `columns` columns of
    /// indentation.
    static func prefixLength(_ line: String, columns: Int) -> Int {
        var column = 0, count = 0
        for character in line where column < columns {
            if character == " " { column += 1 }
            else if character == "\t" { column += 4 - column % 4 }
            else { break }
            count += 1
        }
        return count
    }

    struct ListItem {
        var ordered: Bool
        var marker: Character
        var number: Int
        /// The width of the marker, `-` or `12.`.
        var width: Int
        var spacing: Int
        var task: NoteRow.Task?
        var text: String
    }

    static func listItem(_ content: String) -> ListItem? {
        var rest = Substring(content)
        var item: ListItem
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            item = ListItem(ordered: false, marker: first, number: 1, width: 1, spacing: 0, task: nil, text: "")
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
            item = ListItem(ordered: true, marker: delimiter, number: number, width: digits.count + 1, spacing: 0, task: nil, text: "")
            rest = after.dropFirst()
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let spaces = rest.prefix(while: { $0 == " " })
        item.spacing = spaces.count
        rest = rest.dropFirst(spaces.count)
        if rest.first == "\t" { return nil }
        if item.spacing >= 1, let task = taskBox(rest) {
            let after = rest.dropFirst(3)
            if after.isEmpty || after.first == " " {
                item.task = task
                rest = after.dropFirst(after.isEmpty ? 0 : 1)
            }
        }
        item.text = String(rest)
        return item
    }

    private static func taskBox(_ text: Substring) -> NoteRow.Task? {
        guard text.count >= 3, text.first == "[" else { return nil }
        let middle = text[text.index(after: text.startIndex)]
        guard text[text.index(text.startIndex, offsetBy: 2)] == "]" else { return nil }
        switch middle {
        case " ": return .open
        case "x", "X": return .done(middle)
        default: return nil
        }
    }

    static func heading(_ content: String) -> (level: Int, spacing: Int, text: String)? {
        let hashes = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = content.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        let spacing = rest.prefix(while: { $0 == " " }).count
        return (hashes, spacing, String(rest.dropFirst(spacing)))
    }

    static func fenceMarker(_ content: String) -> String? {
        for marker in ["```", "~~~"] where content.hasPrefix(marker) {
            let run = content.prefix(while: { $0 == marker.first })
            if marker == "```" && content.dropFirst(run.count).contains("`") { return nil }
            return String(run)
        }
        return nil
    }

    static func isRule(_ content: String) -> Bool {
        let marks = content.filter { $0 != " " && $0 != "\t" }
        guard let first = marks.first, first == "-" || first == "*" || first == "_", marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// Whether a line, stripped of its indentation, starts a block of its
    /// own rather than going on with the text before it.
    static func startsBlock(_ content: String, interruptingParagraph: Bool) -> Bool {
        if heading(content) != nil || fenceMarker(content) != nil || isRule(content) || content.hasPrefix(">") {
            return true
        }
        guard let item = listItem(content) else { return false }
        if interruptingParagraph {
            // Markdown lets only a list item with something in it, and an
            // ordered one only when it counts from one, break into a paragraph.
            if item.text.isEmpty && item.task == nil { return false }
            if item.ordered && item.number != 1 { return false }
        }
        return true
    }
}

private extension NoteRow {
    /// Whether a line straight after this row can go on with its text.
    var continues: Bool {
        switch kind {
        case .paragraph, .quote: true
        case .bullet, .ordered: !(text.isEmpty && task == nil)
        case .heading, .code, .rule: false
        }
    }
}

extension NoteRow {
    /// The number of lines the row's text takes.
    var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
}

// MARK: The block's outline

/// An entry in a note's outline, as its tile shows it (ticks, sidebar, ⌘P):
/// a heading, or an item at the top of the outline.
public struct NoteOutlineItem: Equatable, Sendable {
    public var title: String
    /// How far in: a heading by its rank among the note's, an item one
    /// step under the heading before it.
    public var level: Int
    /// The line it starts on in the text, from 0.
    public var line: Int
    /// Its row among the outline's.
    public var row: Int
    public var task: NoteRow.Task?
    public var isHeading: Bool
}

extension NoteOutlineMarkdown {
    /// A note's outline whatever shows it — its editor, its preview, its
    /// outline: its headings, and its top-level items each under the
    /// heading before it (what's deeper in is the outline's own to show).
    public static func items(of outline: NoteOutline) -> [NoteOutlineItem] {
        var line = outline.frontmatter.map { $0.components(separatedBy: "\n").count } ?? 0
        let top = outline.rows.compactMap { row -> Int? in
            if case let .heading(level) = row.kind, row.depth == 0 { return level }
            return nil
        }.min()
        var under = 0
        var items: [NoteOutlineItem] = []
        for (i, row) in outline.rows.enumerated() {
            line += row.gap.count
            defer { line += row.lineCount }
            guard row.depth == 0 else { continue }
            let title = String(row.text.prefix { $0 != "\n" })
            if case let .heading(level) = row.kind {
                let rank = min(max(level - (top ?? level), 0), 3)
                under = rank + 1
                items.append(NoteOutlineItem(title: title, level: rank, line: line, row: i, task: nil, isHeading: true))
            } else if row.kind.isListItem, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(NoteOutlineItem(title: title, level: min(under, 4), line: line, row: i, task: row.task, isHeading: false))
            }
        }
        return items
    }

    /// The same, from the text.
    public static func items(in source: String) -> [NoteOutlineItem] { items(of: parse(source)) }
}
