import Foundation

// The block tree: a note's body as editors hold it.
//
// A `Document` is a tree of `Block`s. Markdown's lists are its nesting: a
// list item is a block, and what sits inside it — its sublist, a paragraph
// after a blank line, a code block — is its children. Anything else (a
// heading, a paragraph, a quote, a table) is a block wherever it stands. An
// outline editor walks it as rows at depths (`Document.rows`) and
// restructures it with `Markup.Outline`.
//
// A block's inline content stays in its `text` as the Markdown it was
// written in; `Markup.Inline` finds the spans in it.
//
// Losslessness: reading a body and writing it back unchanged gives the
// same bytes, for every input. Each block keeps the small facts of how it
// was written (`Layout`), and whatever part of a body would still not
// write back as it was read is kept whole as a `.raw` block — checked at
// parse time, top-level block by top-level block. An edited or new block
// is written canonically.

extension Markup {
    /// How a document's lines end.
    public enum LineEnding: Equatable, Sendable { case lf, crlf }

    /// A note's body.
    public struct Document: Equatable, Sendable {
        /// The top-level blocks, in order.
        public var blocks: [Block] = []
        /// Blank lines after the last block, as written.
        public var trailingBlank: [String] = []
        /// Whether the last line ends in a line break.
        public var finalNewline = false
        public var lineEnding: LineEnding = .lf

        /// An empty document, as a new note starts.
        public init() { finalNewline = true }

        init(blocks: [Block], trailingBlank: [String] = [], finalNewline: Bool, lineEnding: LineEnding) {
            self.blocks = blocks; self.trailingBlank = trailingBlank; self.finalNewline = finalNewline; self.lineEnding = lineEnding
        }
    }

    /// What a block is. The block's `text` means what its kind says.
    public enum BlockKind: Equatable, Sendable {
        /// Text that is nothing else. `text` is its lines.
        case paragraph
        /// `## text`; the level is 1 to 6. `text` is what follows the hashes.
        case heading(Int)
        /// A list item: `- text`, `1. text`, `+ [ ] text`.
        case item(Item)
        /// `> text`. `text` is the quoted lines without their `>`.
        case quote
        /// A fenced code block. `text` is all of it, fences included.
        case code
        /// A pipe table. `text` is its lines.
        case table
        /// `---`, `***` or `___`, as written.
        case rule
        /// Lines kept exactly as they were, because they would not otherwise
        /// write back as read. Shown as plain text.
        case raw
    }

    /// A list item's marker and checkbox.
    public struct Item: Equatable, Sendable {
        public var marker: Marker
        public var task: Task?
        public init(marker: Marker, task: Task?) { self.marker = marker; self.task = task }
    }

    /// What a list item starts with.
    public enum Marker: Equatable, Sendable {
        /// `-`, `*` or `+`.
        case bullet(Character)
        /// `1.` or `1)`: the number, and the delimiter after it.
        case ordered(number: Int, delimiter: Character)

        var width: Int {
            switch self {
            case .bullet: return 1
            case .ordered(let number, _): return String(number).utf8.count + 1
            }
        }

        var written: String {
            switch self {
            case .bullet(let c): return String(c)
            case .ordered(let number, let delimiter): return "\(number)\(delimiter)"
            }
        }
    }

    /// A checkbox on a list item.
    public enum Task: Equatable, Sendable {
        case open
        /// Done, with the letter it was checked with: `x` or `X`.
        case done(Character)
        public var isDone: Bool { if case .done = self { return true } else { return false } }
    }

    /// How a block was written, beyond what it says. A new block's default
    /// layout writes canonical Markdown.
    public struct Layout: Equatable, Sendable {
        /// The blank lines before the block, as written.
        public var gap: [String] = []
        /// Spaces between the marker (or the hashes, or `>`) and the text.
        public var spacing = 1
        /// Spaces of indentation beyond what the block's depth asks for.
        public var extraIndent = 0
        /// How each line after the first was indented, when not the usual;
        /// nil is the usual. See `quoteBare`.
        var continuation: [Int?]? = nil
        public init() {}
    }

