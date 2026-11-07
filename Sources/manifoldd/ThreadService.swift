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
        guard node.block(block) == nil else { return }
        append(.create(kind: .thread, title: nil, path: nil), to: .block(block))
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
