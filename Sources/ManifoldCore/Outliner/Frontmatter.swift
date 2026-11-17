// Frontmatter: the block of `key: value` lines a note may start with.
//
// Only YAML's plainest part is read: `key: value`, quoted or not; lists as
// `[a, b]` or one `- item` a line; `|` and `>` blocks. Every value is text
// or a list of text — no numbers, no nesting — which is all a note's
// fields need, and small enough to write back exactly.
//
// Lossless by construction. Each entry keeps the lines it was read from.
// Writing a Frontmatter back emits those lines untouched, so comments, key
// order, quoting and spacing survive; only an entry that was set is
// written anew.
//
// Text is handled as Unicode scalars throughout, never as Characters: a
// "\r\n" is one Character, and Character comparison is by canonical
// equivalence, where this reads and writes bytes.

extension Markup {
    /// A note's frontmatter, fences and all.
    public struct Frontmatter: Equatable, Sendable, CustomStringConvertible {
        /// The opening fence, as written (`---`, maybe with trailing spaces).
        private var open: String
        private var items: [Entry]
        /// The closing fence: `---` or `...`.
        private var close: String
        /// `\n` or `\r\n`.
        private var newline: String

        /// An empty frontmatter, to be filled with `set`.
        public init() {
            open = "---"
            items = []
            close = "---"
            newline = "\n"
        }

        /// Splits a note's source into its frontmatter and its body.
        ///
        /// Frontmatter is there when the first line is `---` and a later line
        /// is `---` or `...`; otherwise the whole source is body. The two
        /// returned pieces always concatenate back to `source` when the
        /// frontmatter is written with `description`.
        public static func split(_ source: String) -> (Frontmatter?, String) {
            var lines = LineCursor(Array(source.unicodeScalars))
            guard let first = lines.next() else { return (nil, source) }
            let (open, ending) = first
            if trimEnd(open, spaceOrTab) != dashes || ending.isEmpty {
                return (nil, source)
            }
            let newline = ending == crlf ? "\r\n" : "\n"
            var body: [Scalars] = []
            while let next = lines.next() {
                let (line, lineEnding) = next
                let fence = trimEnd(line, spaceOrTab)
                if fence == dashes || fence == dots {
                    // A header whose lines end differently from its fence would
                    // not write back the same: leave such a file all body.
                    if (!lineEnding.isEmpty && !same(lineEnding, newline)) || body.contains(where: { $0.last == "\r" }) {
                        return (nil, source)
                    }
                    // A closing fence at the very end of the file, with no line
                    // break after it, is the one shape `description` cannot give
                    // back; such a note is rare enough to be read as all body.
                    if lineEnding.isEmpty {
                        return (nil, source)
                    }
                    var frontmatter = Frontmatter()
                    frontmatter.open = string(open)
                    frontmatter.close = string(line)
                    frontmatter.newline = newline
                    frontmatter.items = parseEntries(body)
                    return (frontmatter, string(lines.source[lines.offset...]))
                }
                if newline == "\n" && lineEnding == crlf {
                    return (nil, source)
                }
                body.append(line)
            }
            return (nil, source)
        }

        /// The value of a key, the first of that name.
        public func get(_ key: String) -> Value? {
            items.first(where: { same($0.key, key) })?.value
        }

        /// A key's text, when it holds text.
        public func text(_ key: String) -> String? {
            get(key)?.asText
        }

        /// A key's items: a list's, or one for text; empty when there is none.
        public func list(_ key: String) -> [String] {
            get(key)?.toList() ?? []
        }

        /// Whether a key marks the note: it is there, with a value that does
        /// not say no (`isSet`). `private: true`, `pinned: 3` and
        /// `topic: Maths` all mark; `inbox: no` and a bare `inbox:` do not.
        public func flag(_ key: String) -> Bool {
            guard let first = get(key)?.toList().first else { return false }
            return Frontmatter.isSet(first)
        }

        public func contains(_ key: String) -> Bool {
            items.contains(where: { same($0.key, key) })
        }

        /// The keys, in the order written.
        public var keys: [String] {
            items.compactMap(\.key)
        }

        /// Every entry, in the order written.
        public var entries: [(key: String, value: Value)] {
            items.compactMap { entry in
                guard let key = entry.key, let value = entry.value else { return nil }
                return (key, value)
            }
        }

