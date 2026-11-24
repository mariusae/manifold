import Foundation

/// What keeps a block (§4): the roots on a host, and what is reachable
/// from them over strong edges. The workspaces are the roots — every one,
/// until it's removed by hand — and other hosts' holds; a block is kept by
/// a workspace that shows it, pins it, or reaches it through what it
/// shows and links — by hand, or by reference in what it says (a note's,
/// a comment's, an agent's `manifold:…`). One nothing reaches is
/// collected after a grace.
extension Node {
    /// The roots on a host, as its own shards say.
    public func roots(on host: HostID) -> Set<BlockID> {
        var roots: Set<BlockID> = []
        for id in desk(host).order where id.host == host { roots.insert(id) }
        for h in registry(host).holds.values where h.block.host == host { roots.insert(h.block) }
        // A project (§2.6), its block standing for it: kept while it is, and
        // what's pinned in it with it. (Its agents as they were kept before
        // pins, till the host reads them into pins.)
        for p in desk(host).projects {
            if let b = p.block, b.host == host { roots.insert(b) }
            for a in p.agents ?? [] where a.host == host { roots.insert(a) }
        }
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

    /// Everything on a host that its roots reach, over its own graph.
    public func reachable(on host: HostID) -> Set<BlockID> {
        graph.reachable(from: roots(on: host), edgesFrom: strongEdges(from:))
    }

    /// Whether an edge keeps what it leads to (§4): a strong one that holds
    /// now — and one on a thread's shelf (`ThreadContext.whileOpen`) only
    /// while the thread is open: an agent in a conversation isn't let go
    /// mid-thread, nor what was put there to read; resolved, it lets go of
    /// them (what else keeps them, keeps them).
    /// A block named by its reference in what another says (a note, a
    /// comment, an agent's turn: `mentions`) is kept by it as a link by
    /// hand keeps — what's written there is a link too, and an id once
    /// collected is gone for good.
    public func keeps(_ e: Edge) -> Bool {
        guard e.isLive else { return false }
        if e.kind == .link(.opened) { return e.relation == ThreadText.mentions }
        guard e.kind.isStrong else { return false }
        if let r = e.relation, ThreadContext.whileOpen.contains(r) { return block(e.from)?.thread?.resolved != true }
        return true
    }

    /// The edges out of a block that keep what they lead to.
    public func strongEdges(from block: BlockID) -> [Edge] {
        (graph.strongEdges(from: block) + graph.edges(from: block, kind: .link(.opened))).filter(keeps)
    }
}
