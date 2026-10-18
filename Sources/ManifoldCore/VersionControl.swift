import Foundation

/// The version control systems a git block speaks for: git, and Sapling
/// (`sl`), which keeps no index and names commits by bookmark. Which one
/// a path is under is told by the nearest `.sl` or `.git` up from it;
/// `.sl` wins where both are there (Sapling over a git repository).
public enum VCS: String, Codable, Sendable {
    case git, sapling

    public var command: String { self == .git ? "git" : "sl" }

    /// The file whose change means the repository's state did.
    public var stateFile: String { self == .git ? ".git/index" : ".sl/dirstate" }

    /// What the committed version of a file is called: HEAD, or the
    /// working copy's parent.
    public var headName: String { self == .git ? "HEAD" : "." }

    /// The repository holding a path, by walking up for `.sl` or `.git`.
    public static func repository(of path: String) -> (root: String, vcs: VCS)? {
        var dir = path
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) {
            dir = path.deletingLastPathComponent
        }
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".sl")) { return (dir, .sapling) }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git")) { return (dir, .git) }
            dir = dir.deletingLastPathComponent
        }
        return nil
    }

    // MARK: Commands

    /// Arguments after the command for the status listing.
    public var statusArguments: [String] {
        switch self {
        case .git: ["status", "--porcelain=v1", "-z", "-b"]
        case .sapling: ["status", "--root-relative"]
        }
    }

    /// Where the working copy is: git's branch line comes with the status;
    /// Sapling is asked for the active bookmark and the commit, and for
    /// how many commits are still local (draft).
    public var whereArguments: [String]? {
        switch self {
        case .git: nil
        case .sapling: ["log", "-r", ".", "-T", "{activebookmark}\\n{node|short}\\n"]
        }
    }

    public var aheadArguments: [String]? {
        switch self {
        case .git: nil
        case .sapling: ["log", "-r", "draft() & ::.", "-T", "x\\n"]
        }
    }

    public static let gitLogFormat = "%H%x1f%h%x1f%an%x1f%at%x1f%s"
    public static let saplingLogTemplate = "{node}\\x1f{node|short}\\x1f{author}\\x1f{date|hgdate}\\x1f{desc|firstline}\\n"

    public func logArguments(limit: Int) -> [String] {
        switch self {
        case .git: ["log", "-n", "\(limit)", "--format=\(Self.gitLogFormat)"]
        case .sapling: ["log", "-l", "\(limit)", "-T", Self.saplingLogTemplate]
        }
    }

    /// A file as a revision has it (`HEAD` means the committed version).
    public func catArguments(path relative: String, revision: String) -> [String] {
        switch self {
        case .git: ["show", "\(revision):\(relative)"]
        case .sapling: revision == "HEAD" ? ["cat", relative] : ["cat", "-r", revision, relative]
        }
    }

    /// A commit as a patch with `diff --git` headers.
    public func showArguments(_ sha: String) -> [String] {
        switch self {
        case .git: ["show", "--no-color", "--format=medium", sha]
        case .sapling: ["--color", "never", "show", "--git", sha]
        }
    }

    // MARK: Parsing

    /// `git status --porcelain=v1 -z -b`, or `sl status`.
    public func parseStatus(_ out: String) -> (branch: String?, ahead: Int, behind: Int, entries: [GitStatusEntry]) {
        switch self {
        case .git: return Self.parseGitStatus(out)
        case .sapling: return (nil, 0, 0, Self.parseSaplingStatus(out))
        }
    }

    static func parseGitStatus(_ out: String) -> (branch: String?, ahead: Int, behind: Int, entries: [GitStatusEntry]) {
        var branch: String?
        var ahead = 0, behind = 0
        var entries: [GitStatusEntry] = []
        let records = out.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0
        while i < records.count {
            let r = records[i]
            i += 1
            if r.hasPrefix("## ") {
                // "## main...origin/main [ahead 1, behind 2]" or "## HEAD (no branch)"
                var head = String(r.dropFirst(3))
                if let b = head.range(of: " [") {
                    let flags = head[b.upperBound...].dropLast()
                    for f in flags.split(separator: ",") {
                        let t = f.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("ahead ") { ahead = Int(t.dropFirst(6)) ?? 0 }
                        if t.hasPrefix("behind ") { behind = Int(t.dropFirst(7)) ?? 0 }
                    }
                    head = String(head[..<b.lowerBound])
                }
                if let dots = head.range(of: "...") { head = String(head[..<dots.lowerBound]) }
                branch = head
                continue
            }
            guard r.count >= 4 else { continue }
            let x = String(r[r.startIndex]), y = String(r[r.index(after: r.startIndex)])
            var path = String(r.dropFirst(3))
            // Renames carry the old name in the next record.
            if x == "R" || x == "C", i < records.count { i += 1 }
            if path.hasSuffix("/") { path.removeLast() }
            entries.append(GitStatusEntry(path: path, index: x, workTree: y))
        }
        return (branch, ahead, behind, entries)
    }

    /// `sl status`: a letter, a space, the path: M A R ! for tracked
    /// changes (no index: they go in the work tree column), ? untracked.
    static func parseSaplingStatus(_ out: String) -> [GitStatusEntry] {
        out.split(separator: "\n").compactMap { line in
            guard line.count >= 3, line[line.index(after: line.startIndex)] == " " else { return nil }
            let letter = String(line[line.startIndex])
            let path = String(line.dropFirst(2))
            guard ["M", "A", "R", "!", "?", "C", "I"].contains(letter), !path.isEmpty else { return nil }
            if letter == "?" { return GitStatusEntry(path: path, index: "?", workTree: "?") }
            return GitStatusEntry(path: path, index: " ", workTree: letter)
        }
    }

    /// `sl log -r . -T "{activebookmark}\n{node|short}\n"`: the bookmark, or
    /// the commit.
    public static func parseSaplingWhere(_ out: String) -> String? {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if let b = lines.first, !b.isEmpty { return b }
        if lines.count > 1, !lines[1].isEmpty { return lines[1] }
        return nil
    }

    public func parseLog(_ out: String) -> [GitCommit] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            var author = String(f[2])
            var date = Double(f[3]) ?? 0
            if self == .sapling {
                // "Name <email>" and "unixtime offset".
                if let lt = author.firstIndex(of: "<") { author = String(author[..<lt]).trimmingCharacters(in: .whitespaces) }
                date = Double(f[3].split(separator: " ").first ?? "") ?? 0
            }
            return GitCommit(sha: String(f[0]), short: String(f[1]), author: author, date: date, summary: String(f[4]))
        }
    }
}
