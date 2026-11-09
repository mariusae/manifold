import CPTY
import Foundation
import ManifoldCore

/// Threads on this host (§3.12): made, written to, and seen, as the app
/// (or `mani`, through it) proposes; and who a `mani` command's caller is,
/// found here — fenced, not claimed.
extension Server {
    /// The author of a command whose process is `pid`: the agent at work
    /// in the terminal it runs under, else you (typed in a shell, or run
    /// from outside Manifold's terminals). Up the processes, to the first
    /// that's one of this host's terminals' shells.
    func author(ofCaller pid: pid_t?) -> ThreadAuthor {
        let you = ThreadAuthor.you(machine: Self.machineName)
        guard var p = pid, p > 1 else { return you }
        var shells: [pid_t: BlockID] = [:]
        for (block, s) in sessions { shells[s.pid] = block }
        for _ in 0..<64 {
            if let block = shells[p] {
                guard let b = node.block(block), let agent = b.agent else { return you }
                return .agent(block: block, name: agent.name, turn: b.terminal?.turns?.last?.id)
            }
            let parent = mf_proc_parent(p)
            guard parent > 1, parent != p else { return you }
            p = parent
        }
        return you
    }

    static let machineName: String = {
        let name = ProcessInfo.processInfo.hostName
        return name.split(separator: ".").first.map(String.init) ?? name
    }()

    /// A thread made: its block, its space, what it's about, its first
    /// comment; a `thread` link from its space (keeping it) and an
    /// `annotates` link to what it's about (keeping that, and its anchor).
    func makeThread(_ block: BlockID, space: BlockID?, about: ThreadPlace, text: String, author: ThreadAuthor) {
        guard ensure(block, kind: .thread) else { return }
        if let space { append(.threadSpace(space), to: .block(block)) }
        append(.threadAbout(about), to: .block(block))
        let now = clock.now()
        if !text.isEmpty { append(.threadEntry(ThreadEntry(at: now, author: author, kind: .comment(text))), to: .block(block)) }
        if let space, space.host == host {
            append(.link(Link(from: space, to: block, kind: .thread, at: now, context: "thread")), to: .links(host))
        }
        if about.block != space {
            append(.link(Link(from: block, to: about.block, kind: .linked, at: now, context: about.name ?? about.title,
                              toAnchor: about.anchor, relation: ThreadText.annotates)), to: .links(host))
        }
        threadMentions(block)
        watchPlaces(block)
    }

    /// A thread's space given (one made by `mani`, its agent's space found
    /// by the app): the link from it too.
    func setThreadSpace(_ block: BlockID, _ space: BlockID) {
        guard let t = node.block(block)?.thread, t.space != space else { return }
        append(.threadSpace(space), to: .block(block))
        if space.host == host, !node.graph.edges(from: space, kind: .link(.thread)).contains(where: { $0.to == block }) {
            append(.link(Link(from: space, to: block, kind: .thread, at: clock.now(), context: "thread")), to: .links(host))
        }
    }

    /// An entry, stamped now. A comment of yours on a resolved thread
    /// reopens it first.
    func addThreadEntry(_ block: BlockID, _ entry: ThreadEntry) -> String? {
        guard let t = node.block(block)?.thread else { return "not a thread" }
        if let c = entry.comment, c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "nothing to say" }
        var e = entry
        e.at = clock.now()
        if t.resolved, e.comment != nil {
            append(.threadEntry(ThreadEntry(at: e.at, author: e.author, kind: .reopened)), to: .block(block))
            e.at = clock.now()
        }
        switch e.kind {
        case .resolved where t.resolved, .reopened where !t.resolved: return nil
        default: break
        }
        append(.threadEntry(e), to: .block(block))
        if e.comment != nil { threadMentions(block) }
        return nil
    }

    /// What's been seen, kept on the desk: only ever forward.
    func threadsSeen(_ marks: [BlockID: Stamp]) {
        let desk = node.desk(host)
        let forward = marks.filter { m in desk.threadsSeen[m.key].map { m.value > $0 } ?? true }
        if !forward.isEmpty { append(.threadSeen(forward), to: .desk(host)) }
    }

    /// The links a thread's comments mention (§3.12): one to each block or
    /// place a comment names (`manifold:…`, a pill dropped in), meaning
    /// `mentions`, brought to match what the comments say.
    func threadMentions(_ block: BlockID) {
        guard let t = node.block(block)?.thread else { return }
        struct Target: Hashable { var block: BlockID; var anchor: String? }
        var wanted: [Target: String] = [:]
        for c in t.comments {
            for m in Mention.find(in: c.comment ?? "") {
                guard case .block(let to) = m.target, to != block, to != t.about?.block else { continue }
                let target = Target(block: to, anchor: m.anchor)
                if wanted[target] == nil { wanted[target] = "[[" + String(m.text.prefix(118)) + "]]" }
            }
        }
        let have = node.graph.edges(from: block, kind: .link(.opened)).filter { $0.relation == ThreadText.mentions }
        for e in have where wanted[Target(block: e.to, anchor: e.toAnchor)] == nil { append(.unlink(e.id), to: .links(host)) }
        for (target, context) in wanted where !have.contains(where: { $0.to == target.block && $0.toAnchor == target.anchor }) {
            append(.link(Link(from: block, to: target.block, kind: .opened, at: clock.now(), context: context,
                              toAnchor: target.anchor, relation: ThreadText.mentions)), to: .links(host))
        }
    }
}

