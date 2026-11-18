import Foundation

/// What keeps a block (§4): the roots on a host, and what is reachable
/// from them over strong edges. The workspaces are the roots — every one,
/// until it's removed by hand — and other hosts' holds; a block is kept by
/// a workspace that shows it, pins it, or reaches it through what it
/// shows and links. One nothing reaches is collected after a grace.
extension Node {
    /// The roots on a host, as its own shards say.
    public func roots(on host: HostID) -> Set<BlockID> {
        var roots: Set<BlockID> = []
        for id in desk(host).order where id.host == host { roots.insert(id) }
        for h in registry(host).holds.values where h.block.host == host { roots.insert(h.block) }
        // A project's agents (§3.12): kept while it is.
        for p in desk(host).projects { for a in p.agents ?? [] where a.host == host { roots.insert(a) } }
        return roots
    }

    /// Whether a workspace has anything pinned in it (a live pin edge out of
    /// it).
    public func hasPins(_ workspace: BlockID) -> Bool {
        graph.edges(from: workspace, kind: .link(.pinned)).contains(where: \.isLive)
    }

    /// What brings into the workspaces whatever kept things before they
    /// were the only roots, so nothing is lost: a workspace kept outside
    /// them (named, titled, or with pins) back among them; a block kept by
    /// its own Keep and nothing else, pinned in a "Kept" workspace (made
    /// if there's none); every Keep let go. The events, in order, with
    /// their shards; none once settled.
    public func settlingRoots(on host: HostID, at now: Stamp, newID: () -> BlockID) -> [(event: Event, shard: ShardID)] {
        var out: [(event: Event, shard: ShardID)] = []
        var order = desk(host).order
        for b in blocks where b.id.host == host && !order.contains(b.id) {
            guard let a = b.arrangement, a.isNamed || !(b.title ?? "").isEmpty || hasPins(b.id) else { continue }
            order.append(b.id)
        }
        let kept = blocks.filter { $0.id.host == host && $0.isPinned }
        let reached = graph.reachable(from: Set(order.filter { $0.host == host }).union(registry(host).holds.values.map(\.block)))
        let lost = kept.filter { !reached.contains($0.id) && $0.kind != .arrangement }
        var space: BlockID?
        if !lost.isEmpty {
            space = order.first { block($0)?.title == "Kept" }
            if space == nil {
                let id = newID()
                out.append((.create(kind: .arrangement, title: "Kept", path: nil), .block(id)))
                order.append(id)
                space = id
            }
        }
        if order != desk(host).order { out.append((.order(order), .desk(host))) }
        if let space {
            for b in lost { out.append((.link(Link(from: space, to: b.id, kind: .pinned, at: now, context: "kept")), .links(host))) }
        }
        for b in kept { out.append((.pinned(false), .block(b.id))) }
        return out
    }

    /// Everything on a host that its roots reach, over its own graph — and
    /// what an open thread holds on its shelf.
    public func reachable(on host: HostID) -> Set<BlockID> {
        var seen = roots(on: host)
        var frontier = Array(seen)
        while let b = frontier.popLast() {
            for t in graph.strongEdges(from: b).map(\.to) + shelfHeld(by: b) where seen.insert(t).inserted { frontier.append(t) }
        }
        return seen
    }

    /// The agents an open thread holds (§3.12): those on its shelf, kept
    /// while it's open — with nothing else showing them (a tile closed), an
    /// agent in a conversation isn't let go mid-thread. Resolved, it lets
    /// go of them (what else keeps them, keeps them). Not an edge of the
    /// graph: the shelf is the thread's annotation.
    public func shelfHeld(by id: BlockID) -> [BlockID] {
        guard let b = block(id), b.kind == .thread, b.thread?.resolved != true else { return [] }
        return ThreadContext.participants(of: b)
    }
}
