import Foundation

/// A difference between two sequences of lines, as hunks: a run of lines
/// in the old text replaced by a run in the new (either may be empty).
public struct DiffHunk: Equatable, Sendable {
    /// Lines from 0 in the old text; `oldCount` may be 0 (an insertion).
    public var oldStart: Int
    public var oldCount: Int
    /// Lines from 0 in the new text; `newCount` may be 0 (a deletion).
    public var newStart: Int
    public var newCount: Int

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }
}

/// Lines compared with Myers' algorithm (the plain O(ND) one, enough for
/// files edited by hand), the common prefix and suffix taken off first.
public enum LineDiff {
    public static func lines(_ text: String) -> [Substring] {
        var out = text.split(separator: "\n", omittingEmptySubsequences: false)
        if out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    public static func hunks(old: String, new: String) -> [DiffHunk] {
        hunks(old: lines(old), new: lines(new))
    }

    public static func hunks(old a: [Substring], new b: [Substring]) -> [DiffHunk] {
        // Hash the lines once; equal hashes are checked against the text.
        let ah = a.map { $0.hashValue }, bh = b.map { $0.hashValue }
        func same(_ i: Int, _ j: Int) -> Bool { ah[i] == bh[j] && a[i] == b[j] }
        var start = 0
        while start < a.count, start < b.count, same(start, start) { start += 1 }
        var aEnd = a.count, bEnd = b.count
        while aEnd > start, bEnd > start, same(aEnd - 1, bEnd - 1) { aEnd -= 1; bEnd -= 1 }
        let n = aEnd - start, m = bEnd - start
        if n == 0 && m == 0 { return [] }
        if n == 0 || m == 0 { return [DiffHunk(oldStart: start, oldCount: n, newStart: start, newCount: m)] }

        // Myers: the edit script as a list of (x, y) moves, from the trace.
        let max = n + m
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...max {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[max + k - 1] < v[max + k + 1]) {
                    x = v[max + k + 1]
                } else {
                    x = v[max + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, same(start + x, start + y) { x += 1; y += 1 }
                v[max + k] = x
                if x >= n, y >= m { found = true; break outer }
                k += 2
            }
            // Too far apart to be worth a fine diff: one hunk.
            if d > 2000 { break }
        }
        guard found else { return [DiffHunk(oldStart: start, oldCount: n, newStart: start, newCount: m)] }

        // Walk the trace back, collecting the moves.
        var x = n, y = m
        var ops: [(Int, Int, Bool)] = []  // (x, y, isDeletion) for each non-diagonal step
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[max + k - 1] < v[max + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = v[max + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY { x -= 1; y -= 1 }
            if d > 0 {
                if x == prevX { ops.append((prevX, prevY, false)) } else { ops.append((prevX, prevY, true)) }
            }
            x = prevX
            y = prevY
        }
        ops.reverse()

        // Adjacent operations become hunks.
        var hunks: [DiffHunk] = []
        var i = 0
        while i < ops.count {
            let (ox, oy, del) = ops[i]
            var h = DiffHunk(oldStart: start + ox, oldCount: del ? 1 : 0, newStart: start + oy, newCount: del ? 0 : 1)
            var j = i + 1
            while j < ops.count {
                let (nx, ny, nd) = ops[j]
                // Continues the hunk if it starts where the hunk ends so far.
                guard start + nx == h.oldStart + h.oldCount, start + ny == h.newStart + h.newCount else { break }
                if nd { h.oldCount += 1 } else { h.newCount += 1 }
                j += 1
            }
            hunks.append(h)
            i = j
        }
        return hunks
    }
}

/// A mark in the editor's gutter: how a line stands against the committed
/// text.
public struct GutterMark: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, modified, deleted }
    /// The line from 0 in the current text; for `deleted`, the line after
    /// the gap.
    public var line: Int
    public var count: Int
    public var kind: Kind

    public init(line: Int, count: Int, kind: Kind) {
        self.line = line
        self.count = count
        self.kind = kind
    }

    public static func marks(_ hunks: [DiffHunk]) -> [GutterMark] {
        hunks.map { h in
            if h.newCount == 0 { return GutterMark(line: h.newStart, count: 0, kind: .deleted) }
            return GutterMark(line: h.newStart, count: h.newCount, kind: h.oldCount == 0 ? .added : .modified)
        }
    }
}