    /// One block of a document, with the blocks nested in it.
    public struct Block: Equatable, Sendable {
        public var kind: BlockKind
        /// The block's content, as Markdown, without its marker. Lines after
        /// the first are joined with `\n`, without their indentation.
        public var text: String
        /// The blocks inside this one.
        public var children: [Block] = []
        public var layout = Layout()
        /// Whether an outline shows the block without what is under it. Not
        /// part of the note unless a session writes it; held here so that a
        /// block moved takes its fold with it.
        public var folded = false
        /// What the block is known by, if a session named it
        /// (`<!-- ^k3f9 -->`).
        public var anchor: String? = nil
        /// Whether the block is shown as the card of what it links to
        /// (`<!-- card -->`).
        public var card = false

        public init(_ kind: BlockKind, _ text: String) { self.kind = kind; self.text = text }

        public static func paragraph(_ text: String) -> Block { Block(.paragraph, text) }
        /// A heading; the level is held to 1–6.
        public static func heading(_ level: Int, _ text: String) -> Block { Block(.heading(min(max(level, 1), 6)), text) }
        /// `- text`.
        public static func bullet(_ text: String) -> Block { Block(.item(Item(marker: .bullet("-"), task: nil)), text) }
        /// `+ [ ] text`: a task, as Prism writes them.
        public static func task(_ text: String) -> Block { Block(.item(Item(marker: .bullet("+"), task: .open)), text) }
        /// `1. text`.
        public static func ordered(_ number: Int, _ text: String) -> Block { Block(.item(Item(marker: .ordered(number: number, delimiter: "."), task: nil)), text) }
        public static func quote(_ text: String) -> Block { Block(.quote, text) }
        public static func rule() -> Block { Block(.rule, "---") }

        /// A fenced code block, its fence long enough to hold a body with
        /// fences of its own.
        public static func code(_ info: String, _ body: String) -> Block {
            let longest = body.u8.lines.map { $0.trimmedStart.leading(UInt8(ascii: "`")) }.max() ?? 0
            let fence = String(repeating: "`", count: max(longest, 2) + 1)
            let newline = body.isEmpty || body.u8.last == .newline ? "" : "\n"
            return Block(.code, "\(fence)\(info)\n\(body)\(newline)\(fence)")
        }

        public func with(children: [Block]) -> Block { var b = self; b.children = children; return b }

        /// The item's marker and checkbox, when the block is a list item.
        public var item: Item? { if case .item(let item) = kind { return item } else { return nil } }
        public var isItem: Bool { item != nil }
        public var taskState: Task? { item?.task }

        /// Whether rows can go under this one: a list item's, or a
        /// paragraph's — every body row can have children, as Bike's. A
        /// paragraph with rows under it is written as a `- ` item.
        public var canHaveChildren: Bool {
            switch kind {
            case .item, .paragraph: return true
            default: return false
            }
        }

        /// Whether this is a plain body row: a paragraph, or a `- ` item with
        /// no box. The two are one kind of row, written two ways.
        public var isBodyRow: Bool {
            switch kind {
            case .paragraph: return true
            case .item(let item): return item.marker == .bullet("-") && item.task == nil
            default: return false
            }
        }

        /// The kind the block is written as: a paragraph Markdown could not
        /// read back as the same row — one with rows under it, or with no
        /// words — is written as a `- ` item.
        public var writtenKind: BlockKind {
            if kind == .paragraph && (!children.isEmpty || text.isBlankWS) { return .item(Item(marker: .bullet("-"), task: nil)) }
            return kind
        }

        /// Whether Return in the block's words makes two blocks of it.
        public var splits: Bool {
            switch kind {
            case .paragraph, .heading, .item, .quote: return true
            default: return false
            }
        }

        /// Whether the block has inline Markdown in its text.
        public var hasInlineContent: Bool {
            switch kind {
            case .paragraph, .heading, .item, .quote, .table: return true
            default: return false
            }
        }