        public var isEmpty: Bool {
            items.allSatisfy { $0.key == nil }
        }

        /// Sets a key's value. An entry already holding exactly this value is
        /// left as it was written; one holding another is rewritten in place;
        /// a new key goes at the end.
        public mutating func set(_ key: String, _ value: Value) {
            if let index = items.firstIndex(where: { same($0.key, key) }) {
                if identical(items[index].value, value) {
                    return
                }
                // A list written an item a line stays so, whatever its length:
                // one line an item is what lets git merge two devices' changes.
                var wasBlockList = false
                if case .list? = items[index].value { wasBlockList = items[index].lines.count > 1 }
                items[index].lines = writeEntry(key, value, keepBlockList: wasBlockList)
                items[index].value = value
            } else {
                items.append(Entry(key: key, lines: writeEntry(key, value, keepBlockList: false), value: value))
            }
        }

        /// Sets a key to text.
        public mutating func set(_ key: String, _ text: String) {
            set(key, .text(text))
        }

        /// Sets a key to a list of text.
        public mutating func set(_ key: String, _ items: [String]) {
            set(key, .list(items))
        }

        /// Sets a key to a list written an item a line, however short: for a
        /// list two devices may both add to, so that git merges the two.
        public mutating func setListByLine(_ key: String, _ list: [String]) {
            let value = Value.list(list)
            let lines = writeEntry(key, value, keepBlockList: true)
            if let index = items.firstIndex(where: { same($0.key, key) }) {
                if sameLines(items[index].lines, lines) { return }
                items[index].lines = lines
                items[index].value = value
            } else {
                items.append(Entry(key: key, lines: lines, value: value))
            }
        }

        /// Takes a key out, with its lines. Says whether it was there.
        @discardableResult
        public mutating func remove(_ key: String) -> Bool {
            let before = items.count
            items.removeAll(where: { same($0.key, key) })
            return items.count != before
        }

        /// The block as it goes in a file: both fences, each line ended.
        public var description: String {
            var out = open + newline
            for line in items.flatMap(\.lines) {
                out += line
                out += newline
            }
            out += close
            out += newline
            return out
        }

        /// What a text says, read as yes or no: `true`, `yes`, `on`, `1`, `y` —
        /// `false`, `no`, `off`, `0`, `n` — case aside. `nil` for anything
        /// else. The one reading of yes and no there is.
        public static func truth(_ text: String) -> Bool? {
            let word = asciiLowercased(trim(Array(text.unicodeScalars)))
            if yes.contains(where: { Array($0.unicodeScalars) == word }) { return true }
            if no.contains(where: { Array($0.unicodeScalars) == word }) { return false }
            return nil
        }

        /// Whether a field's value marks its note: anything but nothing, and
        /// anything but no. What `is: pinned` asks, whether the page says
        /// `pinned: true` or `pinned: 3`.
        public static func isSet(_ text: String) -> Bool {
            !trim(Array(text.unicodeScalars)).isEmpty && truth(text) != false
        }
    }
}

extension Markup.Frontmatter {
    /// A frontmatter value: text, or a list of text.
    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])

        public var asText: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        public var asList: [String]? {
            if case .list(let items) = self { return items }
            return nil
        }

        /// The value as a list: a list's items, or text as a list of one —
        /// `tags: Work` and `tags: [Work]` mean the same.
        public func toList() -> [String] {
            switch self {
            case .list(let items): return items
            case .text(let text): return trim(Array(text.unicodeScalars)).isEmpty ? [] : [text]
            }
        }
    }

    /// One entry, or a line that is none (blank, a comment), with its lines
    /// as written — line endings excluded.
    fileprivate struct Entry: Equatable, Sendable {
        var key: String?
        var lines: [String]
        var value: Value?
    }
}

// --- Scalars -----------------------------------------------------------------

private typealias Scalars = [Unicode.Scalar]
private typealias FrontValue = Markup.Frontmatter.Value
private typealias FrontEntry = Markup.Frontmatter.Entry

private let dashes: Scalars = ["-", "-", "-"]
private let dots: Scalars = [".", ".", "."]
private let crlf = "\r\n"
private let spaceOrTab: Set<Unicode.Scalar> = [" ", "\t"]
private let yes = ["true", "yes", "on", "1", "y"]
private let no = ["false", "no", "off", "0", "n"]

private func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

