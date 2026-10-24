import Foundation

/// What keeps a block (§4): the roots on a host, and what is reachable
/// from them over strong edges. Workspaces on the desk and named ones,
/// kept (pinned) blocks, and other hosts' holds are the roots; a
/// block none of them reaches, directly or through what they place and
/// link, is collected after a grace.
extension Node {
    /// The roots on a host, as its own shards say.
    public func roots(on host: HostID) -> Set<BlockID> {
        var roots: Set<BlockID> = []
        for id in desk(host).order where id.host == host { roots.insert(id) }
        for b in blocks where b.id.host == host {
            if b.isPinned { roots.insert(b.id) }
            if let a = b.arrangement, a.isNamed || !(b.title ?? "").isEmpty || hasPins(b.id) { roots.insert(b.id) }
        }
        for h in registry(host).holds.values where h.block.host == host { roots.insert(h.block) }
        return roots
    }

    /// Whether a workspace has anything pinned in it (a live pin edge out of
    /// it): one that does is a root, kept as a named one is, and doesn't
    /// drift off the desk.
    public func hasPins(_ workspace: BlockID) -> Bool {
        graph.edges(from: workspace, kind: .link(.pinned)).contains(where: \.isLive)
    }

    /// Everything on a host that its roots reach, over its own graph.
    public func reachable(on host: HostID) -> Set<BlockID> {
        graph.reachable(from: roots(on: host))
    }
}
