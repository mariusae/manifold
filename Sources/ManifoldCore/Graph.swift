import Foundation

/// The graph of blocks (DESIGN.md §3.5), kept beside the replica and
/// queried cheaply: every edge is indexed by its ends and its kind, live
/// counts are kept as edges come and go, and the trail — the order blocks
/// were gone to — is a sorted run of steps with an index by block.
///
/// Edges come from the logs the node already holds: `placed` from an
/// arrangement's `place` and `remove` (an interval, live until removed),
/// the link kinds from the links shard, and steps from `focus` in
/// arrangements and `select` on the desk. Nothing here is stored; it is
/// rebuilt from the shards' states and their kept entries.
public enum EdgeKind: Hashable, Sendable, CustomStringConvertible {
    /// An arrangement holds a placement of the block.
    case placed
    /// A folder (a directory or repository block) holds a file or folder,
    /// by its path: not stored, read off the paths when asked.
    case contains
    case link(LinkKind)

    public var description: String {
        switch self {
        case .placed: "placed"
        case .contains: "contains"
        case .link(let k): k.rawValue
        }
    }

    /// Strong (§4): a reference that keeps what it points at — a
    /// workspace's placement, a link made by hand. The rest are weak:
    /// what a terminal opened, a search found, a folder contains, the
    /// trail — history and happenstance, keeping nothing alive.
    public var isStrong: Bool {
        switch self {
        case .placed: true
        case .link(let k): k == .linked
        case .contains: false
        }
    }
}

/// A node of the sparse file tree (§3.6): a folder or a file, with the
/// block standing for it if there is one, what's under it, and what the
/// registry says of the blocks beneath.
public struct FileNode: Equatable, Sendable {
    public var path: String
    public var host: HostID
    /// The name shown: a file's; a folder's, or the run of single folders
    /// it stands for ("Sources/Manifold/UI").
    public var name: String
    public var block: BlockID?
    public var kind: BlockKind?
    public var isFolder: Bool
    public var children: [FileNode]
    /// Blocks beneath (files, and folders with blocks).
    public var count: Int
    /// The latest a block here or beneath was seen or made.
    public var latest: Stamp?
    /// A block that is *at* a folder rather than a file in it — a
    /// terminal in its working directory, a note at home there, a patch
    /// against it: shown under the folder by its own title (the tree
    /// doesn't know titles; `name` is empty).
    public var isPlace = false
}

public struct Edge: Hashable, Sendable {
    public var kind: EdgeKind
    public var from: BlockID
    public var to: BlockID
    /// When it was made.
    public var at: Stamp
    /// When it ended, for an interval; nil while it holds.
    public var until: Stamp?
    /// What made it, in words: the line a path was ⌘-clicked on, the hit.
    public var context: String?
    /// The placement or link it stands for.
    public var id: String
    /// The shard whose log it came from.
    public var shard: ShardID

    public var isLive: Bool { until == nil }

    /// Whether it held at a moment (now, for nil).
    public func holds(at stamp: Stamp?) -> Bool {
        guard let stamp else { return isLive }
        guard at <= stamp else { return false }
        if let until { return until > stamp }
        return true
    }
}

/// One step of the trail: a block gone to, when, and by which placement
/// (none for an arrangement selected on the desk).
public struct Step: Codable, Equatable, Sendable {
    public var block: BlockID
    public var at: Stamp
    public var placement: PlacementID?

    public init(block: BlockID, at: Stamp, placement: PlacementID? = nil) {
        self.block = block
        self.at = at
        self.placement = placement
    }
}

/// A block's neighbors, each kind and direction counted and listed
/// newest first.
public struct Neighborhood: Sendable {
    public var block: BlockID
    public var outbound: [EdgeKind: [Edge]] = [:]
    public var inbound: [EdgeKind: [Edge]] = [:]
    /// Blocks gone to just before and just after it, with how often.
    public var before: [TrailNeighbor] = []
    public var after: [TrailNeighbor] = []