/// Whether two texts are the same bytes (String's == is canonical equivalence).
private func same(_ a: String?, _ b: String) -> Bool {
    guard let a else { return false }
    return a.utf8.elementsEqual(b.utf8)
}

private func sameLines(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
}

private func identical(_ a: FrontValue?, _ b: FrontValue) -> Bool {
    switch (a, b) {
    case (.text(let x)?, .text(let y)): return same(x, y)
    case (.list(let x)?, .list(let y)): return sameLines(x, y)
    default: return false
    }
}

private func isWhitespace(_ c: Unicode.Scalar) -> Bool {
    c.properties.isWhitespace
}

/// Rust's `trim`: Unicode White_Space off both ends.
private func trim<C: BidirectionalCollection>(_ s: C) -> Scalars where C.Element == Unicode.Scalar {
    var slice = s[...]
    while let c = slice.first, isWhitespace(c) { slice = slice.dropFirst() }
    while let c = slice.last, isWhitespace(c) { slice = slice.dropLast() }
    return Array(slice)
}

private func trimEnd(_ s: Scalars, _ set: Set<Unicode.Scalar>) -> Scalars {
    var end = s.count
    while end > 0 && set.contains(s[end - 1]) { end -= 1 }
    return Array(s[..<end])
}

private func asciiLowercased(_ s: Scalars) -> Scalars {
    s.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }
}

/// Where `needle` first starts in `s`.
private func find(_ s: Scalars, _ needle: Scalars) -> Int? {
    guard needle.count <= s.count else { return nil }
    for at in 0...(s.count - needle.count) where s[at..<(at + needle.count)].elementsEqual(needle) {
        return at
    }
    return nil
}

private func joined(_ parts: [Scalars], _ separator: Unicode.Scalar) -> Scalars {
    var out: Scalars = []
    for (i, part) in parts.enumerated() {
        if i > 0 { out.append(separator) }
        out.append(contentsOf: part)
    }
    return out
}

/// Splits at each `separator`, keeping empty pieces (Rust's `split`).
private func pieces(_ s: Scalars, _ separator: Unicode.Scalar) -> [Scalars] {
    var out: [Scalars] = [[]]
    for c in s {
        if c == separator { out.append([]) } else { out[out.count - 1].append(c) }
    }
    return out
}

/// Walks a text's lines, giving each without its ending, and the ending.
private struct LineCursor {
    let source: Scalars
    var offset = 0

    init(_ source: Scalars) {
        self.source = source
    }

    mutating func next() -> (Scalars, String)? {
        guard offset < source.count else { return nil }
        var at = offset
        while at < source.count && source[at] != "\n" { at += 1 }
        let line: Scalars
        let ending: String
        if at == source.count {
            (line, ending) = (Array(source[offset..<at]), "")
        } else if at > offset && source[at - 1] == "\r" {
            (line, ending) = (Array(source[offset..<(at - 1)]), crlf)
        } else {
            (line, ending) = (Array(source[offset..<at]), "\n")
        }
        offset += line.count + ending.unicodeScalars.count
        return (line, ending)
    }
}

// --- Reading -----------------------------------------------------------------

private func parseEntries(_ lines: [Scalars]) -> [FrontEntry] {
    var entries: [FrontEntry] = []
    var index = 0
    while index < lines.count {
        let line = lines[index]
        index += 1
        var colon: Int?
        if let first = line.first, first != "#", !isWhitespace(first), first != "-" {
            colon = keyColon(line)
        }
        guard let colon else {
            entries.append(FrontEntry(key: nil, lines: [string(line)], value: nil))
            continue
        }
        let start = index
        // What follows the key and belongs to it: indented lines, or a
        // list's `- ` items at the left edge.
        while index < lines.count, let first = lines[index].first, first == " " || first == "\t" || first == "-" {
            index += 1
        }
        let rest = Array(lines[start..<index])
        let key = unquoteKey(trim(line[..<colon]))
        let value = parseValue(trim(line[(colon + 1)...]), rest)
        entries.append(FrontEntry(key: key, lines: [string(line)] + rest.map { string($0) }, value: value))
    }
    return entries
}

/// The colon ending a key: the first followed by a space or the line's end,
/// outside a quote the line opens with.
private func keyColon(_ line: Scalars) -> Int? {
    var quote: Unicode.Scalar?
    for at in line.indices {
        let c = line[at]
        if let open = quote {
            if c == open { quote = nil }
        } else if (c == "\"" || c == "'") && at == 0 {
            quote = c
        } else if c == ":" && (at + 1 == line.count || line[at + 1] == " " || line[at + 1] == "\t") {
            return at
        }
    }
    return nil
}

