import Foundation

/// Notes as data: a Swift port of prism's prism-markup, the engine under
/// Manifold's outliner. A note's body is read into a lossless tree of
/// blocks (`Markup.Document`), which an editing session (`Markup.Session`)
/// shows as rows and changes as a tree; writing it back gives the same
/// bytes for whatever was not edited.
///
/// Everything inside is the engine's own: only `NoteEditor` and its
/// records are what a view sees. Offsets inside are UTF-8 bytes, as the
/// Rust's are; `NoteEditor` gives UTF-16.
public enum Markup {}

/// UTF-8 bytes: what the engine scans and counts in.
typealias Bytes = [UInt8]

extension Array where Element == UInt8 {
    /// The bytes as a string.
    var string: String { String(decoding: self, as: UTF8.self) }

    func string(_ range: Range<Int>) -> String { String(decoding: self[range], as: UTF8.self) }

    func sub(_ range: Range<Int>) -> Bytes { Array(self[range]) }

    func sub(from start: Int) -> Bytes { start >= count ? [] : Array(self[start...]) }

    /// Whether an offset starts a character (or is the end).
    func isBoundary(_ at: Int) -> Bool { at <= 0 || at >= count || self[at] & 0xC0 != 0x80 }

    /// How many bytes the character at an offset takes (1 past the end).
    func charLen(at: Int) -> Int {
        guard at < count else { return 1 }
        let lead = self[at]
        if lead < 0x80 { return 1 }
        if lead >= 0xF0 { return Swift.min(4, count - at) }
        if lead >= 0xE0 { return Swift.min(3, count - at) }
        if lead >= 0xC0 { return Swift.min(2, count - at) }
        return 1
    }

    /// The character at an offset.
    func scalar(at: Int) -> Unicode.Scalar? {
        guard at >= 0, at < count else { return nil }
        let lead = UInt32(self[at])
        if lead < 0x80 { return Unicode.Scalar(lead) }
        let len = charLen(at: at)
        var value: UInt32
        switch len {
        case 2: value = lead & 0x1F
        case 3: value = lead & 0x0F
        case 4: value = lead & 0x07
        default: return Unicode.Scalar(lead)
        }
        for i in 1..<len { value = value << 6 | UInt32(self[at + i] & 0x3F) }
        return Unicode.Scalar(value)
    }

    /// The character that ends at an offset.
    func scalar(before at: Int) -> Unicode.Scalar? {
        guard at > 0, at <= count else { return nil }
        var start = at - 1
        while start > 0 && self[start] & 0xC0 == 0x80 { start -= 1 }
        return scalar(at: start)
    }

    /// The offset of the character that ends at an offset.
    func start(before at: Int) -> Int {
        var start = at - 1
        while start > 0 && self[start] & 0xC0 == 0x80 { start -= 1 }
        return Swift.max(start, 0)
    }

    /// Whether these bytes are at an offset.
    func has(_ needle: Bytes, at: Int) -> Bool {
        guard at >= 0, at + needle.count <= count else { return false }
        for i in 0..<needle.count where self[at + i] != needle[i] { return false }
        return true
    }

    /// Whether these bytes end at an offset.
    func has(_ needle: Bytes, endingAt end: Int) -> Bool { has(needle, at: end - needle.count) }

    func hasPrefix(_ needle: Bytes) -> Bool { has(needle, at: 0) }

    func hasSuffix(_ needle: Bytes) -> Bool { has(needle, at: count - needle.count) }

    /// The first offset of these bytes, within a range.
    func find(_ needle: Bytes, from start: Int = 0, to end: Int? = nil) -> Int? {
        let end = end ?? count
        guard !needle.isEmpty else { return start <= end ? start : nil }
        guard end - start >= needle.count else { return nil }
        let first = needle[0]
        var at = start
        while at + needle.count <= end {
            if self[at] == first && has(needle, at: at) { return at }
            at += 1
        }
        return nil
    }

    func find(byte: UInt8, from start: Int = 0, to end: Int? = nil) -> Int? {
        let end = Swift.min(end ?? count, count)
        var at = start
        while at < end {
            if self[at] == byte { return at }
            at += 1
        }
        return nil
    }

    /// The last offset of these bytes, within a range.
    func rfind(_ needle: Bytes, from start: Int = 0, to end: Int? = nil) -> Int? {
        let end = end ?? count
        guard end - start >= needle.count else { return nil }
        var at = end - needle.count
        while at >= start {
            if has(needle, at: at) { return at }
            at -= 1
        }
        return nil
    }

    func contains(_ needle: Bytes) -> Bool { find(needle) != nil }

    func occurrences(of needle: Bytes, from start: Int = 0, to end: Int? = nil) -> Int {
        var n = 0, at = start
        let end = end ?? count
        while let found = find(needle, from: at, to: end) { n += 1; at = found + Swift.max(needle.count, 1) }
        return n
    }