        /// A code block's info string and body.
        public var codeParts: (info: String, body: String)? {
            guard kind == .code else { return nil }
            let text = self.text.u8
            let newline = text.find(byte: .newline)
            let first = newline.map { text.sub(0..<$0) } ?? text
            let rest = newline.map { text.sub(from: $0 + 1) } ?? []
            var fenceLen = 0
            for c in first.scalars { if c.1 == "`" || c.1 == "~" { fenceLen += c.1.utf8Len } else { break } }
            let fence = first.sub(0..<fenceLen)
            let info = first.sub(from: fenceLen).trimmed.string
            let body: Bytes
            if let last = rest.rfind([.newline]), isClosingFence(rest.sub(from: last + 1), fence) {
                body = rest.sub(0..<last)
            } else if rest.find(byte: .newline) == nil, isClosingFence(rest, fence) {
                body = []
            } else {
                body = rest
            }
            return (info, body.string)
        }

        /// The callout a quote is, when its first line is `[!KIND]`.
        public var callout: (kind: String, body: String)? {
            guard kind == .quote else { return nil }
            let text = self.text.u8
            let newline = text.find(byte: .newline)
            let first = newline.map { text.sub(0..<$0) } ?? text
            let body = newline.map { text.sub(from: $0 + 1) } ?? []
            let trimmed = first.trimmed
            guard trimmed.hasPrefix("[!".u8), trimmed.hasSuffix("]".u8), trimmed.count >= 3 else { return nil }
            let kind = trimmed.sub(2..<(trimmed.count - 1))
            guard !kind.isEmpty, kind.allSatisfy({ Unicode.Scalar($0).isAsciiAlpha && $0 < 0x80 }) else { return nil }
            return (kind.string, body.string)
        }

        /// This block and every block under it, depth first.
        public var walk: [Block] {
            var out: [Block] = []
            func visit(_ block: Block) { out.append(block); block.children.forEach(visit) }
            visit(self)
            return out
        }

        /// Whether any block here, or under it, is so.
        func any(_ test: (Block) -> Bool) -> Bool { test(self) || children.contains { $0.any(test) } }
    }

    /// A block as an outline shows it: where it is, and how deep.
    public struct Row {
        /// The block's place: an index at each level, outermost first.
        public var path: [Int]
        /// How many list items it is nested in.
        public var depth: Int
        public var block: Block
    }
}

private func isClosingFence(_ line: Bytes, _ fence: Bytes) -> Bool {
    let trimmed = line.trimmed
    return !fence.isEmpty && trimmed.hasPrefix(fence) && trimmed.allSatisfy { fence.contains($0) }
}

extension Markup.Document {
    public typealias Block = Markup.Block
    /// Reads a note's body. Never fails: what is not understood is kept raw.
    public static func parse(_ source: String) -> Markup.Document { Markup.parseDocument(source) }

    /// Writes the body as Markdown.
    public func toMarkdown() -> String {
        var rows: [(Int, Block)] = []
        Markup.flatten(blocks, 0, &rows)
        return Markup.write(rows, trailingBlank, finalNewline, lineEnding)
    }

    /// Every block as a row, in reading order: the outline.
    public func rows() -> [Markup.Row] {
        var out: [Markup.Row] = []
        var path: [Int] = []
        func visit(_ blocks: [Block]) {
            for (index, block) in blocks.enumerated() {
                path.append(index)
                out.append(Markup.Row(path: path, depth: path.count - 1, block: block))
                visit(block.children)
                path.removeLast()
            }
        }
        visit(blocks)
        return out
    }

    /// Every block, depth first.
    public var walk: [Block] { blocks.flatMap(\.walk) }

    /// Whether any block, however deep, is so.
    func any(_ test: (Block) -> Bool) -> Bool { blocks.contains { $0.any(test) } }

    /// The block at a path, if there is one.
    public func get(_ path: [Int]) -> Block? {
        guard let first = path.first, first >= 0, first < blocks.count else { return nil }
        var block = blocks[first]
        for index in path.dropFirst() {
            guard index >= 0, index < block.children.count else { return nil }
            block = block.children[index]
        }
        return block
    }

    /// Changes the block at a path in place; nil when there is none.
    @discardableResult
    mutating func modify<R>(_ path: [Int], _ change: (inout Block) -> R) -> R? {
        func go(_ list: inout [Block], _ rest: ArraySlice<Int>) -> R? {
            guard let first = rest.first, first >= 0, first < list.count else { return nil }
            if rest.count == 1 { return change(&list[first]) }
            return go(&list[first].children, rest.dropFirst())
        }
        return go(&blocks, path[...])
    }