    public var isEmpty: Bool { outbound.isEmpty && inbound.isEmpty && before.isEmpty && after.isEmpty }

    public init(block: BlockID) { self.block = block }
}

public struct TrailNeighbor: Equatable, Sendable {
    public var block: BlockID
    public var count: Int
    public var last: Stamp
}

public final class Graph {
    private var out: [BlockID: [EdgeKind: [Edge]]] = [:]
    private var inbound: [BlockID: [EdgeKind: [Edge]]] = [:]
    private var byID: [String: Edge] = [:]
    private var byShard: [ShardID: Set<String>] = [:]
    private var liveOut: [BlockID: [EdgeKind: Int]] = [:]
    private var liveIn: [BlockID: [EdgeKind: Int]] = [:]

    // Paths: for `contains`, and the file tree.
    private var pathOf: [BlockID: (path: String, kind: BlockKind)] = [:]
    private var atPath: [HostID: [String: [BlockID]]] = [:]
    /// Where a block without a file is (§3.6): a terminal's working
    /// directory, a note's home; by block, and by folder.
    private var placeOf: [BlockID: String] = [:]
    private var atPlace: [HostID: [String: [BlockID]]] = [:]
    private var createdOf: [BlockID: Stamp] = [:]
    private var lastSeen: [BlockID: Stamp] = [:]

    private var steps: [Step] = []
    /// Which registry shard each step came from, by position.
    private var stepShards: [ShardID] = []
    private var stepIndex: [BlockID: [Int]] = [:]
    private var stepIndexValid = true
    /// The most steps kept; older ones fall off the front.
    public var trailLimit = 20_000

    public init() {}

    // MARK: Edges

    public func edges(from block: BlockID, kind: EdgeKind? = nil, at stamp: Stamp? = nil) -> [Edge] {
        if kind == .contains { return contained(by: block) }
        return list(out[block], kind: kind, at: stamp) + (kind == nil ? contained(by: block) : [])
    }

    public func edges(to block: BlockID, kind: EdgeKind? = nil, at stamp: Stamp? = nil) -> [Edge] {
        if kind == .contains { return containers(of: block) }
        return list(inbound[block], kind: kind, at: stamp) + (kind == nil ? containers(of: block) : [])
    }

    // MARK: Paths

    public func path(of block: BlockID) -> String? { pathOf[block]?.path }

    /// The blocks at a path on a host, if any.
    public func blocks(at path: String, on host: HostID) -> [BlockID] { atPath[host]?[path] ?? [] }

    /// When a block was last seen (or made), as the registry says.
    public func seen(_ block: BlockID) -> Stamp? { lastSeen[block] ?? createdOf[block] }

    private func setPath(_ block: BlockID, _ path: String?, kind: BlockKind) {
        if let old = pathOf[block] {
            atPath[block.host]?[old.path]?.removeAll { $0 == block }
            pathOf.removeValue(forKey: block)
        }
        guard let path, !path.isEmpty else { return }
        pathOf[block] = (path, kind)
        atPath[block.host, default: [:]][path, default: []].append(block)
    }

    private func setPlace(_ block: BlockID, _ path: String?) {
        if let old = placeOf[block] {
            atPlace[block.host]?[old]?.removeAll { $0 == block }
            placeOf.removeValue(forKey: block)
        }
        guard let path, path.hasPrefix("/") else { return }
        let p = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        placeOf[block] = p
        atPlace[block.host, default: [:]][p, default: []].append(block)
    }

    /// Where a block without a file is, if it said.
    public func place(of block: BlockID) -> String? { placeOf[block] }

    private static func isFolderKind(_ kind: BlockKind) -> Bool { kind == .directory || kind == .git }