/// A diff as it's shown: rows of context, additions and removals with
/// line numbers on each side, under file headers, with long stretches of
/// context folded. Made from two texts, or from a unified patch as git
/// prints one.
public struct DiffRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case file(String), hunk, context, added, removed, fold(Int) }
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String

    public init(kind: Kind, oldLine: Int? = nil, newLine: Int? = nil, text: String = "") {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

public enum DiffRows {
    /// Rows for two texts, `context` lines kept around each change; the
    /// rest folded unless `unfolded`.
    public static func sides(old: String, new: String, context: Int = 3, unfolded: Bool = false) -> [DiffRow] {
        let a = LineDiff.lines(old), b = LineDiff.lines(new)
        let hunks = LineDiff.hunks(old: a, new: b)
        var rows: [DiffRow] = []
        var ai = 0, bi = 0
        func emitContext(_ count: Int) {
            for _ in 0..<count {
                rows.append(DiffRow(kind: .context, oldLine: ai + 1, newLine: bi + 1, text: String(a[ai])))
                ai += 1; bi += 1
            }
        }
        for h in hunks {
            let gap = h.oldStart - ai
            if unfolded || gap <= 2 * context + 1 {
                emitContext(gap)
            } else {
                let before = rows.isEmpty ? 0 : context
                emitContext(before)
                let folded = gap - before - context
                rows.append(DiffRow(kind: .fold(folded), oldLine: ai + 1, newLine: bi + 1))
                ai += folded; bi += folded
                emitContext(context)
            }
            rows.append(DiffRow(kind: .hunk, oldLine: h.oldStart + 1, newLine: h.newStart + 1))
            for i in 0..<h.oldCount { rows.append(DiffRow(kind: .removed, oldLine: h.oldStart + i + 1, text: String(a[h.oldStart + i]))) }
            for i in 0..<h.newCount { rows.append(DiffRow(kind: .added, newLine: h.newStart + i + 1, text: String(b[h.newStart + i]))) }
            ai = h.oldStart + h.oldCount
            bi = h.newStart + h.newCount
        }
        let tail = a.count - ai
        if unfolded || tail <= context {
            emitContext(tail)
        } else {
            emitContext(context)
            rows.append(DiffRow(kind: .fold(a.count - ai), oldLine: ai + 1, newLine: bi + 1))
        }
        return rows
    }

    /// Rows for a unified patch (`git show`, `git diff`): what git chose to
    /// show, file by file.
    public static func patch(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine = 0, newLine = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                inHunk = false
                // "diff --git a/x b/x": the new side's name.
                let parts = line.dropFirst(11).split(separator: " ")
                let name = parts.last.map { $0.hasPrefix("b/") ? String($0.dropFirst(2)) : String($0) } ?? ""
                rows.append(DiffRow(kind: .file(name)))
            } else if line.hasPrefix("@@") {
                inHunk = true
                // "@@ -a,b +c,d @@ heading"
                let fields = line.split(separator: " ")
                if fields.count >= 3 {
                    oldLine = Int(fields[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
                    newLine = Int(fields[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                let heading = line.range(of: "@@", options: .backwards).map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                rows.append(DiffRow(kind: .hunk, oldLine: oldLine, newLine: newLine, text: heading))
            } else if inHunk, line.hasPrefix("+") {
                rows.append(DiffRow(kind: .added, newLine: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if inHunk, line.hasPrefix("-") {
                rows.append(DiffRow(kind: .removed, oldLine: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else if inHunk, line.hasPrefix(" ") || line.isEmpty {
                guard !(line.isEmpty && raw == text.split(separator: "\n", omittingEmptySubsequences: false).last) else { continue }
                rows.append(DiffRow(kind: .context, oldLine: oldLine, newLine: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            } else if inHunk, line.hasPrefix("\\") {
                continue  // "\ No newline at end of file"
            } else if !inHunk, rows.isEmpty || !line.isEmpty, !line.hasPrefix("index "), !line.hasPrefix("--- "), !line.hasPrefix("+++ "),
                      !line.hasPrefix("new file"), !line.hasPrefix("deleted file"), !line.hasPrefix("similarity"), !line.hasPrefix("rename"),
                      !line.hasPrefix("old mode"), !line.hasPrefix("new mode") {
                // The commit's heading, before the first file.
                if case .file = rows.last?.kind { continue }
                rows.append(DiffRow(kind: .context, text: line))
            }
        }
        return rows
    }
}