    /// Changes the list a path's block is in: the document's own blocks for
    /// a path of one, else its parent's children.
    @discardableResult
    mutating func modifySiblings<R>(_ path: [Int], _ change: (inout [Block]) -> R) -> R? {
        guard !path.isEmpty else { return nil }
        if path.count == 1 { return change(&blocks) }
        return modify(Array(path.dropLast())) { change(&$0.children) }
    }

    /// The list a path's block is in.
    func siblings(_ path: [Int]) -> [Block]? {
        guard !path.isEmpty else { return nil }
        if path.count == 1 { return blocks }
        return get(Array(path.dropLast()))?.children
    }

    /// Finds a block again after the document changed around it: the block
    /// that `fits` at `hint`, or else the one that fits nearest to where
    /// `hint` would be, in reading order — one as deep as `hint` first.
    public func locate(where hint: [Int], _ fits: (Block) -> Bool) -> [Int]? {
        if let block = get(hint), fits(block) { return hint }
        let rows = self.rows()
        let stand = rows.filter { $0.path.lexicographicallyPrecedes(hint) }.count
        var best: (key: (Int, Int), path: [Int])? = nil
        for (at, row) in rows.enumerated() where fits(row.block) {
            let key = (row.path.count != hint.count ? 1 : 0, abs(at - stand))
            if best == nil || key < best!.key { best = (key, row.path) }
        }
        return best?.path
    }

    /// Finds the block with this text: at `hint`, or nearest to it.
    public func locate(_ hint: [Int], _ text: String) -> [Int]? { locate(where: hint) { $0.text.same(text) } }

    /// Whether nothing is written: no blocks, or only empty bullets.
    public var isBlank: Bool {
        !any { block in
            let plain: Bool
            switch block.kind {
            case .item(let item): plain = item.task == nil
            case .paragraph: plain = true
            default: plain = false
            }
            return !(plain && block.text.isBlankWS)
        }
    }
}

// --- Flat rows -------------------------------------------------------------
//
// The reader and the writer both work on a flat run of rows, each at a
// depth: Markdown is read a line at a time, and a line knows its
// indentation, not its parent.

extension Markup {
    struct FlatRow {
        var depth: Int
        var block: Block
        /// The line of the body the row starts at, its gap included.
        var startLine: Int
    }

    static func flatten(_ blocks: [Block], _ depth: Int, _ out: inout [(Int, Block)]) {
        for block in blocks {
            out.append((depth, block))
            flatten(block.children, depth + 1, &out)
        }
    }

    /// Rows at depths, made a tree: a row's children are the deeper rows
    /// that follow it.
    static func buildTree(_ rows: [FlatRow]) -> [Block] {
        var stack: [[Block]] = [[]]
        func close(_ to: Int) {
            while stack.count > to + 1 {
                let children = stack.removeLast()
                if !stack.isEmpty, !stack[stack.count - 1].isEmpty {
                    stack[stack.count - 1][stack[stack.count - 1].count - 1].children = children
                }
            }
        }
        for row in rows {
            // A row cannot be deeper than one below the row before it.
            let depth = min(row.depth, stack.count - 1 + (stack.last.map { $0.isEmpty ? 0 : 1 } ?? 0))
            close(depth)
            while stack.count < depth + 1 { stack.append([]) }
            stack[depth].append(row.block)
        }
        close(0)
        return stack.popLast() ?? []
    }

    // --- Reading -----------------------------------------------------------

