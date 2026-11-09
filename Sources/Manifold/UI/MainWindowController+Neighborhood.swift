import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: The neighborhood, in graph form


    /// ⇧⌥⌘M: the neighborhood map, around the focused block.
    @objc func showNeighborhood(_ sender: Any?) { showNeighborhood(around: nil) }

    /// The neighborhood map: a block's neighborhood to distance 2 as a
    /// picture, to look around and walk; ⌘-click or ⏎ goes to a block.
    /// The one big view of the links; the small one is the tile's badge.
    func showNeighborhood(around block: BlockID?) {
        guard neighborhoodView == nil else { return hideNeighborhood() }
        guard let center = block ?? focusedShown?.placement.block ?? selected else { return }
        let v = NeighborhoodView(frame: root.bounds)
        v.source = { [weak self] id in self?.neighborhoodModel(of: id) ?? NeighborhoodModel(center: id, nodes: [], edges: []) }
        v.onClose = { [weak self] in self?.hideNeighborhood() }
        v.onGo = { [weak self] id in
            self?.hideNeighborhood()
            self?.goTo(id)
        }
        root.addSubview(v, positioned: .above, relativeTo: nil)
        neighborhoodView = v
        v.layoutSubtreeIfNeeded()
        v.center(on: center)
    }

    private func hideNeighborhood() {
        neighborhoodView?.removeFromSuperview()
        neighborhoodView = nil
        if let f = arrangement?.focused { focus(f) }
        render()
    }

    func debugNeighborhood(settle: Bool) -> String {
        if neighborhoodView == nil { showNeighborhood(nil) }
        guard let v = neighborhoodView else { return "nothing focused" }
        if settle { v.settleForScript() }
        guard let center = focusedShown?.placement.block ?? selected else { return "" }
        let m = neighborhoodModel(of: center)
        return m.nodes.map { "\($0.distance) \($0.title)" }.joined(separator: "\n") + "\n" + m.edges.map { "\($0.label): \($0.from.ulid.suffix(4)) → \($0.to.ulid.suffix(4))" }.joined(separator: "\n")
    }

    /// The neighborhood to distance 2: the nearest few dozen by when
    /// their edges were made, each outer node behind the inner one it hangs
    /// off; how many more each has is counted.
    func neighborhoodModel(of center: BlockID) -> NeighborhoodModel {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var more: [BlockID: Int] = [:]
        var have: Set<BlockID> = [center]
        func node(_ id: BlockID, distance: Int) -> GraphNode? {
            guard let b = hosts.block(id) else { return nil }
            let detail: String = switch b.kind {
            case .arrangement: "Space"
            case .terminal: b.terminal?.cwd?.abbreviatingHome ?? "Terminal"
            default: b.path?.deletingLastPathComponent.abbreviatingHome ?? b.kind.defaultTitle
            }
            return GraphNode(id: id, title: b.displayTitle, symbol: Theme.symbolName(for: b), detail: detail,
                             distance: distance, isArrangement: b.kind == .arrangement)
        }
        func addEdge(_ e: GraphEdge) {
            if !edges.contains(where: { $0.from == e.from && $0.to == e.to && $0.kind == e.kind }) { edges.append(e) }
        }
        /// A block's edges, as (other, edge), newest first; the trail's as
        /// kind-less edges.
        func around(_ id: BlockID) -> [(BlockID, GraphEdge)] {
            let n = hosts.neighborhood(of: id)
            var out: [(Stamp, BlockID, GraphEdge)] = []
            for (k, es) in n.outbound { for e in es { out.append((e.at, e.to, GraphEdge(from: e.from, to: e.to, kind: k, context: e.context, at: e.at))) } }
            for (k, es) in n.inbound { for e in es { out.append((e.at, e.from, GraphEdge(from: e.from, to: e.to, kind: k, context: e.context, at: e.at))) } }
            for t in n.before where t.block != id { out.append((t.last, t.block, GraphEdge(from: t.block, to: id, kind: nil, context: t.count == 1 ? "once" : "\(t.count) times", at: t.last))) }
            for t in n.after where t.block != id { out.append((t.last, t.block, GraphEdge(from: id, to: t.block, kind: nil, context: t.count == 1 ? "once" : "\(t.count) times", at: t.last))) }
            return out.sorted { $0.0 > $1.0 }.map { ($0.1, $0.2) }
        }
        guard let c = node(center, distance: 0) else { return NeighborhoodModel(center: center, nodes: [], edges: []) }
        nodes.append(c)
        let inner = around(center)
        var ring1: [BlockID] = []
        for (other, e) in inner {
            if !have.contains(other), ring1.count < 20, let n = node(other, distance: 1) {
                have.insert(other)
                ring1.append(other)
                nodes.append(n)
            }
            if have.contains(other) { addEdge(e) } else { more[center, default: 0] += 1 }
        }
        var total2 = 0
        for id in ring1 {
            var count = 0
            for (other, e) in around(id) {
                if other == center { continue }
                if have.contains(other) {
                    addEdge(e)
                } else if count < 6, total2 < 40, let n = node(other, distance: 2) {
                    have.insert(other)
                    nodes.append(n)
                    addEdge(e)
                    count += 1
                    total2 += 1
                } else {
                    more[id, default: 0] += 1
                }
            }
        }
        return NeighborhoodModel(center: center, nodes: nodes, edges: edges, more: more)
    }
}