    /// The pieces between each `separator`: always one more than there are.
    func split(byte separator: UInt8) -> [Bytes] {
        var out: [Bytes] = []
        var start = 0
        for (i, b) in enumerated() where b == separator {
            out.append(Array(self[start..<i]))
            start = i + 1
        }
        out.append(Array(self[start...]))
        return out
    }

    /// Rust's `str::lines`: split at `\n`, a `\r` before it dropped, and no
    /// empty line after a last line break.
    var lines: [Bytes] {
        var pieces = split(byte: UInt8(ascii: "\n"))
        if pieces.last?.isEmpty == true { pieces.removeLast() }
        return pieces.map { $0.last == UInt8(ascii: "\r") ? Array($0.dropLast()) : $0 }
    }

    /// The range without the whitespace (Unicode's) at its ends.
    func trimmed(_ range: Range<Int>) -> Range<Int> {
        var (start, end) = (range.lowerBound, range.upperBound)
        while start < end, let c = scalar(at: start), c.properties.isWhitespace { start += charLen(at: start) }
        while end > start, let c = scalar(before: end), c.properties.isWhitespace { end = self.start(before: end) }
        return start..<end
    }

    var trimmed: Bytes { sub(trimmed(0..<count)) }

    var trimmedStart: Bytes {
        var start = 0
        while start < count, let c = scalar(at: start), c.properties.isWhitespace { start += charLen(at: start) }
        return sub(from: start)
    }

    var trimmedEnd: Bytes {
        var end = count
        while end > 0, let c = scalar(before: end), c.properties.isWhitespace { end = self.start(before: end) }
        return sub(0..<end)
    }

    /// Without these bytes at the start, however many.
    func trimmingStart(_ set: Bytes) -> Bytes {
        var start = 0
        while start < count && set.contains(self[start]) { start += 1 }
        return sub(from: start)
    }

    func trimmingEnd(_ set: Bytes) -> Bytes {
        var end = count
        while end > 0 && set.contains(self[end - 1]) { end -= 1 }
        return sub(0..<end)
    }

    /// How many of these bytes it starts with.
    func leading(_ byte: UInt8, from start: Int = 0) -> Int {
        var n = 0
        while start + n < count && self[start + n] == byte { n += 1 }
        return n
    }

    var isBlankWS: Bool { trimmed(0..<count).isEmpty }

    /// The characters, each with its offset.
    var scalars: [(Int, Unicode.Scalar)] {
        var out: [(Int, Unicode.Scalar)] = []
        var at = 0
        while at < count {
            if let c = scalar(at: at) { out.append((at, c)) }
            at += charLen(at: at)
        }
        return out
    }

    func replacing(_ old: Bytes, with new: Bytes) -> Bytes {
        guard !old.isEmpty, find(old) != nil else { return self }
        var out: Bytes = []
        out.reserveCapacity(count)
        var at = 0
        while let found = find(old, from: at) {
            out.append(contentsOf: self[at..<found])
            out.append(contentsOf: new)
            at = found + old.count
        }
        out.append(contentsOf: self[at...])
        return out
    }
}

extension UInt8 {
    static let newline = UInt8(ascii: "\n")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    var isAsciiDigit: Bool { self >= 0x30 && self <= 0x39 }
}

extension Unicode.Scalar {
    /// Rust's `char::is_whitespace`: Unicode's White_Space.
    var isWS: Bool { properties.isWhitespace }
    var isAlpha: Bool { properties.isAlphabetic }
    /// Rust's `char::is_alphanumeric`: alphabetic, or a number of any kind.
    var isAlnum: Bool {
        if properties.isAlphabetic { return true }
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
    var isAsciiPunct: Bool {
        let v = value
        return (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v)
    }
    var isAsciiDigit: Bool { value >= 0x30 && value <= 0x39 }
    var isAsciiAlpha: Bool { (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) }
    var isAsciiAlnum: Bool { isAsciiDigit || isAsciiAlpha }
    var utf8Len: Int { value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4 }
    var utf16Len: Int { value < 0x10000 ? 1 : 2 }
}

extension String {
    /// The bytes.
    var u8: Bytes { Array(utf8) }

    /// Without Unicode's whitespace at either end: Rust's `trim`.
    var trimmedWS: String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })!
        return String(scalars[first...last])
    }

    var isBlankWS: Bool { unicodeScalars.allSatisfy { $0.properties.isWhitespace } }

    /// Whether the bytes are the same: Swift's `==` takes canonically
    /// equivalent strings as one, and a file is its bytes.
    func same(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }

    /// The text of a range of the bytes.
    func bytes(_ range: Range<Int>) -> String { u8.string(range) }

    /// Rust's `split_whitespace`.
    var wordsWS: [String] {
        unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map { String($0) }
    }

    func containsScalar(_ c: Unicode.Scalar) -> Bool { unicodeScalars.contains(c) }
}
