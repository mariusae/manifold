import Foundation

/// A file's history as its version control has it: the commits that
/// changed it, newest first (renames followed); the file as one of them
/// left it; and each line's commit (blame) as of one of them, or now.
public enum FileHistoryRequest: Codable, Sendable {
    /// The commits that changed the file at `path` (absolute), `skip` of
    /// the newest passed over, `limit` at most.
    case log(path: String, skip: Int, limit: Int)
    /// The file as `revision` left it; `path` as it was named then
    /// (repository-relative, as the log says), in the repository of `file`.
    case text(file: String, path: String, revision: String)
    /// Each line's commit as of `revision` (the file named `path` then):
    /// for now, the last commit's, carried onto the text as it is by a
    /// line diff (what differs isn't committed) — the same for git and
    /// Sapling, and for edits not saved.
    case blame(file: String, path: String, revision: String)
}

public enum FileHistoryResult: Codable, Sendable {
    /// Not in a repository: Manifold's own history is all there is.
    case untracked
    case log(root: String, vcs: VCS, revisions: [FileRevision], more: Bool)
    case text(String)
    case blame(BlameLines)
    case error(String)
}

/// A commit that changed a file.
public struct FileRevision: Codable, Sendable, Equatable, Hashable {
    public var sha: String
    public var author: String
    /// Seconds since 1970.
    public var at: Double
    public var summary: String
    /// The file's name in it, repository-relative (it may have been renamed since).
    public var path: String

    public init(sha: String, author: String, at: Double, summary: String, path: String) {
        self.sha = sha
        self.author = author
        self.at = at
        self.summary = summary
        self.path = path
    }

    public var short: String { String(sha.prefix(8)) }
}

/// Each line's commit: the commits, and for every line the index of its
/// commit among them (-1: not committed).
public struct BlameLines: Codable, Sendable, Equatable {
    public struct Commit: Codable, Sendable, Equatable {
        public var sha: String
        public var author: String
        public var at: Double
        public var summary: String
        public init(sha: String, author: String, at: Double, summary: String) {
            self.sha = sha
            self.author = author
            self.at = at
            self.summary = summary
        }
    }
    public var commits: [Commit]
    public var lines: [Int]

    public init(commits: [Commit] = [], lines: [Int] = []) {
        self.commits = commits
        self.lines = lines
    }
}

public enum FileHistory {
    static let record = "\u{1e}", field = "\u{1f}"

    /// The log's arguments: newest first, renames followed, each commit's
    /// name for the file. (Sapling has no skip: it's asked for as many as
    /// skipped and wanted, and the first passed over.)
    public static func logArguments(_ vcs: VCS, path: String, skip: Int, limit: Int) -> [String] {
        switch vcs {
        case .git:
            return ["log", "--no-color", "--follow", "--name-only", "--skip=\(skip)", "--max-count=\(limit)",
                    "--format=\(record)%H\(field)%an\(field)%at\(field)%s", "--", path]
        case .sapling:
            return ["log", "--follow", "--limit", "\(skip + limit)",
                    "-T", "\(record){node}\(field){author|person}\(field){date|hgdate}\(field){desc|firstline}\(field){files % '{file}\\n'}", path]
        }
    }