    static func parseDocument(_ source: String) -> Document {
        let bytes = source.u8
        // `\r\n` throughout is a Windows note; a stray `\r` is just a character.
        let crlfs = bytes.occurrences(of: "\r\n".u8)
        let crlf = crlfs > 0 && crlfs == bytes.occurrences(of: [.newline])
        let body = crlf ? bytes.replacing("\r\n".u8, with: [.newline]) : bytes
        var document = Document(blocks: [], finalNewline: true, lineEnding: crlf ? .crlf : .lf)
        if body.isEmpty { return document }
        var lines = body.split(byte: .newline)
        if lines.last?.isEmpty == true { lines.removeLast() } else { document.finalNewline = false }

        var parser = Parser()
        for (index, line) in lines.enumerated() {
            parser.read(line, index + 1 < lines.count ? lines[index + 1] : nil, index)
        }
        let rows = parser.rows
        document.trailingBlank = parser.pendingGap.map(\.string)
        let contentEnd = lines.count - document.trailingBlank.count
        func joined(_ range: Range<Int>) -> Bytes {
            var out: Bytes = []
            for i in range {
                if i > range.lowerBound { out.append(.newline) }
                out.append(contentsOf: lines[i])
            }
            return out
        }

        // Whatever would not be written back as it was read is kept raw, one
        // top-level block (with all that is nested in it) at a time.
        var starts = rows.indices.filter { rows[$0].depth == 0 }
        starts.append(rows.count)
        var checked: [FlatRow] = []
        checked.reserveCapacity(rows.count)
        for w in 0..<max(starts.count - 1, 0) {
            let (start, end) = (starts[w], starts[w + 1])
            let covered = rows[start].startLine..<(end < rows.count ? rows[end].startLine : contentEnd)
            let chunk = rows[start..<end].map { ($0.depth, $0.block) }
            let faithful = write(chunk, [], false, .lf).utf8.elementsEqual(joined(covered))
            if faithful {
                checked.append(contentsOf: rows[start..<end])
            } else {
                checked.append(FlatRow(depth: 0, block: Block(.raw, joined(covered).string), startLine: covered.lowerBound))
            }
        }
        document.blocks = buildTree(checked)

        // The last line of defence: a body that still does not round-trip is
        // one raw block.
        var flat: [(Int, Block)] = []
        flatten(document.blocks, 0, &flat)
        let back = write(flat, document.trailingBlank, document.finalNewline, .lf)
        if !back.utf8.elementsEqual(body) {
            document.blocks = [Block(.raw, joined(0..<contentEnd).string)]
        }
        return document
    }

    /// Among a quote's continuation facts: a line written `>` with no space.
    static let quoteBare = -1

    struct Parser {
        var rows: [FlatRow] = []
        var pendingGap: [Bytes] = []
        /// The content column of each open list item, outermost first.
        var open: [Int] = []
        /// The fence that opened the code block being read.
        var fence: Bytes? = nil
        /// The column the last row's continuation lines are measured from.
        var lastContentColumn = 0
        /// How many lines the last row's text takes.
        var lastLineCount = 0

        mutating func read(_ line: Bytes, _ next: Bytes?, _ index: Int) {
            if let fence { return readFenced(line, fence, next, index) }
            if isBlank(line) { pendingGap.append(line); return }
            let indent = indentation(line)
            let content = line.trimmingStart([.space, .tab])
            if pendingGap.isEmpty, let last = rows.last {
                // `>` straight after a quote, where it starts: its next line.
                if last.block.kind == .quote && content.first == UInt8(ascii: ">") && indent == lastContentColumn {
                    return appendQuoteLine(content)
                }
                // A line straight after text, that starts nothing new, goes on
                // with that text — even when not indented to match.
                if continues(last.block) && !startsBlock(content, indent >= lastContentColumn) {
                    return appendContinuation(line, indent)
                }
            }
            while let column = open.last, indent < column { open.removeLast() }
            let depth = open.count
            let base = open.last ?? 0
            let gap = pendingGap
            pendingGap = []
            let startLine = index - gap.count
            var block = Block.paragraph("")
            block.layout.gap = gap.map(\.string)
            block.layout.extraIndent = indent - base
            lastContentColumn = indent

            if let item = listItem(content) {
                block.kind = .item(Item(marker: item.marker, task: item.task))
                block.layout.spacing = item.spacing
                block.text = item.text.string
                let column = indent + item.marker.width + max(item.spacing, 1)
                open.append(column)
                lastContentColumn = column
            } else if let found = heading(content) {
                block.kind = .heading(found.0)
                block.layout.spacing = found.1
                block.text = found.2.string
            } else if let marker = fenceMarker(content) {
                block.kind = .code
                block.text = content.string
                fence = marker
            } else if isRule(content) {
                block.kind = .rule
                block.text = content.string
            } else if content.first == UInt8(ascii: ">") {
                let rest = content.sub(from: 1)
                block.kind = .quote
                block.layout.spacing = rest.first == .space ? 1 : 0
                block.text = rest.sub(from: block.layout.spacing).string
            } else {
                if content.first == UInt8(ascii: "|"), let next, Table.isSeparator(next.string) { block.kind = .table }
                block.text = content.string
            }
            rows.append(FlatRow(depth: depth, block: block, startLine: startLine))
            lastLineCount = 1
        }

