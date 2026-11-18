import Foundation
import ManifoldCore

/// Projects' blocks and what's pinned in them (§2.6), and threads' shelves
/// (§3.12): each kept as links in the graph, as everything else is.
extension Server {
    // MARK: Projects

    /// A project's block, made if it hasn't one: the project in the graph.
    @discardableResult
    func projectBlock(_ root: String) -> BlockID? {
        guard var p = node.desk(host).projects.first(where: { $0.root == root }) else { return nil }
        if let b = p.block, node.block(b) != nil { return b }
        let id = BlockID(host: host)
        _ = ensure(id, kind: .project, title: p.name)
        p.block = id
        append(.project(p), to: .desk(host))
        return id
    }

    /// A project follows its folder (§2.6): one whose folder has been gone
    /// for the collection's grace — not a moment's absence, a volume
    /// unmounted a while — is no longer a project, and its block, no longer
    /// kept, is collected as anything is. Back meanwhile, it's as it was.
    func projectsFollowTheirFolders() {
        let minutes = node.desk(host).settings.collectAfterMinutes
        guard minutes > 0 else { return }
        let now = Date()
        for p in node.desk(host).projects {
            if FileManager.default.isDirectory(atPath: p.root) == true {
                folderGoneSince.removeValue(forKey: p.root)
                continue
            }
            let since = folderGoneSince[p.root] ?? now
            folderGoneSince[p.root] = since
            guard now.timeIntervalSince(since) >= Double(minutes) * 60 else { continue }
            folderGoneSince.removeValue(forKey: p.root)
            append(.unproject(p.root), to: .desk(host))
            log("project \(p.name): its folder gone \(minutes) minutes, no longer a project")
        }
    }

    /// What's pinned in a block (a space, a project): its live `pinned` links' ends.
    func pinned(in block: BlockID) -> [BlockID] {
        node.graph.edges(from: block, kind: .link(.pinned)).filter(\.isLive).map(\.to)
    }

    /// Pinned in a block, if it isn't already.
    func pin(_ target: BlockID, in block: BlockID) {
        guard !pinned(in: block).contains(target) else { return }
        append(.link(Link(from: block, to: target, kind: .pinned, at: clock.now(), context: "pinned")), to: .links(host))
    }

    /// Every project its block; and the agents a project kept before pins,
    /// pinned in it, the list let go of. At every collection: a project
    /// made by an older client comes without its block.
    func settleProjects() {
        for p in node.desk(host).projects {
            guard let b = projectBlock(p.root) else { continue }
            guard let agents = p.agents else { continue }
            for a in agents where a.host == host && node.block(a) != nil { pin(a, in: b) }
            guard var now = node.desk(host).projects.first(where: { $0.root == p.root }) else { continue }
            now.agents = nil
            append(.project(now), to: .desk(host))
            log("project \(p.name): \(agents.count) agent(s) pinned in it")
        }
    }

    /// The agents pinned in a project, by its root.
    func projectAgents(_ root: String) -> [BlockID] {
        guard let b = node.desk(host).projects.first(where: { $0.root == root })?.block else { return [] }
        return pinned(in: b).filter { node.block($0)?.agent != nil || node.block($0)?.kind == .agent }
    }

    /// Every project's pinned agents, by the project's block.
    var projectAgentsByProject: [BlockID: [BlockID]] {
        var out: [BlockID: [BlockID]] = [:]
        for p in node.desk(host).projects { if let b = p.block { out[b] = projectAgents(p.root) } }
        return out
    }

    // MARK: Threads' shelves

