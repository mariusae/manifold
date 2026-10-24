import Foundation

/// A range of text, in UTF-8 byte offsets.
public struct TextRange: Hashable, Codable, Sendable, Comparable {
    public var start: Int
    public var end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public init(at offset: Int) { self.init(offset, offset) }

    public var isEmpty: Bool { start == end }
    public var length: Int { end - start }
    public var range: Range<Int> { start..<end }

    public func contains(_ offset: Int) -> Bool { offset >= start && offset < end }
    public func clamped(to limit: Int) -> TextRange { TextRange(min(start, limit), min(end, limit)) }

    public static func < (a: TextRange, b: TextRange) -> Bool {
        a.start != b.start ? a.start < b.start : a.end < b.end
    }
}

/// A change to text: `text` put in place of the bytes `start..<end`.
public struct TextEdit: Hashable, Codable, Sendable {
    public var start: Int
    public var end: Int
    public var text: String

    public init(_ range: TextRange, _ text: String) {
        start = range.start
        end = range.end
        self.text = text
    }

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var range: TextRange { TextRange(start, end) }
    public static func insert(_ text: String, at offset: Int) -> TextEdit { TextEdit(start: offset, end: offset, text: text) }
    public static func delete(_ range: TextRange) -> TextEdit { TextEdit(range, "") }
}

/// Text held as UTF-8 in chunks of a few kilobytes, each with its count of
/// UTF-16 units and line breaks, and running totals over the chunks, so
/// that editing anywhere, finding a line, and converting offsets for
/// AppKit are all cheap on texts of many megabytes.
///
/// Offsets are UTF-8 byte offsets, always at character boundaries. Line
/// endings are `\n`.
public struct Rope: Equatable, Sendable, CustomStringConvertible {
    struct Chunk: Equatable {
        var bytes: [UInt8]
        var utf16: Int
        var lines: Int

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            utf16 = Rope.utf16Count(bytes)
            lines = bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
    }

    static let maxChunk = 4096
    static let mergeBelow = 1536

    private var chunks: [Chunk] = []
    /// Running totals: `prefix[i]` is the sum over chunks before `i`.
    private var byteStarts: [Int] = [0]
    private var utf16Starts: [Int] = [0]
    private var lineStarts: [Int] = [0]

    public init() {}

    public init(_ string: String) {
        let bytes = Array(string.utf8)
        var i = 0
        while i < bytes.count {
            var end = min(i + Self.maxChunk, bytes.count)
            while end < bytes.count, Self.isContinuation(bytes[end]) { end -= 1 }
            chunks.append(Chunk(Array(bytes[i..<end])))
            i = end
        }
        reindex()
    }

    // MARK: Counts

    public var count: Int { byteStarts[chunks.count] }
    public var utf16Count: Int { utf16Starts[chunks.count] }
    /// Lines, as a text editor counts them: one more than the line breaks.
    public var lineCount: Int { lineStarts[chunks.count] + 1 }
    public var isEmpty: Bool { count == 0 }

    public var string: String {
        var out = [UInt8]()
        out.reserveCapacity(count)
        for c in chunks { out.append(contentsOf: c.bytes) }
        return String(decoding: out, as: UTF8.self)
    }

    public var description: String { string }

    // MARK: Reading

