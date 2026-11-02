import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// This host's SCIP indexes (DESIGN §2.5): a project's made by its
/// language's indexer when asked (in the root, in the user's login shell,
/// so it finds what their PATH has), kept in the host's folder
/// (`scip/<root's hash>.scip`, the indexer's words beside it), read once
/// and again when it's made anew, and asked: the symbol at a place, where
/// it's used across the project, what a file defines.
final class SCIPService {
    private let queue: DispatchQueue
    var indexers = SCIPIndexer.defaults
    /// The host's projects (§2.6): a path in one is indexed at its root,
    /// with the indexer it says.
    var projects: () -> [Project] = { [] }
    /// Indexes read, by root, with when their file was made.
    private var loaded: [String: (index: SCIPIndex, made: Date)] = [:]
    /// What each can find by name, its names lowered, made when first asked.
    private var names: [String: (made: Date, items: [(SCIPIndex.Searchable, lower: String)])] = [:]
    /// Roots being indexed, and how each last went.
    private var running: Set<String> = []
    private var failures: [String: String] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    private var folder: URL { Paths.directory.appendingPathComponent("scip") }

    private func file(_ root: String) -> URL {
        var h: UInt64 = 14_695_981_039_346_656_037
        for b in root.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return folder.appendingPathComponent(String(h, radix: 36) + ".scip")
    }

    /// A path as one spelling of it (/tmp and /private/tmp the same root).
    private static func real(_ path: String) -> String {
        let leaf = path.lastPathComponent
        let dir = URL(fileURLWithPath: path.deletingLastPathComponent).resolvingSymlinksInPath().path
        return dir.appendingPathComponent(leaf)
    }

    func request(_ r: SCIPRequest, done: @escaping (SCIPResult) -> Void) {
        let r: SCIPRequest = switch r {
        case let .index(path): .index(path: Self.real(path))
        case let .status(path): .status(path: Self.real(path))
        case let .symbol(path, line, byte): .symbol(path: Self.real(path), line: line, byte: byte)
        case let .references(symbol, path): .references(symbol: symbol, path: Self.real(path))
        case let .defined(path): .defined(path: Self.real(path))
        case let .definition(symbol, path): .definition(symbol: symbol, path: Self.real(path))
        }
        switch r {
        case let .index(path):
            guard let (indexer, root) = locate(path) else {
                return done(.error("no indexer for \(path.lastPathComponent)'s language, or no project around it"))
            }
            index(root, with: indexer)
            done(.status(status(root, indexer)))
        case let .status(path):
            guard let (indexer, root) = locate(path) else {
                let none = Project.holding(path, in: projects())?.indexer == "none"
                return done(.status(SCIPStatus(root: nil, indexer: nil, state: .none, message: none ? "its project's settings say it has none" : "no indexer for its language")))
            }
            done(.status(status(root, indexer)))
        case let .symbol(path, line, byte):
            ask(path, done) { index, root, rel in
                let character = self.character(byte, line: line, of: path, encoding: index.documents[rel]?.encoding ?? 0)
                guard let s = index.symbol(at: rel, line: line, character: character) else { return .symbol(nil) }
                return .symbol(self.describe(s, in: index, root: root))
            }
        case let .references(symbol, path):
            ask(path, done) { index, root, _ in
                .locations(index.references(to: symbol).map { self.location($0.path, $0.occurrence, root: root) })
            }
        case let .definition(symbol, path):
            ask(path, done) { index, root, _ in
                .locations(index.definitions(of: symbol).map { self.location($0.path, $0.occurrence, root: root) })
            }
        case let .defined(path):
            ask(path, done) { index, root, rel in
                .symbols(index.defined(in: rel).map { o in
                    SCIPSymbol(symbol: o.symbol, name: index.name(of: o.symbol), documentation: "", definition: self.location(rel, o, root: root))
                })
            }
        }
    }