private func unquoteKey(_ key: Scalars) -> String {
    if key.count >= 2, let first = key.first, first == "\"" || first == "'", first == key.last {
        return unquote(key)
    }
    return string(key)
}

private func parseValue(_ inline: Scalars, _ rest: [Scalars]) -> FrontValue {
    if inline.first == "|" || inline.first == ">" {
        return .text(blockScalar(inline, rest))
    }
    if inline.first == "[" {
        return .list(flowList(inline))
    }
    if inline.isEmpty && !rest.isEmpty && rest.allSatisfy({ trim($0).first == "-" }) {
        return .list(rest.map { scalar(trim(trim($0).dropFirst())) })
    }
    let parts = [inline] + rest.map { trim($0) }
    if inline.first == "\"" || inline.first == "'" {
        // A quoted value may run on over lines; they are joined by spaces.
        return .text(unquote(joined(parts, " ")))
    }
    return .text(string(joined(parts.map(stripComment).filter { !$0.isEmpty }, " ")))
}

private func scalar(_ text: Scalars) -> String {
    if text.first == "\"" || text.first == "'" {
        return unquote(text)
    }
    return string(stripComment(text))
}

private func stripComment(_ text: Scalars) -> Scalars {
    guard let at = find(text, [" ", "#"]) else { return text }
    return trim(text[..<at])
}

/// `|`, `|-`, `|+` (and `>`, folded) with the lines under it, unindented.
private func blockScalar(_ indicator: Scalars, _ lines: [Scalars]) -> String {
    let folded = indicator.first == ">"
    let indent = lines.first(where: { !trim($0).isEmpty }).map { line in line.prefix(while: { $0 == " " }).count } ?? 0
    // Rust's `l.get(indent..)`: a byte offset, nothing when past the end or
    // inside a character.
    var body: [String] = lines.map { line in
        let bytes = Array(string(line).utf8)
        if indent > bytes.count || (indent < bytes.count && bytes[indent] & 0xC0 == 0x80) {
            return ""
        }
        return String(decoding: bytes[indent...], as: UTF8.self)
    }
    var trailing = 0
    while let last = body.last, last.isEmpty {
        body.removeLast()
        trailing += 1
    }
    var text = body.joined(separator: folded ? " " : "\n")
    if indicator.contains("+") {
        text += String(repeating: "\n", count: trailing + 1)
    } else if !indicator.contains("-") {
        text += "\n"
    }
    return text
}

private func flowList(_ text: Scalars) -> [String] {
    var inner = Array(text.dropFirst())
    if let end = inner.lastIndex(of: "]") {
        inner = Array(inner[..<end])
    }
    var items: [Scalars] = []
    var current: Scalars = []
    var quote: Unicode.Scalar?
    var escaped = false
    for c in inner {
        if let open = quote {
            current.append(c)
            if open == "\"" && c == "\\" && !escaped {
                escaped = true
                continue
            }
            if c == open && !escaped {
                quote = nil
            }
            escaped = false
        } else if (c == "\"" || c == "'") && trim(current).isEmpty {
            quote = c
            current.append(c)
        } else if c == "," {
            items.append(current)
            current = []
        } else {
            current.append(c)
        }
    }
    items.append(current)
    // An empty item is a trailing comma's.
    return items.map { trim($0) }.filter { !$0.isEmpty }.map(scalar)
}

private func unquote(_ text: Scalars) -> String {
    guard let quote = text.first, quote == "\"" || quote == "'" else { return string(text) }
    var body = Array(text.dropFirst())
    if body.last == quote {
        body.removeLast()
    }
    var result: Scalars = []
    var i = 0
    if quote == "'" {
        while i < body.count {
            result.append(body[i])
            i += body[i] == "'" && i + 1 < body.count && body[i + 1] == "'" ? 2 : 1
        }
        return string(result)
    }
    while i < body.count {
        let c = body[i]
        i += 1
        if c != "\\" {
            result.append(c)
            continue
        }
        guard i < body.count else {
            result.append("\\")
            break
        }
        let kind = body[i]
        i += 1
        switch kind {
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        case "0": result.append("\0")
        case "u", "x":
            let hex = Array(body[i..<min(i + (kind == "u" ? 4 : 2), body.count)])
            i += hex.count
            if let value = hexValue(hex), let c = Unicode.Scalar(value) {
                result.append(c)
            }
        default: result.append(kind)
        }
    }
    return string(result)
}