    public func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        let (c, i) = locate(offset)
        return chunks[c].bytes[i]
    }

    public subscript(range: TextRange) -> String {
        String(decoding: bytes(in: range), as: UTF8.self)
    }

    public func bytes(in range: TextRange) -> [UInt8] {
        let r = range.clamped(to: count)
        guard !r.isEmpty else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(r.length)
        var (c, i) = locate(r.start)
        var remaining = r.length
        while remaining > 0, c < chunks.count {
            let take = min(remaining, chunks[c].bytes.count - i)
            out.append(contentsOf: chunks[c].bytes[i..<i + take])
            remaining -= take
            c += 1
            i = 0
        }
        return out
    }

    /// The byte at `offset` begins a character (or is the end).
    public func isBoundary(_ offset: Int) -> Bool {
        guard offset > 0, offset < count else { return true }
        return !Self.isContinuation(byte(at: offset)!)
    }

    /// The nearest character boundary at or before `offset`.
    public func floorBoundary(_ offset: Int) -> Int {
        var o = min(max(offset, 0), count)
        while !isBoundary(o) { o -= 1 }
        return o
    }

    public func ceilBoundary(_ offset: Int) -> Int {
        var o = min(max(offset, 0), count)
        while !isBoundary(o) { o += 1 }
        return o
    }

    /// The character boundary after `offset`, or `count`.
    public func next(_ offset: Int) -> Int {
        guard offset < count else { return count }
        return ceilBoundary(offset + 1)
    }

    public func previous(_ offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        return floorBoundary(offset - 1)
    }

    // MARK: Lines

    /// The line (from 0) holding `offset`.
    public func line(at offset: Int) -> Int {
        let o = min(max(offset, 0), count)
        guard !chunks.isEmpty else { return 0 }
        let (c, i) = locate(o)
        var n = lineStarts[c]
        let bytes = chunks[c].bytes
        var k = 0
        while k < i { if bytes[k] == 0x0A { n += 1 }; k += 1 }
        return n
    }

    /// Where line `n` (from 0) begins; past the last line, `count`.
    public func offset(ofLine n: Int) -> Int {
        guard n > 0 else { return 0 }
        guard n < lineCount else { return count }
        // The chunk in which the n-th line break falls.
        var lo = 0, hi = chunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid + 1] < n { lo = mid + 1 } else { hi = mid }
        }
        let c = lo
        var seen = lineStarts[c]
        let bytes = chunks[c].bytes
        for (k, b) in bytes.enumerated() where b == 0x0A {
            seen += 1
            if seen == n { return byteStarts[c] + k + 1 }
        }
        return count
    }

    /// Line `n`'s bytes, without its line break.
    public func lineRange(_ n: Int) -> TextRange {
        let start = offset(ofLine: n)
        var end = n + 1 < lineCount ? offset(ofLine: n + 1) : count
        if end > start, byte(at: end - 1) == 0x0A { end -= 1 }
        return TextRange(start, end)
    }

    public func lineText(_ n: Int) -> String { self[lineRange(n)] }

    /// Every line's length in bytes (its break not counted), in one pass.
    public func lineLengths() -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(lineCount)
        var run = 0
        for c in chunks {
            c.bytes.withUnsafeBufferPointer { p in
                var start = 0
                while start < p.count, let nl = memchr(p.baseAddress! + start, 0x0A, p.count - start) {
                    let k = p.baseAddress!.distance(to: nl.assumingMemoryBound(to: UInt8.self))
                    out.append(run + k - start)
                    run = 0
                    start = k + 1
                }
                run += p.count - start
            }
        }
        out.append(run)
        return out
    }

    // MARK: UTF-16

    public func utf16Offset(ofByte offset: Int) -> Int {
        let o = min(max(offset, 0), count)
        guard !chunks.isEmpty else { return 0 }
        let (c, i) = locate(o)
        return utf16Starts[c] + Self.utf16Count(chunks[c].bytes[0..<i])
    }

    public func byteOffset(ofUTF16 u: Int) -> Int {
        let target = min(max(u, 0), utf16Count)
        guard !chunks.isEmpty else { return 0 }
        var lo = 0, hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if utf16Starts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        let c = lo
        var units = utf16Starts[c]
        let bytes = chunks[c].bytes
        var k = 0
        while k < bytes.count {
            let b = bytes[k]
            if !Self.isContinuation(b) {
                if units >= target { return byteStarts[c] + k }
                units += b >= 0xF0 ? 2 : 1
            }
            k += 1
        }
        return byteStarts[c] + bytes.count
    }

    // MARK: Editing

    public mutating func replace(_ range: TextRange, with text: String) {
        let r = TextRange(floorBoundary(range.start), floorBoundary(range.end)).clamped(to: count)
        if !r.isEmpty { delete(r) }
        if !text.isEmpty { insert(Array(text.utf8), at: r.start) }
    }

    public mutating func apply(_ edit: TextEdit) { replace(edit.range, with: edit.text) }

    private mutating func insert(_ bytes: [UInt8], at offset: Int) {
        // Into nothing: the text is the bytes, chunked, and indexed afresh.
        if chunks.isEmpty {
            chunks = Self.split(bytes)
            reindex()
            return
        }
        let (c, i) = locateForInsert(offset)
        var merged = chunks[c].bytes
        merged.insert(contentsOf: bytes, at: i)
        chunks.replaceSubrange(c...c, with: Self.split(merged))
        reindex()
    }

    private mutating func delete(_ range: TextRange) {
        let (c0, i0) = locate(range.start)
        let (c1raw, i1raw) = locate(range.end)
        var c1 = c1raw, i1 = i1raw
        if c1 >= chunks.count { c1 = chunks.count - 1; i1 = chunks[c1].bytes.count }
        if c0 == c1 {
            chunks[c0].bytes.removeSubrange(i0..<i1)
        } else {
            var merged = Array(chunks[c0].bytes[0..<i0])
            merged.append(contentsOf: chunks[c1].bytes[i1...])
            chunks.replaceSubrange(c0...c1, with: [Chunk(merged)])
        }
        chunks[c0] = Chunk(chunks[c0].bytes)
        // Small neighbours join up, so a text edited down stays compact.
        if c0 + 1 < chunks.count, chunks[c0].bytes.count + chunks[c0 + 1].bytes.count < Self.mergeBelow {
            let joined = chunks[c0].bytes + chunks[c0 + 1].bytes
            chunks.replaceSubrange(c0...c0 + 1, with: [Chunk(joined)])
        }
        if chunks[c0].bytes.isEmpty, chunks.count > 1 { chunks.remove(at: c0) }
        reindex()
    }

    // MARK: Internals

    private static func split(_ bytes: [UInt8]) -> [Chunk] {
        guard bytes.count > maxChunk else { return [Chunk(bytes)] }
        var out: [Chunk] = []
        var i = 0
        let target = max(maxChunk / 2, (bytes.count + (bytes.count / maxChunk)) / (bytes.count / maxChunk + 1))
        while i < bytes.count {
            var end = min(i + target, bytes.count)
            while end < bytes.count, isContinuation(bytes[end]) { end -= 1 }
            if end <= i { end = min(i + target, bytes.count) }
            out.append(Chunk(Array(bytes[i..<end])))
            i = end
        }
        return out
    }

    private mutating func reindex() {
        byteStarts = [0]
        utf16Starts = [0]
        lineStarts = [0]
        byteStarts.reserveCapacity(chunks.count + 1)
        var b = 0, u = 0, l = 0
        for c in chunks {
            b += c.bytes.count
            u += c.utf16
            l += c.lines
            byteStarts.append(b)
            utf16Starts.append(u)
            lineStarts.append(l)
        }
    }

    /// The chunk holding byte `offset`, and the index within it; at the very
    /// end, the last chunk and its count.
    private func locate(_ offset: Int) -> (Int, Int) {
        guard !chunks.isEmpty else { return (0, 0) }
        let o = min(max(offset, 0), count)
        var lo = 0, hi = chunks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if byteStarts[mid] <= o { lo = mid } else { hi = mid - 1 }
        }
        if o == count { return (chunks.count - 1, chunks[chunks.count - 1].bytes.count) }
        return (lo, o - byteStarts[lo])
    }

    private func locateForInsert(_ offset: Int) -> (Int, Int) { locate(offset) }

    static func isContinuation(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }

    static func utf16Count<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 {
        var n = 0
        for b in bytes where !isContinuation(b) { n += b >= 0xF0 ? 2 : 1 }
        return n
    }

    public static func == (a: Rope, b: Rope) -> Bool {
        a.count == b.count && a.string == b.string
    }
}