        mutating func readFenced(_ line: Bytes, _ fence: Bytes, _ next: Bytes?, _ index: Int) {
            let indent = indentation(line)
            let content = line.trimmingStart([.space])
            // A fence inside a list item is indented with it; a line indented
            // less has ended the block with the item.
            if !line.isEmpty && indent < lastContentColumn && !content.hasPrefix(fence) {
                self.fence = nil
                return read(line, next, index)
            }
            appendContinuation(line, indent)
            let trimmed = content.trimmed
            if trimmed.hasPrefix(fence) && trimmed.allSatisfy({ fence.first == $0 }) { self.fence = nil }
        }

        /// A quote's next line, written with its `>`: in the text without it.
        mutating func appendQuoteLine(_ content: Bytes) {
            let rest = content.sub(from: 1)
            if rest.first == .space { appendLine(rest.sub(from: 1), nil) } else { appendLine(rest, quoteBare) }
        }

        mutating func appendContinuation(_ line: Bytes, _ indent: Int) {
            if isBlank(line) {
                // Spaces alone, indented as far as the block: the block's, past its indentation.
                let column = lastContentColumn
                if column > 0 && line.count > column && line[0..<column].allSatisfy({ $0 == .space }) {
                    return appendLine(line.sub(from: column), nil)
                }
                // Any other blank line inside a block is kept as it was, spaces and all.
                return appendLine(line, line.isEmpty ? nil : 0)
            }
            let strip = min(indent, lastContentColumn)
            let isQuote = rows.last?.block.kind == .quote
            // Indented less than usual (a lazy continuation) is recorded; more
            // than usual keeps the extra in the text. A quote's line without
            // its `>` is always recorded: its usual has one.
            let fact: Int? = (indent < lastContentColumn || isQuote) ? strip : nil
            appendLine(line.sub(from: prefixLen(line, strip)), fact)
        }

        mutating func appendLine(_ line: Bytes, _ fact: Int?) {
            let count = lastLineCount
            guard !rows.isEmpty else { return }
            let last = rows.count - 1
            rows[last].block.text += "\n" + line.string
            if rows[last].block.layout.continuation != nil {
                rows[last].block.layout.continuation!.append(fact)
            } else if fact != nil {
                var facts = [Int?](repeating: nil, count: count - 1)
                facts.append(fact)
                rows[last].block.layout.continuation = facts
            }
            lastLineCount += 1
        }
    }

    /// Whether a line straight after this block can go on with its text.
    static func continues(_ block: Block) -> Bool {
        switch block.writtenKind {
        case .paragraph, .quote, .table: return true
        case .item(let item): return !(block.text.isEmpty && item.task == nil)
        case .heading, .code, .rule, .raw: return false
        }
    }

    // --- Writing -----------------------------------------------------------