    /// Symbols named like `query` in the project at `root` (§2.6), best
    /// first — none where it has no index (yet).
    func search(root: String, query: String, limit: Int, done: @escaping ([SymbolHit]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return done([]) }
        // Answered within; the result `ask` passes on is only its failure's.
        ask(Self.real(root.appendingPathComponent(".")), { r in if case .error = r { done([]) } }) { index, root, _ in
            let made = self.loaded[root]?.made ?? .distantPast
            if self.names[root]?.made != made {
                self.names[root] = (made, index.searchable().map { ($0, ($0.container + "." + $0.name).lowercased()) })
            }
            // Its letters in order somewhere in the name (cheap), then scored.
            let letters = Array(q.utf8.filter { $0 != 0x20 && $0 != 0x2E })
            var found: [SymbolHit] = []
            for (s, lower) in self.names[root]?.items ?? [] {
                var i = 0
                for b in lower.utf8 where i < letters.count && b == letters[i] { i += 1 }
                guard i == letters.count else { continue }
                let score = SymbolHit.score(query, name: s.name, container: s.container, kind: s.kind)
                guard score > 0 else { continue }
                found.append(SymbolHit(name: s.name, container: s.container, kind: s.kind, path: s.path, line: s.occurrence.line,
                                       character: s.occurrence.character, text: "", source: .index, score: score))
            }
            let best = SymbolHit.merge([found], limit: limit).map { h -> SymbolHit in
                var h = h
                let loc = self.location(h.path, SCIPIndex.Occurrence(line: h.line, character: h.character, endLine: h.line, endCharacter: h.character, symbol: "", roles: 1), root: root)
                h.path = loc.path
                h.text = loc.text
                return h
            }
            done(best)
            return .symbols([])
        }
    }

    /// A file saved: its project indexed again, if it has an index, a
    /// while after the last save (a burst of saves, one indexing).
    private var pendingIndex: [String: DispatchWorkItem] = [:]
    static var reindexAfter: TimeInterval = 20

    func saved(_ path: String) {
        let path = Self.real(path)
        // Code, not a note about it.
        guard CodeLanguage.forPath(path) != nil, let (indexer, root) = locate(path) else { return }
        again(root, with: indexer)
    }

    /// A project's working copy moved (§2.6): indexed again, if it has an
    /// index, as a save does it.
    func moved(_ project: Project) {
        guard let (indexer, root) = locate(Self.real(project.root.appendingPathComponent("."))) else { return }
        again(root, with: indexer)
    }

