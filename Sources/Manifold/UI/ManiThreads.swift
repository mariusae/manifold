import AppKit
import ManifoldCore

/// `mani threads` and `mani thread …` (§3.12): threads listed, read,
/// started, replied to, resolved — each entry's author the one the host
/// the command ran on found (an agent, by its terminal; else you).
extension ManiDesk {
    func threads(_ r: ManiRequest, _ scope: Scope) async throws -> String? {
        let author = r.author ?? Hosts.you
        switch r.verb {
        case "threads":
            var list: [Block]
            if let place = r.flags["place"] {
                let t = try await target(place, scope)
                let anchor = wc.anchor(t.at, in: t.block)?.anchorID
                list = anchor == nil ? hosts.threads(about: t.block, anyPlace: true) : hosts.threads(about: t.block, anchor: anchor)
            } else if r.flags["project"] != nil {
                let host = scope.host
                guard let root = hosts.client(host)?.node.graph.project(holding: r.cwd, on: host) else {
                    throw Failure(message: "\(r.cwd) isn't in a project (mani project --make makes one)")
                }
                list = hosts.threads(inProject: root, on: host)
            } else {
                guard let ws = scope.workspace else { throw Failure(message: "no space is shown") }
                list = hosts.threads(inSpace: ws)
            }
            if r.flags["all"] == nil { list = list.filter { $0.thread?.resolved != true } }
            list.sort { ($0.thread?.lastActivity ?? $0.created) < ($1.thread?.lastActivity ?? $1.created) }
            if r.flags["json"] != nil { return json(list.map(threadJSON)) }
            if list.isEmpty { return r.flags["all"] == nil ? "No open threads." : "No threads." }
            return list.map(threadText).joined(separator: "\n\n")
        case "thread read":
            let t = try await thread(r.args[0], scope)
            return r.flags["json"] != nil ? json(threadJSON(t)) : threadText(t)
        case "thread new":
            let target = try await target(r.args[0], scope)
            guard let text = (r.args.count > 1 ? r.args[1] : r.input)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw Failure(message: "no text: give it, or pipe it in", status: 2)
            }
            let place = try await threadPlace(target)
            let id = hosts.newThread(about: place, space: scope.workspace, text: text, author: author)
            wc.askAgents(in: id, comment: text, author: author)
            return MainWindowController.address(id)
        case "thread reply":
            let t = try await thread(r.args[0], scope)
            guard let text = (r.args.count > 1 ? r.args[1] : r.input)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw Failure(message: "no text: give it, or pipe it in", status: 2)
            }
            hosts.addToThread(t.id, .comment(text), author: author)
            wc.askAgents(in: t.id, comment: text, author: author)
            if r.flags["resolve"] != nil { hosts.addToThread(t.id, .resolved, author: author) }
            return ""
        case "thread edit":
            let t = try await thread(r.args[0], scope)
            guard let text = (r.args.count > 1 ? r.args[1] : r.input)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw Failure(message: "no text: give it, or pipe it in", status: 2)
            }
            let mine = t.thread?.entries.filter { $0.comment != nil && $0.author.same(as: author) } ?? []
            let e: ThreadEntry
            if let id = r.flags["entry"] {
                guard let found = t.thread?.entries.first(where: { $0.id == id && $0.comment != nil }) else { throw Failure(message: "no comment \(id) in that thread") }
                guard found.author.same(as: author) else { throw Failure(message: "that comment is \(found.author.shownName)'s: only whoever wrote it changes it") }
                e = found
            } else {
                guard let last = mine.last else { throw Failure(message: "you haven't written in that thread") }
                e = last
            }
            let error: String? = await withCheckedContinuation { c in
                hosts.editThreadComment(t.id, entry: e.id, text: text, author: author) { c.resume(returning: $0) }
            }
            if let error { throw Failure(message: error) }
            return ""
        case "thread context":
            // "thread context <thread> [add|remove <ref>…]": its shelf, or a
            // thing put on it or taken off (an agent into the conversation; a
            // reference into its context) — as you, or the agent running it.
            let t = try await thread(r.args[0], scope)
            if r.args.count > 2, ["add", "remove"].contains(r.args[1]) {
                var addresses: [String] = []
                for name in r.args.dropFirst(2) {
                    if name.hasPrefix("manifold:") || name.hasPrefix("http") { addresses.append(name); continue }
                    // A block's id (host/ULID): the block.
                    if let id = BlockID(string: name), ManifoldAddress.parse("manifold:" + name) == .block(id, fragment: nil) {
                        addresses.append(MainWindowController.address(id))
                        continue
                    }
                    // A path — one that's there, on this Mac; any, given as a path — the
                    // file (or folder) on the command's host.
                    var path = (name as NSString).expandingTildeInPath
                    if !path.hasPrefix("/") { path = (r.cwd as NSString).appendingPathComponent(path) }
                    path = (path as NSString).standardizingPath
                    let there = scope.host == hosts.local.host && FileManager.default.fileExists(atPath: path)
                    if there || name.hasPrefix("/") || name.hasPrefix("~") || name.hasPrefix(".") {
                        addresses.append(ManifoldAddress.of(file: path, on: scope.host))
                        continue
                    }
                    let found = try await target(name, scope)
                    addresses.append(MainWindowController.address(found.block, anchor: wc.anchor(found.at, in: found.block)?.anchorID))
                }
                if r.args[1] == "add" { wc.addToContext(t.id, addresses, author: author) } else { for a in addresses { wc.removeFromContext(t.id, a, author: author) } }
                return ""
            }
            let parts = wc.participants(of: t)
            let refs = ThreadContext.references(of: t)
            if parts.isEmpty && refs.isEmpty { return "Nothing in its context yet." }
            return (parts.map { id in "agent \(hosts.block(id).map(AgentLook.name(of:)) ?? "?") — \(MainWindowController.address(id))" }
                + refs.map { "ref \(wc.contextTitle($0)) — \($0)" }).joined(separator: "\n")
        case "thread resolve", "thread reopen":
            let t = try await thread(r.args[0], scope)
            hosts.addToThread(t.id, r.verb == "thread resolve" ? .resolved : .reopened, author: author)
            return ""
        default:
            return nil
        }
    }

    /// A thread by its reference (or any name of it).
    private func thread(_ name: String, _ scope: Scope) async throws -> Block {
        let t = try await target(name, scope)
        guard let b = hosts.block(t.block), b.kind == .thread else { throw Failure(message: "\(name) isn't a thread (mani threads lists them)") }
        return b
    }

    /// A place named, as a thread would be about it (the window's
    /// `threadPlace`): anchored, with the text there — a selection's lines
    /// (`@selection`), its words.
    private func threadPlace(_ t: Target) async throws -> ThreadPlace {
        var place = Place(block: t.block, at: t.at)
        if t.at == nil, let s = t.selection {
            place.context = s.text
            if let lines = s.lines { place.at = .lines(lines.lowerBound, lines.upperBound) }
            if let page = s.page { place.at = .page(page) }
        }
        let made: ThreadPlace? = await withCheckedContinuation { c in wc.threadPlace(place) { c.resume(returning: $0) } }
        guard let made else { throw Failure(message: "there's no place there to be about") }
        return made
    }

    /// A thread as text: its reference and state, where it is, what it
    /// was written against, and every entry with who made it.
    func threadText(_ b: Block) -> String {
        guard let t = b.thread else { return "" }
        var out = [MainWindowController.address(b.id) + (t.resolved ? "  (resolved)" : "")]
        if let p = t.about {
            let d = wc.describe(p)
            out.append("about: " + d.title + (d.drift.map { " (\($0))" } ?? "") + (d.gone ? " — GONE: read the text it was written against" : ""))
            out.append("at: " + MainWindowController.address(p.block, anchor: p.anchor))
            if let diff = p.diff { out.append("made in a diff: \(diff.file), \(diff.new ? "new" : "old") lines \(diff.start)-\(diff.end)" + (diff.commit.map { ", commit \($0)" } ?? "")) }
            if let c = p.context, !c.isEmpty {
                out.append("written against:")
                out += c.split(separator: "\n", omittingEmptySubsequences: false).map { "  | " + $0 }
            }
        }
        // Its context (§3.12): who's in the conversation, what's kept in it.
        let parts = wc.participants(of: b)
        if !parts.isEmpty {
            out.append("in the conversation (told everything said here; a comment naming no one asks the first):")
            for id in parts {
                let a = hosts.block(id)
                out.append("  - \(a.map(AgentLook.name(of:)) ?? "an agent") — \(MainWindowController.address(id))\(a.map { " · " + AgentLook.description(of: $0) } ?? "")")
            }
        }
        let refs = ThreadContext.references(of: b)
        if !refs.isEmpty {
            out.append("context (kept with it — read these for what it's about):")
            out += refs.map { "  - \(wc.contextTitle($0)) — \($0)" }
        }
        for e in t.entries {
            let when = BlockSummary.since(e.at.date, now: Date())
            switch e.kind {
            case .comment(let text):
                out.append("\(e.author.shownName) (\(when)\(e.edited == nil ? "" : ", edited")):")
                out += text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
            case .resolved: out.append("— resolved by \(e.author.shownName) (\(when))")
            case .reopened: out.append("— reopened by \(e.author.shownName) (\(when))")
            case let .asked(_, name): out.append("— \(name) asked (\(when))")
            case let .edited(a, r):
                let who: String = if case .manifold = e.author { "changed on disk" } else { "edited by \(e.author.shownName)" }
                out.append("— \(who), +\(a) −\(r) (\(when))")
            case .gone: out.append("— its lines were deleted (\(when))")
            case .stopped(let why): out.append("— \(why) (\(when))")
            case let .context(added, address, title): out.append("— \(e.author.shownName) \(added ? "added" : "took out") \(title) (\(address)) \(added ? "to" : "from") its context (\(when))")
            }
        }
        return out.joined(separator: "\n")
    }

    private func threadJSON(_ b: Block) -> [String: Any] {
        guard let t = b.thread else { return [:] }
        var o: [String: Any] = ["thread": MainWindowController.address(b.id), "resolved": t.resolved]
        if let p = t.about {
            let d = wc.describe(p)
            o["about"] = d.title
            o["place"] = MainWindowController.address(p.block, anchor: p.anchor)
            o["moved"] = d.drift ?? NSNull()
            o["gone"] = d.gone
            o["context"] = p.context ?? NSNull()
            o["line"] = p.line ?? NSNull()
        }
        o["entries"] = t.entries.map { e -> [String: Any] in
            var x: [String: Any] = ["id": e.id, "author": e.author.shownName, "you": e.author.isYou, "at": e.at.date.timeIntervalSince1970]
            if let edited = e.edited { x["edited"] = edited.date.timeIntervalSince1970 }
            if let a = e.author.agentBlock { x["agent"] = MainWindowController.address(a) }
            switch e.kind {
            case .comment(let c): x["comment"] = c
            default: x["event"] = "\(e.kind)"
            }
            return x
        }
        return o
    }
}
