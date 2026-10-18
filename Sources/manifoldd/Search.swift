import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, buf, n) }

/// Searches run on this host for search blocks (DESIGN.md §7.5): ripgrep
/// when it's on the PATH, else grep, read as it finds things and handed
/// over in batches; one run per block, a new query ending the last.
final class Searches {
    static let maxHits = 5000
    private let queue: DispatchQueue
    private var running: [BlockID: Child] = [:]
    /// Hits found so far (in order), done, truncated, error.
    var onHits: ((BlockID, [SearchHit], Bool, Bool, String?) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func cancel(_ block: BlockID) {
        guard let child = running.removeValue(forKey: block) else { return }
        kill(child.pid, SIGTERM)
    }

    func run(_ block: BlockID, _ query: SearchQuery) {
        cancel(block)
        guard !query.text.isEmpty else {
            onHits?(block, [], true, false, nil)
            return
        }
        let child: Child
        let usingRg: Bool
        if let c = try? Child.spawn(Self.rgCommand(query), stderrToNull: true) {
            child = c
            usingRg = true
        } else if let c = try? Child.spawn(Self.grepCommand(query), stderrToNull: true) {
            child = c
            usingRg = false
        } else {
            onHits?(block, [], true, false, "neither rg nor grep is on the PATH")
            return
        }
        close(child.input)
        running[block] = child
        let thread = Thread { [weak self] in
            self?.read(child, block: block, query: query, rg: usingRg)
        }
        thread.start()
    }

    /// Reads the child's output on its own thread, a batch at a time.
    private func read(_ child: Child, block: BlockID, query: SearchQuery, rg: Bool) {
        var buffer = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        var batch: [SearchHit] = []
        var total = 0
        var truncated = false
        var lastFlush = Date()
        func flush(done: Bool, error: String? = nil) {
            let hits = batch
            batch = []
            lastFlush = Date()
            queue.async { [weak self] in
                guard let self else { return }
                // A newer run replaced this one: its results don't matter.
                guard done || self.running[block]?.pid == child.pid else { return }
                if done, self.running[block]?.pid == child.pid { self.running.removeValue(forKey: block) }
                if done, self.running[block] != nil { return }
                self.onHits?(block, hits, done, truncated, error)
            }
        }
        outer: while true {
            let n = sysRead(child.output, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(contentsOf: buf[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let hit = Self.parse(line, rg: rg, query: query) {
                    batch.append(hit)
                    total += 1
                    if total >= Self.maxHits {
                        truncated = true
                        kill(child.pid, SIGTERM)
                        break outer
                    }
                }
            }
            if batch.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.15 { flush(done: false) }
        }
        close(child.output)
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        // rg and grep exit 1 for no matches, 2 for an error.
        flush(done: true, error: code == 2 && total == 0 ? "the search command failed" : nil)
    }

    static func rgCommand(_ q: SearchQuery) -> [String] {
        var argv = ["rg", "--vimgrep", "--no-heading", "--color", "never", "--no-messages"]
        argv.append(q.caseSensitive ? "--case-sensitive" : "--ignore-case")
        if !q.regex { argv.append("--fixed-strings") }
        if let g = q.glob, !g.isEmpty { argv += ["--glob", g] }
        argv += ["--", q.text, q.root]
        return argv
    }

    static func grepCommand(_ q: SearchQuery) -> [String] {
        var argv = ["grep", "-rnI", "--color=never", "-s"]
        if !q.caseSensitive { argv.append("-i") }
        argv.append(q.regex ? "-E" : "-F")
        if let g = q.glob, !g.isEmpty { argv.append("--include=\(g)") }
        argv += ["--exclude-dir=.git", "-e", q.text, "--", q.root]
        return argv
    }

    /// `path:line:column:text` from rg, `path:line:text` from grep.
    static func parse(_ line: Data.SubSequence, rg: Bool, query: SearchQuery) -> SearchHit? {
        let s = String(decoding: line, as: UTF8.self)
        // The path may hold colons; the line number is the first field
        // after it that's all digits, found from the start past the root.
        var rest = s[...]
        if s.hasPrefix(query.root) { rest = s[s.index(s.startIndex, offsetBy: query.root.count)...] }
        guard let c1 = rest.firstIndex(of: ":") else { return nil }
        let path = String(s[s.startIndex..<c1])
        var after = rest[rest.index(after: c1)...]
        guard let c2 = after.firstIndex(of: ":"), let lineNo = Int(after[after.startIndex..<c2]) else { return nil }
        after = after[after.index(after: c2)...]
        var column = 1
        if rg {
            guard let c3 = after.firstIndex(of: ":"), let col = Int(after[after.startIndex..<c3]) else { return nil }
            column = col
            after = after[after.index(after: c3)...]
        } else if !query.regex, let r = after.range(of: query.text, options: query.caseSensitive ? [] : [.caseInsensitive]) {
            column = after[after.startIndex..<r.lowerBound].utf8.count + 1
        }
        var text = String(after)
        if text.count > 400 { text = String(text.prefix(400)) + "…" }
        return SearchHit(path: path, line: lineNo, column: column, text: text)
    }

    func stopAll() {
        for (_, c) in running { kill(c.pid, SIGTERM) }
        running = [:]
    }
}
