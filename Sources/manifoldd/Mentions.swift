import Foundation
import ManifoldCore

/// Keeps the links a text mentions (§3.6) in the links shard as the text
/// changes: `[[titles]]` and paths found in it are resolved to blocks —
/// made for files that have none yet — and the block's `mention` links
/// are brought to match, a moment after the last change.
///
/// A block named by its reference (`manifold:host/id`, as `mani ref`
/// writes and a dropped pill lands) is kept by what names it (§4): its
/// link means `mentions` — in a note, a thread's comment, what an agent
/// said or was asked. What's named by a title or a path isn't: it's found
/// again by them, where an id once collected is gone.
extension Server {
    func mentionsChanged(_ block: BlockID) {
        mentionsDue.schedule(block, after: 1) { [weak self] in self?.refreshMentions(block) }
    }

    /// Once, at the start: every text's and agent's links brought to match
    /// what they say (references written before they kept anything).
    func refreshAllMentions() {
        for b in node.blocks where b.id.host == host && (b.kind == .text && b.text != nil || b.terminal?.turns?.isEmpty == false) {
            mentionsChanged(b.id)
        }
    }

    private func refreshMentions(_ block: BlockID) {
        let all = node.blocks
        guard let b = all.first(where: { $0.id == block }) else { return }
        if let turns = b.terminal?.turns, b.kind != .text { return agentMentions(b, turns) }
        guard let text = b.text?.text.string else { return }
        // Each block the text names: an image it shows (`![…](…)`) is
        // embedded, kept by the text; the rest mentioned.
        // By the block and the place in it (§2.5): one link to each.
        var wanted: [LinkTarget: Wanted] = [:]
        for m in Mention.find(in: text) {
            guard let to = resolve(m.target, from: b, among: all), to != block else { continue }
            let target = LinkTarget(block: to, anchor: m.anchor)
            let words = String(m.text.prefix(118))
            let embeds = m.embeds && all.first(where: { $0.id == to })?.kind == .image
            let named: String? = if case .block = m.target { ThreadText.mentions } else { nil }
            if embeds || wanted[target] == nil {
                wanted[target] = embeds ? ("![" + words + "]", .embeds, nil) : ("[[" + words + "]]", .opened, named)
            }
        }
        let have = node.graph.edges(from: block, kind: .link(.opened)).filter { $0.context?.hasPrefix("[[") == true }
            + node.graph.edges(from: block, kind: .link(.embeds)).filter { $0.context?.hasPrefix("![") == true }
        reconcileLinks(from: block, wanted: wanted, existing: have)
    }

    /// An agent's references: the blocks what it said, or was asked,
    /// names — its conversation's links, kept while it is.
    private func agentMentions(_ b: Block, _ turns: [AgentTurn]) {
        var wanted: [LinkTarget: Wanted] = [:]
        for t in turns {
            for m in Mention.find(in: t.prompt) + Mention.find(in: t.message ?? "") {
                guard case .block(let to) = m.target, to != b.id else { continue }
                let target = LinkTarget(block: to, anchor: m.anchor)
                if wanted[target] == nil { wanted[target] = ("[[" + String(m.text.prefix(118)) + "]]", .opened, ThreadText.mentions) }
            }
        }
        let have = node.graph.edges(from: b.id, kind: .link(.opened)).filter { $0.relation == ThreadText.mentions }
        reconcileLinks(from: b.id, wanted: wanted, existing: have)
    }

    typealias Wanted = (context: String, kind: LinkKind, relation: String?)

    /// A block's links brought to match what it says: each target wanted
    /// linked, with its words, kind and meaning, and each link there that
    /// isn't wanted (or is, said otherwise) gone.
    func reconcileLinks(from block: BlockID, wanted: [LinkTarget: Wanted], existing: [Edge]) {
        func same(_ e: Edge, _ w: Wanted) -> Bool { e.context == w.context && e.kind == .link(w.kind) && e.relation == w.relation }
        for e in existing where wanted[LinkTarget(block: e.to, anchor: e.toAnchor)].map({ !same(e, $0) }) ?? true {
            append(.unlink(e.id), to: .links(host))
        }
        for (target, w) in wanted where !existing.contains(where: { $0.to == target.block && $0.toAnchor == target.anchor && same($0, w) }) {
            append(.link(Link(from: block, to: target.block, kind: w.kind, at: clock.now(), context: w.context,
                              toAnchor: target.anchor, relation: w.relation)), to: .links(host))
        }
    }

    /// A mention's block: by title among the blocks here, or by path — a
    /// file beside the mentioning one, made a block if it's there.
    private func resolve(_ target: Mention.Target, from b: Block, among all: [Block]) -> BlockID? {
        switch target {
        case .title(let title):
            let key = title.lowercased()
            if let t = all.first(where: { $0.kind == .text && $0.displayTitle.lowercased() == key }) { return t.id }
            if let t = all.first(where: { $0.kind == .text && ($0.path?.lastPathComponent.lowercased() == key + ".md" || $0.path?.lastPathComponent.lowercased() == key) }) { return t.id }
            // A file so named beside this one.
            if let path = b.path {
                for name in [title + ".md", title] {
                    let candidate = path.deletingLastPathComponent.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: candidate) { return mentionedBlock(for: candidate, among: all) }
                }
            }
            return nil
        case .block(let id):
            return id
        case .path(let p):
            guard let path = Mention.resolve(p, from: b.path) else { return nil }
            guard FileManager.default.isDirectory(atPath: path) == false else { return nil }
            return mentionedBlock(for: path, among: all)
        }
    }

    func mentionedBlock(for path: String, among all: [Block], kind wanted: BlockKind? = nil) -> BlockID? {
        let kind = wanted ?? BlockKind.forFile(path)
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let b = all.first(where: { $0.kind == kind && ($0.path == path || $0.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == real } ?? false) }) {
            return b.id
        }
        // A block for a file the text names, before anyone opens it: the
        // app finds it by path when they do.
        let id = BlockID(host: host)
        append(.create(kind: kind, title: nil, path: path), to: .block(id))
        return id
    }
}

/// What a link goes to: a block, and a place in it (§2.5).
struct LinkTarget: Hashable {
    var block: BlockID
    var anchor: String?
}