    /// A thread's shelf brought to what's asked (§3.12): its `participant`
    /// links to the agents, its lead annotated; its `shelved` links to
    /// what's kept, each address made a block if it names a file or a page
    /// that hasn't one. Nil, left as it is.
    func setThreadShelf(_ thread: BlockID, participants: [BlockID]?, references: [String]?) {
        guard node.block(thread)?.kind == .thread else { return }
        let edges = node.graph.edges(from: thread, kind: .link(.linked)).filter(\.isLive)
        if let participants {
            var wanted: [BlockID] = []
            for p in participants where !wanted.contains(p) && p != thread { wanted.append(p) }
            for e in edges where e.relation == ThreadContext.participant && !wanted.contains(e.to) {
                append(.unlink(e.id), to: .links(host))
            }
            let have = Set(edges.filter { $0.relation == ThreadContext.participant }.map(\.to))
            for p in wanted where !have.contains(p) {
                let name = node.block(p).flatMap(AgentIdentity.name(of:)) ?? node.block(p)?.agent?.name ?? "agent"
                append(.link(Link(from: thread, to: p, kind: .linked, at: clock.now(), context: name, relation: ThreadContext.participant)), to: .links(host))
            }
            let lead = wanted.first?.description ?? ""
            if (node.block(thread)?.annotations?[ThreadContext.leadKey] ?? "") != lead {
                append(.annotate([ThreadContext.leadKey: lead]), to: .block(thread))
            }
        }
        if let references {
            var wanted: [LinkTarget: String] = [:]
            var order: [LinkTarget] = []
            let all = node.blocks
            for address in references {
                guard let target = shelfTarget(address, among: all), target.block != thread, wanted[target] == nil else { continue }
                wanted[target] = address
                order.append(target)
            }
            for e in edges where e.relation == ThreadContext.shelved && wanted[LinkTarget(block: e.to, anchor: e.toAnchor)] == nil {
                append(.unlink(e.id), to: .links(host))
            }
            let have = Set(edges.filter { $0.relation == ThreadContext.shelved }.map { LinkTarget(block: $0.to, anchor: $0.toAnchor) })
            for t in order where !have.contains(t) {
                append(.link(Link(from: thread, to: t.block, kind: .linked, at: clock.now(), context: wanted[t],
                                  toAnchor: t.anchor, relation: ThreadContext.shelved)), to: .links(host))
            }
        }
    }

    /// The block an address on a shelf names, and the place in it: a
    /// block's own; a file's or a folder's here, its block (made if it has
    /// none); a page's, its block (made likewise).
    private func shelfTarget(_ address: String, among all: [Block]) -> LinkTarget? {
        switch ManifoldAddress.parse(address) {
        case let .block(id, fragment)?:
            return LinkTarget(block: id, anchor: fragment)
        case let .file(h, path, fragment)?:
            guard h == host else { return nil }
            let isFolder = path.hasSuffix("/") || FileManager.default.isDirectory(atPath: path) == true
            let p = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            guard let id = mentionedBlock(for: p, among: all, kind: isFolder ? .directory : nil) else { return nil }
            return LinkTarget(block: id, anchor: isFolder ? nil : fragment)
        case nil:
            guard let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme) else { return nil }
            if let b = all.first(where: { $0.kind == .web && $0.web?.url == address }) { return LinkTarget(block: b.id, anchor: nil) }
            let id = BlockID(host: host)
            append(.create(kind: .web, title: nil, path: nil), to: .block(id))
            append(.url(address, viaHost: false), to: .block(id))
            return LinkTarget(block: id, anchor: nil)
        }
    }

    /// Threads' shelves as they were kept before their links (annotations),
    /// made links, once: the participants then (or, for a thread from
    /// before them, the agent it was held to and those that wrote in it)
    /// and its references; the annotations let go of.
    func settleShelves() {
        guard !node.desk(host).settings.shelvesSettled else { return }
        var n = 0
        for b in node.blocks where b.id.host == host && b.kind == .thread {
            var parts = ThreadContext.legacyParticipants(of: b)
            if parts == nil {
                var out: [BlockID] = []
                if let s = b.annotations?[ThreadContext.leadKey], let id = BlockID(string: s), node.block(id)?.agent != nil { out.append(id) }
                for a in b.thread?.agents ?? [] where !out.contains(a.block) && node.block(a.block)?.agent != nil { out.append(a.block) }
                parts = out
            }
            let refs = ThreadContext.legacyReferences(of: b)
            setThreadShelf(b.id, participants: parts, references: refs)
            if b.annotations?[ThreadContext.participantsKey] != nil || b.annotations?[ThreadContext.referencesKey] != nil {
                append(.annotate([ThreadContext.participantsKey: "", ThreadContext.referencesKey: ""]), to: .block(b.id))
            }
            n += 1
        }
        var s = node.desk(host).settings
        s.shelvesSettled = true
        append(.settings(s), to: .desk(host))
        if n > 0 { log("shelves settled: \(n) thread(s)' shelves made links") }
    }
}