    private func again(_ root: String, with indexer: SCIPIndexer) {
        guard FileManager.default.fileExists(atPath: file(root).path) else { return }
        pendingIndex[root]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingIndex.removeValue(forKey: root)
            self?.index(root, with: indexer)
        }
        pendingIndex[root] = work
        queue.asyncAfter(deadline: .now() + Self.reindexAfter, execute: work)
    }

    /// Where a path's index is, and its indexer: its project's (§2.6),
    /// else its language's indexer's nearest marker, else any's.
    private func locate(_ path: String) -> (SCIPIndexer, root: String)? {
        if let p = Project.holding(path, in: projects()) {
            let fm = FileManager.default
            guard let i = p.indexer(among: indexers, for: path, has: { fm.fileExists(atPath: $0) }) else { return nil }
            return (i, p.root)
        }
        return SCIPIndexer.forFile(path, among: indexers) ?? project(of: path)
    }

    /// A file in no indexer's language (a Markdown file in a Rust crate):
    /// the project around it, by any indexer's markers.
    private func project(of path: String) -> (SCIPIndexer, root: String)? {
        var dir = path.deletingLastPathComponent
        while !dir.isEmpty, dir != "/" {
            for i in indexers where i.rootMarkers.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0)) }) { return (i, dir) }
            dir = dir.deletingLastPathComponent
        }
        return nil
    }

    private func status(_ root: String, _ indexer: SCIPIndexer) -> SCIPStatus {
        if running.contains(root) { return SCIPStatus(root: root, indexer: indexer.id, state: .indexing) }
        let made = (try? file(root).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let why = failures[root] { return SCIPStatus(root: root, indexer: indexer.id, state: .failed, at: made, message: why) }
        guard let made else { return SCIPStatus(root: root, indexer: indexer.id, state: .none) }
        var s = SCIPStatus(root: root, indexer: indexer.id, state: .current, at: made)
        s.changed = changedSince(root, made)
        return s
    }

    /// How many of a project's code files changed after its index was made
    /// (§2.6): counted off the queue, at most every ten seconds a root; the
    /// last count (for the same index) meanwhile.
    private var counts: [String: (made: Date, at: Date, changed: Int?)] = [:]
    private func changedSince(_ root: String, _ made: Date) -> Int? {
        let last = counts[root].flatMap { $0.made == made ? $0 : nil }
        if let last, Date().timeIntervalSince(last.at) < 10 { return last.changed }
        counts[root] = (made, Date(), last?.changed)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            let n = FileFinder.list(root: root).filter { rel in
                guard CodeLanguage.forPath(rel)?.kind == .language,
                      let m = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(rel)))?[.modificationDate] as? Date else { return false }
                return m > made
            }.count
            self?.queue.async { if self?.counts[root]?.made == made { self?.counts[root]?.changed = n } }
        }
        return last?.changed
    }

    /// The index of a file's project, read (once, and again when made
    /// anew), asked off the server's queue.
    private func ask(_ path: String, _ done: @escaping (SCIPResult) -> Void, _ body: @escaping (SCIPIndex, String, String) -> SCIPResult) {
        guard let (indexer, root) = locate(path) else {
            return done(.error("no indexer for \(path.lastPathComponent)'s language, or no project around it"))
        }
        let url = file(root)
        guard let made = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return done(.error(running.contains(root) ? "\(root) is being indexed" : "\(root) has no index yet (mani index, or Code ▸ Index Project, with \(indexer.id)'s indexer)"))
        }
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        if let l = loaded[root], l.made == made { return done(body(l.index, root, rel)) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let index = try SCIPIndex.read(try Data(contentsOf: url))
                self?.queue.async {
                    self?.loaded[root] = (index, made)
                    done(body(index, root, rel))
                }
            } catch {
                self?.queue.async { done(.error("\(root)'s index can't be read: \(error)")) }
            }
        }
    }

    private func describe(_ s: String, in index: SCIPIndex, root: String) -> SCIPSymbol {
        let def = index.definitions(of: s).first.map { location($0.path, $0.occurrence, root: root) }
        return SCIPSymbol(symbol: s, name: index.name(of: s), documentation: index.information[s]?.documentation.joined(separator: "\n\n") ?? "", definition: def)
    }

    /// A byte of a line as the index counts characters (UTF-16 unless it
    /// says otherwise).
    private func character(_ byte: Int, line: Int, of path: String, encoding: Int) -> Int {
        guard encoding != 1 else { return byte }
        if lines[path] == nil, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            lines[path] = text.split(separator: "\n", omittingEmptySubsequences: false)
        }
        guard let all = lines[path], line < all.count else { return byte }
        let prefix = String(decoding: Array(all[line].utf8.prefix(byte)), as: UTF8.self)
        return encoding == 3 ? prefix.unicodeScalars.count : prefix.utf16.count
    }

    /// A place, its file's line read for its words.
    private var lines: [String: [Substring]] = [:]
    private func location(_ rel: String, _ o: SCIPIndex.Occurrence, root: String) -> SCIPLocation {
        let path = rel.hasPrefix("/") ? rel : root.appendingPathComponent(rel)
        if lines[path] == nil, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            lines[path] = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 400 { lines.removeAll() }
        }
        let words = lines[path].flatMap { o.line < $0.count ? String($0[o.line]) : nil } ?? ""
        return SCIPLocation(path: path, line: o.line, character: o.character, endLine: o.endLine, endCharacter: o.endCharacter,
                            isDefinition: o.isDefinition, text: words.trimmingCharacters(in: .whitespaces))
    }

    /// The indexer run for a root, in the user's login shell, its index
    /// written beside the others once it's done (its words kept if it fails).
    private func index(_ root: String, with indexer: SCIPIndexer) {
        guard !running.contains(root) else { return }
        running.insert(root)
        failures.removeValue(forKey: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = file(root), partial = out.appendingPathExtension("part")
        let command = "cd '\(root.replacingOccurrences(of: "'", with: "'\\''"))' && " + indexer.command(root: root, out: partial.path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.loginShell)
            p.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var output = Data()
            do {
                try p.run()
                output = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            } catch {
                output = Data("can't run \(Self.loginShell): \(error)".utf8)
            }
            let ok = p.terminationStatus == 0 && FileManager.default.fileExists(atPath: partial.path)
            if ok {
                try? FileManager.default.removeItem(at: out)
                try? FileManager.default.moveItem(at: partial, to: out)
            } else {
                try? FileManager.default.removeItem(at: partial)
            }
            let words = String(decoding: output.suffix(2000), as: UTF8.self).split(separator: "\n").suffix(6).joined(separator: "\n")
            self?.queue.async {
                self?.running.remove(root)
                if !ok { self?.failures[root] = words.isEmpty ? "the indexer failed" : words }
            }
        }
    }

    /// The user's shell, as their account has it (for a login's PATH).
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/sh"
    }
}
