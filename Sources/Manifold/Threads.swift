import Foundation
import ManifoldCore

/// Threads across every host (§3.12): a space's, a project's, a place's;
/// what's not been seen of them; and writing to them — as the app sees
/// them, every host's graph asked by its indexes.
extension Hosts {
    /// You, on this Mac: who the app's own comments are by.
    static var you: ThreadAuthor { .you(machine: HostClient.machine) }

    /// Every thread there is, on every host.
    var threads: [Block] {
        all.flatMap { c in c.node.graph.blocks(kind: .thread).compactMap { c.block($0) } }
    }

    /// A space's threads: those made in it, and those about it.
    func threads(inSpace space: BlockID) -> [Block] {
        var ids = Set<BlockID>()
        for c in all {
            for e in c.node.graph.edges(from: space, kind: .link(.thread)) { ids.insert(e.to) }
        }
        var out = ids.compactMap { block($0) }
        // Those the space's link hasn't come for yet (made elsewhere), by
        // their own say.
        for t in threads where t.thread?.space == space && !ids.contains(t.id) { out.append(t) }
        return out
    }

    /// A project's threads: about something in it — a file, a folder, a
    /// terminal working there — or about the project's folder itself.
    func threads(inProject root: String, on host: HostID) -> [Block] {
        guard let g = client(host)?.node.graph else { return [] }
        return threads.filter { t in
            guard let about = t.thread?.about?.block, about.host == host else { return false }
            return g.project(of: about) == root
        }
    }

    /// The threads about a block, or a place in it (its anchor).
    func threads(about block: BlockID, anchor: String? = nil, anyPlace: Bool = false) -> [Block] {
        var out: [Block] = []
        for c in all {
            let edges = anyPlace ? c.node.graph.edges(to: block, kind: .link(.linked)).filter { $0.relation == ThreadText.annotates }
                : c.node.graph.edges(to: block, anchor: anchor, relation: ThreadText.annotates)
            out += edges.compactMap { e in self.block(e.from).flatMap { $0.kind == .thread ? $0 : nil } }
        }
        return out
    }

    /// The threads that mention a block (a comment naming it).
    func threads(mentioning block: BlockID) -> [Block] {
        var out: [Block] = []
        for c in all {
            out += c.node.graph.edges(to: block, kind: .link(.opened)).filter { $0.relation == ThreadText.mentions }
                .compactMap { e in self.block(e.from).flatMap { $0.kind == .thread ? $0 : nil } }
        }
        return out
    }

    /// What you've seen of a thread: its latest entry seen.
    func seenMark(_ thread: BlockID) -> Stamp? { client(thread.host)?.desk.threadsSeen[thread] }

    /// A thread's entries you haven't seen that are worth telling you of.
    func unseen(_ thread: Block) -> [ThreadEntry] {
        thread.thread?.unseen(after: seenMark(thread.id)) ?? []
    }

    /// The threads with something not seen: what the inbox holds of them.
    var unseenThreads: [Block] { threads.filter { !unseen($0).isEmpty } }

    /// Seen, up to an entry (the latest, if not said).
    func markSeen(_ thread: Block, upTo: Stamp? = nil) {
        guard let last = upTo ?? thread.thread?.lastActivity else { return }
        if let mark = seenMark(thread.id), mark >= last { return }
        propose(.threadSeen([thread.id: last]))
    }

    func markSeen(_ threads: [Block]) {
        var marks: [BlockID: Stamp] = [:]
        for t in threads {
            guard let last = t.thread?.lastActivity, seenMark(t.id).map({ last > $0 }) ?? true else { continue }
            marks[t.id] = last
        }
        if !marks.isEmpty { propose(.threadSeen(marks)) }
    }

    /// A thread made, on the space's host (the place's if there's no
    /// space): its id.
    @discardableResult
    func newThread(about: ThreadPlace, space: BlockID?, text: String, author: ThreadAuthor = Hosts.you, done: ((String?) -> Void)? = nil) -> BlockID {
        let id = BlockID(host: space?.host ?? about.block.host)
        propose(.newThread(block: id, space: space, about: about, text: text, author: author), done: done)
        return id
    }

    /// A comment, or something done to a thread.
    func addToThread(_ thread: BlockID, _ kind: ThreadEntryKind, author: ThreadAuthor = Hosts.you, done: ((String?) -> Void)? = nil) {
        let entry = ThreadEntry(at: client(thread.host)?.clock.now() ?? Stamp(wall: 0), author: author, kind: kind)
        propose(.threadEntry(block: thread, entry), done: done)
    }
}