/// Rust's `u32::from_str_radix(_, 16)`: a `+` allowed before the digits.
private func hexValue(_ text: Scalars) -> UInt32? {
    var digits = text[...]
    if digits.first == "+" { digits = digits.dropFirst() }
    guard !digits.isEmpty else { return nil }
    var value: UInt32 = 0
    for c in digits {
        let digit: UInt32
        switch c {
        case "0"..."9": digit = c.value - 0x30
        case "a"..."f": digit = c.value - 0x61 + 10
        case "A"..."F": digit = c.value - 0x41 + 10
        default: return nil
        }
        value = value * 16 + digit
    }
    return value
}

// --- Writing -----------------------------------------------------------------

private func writeEntry(_ key: String, _ value: FrontValue, keepBlockList: Bool) -> [String] {
    let keyScalars = Array(key.unicodeScalars)
    let name = isPlain(keyScalars, inFlow: true) ? key : quote(keyScalars)
    switch value {
    case .text(let text):
        let scalars = Array(text.unicodeScalars)
        if scalars.contains("\n"), let block = blockLines(scalars) {
            return ["\(name): \(block.indicator)"] + block.lines
        }
        return ["\(name): \(scalarText(scalars, inFlow: false))"]
    case .list(let items) where items.isEmpty:
        return ["\(name): []"]
    case .list(let items):
        let flow = "[" + items.map { scalarText(Array($0.unicodeScalars), inFlow: true) }.joined(separator: ", ") + "]"
        // Short lists on one line; long ones an item a line, so that git
        // merges changes to different items.
        if !keepBlockList && items.count <= 4 && flow.unicodeScalars.count <= 60 {
            return ["\(name): \(flow)"]
        }
        return ["\(name):"] + items.map { "  - \(scalarText(Array($0.unicodeScalars), inFlow: false))" }
    }
}

private func blockLines(_ text: Scalars) -> (indicator: String, lines: [String])? {
    if text.contains("\r") || text.contains("\t") || text.first == " " || text.first == "\n" {
        return nil
    }
    var body = text[...]
    while body.last == "\n" { body = body.dropLast() }
    let trailing = text.count - body.count
    let indicator = trailing == 0 ? "|-" : trailing == 1 ? "|" : "|+"
    var lines = pieces(Array(body), "\n").map { $0.isEmpty ? "" : "  " + string($0) }
    lines += Array(repeating: "", count: max(trailing - 1, 0))
    return (indicator, lines)
}

private func scalarText(_ text: Scalars, inFlow: Bool) -> String {
    isPlain(text, inFlow: inFlow) ? string(text) : quote(text)
}

/// Whether text reads back as itself when written without quotes.
private func isPlain(_ text: Scalars, inFlow: Bool) -> Bool {
    guard let first = text.first, let last = text.last else { return false }
    if isWhitespace(first) || isWhitespace(last) || "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) {
        return false
    }
    if find(text, [":", " "]) != nil || find(text, [" ", "#"]) != nil || last == ":" {
        return false
    }
    if text.contains(where: { $0.properties.generalCategory == .control }) {
        return false
    }
    if inFlow && text.contains(where: { ",[]{}".unicodeScalars.contains($0) }) {
        return false
    }
    // `true`, `yes`, `4` are written plain: flags and numbers as YAML reads
    // them, and text here, which every value is.
    let lower = asciiLowercased(text)
    return lower != ["n", "u", "l", "l"] && lower != ["~"]
}

private func quote(_ text: Scalars) -> String {
    var result: Scalars = ["\""]
    for c in text {
        switch c {
        case "\"": result += ["\\", "\""]
        case "\\": result += ["\\", "\\"]
        case "\n": result += ["\\", "n"]
        case "\t": result += ["\\", "t"]
        case "\r": result += ["\\", "r"]
        case _ where c.value < 0x20:
            let hex = String(c.value, radix: 16)
            result += ["\\", "x"]
            result += (hex.count < 2 ? "0" + hex : hex).unicodeScalars
        default: result.append(c)
        }
    }
    result.append("\"")
    return string(result)
}
