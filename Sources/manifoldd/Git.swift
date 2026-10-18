import Foundation
import ManifoldCore

/// Git on this host, for git and diff blocks and the editor's gutter
/// (DESIGN.md §7.5): commands run off the server's queue, answered on it.
final class Git {
    private let queue: DispatchQueue
    private let work = DispatchQueue(label: "manifold.git", qos: .userInitiated)
    private var roots: [String: String?] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// The repository a path is in, if any (cached by directory).
    func root(of path: String) -> String? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let dir = isDir.boolValue ? path : path.deletingLastPathComponent
        if let known = roots[dir] { return known }
        var found: String?
        if let (out, status) = try? Child.run(["git", "-C", dir, "rev-parse", "--show-toplevel"], timeout: 10, quiet: true), status == 0 {
            found = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if found?.isEmpty == true { found = nil }
        }
        roots[dir] = found
        return found
    }

    /// Runs git in a directory; the output, or the error, on the server's
    /// queue.
    func run(_ args: [String], in dir: String, done: @escaping (Result<String, GitError>) -> Void) {
        work.async {
            let result: Result<String, GitError>
            do {
                let (out, status) = try Child.run(["git", "-C", dir] + args, timeout: 60, quiet: true)
                if status == 0 {
                    result = .success(String(decoding: out, as: UTF8.self))
                } else {
                    result = .failure(GitError("git \(args.first ?? "") failed (\(status))"))
                }
            } catch {
                result = .failure(GitError("couldn't run git: \(error)"))
            }
            self.queue.async { done(result) }
        }
    }

    /// Several commands, together.
    func run(_ commands: [[String]], in dir: String, done: @escaping ([Result<String, GitError>]) -> Void) {
        var results = [Result<String, GitError>?](repeating: nil, count: commands.count)
        var left = commands.count
        guard left > 0 else { return done([]) }
        for (i, args) in commands.enumerated() {
            run(args, in: dir) { r in
                results[i] = r
                left -= 1
                if left == 0 { done(results.map { $0! }) }
            }
        }
    }

    /// A file as a revision has it; nil if the revision doesn't have it.
    func show(_ path: String, at revision: String, done: @escaping (String?) -> Void) {
        guard let root = root(of: path) else { return done(nil) }
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        run(["show", "\(revision):\(rel)"], in: root) { result in
            if case .success(let text) = result { done(text) } else { done(nil) }
        }
    }

    // MARK: Parsing

    /// `git status --porcelain=v1 -z -b`.
    static func parseStatus(_ out: String) -> (branch: String?, ahead: Int, behind: Int, entries: [GitStatusEntry]) {
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

    static let logFormat = "%H%x1f%h%x1f%an%x1f%at%x1f%s"

    static func parseLog(_ out: String) -> [GitCommit] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            return GitCommit(sha: String(f[0]), short: String(f[1]), author: String(f[2]), date: Double(f[3]) ?? 0, summary: String(f[4]))
        }
    }
}

struct GitError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