extension Rope: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

extension Rope {
    /// Finds `needle` from `offset` on (or back from it), as bytes.
    public func find(_ needle: String, from offset: Int, backwards: Bool = false, caseInsensitive: Bool = false) -> TextRange? {
        let hay = caseInsensitive ? string.lowercased() : string
        let n = caseInsensitive ? needle.lowercased() : needle
        guard !n.isEmpty else { return nil }
        let hb = Array(hay.utf8), nb = Array(n.utf8)
        guard hb.count >= nb.count else { return nil }
        func match(_ i: Int) -> Bool {
            var k = 0
            while k < nb.count { if hb[i + k] != nb[k] { return false }; k += 1 }
            return true
        }
        if backwards {
            var i = min(offset, hb.count - nb.count)
            while i >= 0 { if match(i) { return TextRange(i, i + nb.count) }; i -= 1 }
        } else {
            var i = max(0, offset)
            while i + nb.count <= hb.count { if match(i) { return TextRange(i, i + nb.count) }; i += 1 }
        }
        return nil
    }

    /// Every match, in order: the text read once, not again for each
    /// match (which made finding in a big file quadratic).
    public func findAll(_ needle: String, caseInsensitive: Bool = false, limit: Int = 100_000) -> [TextRange] {
        let hay = Array((caseInsensitive ? string.lowercased() : string).utf8)
        let nb = Array((caseInsensitive ? needle.lowercased() : needle).utf8)
        guard !nb.isEmpty, hay.count >= nb.count else { return [] }
        var out: [TextRange] = []
        hay.withUnsafeBytes { h in
            nb.withUnsafeBytes { n in
                guard let base = h.baseAddress, let nbase = n.baseAddress else { return }
                var at = 0
                while out.count < limit, at <= hay.count - nb.count, let p = memmem(base + at, hay.count - at, nbase, nb.count) {
                    let i = base.distance(to: UnsafeRawPointer(p))
                    out.append(TextRange(i, i + nb.count))
                    at = i + nb.count
                }
            }
        }
        return out
    }
}
