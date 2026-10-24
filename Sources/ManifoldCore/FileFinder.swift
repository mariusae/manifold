import Foundation

/// Finding files to open by name: the files under a folder, and a fuzzy
/// match of what's typed against their paths.
public enum FileFinder {
    /// Folders never worth listing the insides of.
    static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", "target", "__pycache__"]

    /// The files under `root`, as paths relative to it: from git, when it's
    /// in a repository (tracked files and untracked ones not ignored); else
    /// found by looking, nearest first, skipping hidden and dependency
    /// folders, until there are `limit` of them.
    public static func list(root: String, limit: Int = 20_000) -> [String] {
        if let files = gitFiles(root: root, limit: limit) {
            return sorted(files)
        }
        return sorted(walk(root: root, limit: limit))
    }

    /// Nearest first, then by name.
    static func sorted(_ paths: [String]) -> [String] {
        let keyed: [(path: String, depth: Int)] = paths.map { ($0, $0.split(separator: "/").count) }
        let ordered = keyed.sorted { a, b in
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path.standardCompare(b.path)
        }
        return ordered.map(\.path)
    }

    static func gitFiles(root: String, limit: Int = .max) -> [String]? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return nil }
        // Deleted-but-tracked files are listed too; only what's there — and
        // only as many as are kept are looked for (a big checkout has more).
        let fm = FileManager.default
        var files: [String] = []
        for raw in data.split(separator: 0) {
            let path = String(decoding: raw, as: UTF8.self)
            if fm.fileExists(atPath: root.appendingPathComponent(path)) { files.append(path) }
            if files.count >= limit { break }
        }
        return files
    }

    static func walk(root: String, limit: Int) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var found: [String] = []
        var queue: [String] = [""]
        while !queue.isEmpty, found.count < limit {
            let rel = queue.removeFirst()
            let dir = rel.isEmpty ? root : root.appendingPathComponent(rel)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = rel.isEmpty ? name : rel + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.appendingPathComponent(name), isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let packaged = ["app", "bundle", "framework", "xcodeproj", "xcworkspace"].contains(name.pathExtension)
                    let homeLibrary = rel.isEmpty && name == "Library" && URL(fileURLWithPath: root).standardizedFileURL.path == home
                    if !skipped.contains(name) && !packaged && !homeLibrary { queue.append(path) }
                } else {
                    found.append(path)
                    if found.count >= limit { break }
                }
            }
        }
        return found
    }

    /// How well `query` matches `path` (higher is better), or nil when it
    /// doesn't: every letter of the query must appear in order. Matches in
    /// the file's name, in runs, and at the starts of words count for more,
    /// and shorter paths win ties. Spaces in the query are ignored.
    public static func score(_ query: String, _ path: String) -> Int? {
        if let ascii = asciiScore(query, path) { return ascii }
        return characterScore(query, path)
    }

    /// `score` by characters, for any text.
    static func characterScore(_ query: String, _ path: String) -> Int? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return 0 }
        let p = Array(path)
        let lower = Array(path.lowercased())
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
        // Without a slash in the query, try the name alone first.
        if !q.contains("/"), let s = match(q, lower, p, from: nameStart) {
            return 1000 + s - path.count / 4
        }
        guard let s = match(q, lower, p, from: 0) else { return nil }
        return s - path.count / 4
    }

    /// `score` over bytes, when the query and path are ASCII (as most
    /// are): the same answer without making arrays of characters of every
    /// path, which was most of a ranking's time. `.none` when either isn't.
    private static func asciiScore(_ query: String, _ path: String) -> Int?? {
        guard let q = asciiQuery(query) else { return .none }
        return asciiScore(q, path)
    }

    /// A query as `asciiScore` takes it — its bytes lowercased, spaces
    /// out — made once for many paths; nil if it isn't ASCII.
    public static func asciiQuery(_ query: String) -> [UInt8]? {
        var q: [UInt8] = []
        q.reserveCapacity(query.utf8.count)
        for b in query.utf8 {
            guard b < 0x80 else { return nil }
            if b != 0x20 { q.append(b >= 0x41 && b <= 0x5A ? b + 32 : b) }
        }
        return q
    }

    /// `score` for a query made by `asciiQuery`: `.none` if the path isn't
    /// ASCII.
    public static func asciiScore(_ q: [UInt8], _ path: String) -> Int?? {
        guard !q.isEmpty else { return .some(0) }
        let slash = q.contains(0x2F)
        return path.utf8.withContiguousStorageIfAvailable { p -> Int?? in
            var nameStart = 0
            for (i, b) in p.enumerated() {
                guard b < 0x80 else { return .none }
                if b == 0x2F { nameStart = i + 1 }
            }
            if !slash, let s = byteMatch(q, p, from: nameStart) { return .some(1000 + s - p.count / 4) }
            guard let s = byteMatch(q, p, from: 0) else { return .some(nil) }
            return .some(s - p.count / 4)
        } ?? .none
    }

    /// `match` over ASCII bytes, lowercasing as it goes.
    private static func byteMatch(_ q: [UInt8], _ p: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        @inline(__always) func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 32 : b }
        @inline(__always) func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
        @inline(__always) func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
        var score = 0, qi = 0, last = -2
        var i = start
        while i < p.count, qi < q.count {
            if lower(p[i]) == q[qi] {
                score += 10
                if i == last + 1 { score += 20 }
                if i == start { score += 25 }
                if i > 0 {
                    let before = p[i - 1]
                    // "/._- "
                    if before == 0x2F || before == 0x2E || before == 0x5F || before == 0x2D || before == 0x20 || (isLower(before) && isUpper(p[i])) { score += 12 }
                } else {
                    score += 12
                }
                if last >= 0 { score -= min(2 * (i - last - 1), 16) }
                last = i
                qi += 1
            }
            i += 1
        }
        return qi == q.count ? score : nil
    }

    /// Where a query's letters fall in a path (character offsets), as
    /// `score` matches them — in the name if they can be, else anywhere —
    /// for showing them; nil if they don't.
    public static func positions(_ query: String, _ path: String) -> [Int]? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return [] }
        let p = Array(path)
        let lower = Array(path.lowercased())
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
        // Unbroken in the name, if it's there so: that run.
        let name = Array(lower[nameStart...])
        if !q.contains("/"), q.count <= name.count {
            for i in 0...(name.count - q.count) where Array(name[i..<(i + q.count)]) == q {
                return Array((nameStart + i)..<(nameStart + i + q.count))
            }
        }
        var at: [Int] = []
        if !q.contains("/"), match(q, lower, p, from: nameStart, positions: &at) != nil { return at }
        at = []
        return match(q, lower, p, from: 0, positions: &at) != nil ? at : nil
    }

    private static func match(_ q: [Character], _ lower: [Character], _ p: [Character], from start: Int) -> Int? {
        var unused: [Int] = []
        return match(q, lower, p, from: start, positions: &unused)
    }

    /// Greedy subsequence match from `start`, scored; where each letter fell.
    private static func match(_ q: [Character], _ lower: [Character], _ p: [Character], from start: Int, positions: inout [Int]) -> Int? {
        var score = 0, qi = 0, last = -2
        var i = start
        while i < lower.count, qi < q.count {
            if lower[i] == q[qi] {
                score += 10
                if i == last + 1 { score += 20 }
                if i == start { score += 25 }
                if i > 0 {
                    let before = p[i - 1]
                    if "/._- ".contains(before) || (before.isLowercase && p[i].isUppercase) { score += 12 }
                } else {
                    score += 12
                }
                if last >= 0 { score -= min(2 * (i - last - 1), 16) }
                last = i
                positions.append(i)
                qi += 1
            }
            i += 1
        }
        return qi == q.count ? score : nil
    }

    /// How well a query names something: by its title first — the whole
    /// of it, the start of it, the start of a word in it, somewhere in it,
    /// its letters in order — and only then by what's around it (a path,
    /// a folder, a program), which counts for less. 0 for no match.
    public static func nameMatch(_ query: String, title: String, secondary: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 1 }
        let t = title.lowercased()
        if t == q { return 600 }
        if t.hasPrefix(q) { return 520 }
        let words = t.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 500 }
        // Every word of the query the start of a word in the title, in order.
        let qs = q.split(separator: " ")
        if qs.count > 1 {
            var i = 0
            var all = true
            for w in qs {
                guard let j = words[i...].firstIndex(where: { $0.hasPrefix(w) }) else { all = false; break }
                i = j + 1
            }
            if all { return 480 }
        }
        if t.contains(q) { return 400 }
        if let f = score(q, title) { return 200 + min(f, 150) / 2 }
        if let f = score(q, secondary) { return 100 + min(f, 150) / 3 }
        return 0
    }


    /// The paths matching a query, best first.
    public static func rank(_ query: String, _ paths: [String], limit: Int = 500) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(paths.prefix(limit)) }
        return paths.compactMap { p in score(q, p).map { (p, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }
            .prefix(limit).map(\.0)
    }
}

/// A place in a file, as grep, compilers, and the like print one:
/// `path:line`, `path:line:column`, often with a colon after.
public struct FileLocation: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// Splits off a trailing line and column; nil when there are none.
    public static func split(_ text: String) -> FileLocation? {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let n = Int(parts.last!), n > 0 {
            numbers.insert(n, at: 0)
            parts.removeLast()
        }
        guard !numbers.isEmpty else { return nil }
        let path = parts.joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return FileLocation(path: path, line: numbers[0], column: numbers.count > 1 ? numbers[1] : nil)
    }
}
