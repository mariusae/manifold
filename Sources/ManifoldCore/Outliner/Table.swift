// Pipe tables, as GitHub writes them.
//
// A table block keeps its lines as written; this reads them as cells for an
// editor to show, and writes cells back as lines. Text is handled as Unicode
// scalars, never Characters (a "\r\n" is one Character).

extension Markup {
    /// How a column's cells are set.
    public enum Align: Equatable, Sendable {
        case none
        case left
        case center
        case right
    }

    /// A table's cells. Each cell is inline Markdown.
    public struct Table: Equatable, Sendable {
        public var header: [String]
        public var alignments: [Align]
        public var rows: [[String]]

        public init(header: [String] = [], alignments: [Align] = [], rows: [[String]] = []) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
        }

        /// Whether a line is the row of dashes under a table's header: `|---|:-:|`.
        public static func isSeparator(_ line: String) -> Bool {
            let trimmed = tableTrim(Array(line.unicodeScalars))
            return trimmed.first == "|" && trimmed.contains("-")
                && trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
        }

        /// Reads a table block's text. `nil` when it is not a header line
        /// with a separator under it.
        public static func parse(_ text: String) -> Table? {
            let lines = tableLines(Array(text.unicodeScalars))
            guard let first = lines.first else { return nil }
            let header = cells(first)
            guard lines.count > 1, isSeparator(tableString(lines[1])) else { return nil }
            let alignments: [Align] = cells(lines[1]).map { cell in
                let scalars = Array(cell.unicodeScalars)
                switch (scalars.first == ":", scalars.last == ":") {
                case (true, true): return .center
                case (true, false): return .left
                case (false, true): return .right
                case (false, false): return .none
                }
            }
            var rows: [[String]] = []
            for line in lines.dropFirst(2) {
                guard tableTrim(line, end: false).first == "|" else { break }
                rows.append(cells(line))
            }
            return Table(header: header, alignments: alignments, rows: rows)
        }

        /// The table as lines of Markdown, a row a line, no line break at the
        /// end: what a table block's text is set to.
        public func toMarkdown() -> String {
            func row(_ cells: [String]) -> String {
                let escaped = cells.map { cell in
                    tableString(cell.unicodeScalars.flatMap { $0 == "|" ? ["\\", "|"] : [$0] as [Unicode.Scalar] })
                }
                return "| " + escaped.joined(separator: " | ") + " |"
            }
            let separator = header.indices.map { i -> String in
                switch i < alignments.count ? alignments[i] : .none {
                case .none: return "---"
                case .left: return ":--"
                case .center: return ":-:"
                case .right: return "--:"
                }
            }
            var lines = [row(header), "| " + separator.joined(separator: " | ") + " |"]
            lines += rows.map(row)
            return lines.joined(separator: "\n")
        }
    }
}

private func tableString<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

/// Rust's `trim` (or `trim_start`, without `end`): Unicode White_Space off.
private func tableTrim<C: BidirectionalCollection>(_ s: C, end: Bool = true) -> [Unicode.Scalar] where C.Element == Unicode.Scalar {
    var slice = s[...]
    while let c = slice.first, c.properties.isWhitespace { slice = slice.dropFirst() }
    while end, let c = slice.last, c.properties.isWhitespace { slice = slice.dropLast() }
    return Array(slice)
}

/// Rust's `str::lines`: split at `\n`, a `\r` before it dropped, no empty
/// line after a final `\n`.
private func tableLines(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
    var lines: [[Unicode.Scalar]] = []
    var start = 0
    while start < text.count {
        var end = start
        while end < text.count && text[end] != "\n" { end += 1 }
        var line = Array(text[start..<end])
        if end < text.count && line.last == "\r" { line.removeLast() }
        lines.append(line)
        start = end + 1
    }
    return lines
}

/// A row's cells: split at each `|` not escaped, with `\|` unescaped.
private func cells(_ line: [Unicode.Scalar]) -> [String] {
    var body = tableTrim(line)[...]
    if body.first == "|" { body = body.dropFirst() }
    if body.last == "|" && !(body.count >= 2 && body[body.index(before: body.endIndex) - 1] == "\\") {
        body = body.dropLast()
    }
    var cells: [String] = []
    var current: [Unicode.Scalar] = []
    var i = body.startIndex
    while i < body.endIndex {
        let c = body[i]
        i += 1
        if c == "\\" && i < body.endIndex && body[i] == "|" {
            i += 1
            current.append("|")
        } else if c == "|" {
            cells.append(tableString(tableTrim(current)))
            current = []
        } else {
            current.append(c)
        }
    }
    cells.append(tableString(tableTrim(current)))
    return cells
}