    /// The log, read: each commit and what the file was called in it.
    public static func parseLog(_ vcs: VCS, _ out: String, path: String, skip: Int) -> [FileRevision] {
        var revisions: [FileRevision] = []
        // Sapling's name for it, going back: a commit that doesn't list it
        // but lists one file only is from before a rename — that's its name.
        var named = path
        for chunk in out.components(separatedBy: record) where !chunk.isEmpty {
            var lines = chunk.components(separatedBy: "\n")
            let head = lines.removeFirst().components(separatedBy: field)
            guard head.count >= 4 else { continue }
            let at = Double(head[2].split(separator: " ").first ?? "") ?? 0
            let names = (head.count > 4 ? [head[4]] + lines : lines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Git names the file as it was in that commit; Sapling lists the
            // commit's files: the one that's this file's name then, else ours.
            let name: String
            switch vcs {
            case .git: name = names.last ?? path
            case .sapling:
                if !names.contains(named), names.count == 1 { named = names[0] }
                name = named
            }
            revisions.append(FileRevision(sha: head[0], author: head[1], at: at, summary: head[3], path: name))
        }
        return vcs == .sapling ? Array(revisions.dropFirst(skip)) : revisions
    }

    /// Blame's arguments: as of `revision`.
    public static func blameArguments(_ vcs: VCS, path: String, revision: String) -> [String] {
        switch vcs {
        case .git: return ["blame", "--porcelain", revision, "--", path]
        // Each line's commit, author and date (-c, -u, -d: with only some,
        // the JSON leaves the others out).
        case .sapling: return ["annotate", "-Tjson", "-c", "-u", "-d", "-r", revision, path]
        }
    }

    /// Blame of one text carried onto another (the last commit's onto the
    /// file as it's being edited): lines unchanged keep theirs; lines
    /// added or changed are not committed (-1).
    public static func carry(_ blame: BlameLines, from old: String, to new: String) -> BlameLines {
        let a = LineDiff.lines(old), b = LineDiff.lines(new)
        var lines: [Int] = []
        lines.reserveCapacity(b.count)
        var ai = 0, bi = 0
        func same(_ n: Int) {
            for _ in 0..<n {
                lines.append(ai < blame.lines.count ? blame.lines[ai] : -1)
                ai += 1; bi += 1
            }
        }
        for h in LineDiff.hunks(old: a, new: b) {
            same(h.oldStart - ai)
            ai += h.oldCount
            lines.append(contentsOf: Array(repeating: -1, count: h.newCount))
            bi += h.newCount
        }
        same(b.count - bi)
        return BlameLines(commits: blame.commits, lines: lines)
    }

    /// Blame, read: git's porcelain (a commit's fields said the first time
    /// it's named), or Sapling's JSON.
    public static func parseBlame(_ vcs: VCS, _ out: String) -> BlameLines {
        vcs == .git ? parseGitBlame(out) : parseSaplingBlame(out)
    }

    static func parseGitBlame(_ out: String) -> BlameLines {
        var result = BlameLines()
        var index: [String: Int] = [:]
        var pending: (sha: String, author: String, at: Double, summary: String)?
        var current: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                // The line itself: its commit's, which is now known whole.
                guard let sha = current else { continue }
                if index[sha] == nil {
                    let p = pending ?? (sha, "", 0, "")
                    index[sha] = result.commits.count
                    result.commits.append(.init(sha: sha, author: p.author, at: p.at, summary: p.summary))
                }
                result.lines.append(Self.notCommitted(sha) ? -1 : index[sha]!)
                pending = nil
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                current = String(key)
                if index[current!] == nil { pending = (current!, "", 0, "") }
            } else if pending != nil {
                switch key {
                case "author": pending?.author = value
                case "author-time": pending?.at = Double(value) ?? 0
                case "summary": pending?.summary = value
                default: break
                }
            }
        }
        return result
    }

    static func notCommitted(_ sha: String) -> Bool { sha.allSatisfy { $0 == "0" } || sha.allSatisfy { $0 == "f" } }

    static func parseSaplingBlame(_ out: String) -> BlameLines {
        struct File: Decodable { var lines: [Line] }
        struct Line: Decodable {
            var node: String
            var user: String?
            var date: [Double]?
        }
        guard let data = out.data(using: .utf8), let files = try? JSONDecoder().decode([File].self, from: data), let file = files.first else { return BlameLines() }
        var result = BlameLines()
        var index: [String: Int] = [:]
        for l in file.lines {
            guard !notCommitted(l.node) else { result.lines.append(-1); continue }
            if index[l.node] == nil {
                index[l.node] = result.commits.count
                // "Name <mail>": the name.
                let name = (l.user ?? "").components(separatedBy: " <").first ?? ""
                result.commits.append(.init(sha: l.node, author: name, at: l.date?.first ?? 0, summary: ""))
            }
            result.lines.append(index[l.node]!)
        }
        return result
    }
}