    /// The rows written as lines; `record` is told, of each row in turn, the
    /// line its words start on and how many lines they take.
    static func write(_ rows: [(Int, Block)], _ trailing: [String], _ finalNewline: Bool, _ ending: LineEnding,
                      record: ((Int, Int) -> Void)? = nil) -> String {
        var lines: [String] = []
        // The content column of the list item open at each depth.
        var columns: [Int] = []
        // When a line straight after the row before would go on with its
        // text: the column that text is measured from.
        var continuing: Int? = nil
        // The depth of an empty item just written: Markdown reads its first
        // child as its own only with no blank line between them.
        var emptyItem: Int? = nil
        // The depth of a quote just written: a quote straight after it would
        // be read as more of it.
        var quote: Int? = nil
        for (rowDepth, block) in rows {
            if block.kind == .raw {
                let rawLines = block.text.u8.split(byte: .newline).map(\.string)
                record?(lines.count, rawLines.count)
                lines.append(contentsOf: rawLines)
                columns.removeAll()
                continuing = nil
                quote = nil
                continue
            }
            let opensEmpty = emptyItem.map { rowDepth > $0 } ?? false
            if !opensEmpty { lines.append(contentsOf: block.layout.gap) }
            if block.kind == .quote && block.layout.gap.isEmpty && quote == rowDepth { lines.append("") }
            quote = block.kind == .quote ? rowDepth : nil
            let depth = min(rowDepth, columns.count)
            columns.removeLast(columns.count - depth)
            let base = columns.last ?? 0
            let indent = base + block.layout.extraIndent
            let pad = String(repeating: " ", count: max(indent, 0))
            let textBytes = block.text.u8
            let textLines = textBytes.split(byte: .newline)
            let firstLine = textLines[0].string
            var spaces = String(repeating: " ", count: block.layout.spacing)
            var continuation = indent
            let kind = block.writtenKind
            // A paragraph written as an item has the item's one space after its marker.
            let spacing = block.kind == .paragraph ? 1 : block.layout.spacing
            if case .item = kind { spaces = String(repeating: " ", count: spacing) }
            let first: String
            switch kind {
            case .item(let item):
                let marker = item.marker.written
                var head = pad + marker + spaces
                switch item.task {
                case nil: break
                case .open: head += "[ ]"
                case .done(let letter): head += "[\(letter)]"
                }
                if item.task != nil && !block.text.isEmpty { head += " " }
                // The words' column as Markdown reads it: spaces at the start
                // of the words count with those after the marker — up to four;
                // past that, one does.
                let lead = item.task == nil ? textLines[0].leading(.space) : 0
                let after = max(spacing, 1) + lead
                continuation = indent + marker.utf8.count + (after <= 4 ? after : 1)
                columns.append(continuation)
                first = head + firstLine
            case .heading(let level): first = pad + String(repeating: "#", count: level) + spaces + firstLine
            case .quote: first = pad + ">" + spaces + firstLine
            default: first = pad + firstLine
            }
            if case .item(let item) = kind, item.task == nil, block.text.isBlankWS { emptyItem = rowDepth } else { emptyItem = nil }
            // A block made in an editor can sit straight after text it would
            // be read back as part of; a blank line keeps it a block.
            if block.layout.gap.isEmpty && !opensEmpty, let column = continuing {
                let firstBytes = first.u8
                if !startsBlock(firstBytes.trimmingStart([.space]), indentation(firstBytes) >= column) { lines.append("") }
            }
            let firstLineIndex = lines.count
            lines.append(first)
            continuing = continues(block) ? continuation : nil
            let facts = block.layout.continuation ?? []
            for (offset, line) in textLines.dropFirst().enumerated() {
                let fact = offset < facts.count ? facts[offset] : nil
                if block.kind == .quote && (fact == nil || fact == quoteBare) {
                    // A quote's lines each with its `>`, as they were written.
                    let space = fact == quoteBare || line.isEmpty ? "" : " "
                    lines.append(pad + ">" + space + line.string)
                } else if let written = fact {
                    lines.append(String(repeating: " ", count: max(written, 0)) + line.string)
                } else if line.isEmpty {
                    lines.append("")
                } else {
                    lines.append(String(repeating: " ", count: continuation) + line.string)
                }
            }
            record?(firstLineIndex, lines.count - firstLineIndex)
        }
        lines.append(contentsOf: trailing)
        let newline = ending == .crlf ? "\r\n" : "\n"
        var text = lines.joined(separator: newline)
        if finalNewline && !lines.isEmpty { text += newline }
        return text
    }

    // --- Lines -------------------------------------------------------------

    static func isBlank(_ line: Bytes) -> Bool { line.allSatisfy { $0 == .space || $0 == .tab } }

    /// Columns of leading whitespace, a tab reaching the next stop of four.
    static func indentation(_ line: Bytes) -> Int {
        var column = 0
        for byte in line {
            if byte == .space { column += 1 } else if byte == .tab { column += 4 - column % 4 } else { break }
        }
        return column
    }

