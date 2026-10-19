import Foundation
import ManifoldCore

/// Keeps the links a text mentions (§3.6) in the links shard as the text
/// changes: `[[titles]]` and paths found in it are resolved to blocks —
/// made for files that have none yet — and the block's `mention` links
/// are brought to match, a moment after the last change.
final class Mentions {
    private let queue: DispatchQueue
    private var pending: [BlockID: DispatchWorkItem] = [:]
    /// The blocks on this host, to resolve against.
    var blocks: () -> [Block] = { [] }
    var mentions: (BlockID) -> [Edge] = { _ in [] }
    /// A block to make for a file, giving its id.
    var makeBlock: ((_ kind: BlockKind, _ path: String) -> BlockID)?
    var link: ((Link) -> Void)?
    var unlink: ((String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func textChanged(_ block: BlockID) {
        pending[block]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(block) }
        pending[block] = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func refresh(_ block: BlockID) {
        pending.removeValue(forKey: block)
        let all = blocks()
        guard let b = all.first(where: { $0.id == block }), let text = b.text?.text.string else { return }
        var wanted: [BlockID: String] = [:]
        for m in Mention.find(in: text) {
            guard let target = resolve(m.target, from: b, among: all), target != block else { continue }
            if wanted[target] == nil { wanted[target] = m.text }
        }
        let have = mentions(block)
        for e in have where wanted[e.to] == nil { unlink?(e.id) }
        for (to, words) in wanted where !have.contains(where: { $0.to == to && $0.context == words }) {
            link?(Link(from: block, to: to, kind: .mention, at: Stamp(wall: Int64(Date().timeIntervalSince1970 * 1000), logical: 0, host: block.host),
                       context: String(words.prefix(120))))
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
                    if FileManager.default.fileExists(atPath: candidate) { return block(for: candidate, among: all) }
                }
            }
            return nil
        case .path(let p):
            guard let path = Mention.resolve(p, from: b.path) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return block(for: path, among: all)
        }
    }

    private func block(for path: String, among all: [Block]) -> BlockID? {
        let kind = BlockKind.forFile(path)
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let b = all.first(where: { $0.kind == kind && ($0.path == path || $0.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == real } ?? false) }) {
            return b.id
        }
        return makeBlock?(kind, path)
    }
}
