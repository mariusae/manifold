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
        if let files = gitFiles(root: root) {
            return sorted(Array(files.prefix(limit)))
        }
        return sorted(walk(root: root, limit: limit))
    }

    /// Nearest first, then by name.
    static func sorted(_ paths: [String]) -> [String] {
        let keyed: [(path: String, depth: Int)] = paths.map { ($0, $0.split(separator: "/").count) }
        let ordered = keyed.sorted { a, b in
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        return ordered.map(\.path)
    }

    static func gitFiles(root: String) -> [String]? {
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
        let files = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        // Deleted-but-tracked files are listed too; only what's there.
        let fm = FileManager.default
        return files.filter { fm.fileExists(atPath: (root as NSString).appendingPathComponent($0)) }
    }

    static func walk(root: String, limit: Int) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var found: [String] = []
        var queue: [String] = [""]
        while !queue.isEmpty, found.count < limit {
            let rel = queue.removeFirst()
            let dir = rel.isEmpty ? root : (root as NSString).appendingPathComponent(rel)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = rel.isEmpty ? name : rel + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let packaged = ["app", "bundle", "framework", "xcodeproj", "xcworkspace"].contains((name as NSString).pathExtension)
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

    /// Greedy subsequence match from `start`, scored.
    private static func match(_ q: [Character], _ lower: [Character], _ p: [Character], from start: Int) -> Int? {
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
                qi += 1
            }
            i += 1
        }
        return qi == q.count ? score : nil
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