    /// How many bytes of `line` make up its first `columns` columns of
    /// indentation.
    static func prefixLen(_ line: Bytes, _ columns: Int) -> Int {
        var (column, count) = (0, 0)
        for byte in line {
            if column >= columns { break }
            if byte == .space { column += 1 } else if byte == .tab { column += 4 - column % 4 } else { break }
            count += 1
        }
        return count
    }

    struct ListItem {
        var marker: Marker
        var spacing: Int
        var task: Task?
        var text: Bytes
    }

    static func listItem(_ content: Bytes) -> ListItem? {
        guard let first = content.first else { return nil }
        let marker: Marker
        let rest: Bytes
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
            marker = .bullet(Character(Unicode.Scalar(first)))
            rest = content.sub(from: 1)
        } else {
            var digits = 0
            while digits < content.count && content[digits].isAsciiDigit { digits += 1 }
            guard (1...9).contains(digits), digits < content.count else { return nil }
            let delimiter = content[digits]
            guard delimiter == UInt8(ascii: ".") || delimiter == UInt8(ascii: ")") else { return nil }
            guard let number = Int(content.string(0..<digits)) else { return nil }
            marker = .ordered(number: number, delimiter: Character(Unicode.Scalar(delimiter)))
            rest = content.sub(from: digits + 1)
        }
        guard rest.isEmpty || rest[0] == .space || rest[0] == .tab else { return nil }
        let spacing = rest.leading(.space)
        var text = rest.sub(from: spacing)
        if text.first == .tab { return nil }
        var task: Task? = nil
        if spacing >= 1, let found = taskBox(text) {
            let after = text.sub(from: 3)
            if after.isEmpty || after[0] == .space {
                task = found
                text = after.first == .space ? after.sub(from: 1) : after
            }
        }
        return ListItem(marker: marker, spacing: spacing, task: task, text: text)
    }

    static func taskBox(_ text: Bytes) -> Task? {
        guard text.count >= 3, text[0] == UInt8(ascii: "["), text[2] == UInt8(ascii: "]") else { return nil }
        switch text[1] {
        case .space: return .open
        case UInt8(ascii: "x"), UInt8(ascii: "X"): return .done(Character(Unicode.Scalar(text[1])))
        default: return nil
        }
    }

    static func heading(_ content: Bytes) -> (Int, Int, Bytes)? {
        let hashes = content.leading(UInt8(ascii: "#"))
        guard (1...6).contains(hashes) else { return nil }
        let rest = content.sub(from: hashes)
        guard rest.isEmpty || rest[0] == .space else { return nil }
        let spacing = rest.leading(.space)
        return (hashes, spacing, rest.sub(from: spacing))
    }

    /// The run of backticks or tildes that opens a fence.
    static func fenceMarker(_ content: Bytes) -> Bytes? {
        guard let first = content.first, first == UInt8(ascii: "`") || first == UInt8(ascii: "~") else { return nil }
        let run = content.leading(first)
        if run < 3 || (first == UInt8(ascii: "`") && content.find(byte: first, from: run) != nil) { return nil }
        return content.sub(0..<run)
    }

    static func isRule(_ content: Bytes) -> Bool {
        let marks = content.filter { $0 != .space && $0 != .tab }
        guard let first = marks.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "_") else { return false }
        return marks.allSatisfy { $0 == first } && marks.count >= 3
    }

    /// Whether a line, stripped of its indentation, starts a block of its own
    /// rather than going on with the text before it.
    static func startsBlock(_ content: Bytes, _ interruptingParagraph: Bool) -> Bool {
        if heading(content) != nil || fenceMarker(content) != nil || isRule(content) || content.first == UInt8(ascii: ">") { return true }
        guard let item = listItem(content) else { return false }
        if interruptingParagraph {
            // Markdown lets only a list item with something in it, and an
            // ordered one only when it counts from one, break into a paragraph.
            if item.text.isEmpty && item.task == nil { return false }
            if case .ordered(let number, _) = item.marker, number != 1 { return false }
        }
        return true
    }
}