    /// The folder blocks holding a block, by its path's parent.
    private func containers(of block: BlockID) -> [Edge] {
        guard let (path, _) = pathOf[block], path.count > 1 else { return [] }
        let parent = path.deletingLastPathComponent
        return blocks(at: parent, on: block.host).filter { pathOf[$0].map { Self.isFolderKind($0.kind) } ?? false }.map { folder in
            Edge(kind: .contains, from: folder, to: block, at: createdOf[block] ?? Stamp(wall: 0, logical: 0, host: block.host),
                 id: "contains:\(folder.ulid):\(block.ulid)", shard: .block(folder))
        }
    }

    /// The blocks a folder block holds directly, by path.
    private func contained(by folder: BlockID) -> [Edge] {
        guard let (path, kind) = pathOf[folder], Self.isFolderKind(kind) else { return [] }
        var out: [Edge] = []
        for (p, blocks) in atPath[folder.host] ?? [:] where p != path && p.deletingLastPathComponent == path {
            for b in blocks where b != folder {
                out.append(Edge(kind: .contains, from: folder, to: b, at: createdOf[b] ?? Stamp(wall: 0, logical: 0, host: b.host),
                                id: "contains:\(folder.ulid):\(b.ulid)", shard: .block(folder)))
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    /// The sparse file tree of a host (§3.6): every block with a path,
    /// under its folders, under a root — a repository (a git block's root)
    /// or the home folder, else `/`. Runs of single folders are one node;
    /// folders that are blocks (a listing, a repository) keep their own.
    public func fileTree(host: HostID, home: String? = nil) -> [FileNode] {
        let paths = atPath[host] ?? [:]
        let places = (atPlace[host] ?? [:]).filter { !$0.value.isEmpty }
        guard !paths.isEmpty || !places.isEmpty else { return [] }
        let repos = Set(pathOf.filter { $0.key.host == host && $0.value.kind == .git }.map(\.value.path))
        func root(of path: String) -> String {
            if let r = repos.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) { return r }
            if let home, path == home || path.hasPrefix(home + "/") { return home }
            return "/"
        }
        // A trie under each root.
        final class Trie {
            var children: [String: Trie] = [:]
            var blocks: [BlockID] = []
            /// Blocks at this folder (not files in it): shown by title.
            var places: [BlockID] = []
            var path: String
            init(path: String) { self.path = path }
        }
        var roots: [String: Trie] = [:]
        func trie(at path: String) -> Trie {
            let r = root(of: path)
            let trie = roots[r] ?? { let t = Trie(path: r); roots[r] = t; return t }()
            var node = trie
            if path != r {
                let rest = r == "/" ? String(path.dropFirst()) : String(path.dropFirst(r.count + 1))
                for part in rest.split(separator: "/").map(String.init) {
                    let child = node.children[part] ?? { let t = Trie(path: node.path == "/" ? "/" + part : node.path + "/" + part); node.children[part] = t; return t }()
                    node = child
                }
            }
            return node
        }
        for (path, blocks) in paths { trie(at: path).blocks += blocks }
        for (path, blocks) in places { trie(at: path).places += blocks }
        func build(_ t: Trie, name: String, root: Bool = false) -> FileNode {
            // A single folder beneath with nothing of its own: folded into
            // this one — but a root keeps its name, being what the tree
            // hangs off.
            var node = t, shown = name
            while !root, node.blocks.isEmpty, node.children.count == 1, let (childName, child) = node.children.first,
                  !child.children.isEmpty || child.blocks.contains(where: { pathOf[$0].map { Self.isFolderKind($0.kind) } ?? false }) {
                node = child
                shown = shown.isEmpty ? childName : shown == "/" ? "/" + childName : shown + "/" + childName
            }
            let folderBlock = node.blocks.first { pathOf[$0].map { Self.isFolderKind($0.kind) } ?? false }
            let fileBlocks = node.blocks.filter { !(pathOf[$0].map { Self.isFolderKind($0.kind) } ?? false) }
            let isFolder = !node.children.isEmpty || folderBlock != nil || !node.places.isEmpty
            // Under a root, single folders fold too ("/" shows "tmp/scratch").
            var children = node.children.map { build($0.value, name: $0.key) }
            // Blocks at this very folder that aren't the folder itself: a
            // patch against it (a non-folder block with the folder's path),
            // a terminal working here, a note at home here — each under the
            // folder by its own title.
            for b in fileBlocks where isFolder {
                children.append(FileNode(path: node.path, host: host, name: "", block: b, kind: pathOf[b]?.kind,
                                         isFolder: false, children: [], count: 1, latest: seen(b), isPlace: true))
            }
            for b in node.places where pathOf[b] == nil {
                children.append(FileNode(path: node.path, host: host, name: "", block: b, kind: nil,
                                         isFolder: false, children: [], count: 1, latest: seen(b), isPlace: true))
            }
            children.sort { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            let block = isFolder ? folderBlock : fileBlocks.first
            let own = block == nil ? 0 : 1
            let count = isFolder ? children.reduce(own) { $0 + $1.count } : 1
            var latest = block.flatMap(seen)
            for c in children { if let l = c.latest, latest.map({ l > $0 }) ?? true { latest = l } }
            return FileNode(path: node.path, host: host, name: shown, block: block, kind: block.flatMap { pathOf[$0]?.kind },
                            isFolder: isFolder, children: children, count: count, latest: latest)
        }
        return roots.map { r, t in
            var n = build(t, name: r == home ? "~" : r.lastPathComponent.isEmpty ? r : r.lastPathComponent, root: true)
            n.isFolder = true
            if n.name.isEmpty { n.name = r }
            return n
        }.sorted { a, b in
            if (a.path == home) != (b.path == home) { return a.path == home }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func list(_ byKind: [EdgeKind: [Edge]]?, kind: EdgeKind?, at stamp: Stamp?) -> [Edge] {
        guard let byKind else { return [] }
        let lists = kind.map { [byKind[$0] ?? []] } ?? Array(byKind.values)
        var all = lists.flatMap { $0.filter { $0.holds(at: stamp) } }
        all.sort { $0.at > $1.at }
        return all
    }

    /// How many edges of a kind hold now: constant time.
    public func count(from block: BlockID, kind: EdgeKind) -> Int { liveOut[block]?[kind] ?? 0 }
    public func count(to block: BlockID, kind: EdgeKind) -> Int { liveIn[block]?[kind] ?? 0 }

    public func edge(_ id: String) -> Edge? { byID[id] }

    /// The arrangements a block is placed in (now, or at a moment).
    public func arrangements(holding block: BlockID, at stamp: Stamp? = nil) -> [BlockID] {
        var seen: Set<BlockID> = []
        return edges(to: block, kind: .placed, at: stamp).compactMap { seen.insert($0.from).inserted ? $0.from : nil }
    }

    /// Everything about a block's surroundings, in one go.
    public func neighborhood(of block: BlockID, at stamp: Stamp? = nil) -> Neighborhood {
        var n = Neighborhood(block: block)
        for (kind, edges) in out[block] ?? [:] {
            let held = edges.filter { $0.holds(at: stamp) }.sorted { $0.at > $1.at }
            if !held.isEmpty { n.outbound[kind] = held }
        }
        for (kind, edges) in inbound[block] ?? [:] {
            let held = edges.filter { $0.holds(at: stamp) }.sorted { $0.at > $1.at }
            if !held.isEmpty { n.inbound[kind] = held }
        }
        n.before = trailNeighbors(of: block, offset: -1, before: stamp)
        n.after = trailNeighbors(of: block, offset: 1, before: stamp)
        let held = contained(by: block), holders = containers(of: block)
        if !held.isEmpty { n.outbound[.contains] = held }
        if !holders.isEmpty { n.inbound[.contains] = holders }
        return n
    }

    /// Blocks within so many edges (either way) of a block, by distance:
    /// a breadth-first walk over what holds now, for ranking.
    public func distances(from start: BlockID, limit: Int = 3) -> [BlockID: Int] {
        var dist: [BlockID: Int] = [start: 0]
        var frontier = [start]
        var d = 0
        while !frontier.isEmpty, d < limit {
            d += 1
            var next: [BlockID] = []
            for b in frontier {
                for e in (out[b] ?? [:]).values.joined() where e.isLive && dist[e.to] == nil {
                    dist[e.to] = d
                    next.append(e.to)
                }
                for e in (inbound[b] ?? [:]).values.joined() where e.isLive && dist[e.from] == nil {
                    dist[e.from] = d
                    next.append(e.from)
                }
            }
            frontier = next
        }
        return dist
    }

    /// Everything reachable from some roots over the strong edges that
    /// hold now (§4): what is kept. Edges from a block are looked up in
    /// this graph alone; across hosts, the caller walks each block's own
    /// host's graph (`Hosts.reachable`).
    public func reachable<S: Sequence>(from roots: S, edgesFrom: ((BlockID) -> [Edge])? = nil) -> Set<BlockID> where S.Element == BlockID {
        var seen = Set(roots)
        var frontier = Array(seen)
        while let b = frontier.popLast() {
            let edges = edgesFrom?(b) ?? strongEdges(from: b)
            for e in edges where seen.insert(e.to).inserted { frontier.append(e.to) }
        }
        return seen
    }

    /// The strong edges that hold now, out of a block.
    public func strongEdges(from block: BlockID) -> [Edge] {
        (out[block] ?? [:]).flatMap { kind, edges in kind.isStrong ? edges.filter(\.isLive) : [] }
    }

    // MARK: The trail

    private func reindexIfNeeded() {
        guard !stepIndexValid else { return }
        stepIndex = [:]
        for (i, s) in steps.enumerated() { stepIndex[s.block, default: []].append(i) }
        stepIndexValid = true
    }

    public var stepCount: Int { steps.count }
    public func step(at i: Int) -> Step? { i >= 0 && i < steps.count ? steps[i] : nil }

    /// The trail's last steps, newest first, each block once.
    public func recent(limit: Int = 50) -> [Step] {
        var seen: Set<BlockID> = []
        var outSteps: [Step] = []
        for s in steps.reversed() where seen.insert(s.block).inserted {
            outSteps.append(s)
            if outSteps.count >= limit { break }
        }
        return outSteps
    }

    /// Every time the block was gone to, newest first.
    public func visits(_ block: BlockID) -> [Step] {
        reindexIfNeeded()
        return (stepIndex[block] ?? []).reversed().map { steps[$0] }
    }

    /// Blocks that came just before (offset -1) or after (+1) each visit
    /// to the block, aggregated: the most frequent first, then the latest.
    public func trailNeighbors(of block: BlockID, offset: Int, before stamp: Stamp? = nil) -> [TrailNeighbor] {
        reindexIfNeeded()
        var counts: [BlockID: (Int, Stamp)] = [:]
        for i in stepIndex[block] ?? [] {
            if let stamp, steps[i].at > stamp { continue }
            // Past runs of the same block.
            var j = i + offset
            while j >= 0, j < steps.count, steps[j].block == block { j += offset }
            guard j >= 0, j < steps.count else { continue }
            let s = steps[j]
            let c = counts[s.block] ?? (0, s.at)
            counts[s.block] = (c.0 + 1, max(c.1, s.at))
        }
        return counts.map { TrailNeighbor(block: $0.key, count: $0.value.0, last: $0.value.1) }
            .sorted { $0.last != $1.last ? $0.last > $1.last : $0.count > $1.count }
    }

    /// The step before (offset -1) or after (+1) the latest visit to a
    /// block: one step back or forward along the trail.
    public func step(from block: BlockID, offset: Int) -> Step? {
        reindexIfNeeded()
        guard let i = stepIndex[block]?.last else { return nil }
        var j = i + offset
        while j >= 0, j < steps.count, steps[j].block == block { j += offset }
        return j >= 0 && j < steps.count ? steps[j] : nil
    }

    // MARK: Maintaining

    private func add(_ edge: Edge) {
        if let old = byID[edge.id] { removeEdge(old) }
        byID[edge.id] = edge
        byShard[edge.shard, default: []].insert(edge.id)
        insert(edge, into: &out[edge.from, default: [:]][edge.kind, default: []])
        insert(edge, into: &inbound[edge.to, default: [:]][edge.kind, default: []])
        if edge.isLive {
            liveOut[edge.from, default: [:]][edge.kind, default: 0] += 1
            liveIn[edge.to, default: [:]][edge.kind, default: 0] += 1
        }
    }

    /// Kept in order of `at`, so a list reads as a timeline.
    private func insert(_ edge: Edge, into list: inout [Edge]) {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].at <= edge.at { lo = mid + 1 } else { hi = mid }
        }
        list.insert(edge, at: lo)
    }

    private func removeEdge(_ edge: Edge) {
        byID.removeValue(forKey: edge.id)
        byShard[edge.shard]?.remove(edge.id)
        out[edge.from]?[edge.kind]?.removeAll { $0.id == edge.id }
        inbound[edge.to]?[edge.kind]?.removeAll { $0.id == edge.id }
        if edge.isLive {
            liveOut[edge.from]?[edge.kind, default: 1] -= 1
            liveIn[edge.to]?[edge.kind, default: 1] -= 1
        }
    }

    /// Ends an interval edge: it stays, for the past, but no longer holds.
    private func end(_ id: String, at: Stamp) {
        guard let edge = byID[id], edge.isLive else { return }
        var ended = edge
        ended.until = at
        removeEdge(edge)
        add(ended)
    }

    private func addStep(_ step: Step, from shard: ShardID) {
        if let last = steps.last, last.at > step.at {
            // Out of order (another host's trail arriving late): kept sorted.
            var lo = 0, hi = steps.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if steps[mid].at <= step.at { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, steps[lo - 1] == step { return }
            steps.insert(step, at: lo)
            stepShards.insert(shard, at: lo)
            stepIndexValid = false
        } else {
            // The same block again, right away, is one visit.
            if let last = steps.last, last.block == step.block { return }
            steps.append(step)
            stepShards.append(shard)
            if stepIndexValid { stepIndex[step.block, default: []].append(steps.count - 1) }
        }
        if steps.count > trailLimit {
            let n = steps.count - trailLimit
            steps.removeFirst(n)
            stepShards.removeFirst(n)
            stepIndexValid = false
        }
    }

    /// An entry applied to a shard, with the shard's state after it.
    public func apply(_ entry: Entry, to shard: ShardID, state: ShardState) {
        switch (shard, entry.event) {
        case let (.block(id), .create(kind, _, path)):
            createdOf[id] = entry.at
            setPath(id, path, kind: kind)
        case let (.block(id), .path(p)):
            if let kind = pathOf[id]?.kind ?? state.block?.kind { setPath(id, p, kind: kind) }
            if p != nil { setPlace(id, nil) }
        case let (.block(id), .cwd(c)):
            // Where a terminal works, or a note is at home: its place, while
            // it has no file of its own.
            if pathOf[id] == nil { setPlace(id, c) }
        case let (.registry, .seen(ids, at)):
            for id in ids { lastSeen[id] = at }
        case let (.registry, .register(e)):
            if lastSeen[e.id] == nil { lastSeen[e.id] = e.lastSeen }
        case let (.block(arrangement), .place(p, _, _)):
            add(Edge(kind: .placed, from: arrangement, to: p.block, at: entry.at, id: p.id, shard: shard))
        case let (.block(arrangement), .adopt(cols, _)):
            for p in cols.joined() where byID[p.id] == nil {
                add(Edge(kind: .placed, from: arrangement, to: p.block, at: entry.at, id: p.id, shard: shard))
            }
        case let (.block, .remove(pid)):
            end(pid, at: entry.at)
        case let (.registry, .step(s)):
            addStep(s, from: shard)
        case let (.links, .link(l)):
            // One link of a kind between two blocks, as the links shard keeps them.
            for old in edges(from: l.from, kind: .link(l.kind)) where old.to == l.to { removeEdge(old) }
            add(Edge(kind: .link(l.kind), from: l.from, to: l.to, at: l.at, context: l.context, id: l.id, shard: shard))
        case let (.links, .unlink(id)):
            if let e = byID[id] { removeEdge(e) }
        case (.links, .clearGraph):
            forgetEdges(of: shard)
        case (.registry, .clearGraph):
            forgetSteps(of: shard)
        default:
            break
        }
    }

    /// Forgets a shard's edges and steps: before its state is replaced.
    public func remove(_ shard: ShardID) {
        forgetEdges(of: shard)
        if case .block(let id) = shard {
            if let (_, kind) = pathOf[id] { setPath(id, nil, kind: kind) }
            setPlace(id, nil)
            createdOf.removeValue(forKey: id)
        }
        forgetSteps(of: shard)
    }

    private func forgetEdges(of shard: ShardID) {
        for id in byShard[shard] ?? [] {
            if let e = byID[id] { removeEdge(e) }
        }
        byShard.removeValue(forKey: shard)
    }

    private func forgetSteps(of shard: ShardID) {
        guard stepShards.contains(shard) else { return }
        var kept: [Step] = [], keptShards: [ShardID] = []
        for (s, sh) in zip(steps, stepShards) where sh != shard {
            kept.append(s)
            keptShards.append(sh)
        }
        steps = kept
        stepShards = keptShards
        stepIndexValid = false
    }

    /// Indexes a shard from its state and its kept entries: the entries
    /// first, for when things were placed and the steps; then whatever the
    /// state holds that the entries didn't say (placed before they begin).
    public func load(_ shard: ShardID, state: ShardState, entries: [Entry]) {
        remove(shard)
        // The trail is in the registry's state whole: not again from its entries.
        if case .registry(let r) = state {
            for s in r.trail { addStep(s, from: shard) }
            for (id, e) in r.blocks { lastSeen[id] = e.lastSeen }
            return
        }
        for e in entries { apply(e, to: shard, state: state) }
        switch state {
        case .block(let b):
            createdOf[b.id] = b.created
            setPath(b.id, b.path, kind: b.kind)
            // Its place, from the state: a terminal's working directory, a
            // note's home — when it has no file of its own.
            setPlace(b.id, b.path == nil ? (b.terminal?.cwd ?? b.home) : nil)
            if let a = b.arrangement {
                for p in a.placements where byID[p.id] == nil {
                    add(Edge(kind: .placed, from: b.id, to: p.block, at: p.placedAt ?? b.created, id: p.id, shard: shard))
                }
                // Placements the state no longer has, but the entries placed: ended at an unknown time.
                for id in byShard[shard] ?? [] {
                    if let e = byID[id], e.kind == .placed, e.isLive, a.placement(id) == nil { end(id, at: e.at) }
                }
            }
        case .links(let l):
            for link in l.links where byID[link.id] == nil {
                add(Edge(kind: .link(link.kind), from: link.from, to: link.to, at: link.at, context: link.context, id: link.id, shard: shard))
            }
        default:
            break
        }
    }

    /// Everything again, from a node.
    public func rebuild(from node: Node) {
        out = [:]; inbound = [:]; byID = [:]; byShard = [:]; liveOut = [:]; liveIn = [:]
        pathOf = [:]; atPath = [:]; placeOf = [:]; atPlace = [:]; createdOf = [:]; lastSeen = [:]
        steps = []; stepShards = []; stepIndex = [:]; stepIndexValid = true
        for (shard, r) in node.shards { load(shard, state: r.state, entries: r.entries) }
    }
}
