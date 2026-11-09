import Foundation
import ManifoldCore

/// Keeps the links a text mentions (§3.6) in the links shard as the text
/// changes: `[[titles]]` and paths found in it are resolved to blocks —
/// made for files that have none yet — and the block's `mention` links
/// are brought to match, a moment after the last change.
extension Server {
    func mentionsChanged(_ block: BlockID) {
        mentionsDue.schedule(block, after: 1) { [weak self] in self?.refreshMentions(block) }
    }

    private func refreshMentions(_ block: BlockID) {
        let all = node.blocks
        guard let b = all.first(where: { $0.id == block }), let text = b.text?.text.string else { return }
        // Each block the text names: an image it shows (`![…](…)`) is
        // embedded, kept by the text; the rest mentioned.
        // By the block and the place in it (§2.5): one link to each.
        var wanted: [LinkTarget: (context: String, kind: LinkKind)] = [:]
        for m in Mention.find(in: text) {
            guard let to = resolve(m.target, from: b, among: all), to != block else { continue }
            let target = LinkTarget(block: to, anchor: m.anchor)
            let words = String(m.text.prefix(118))
            let embeds = m.embeds && all.first(where: { $0.id == to })?.kind == .image
            if embeds || wanted[target] == nil { wanted[target] = embeds ? ("![" + words + "]", .embeds) : ("[[" + words + "]]", .opened) }
        }
        let have = node.graph.edges(from: block, kind: .link(.opened)).filter { $0.context?.hasPrefix("[[") == true }
            + node.graph.edges(from: block, kind: .link(.embeds)).filter { $0.context?.hasPrefix("![") == true }
        reconcileLinks(from: block, wanted: wanted, existing: have)
    }

    /// A block's links brought to match what it says: each target wanted
    /// linked, with its words and kind, and each link there that isn't
    /// wanted (or is, said otherwise) gone.
    func reconcileLinks(from block: BlockID, wanted: [LinkTarget: (context: String, kind: LinkKind)], existing: [Edge], relation: String? = nil) {
        for e in existing where wanted[LinkTarget(block: e.to, anchor: e.toAnchor)].map({ $0.context != e.context || .link($0.kind) != e.kind }) ?? true {
            append(.unlink(e.id), to: .links(host))
        }
        for (target, w) in wanted where !existing.contains(where: { $0.to == target.block && $0.toAnchor == target.anchor && $0.context == w.context && $0.kind == .link(w.kind) }) {
            append(.link(Link(from: block, to: target.block, kind: w.kind, at: clock.now(), context: w.context,
                              toAnchor: target.anchor, relation: relation)), to: .links(host))
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
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return mentionedBlock(for: path, among: all)
        }
    }

    private func mentionedBlock(for path: String, among all: [Block]) -> BlockID? {
        let kind = BlockKind.forFile(path)
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