/// Edits to threads' places (§3.12): each thread about a place in a text
/// is watched; what's there changing is written into the thread — by
/// whom: you (typed in an editor), the agent whose tool wrote the file a
/// moment before, else the disk — a while after the last change, and its
/// lines deleted, once.
final class PlaceWatch {
    /// What each thread's place held when last looked at.
    var text: [BlockID: String] = [:]
    /// Edits not yet written, by thread: lines added and taken away, and by whom.
    var pending: [BlockID: (added: Int, removed: Int, author: ThreadAuthor)] = [:]
    let flush: KeyedDebouncer<BlockID>
    /// Files agents' tools wrote lately: by whom, and when.
    var writes: [String: (block: BlockID, name: String, at: Date)] = [:]
    var gone: Set<BlockID> = []

    init(queue: DispatchQueue) { flush = KeyedDebouncer(queue: queue) }
}

extension Server {
    /// An agent's tool wrote a file: an edit to a place there, a moment
    /// after, is the agent's.
    func agentWrote(_ path: String, by block: BlockID, agent: String) {
        let name = AgentCatalog.agent(namedByApp: agent)?.name ?? agent
        placeWatch.writes[path] = (block, name, Date())
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if real != path { placeWatch.writes[real] = (block, name, Date()) }
    }

    /// What each open thread's place holds now, to tell an edit by.
    func watchPlaces(_ only: BlockID? = nil) {
        for id in only.map({ [$0] }) ?? Array(node.graph.blocks(kind: .thread)) {
            guard let t = node.block(id)?.thread, !t.resolved, let about = t.about, let anchor = about.anchor,
                  let b = node.block(about.block), let rope = b.text?.text, let r = b.anchors?[anchor]?.range,
                  r.start <= r.end, r.end <= rope.count else { continue }
            placeWatch.text[id] = rope[r]
        }
    }

    /// A text changed: the threads about places in it looked at again.
    func placesEdited(_ file: BlockID, typed: Bool) {
        let threads = node.graph.edges(to: file, kind: .link(.linked)).filter { $0.relation == ThreadText.annotates && $0.toAnchor != nil }
        guard !threads.isEmpty, let b = node.block(file), let rope = b.text?.text else { return }
        for e in threads {
            guard let t = node.block(e.from), t.thread?.resolved != true, let anchor = e.toAnchor, let a = b.anchors?[anchor] else { continue }
            let now: String? = a.range.flatMap { r in r.end <= rope.count && r.start <= r.end ? rope[r] : nil }
            guard let before = placeWatch.text[t.id] else {
                placeWatch.text[t.id] = now ?? ""
                continue
            }
            let after = now ?? ""
            guard after != before else { continue }
            placeWatch.text[t.id] = after
            if after.isEmpty, !before.isEmpty {
                if placeWatch.gone.insert(t.id).inserted {
                    append(.threadEntry(ThreadEntry(at: clock.now(), author: editor(of: b, typed: typed), kind: .gone)), to: .block(t.id))
                }
                continue
            }
            placeWatch.gone.remove(t.id)
            var added = 0, removed = 0
            for h in LineDiff.hunks(old: before, new: after) {
                added += h.newCount
                removed += h.oldCount
            }
            let author = editor(of: b, typed: typed)
            var p = placeWatch.pending[t.id] ?? (0, 0, author)
            if !p.author.same(as: author) {
                flushEdits(t.id)
                p = (0, 0, author)
            }
            p.added += added
            p.removed += removed
            placeWatch.pending[t.id] = p
            placeWatch.flush.schedule(t.id, after: 20) { [weak self] in self?.flushEdits(t.id) }
        }
    }

    /// Who changed a text: an agent's tool that wrote its file lately;
    /// else you, typing; else the disk.
    private func editor(of b: Block, typed: Bool) -> ThreadAuthor {
        if let path = b.path, let w = placeWatch.writes[path] ?? placeWatch.writes[URL(fileURLWithPath: path).resolvingSymlinksInPath().path],
           Date().timeIntervalSince(w.at) < 30 {
            return .agent(block: w.block, name: w.name, turn: node.block(w.block)?.terminal?.turns?.last?.id)
        }
        return typed ? .you(machine: nil) : .manifold
    }

    /// The edits to a place gathered: written into its thread.
    func flushEdits(_ thread: BlockID) {
        placeWatch.flush.cancel(thread)
        guard let p = placeWatch.pending.removeValue(forKey: thread), p.added + p.removed > 0, node.block(thread)?.thread != nil else { return }
        append(.threadEntry(ThreadEntry(at: clock.now(), author: p.author, kind: .edited(added: p.added, removed: p.removed))), to: .block(thread))
    }
}
