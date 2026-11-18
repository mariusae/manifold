import Foundation

/// Threads (§3.12): a conversation about something — a place in a block
/// (§2.5), or a whole space — with yourself or an agent. A thread is a
/// block of its own; its log is its entries, each with who made it.

/// Who made an entry: first-class, and fenced — set from how the entry
/// came (the app, typed: you; `mani`, by the terminal its caller runs
/// under), never claimed.
public enum ThreadAuthor: Codable, Equatable, Hashable, Sendable {
    /// You, the same on every Mac; the Mac it came from, said on hover.
    case you(machine: String?)
    /// An agent: the terminal it runs in, what it is (Claude, Codex, …),
    /// and the turn that wrote it, if known.
    case agent(block: BlockID, name: String, turn: Int?)
    /// What no one typed: a place gone, asking stopped.
    case manifold

    public var isYou: Bool { if case .you = self { true } else { false } }
    public var agentBlock: BlockID? { if case let .agent(b, _, _) = self { b } else { nil } }

    /// As its pill says it.
    public var name: String {
        switch self {
        case .you: "You"
        case let .agent(_, name, _): name
        case .manifold: "Manifold"
        }
    }

    /// The same author, whatever turn or Mac.
    public func same(as other: ThreadAuthor) -> Bool {
        switch (self, other) {
        case (.you, .you), (.manifold, .manifold): true
        case let (.agent(a, _, _), .agent(b, _, _)): a == b
        default: false
        }
    }
}

/// What an entry is: a comment, or something that happened to the thread.
public enum ThreadEntryKind: Codable, Equatable, Sendable {
    /// Markdown; references in it are a note's (§3.10).
    case comment(String)
    case resolved
    case reopened
    /// An agent asked to look (tagged, following, or handed it).
    case asked(agent: BlockID, name: String)
    /// What it's about edited: lines added and taken away there.
    case edited(added: Int, removed: Int)
    /// What it's about is gone from its block (its lines deleted).
    case gone
    /// Asking agents stopped: too many asks in a row without you.
    case stopped(String)
    /// Its context (§3.12's shelf) changed: an agent brought into the
    /// conversation or taken out, a reference put on it or taken off — by
    /// its address (`manifold:…`), named as it was then.
    case context(added: Bool, address: String, title: String)
}

/// A thread's context — the shelf: the agents in its conversation (its
/// participants, the lead first), and the blocks put there to stay part
/// of it (at a place in one, its anchor). Each is a link from the thread
/// (`linked`, meaning `participant` or `shelved`), strong while the
/// thread is open: what's on an open thread's shelf is kept, as what a
/// space shows is; resolved, it lets go of them.
public enum ThreadContext {
    public static let participant = "participant"
    public static let shelved = "shelved"
    /// The relations that hold only while their thread is open.
    public static let whileOpen: Set<String> = [participant, shelved]
    /// The agent a thread asks first (its lead), by id: kept as its
    /// annotation, the lead being a choice rather than a relation.
    public static let leadKey = "asks.agent"

    /// As the shelf was kept before its links: annotations, read once by
    /// the host into links (`settlingThreads`).
    public static let participantsKey = "participants"
    public static let referencesKey = "context"

    public static func legacyParticipants(of t: Block) -> [BlockID]? {
        t.annotations?[participantsKey].map { $0.split(separator: ",").compactMap { BlockID(string: String($0)) } }
    }

    public static func legacyReferences(of t: Block) -> [String]? {
        t.annotations?[referencesKey].map { $0.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
    }
}

extension Node {
    /// A thread's participants (§3.12): its `participant` links, the lead
    /// first, then the rest in the order they came.
    public func participants(of thread: BlockID) -> [BlockID] {
        var ids: [BlockID] = []
        for e in graph.edges(from: thread, kind: .link(.linked)).sorted(by: { $0.at < $1.at })
        where e.relation == ThreadContext.participant && !ids.contains(e.to) { ids.append(e.to) }
        if let s = block(thread)?.annotations?[ThreadContext.leadKey], let lead = BlockID(string: s), let i = ids.firstIndex(of: lead), i > 0 {
            ids.remove(at: i)
            ids.insert(lead, at: 0)
        }
        return ids
    }

    /// What's kept on a thread's shelf besides its agents: each block, at
    /// a place in it if one was put there, in the order they came.
    public func shelved(of thread: BlockID) -> [(block: BlockID, anchor: String?)] {
        var out: [(block: BlockID, anchor: String?)] = []
        for e in graph.edges(from: thread, kind: .link(.linked)).sorted(by: { $0.at < $1.at })
        where e.relation == ThreadContext.shelved && !out.contains(where: { $0.block == e.to && $0.anchor == e.toAnchor }) {
            out.append((e.to, e.toAnchor))
        }
        return out
    }

    /// The threads a block is in (§3.12): about it, with it on their shelf,
    /// named in a comment of theirs, or — an agent — with it in their
    /// conversation; by the links to it in this host's graph, newest first.
    public func threads(of block: BlockID) -> [BlockID] {
        var seen = Set<BlockID>()
        let held = graph.edges(to: block, kind: .link(.linked))
            .filter { [ThreadText.annotates, ThreadContext.participant, ThreadContext.shelved].contains($0.relation ?? "") }
        let named = graph.edges(to: block, kind: .link(.opened)).filter { $0.relation == ThreadText.mentions }
        return (held + named).sorted { $0.at > $1.at }
            .filter { graph.kind(of: $0.from) == .thread || self.block($0.from)?.kind == .thread }
            .compactMap { seen.insert($0.from).inserted ? $0.from : nil }
    }
}

public struct ThreadEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Stamp
    public var author: ThreadAuthor
    public var kind: ThreadEntryKind
    /// A comment's words last changed by its author (`threadEdit`), when.
    public var edited: Stamp?

    public init(id: String = ULID.make(), at: Stamp, author: ThreadAuthor, kind: ThreadEntryKind) {
        self.id = id
        self.at = at
        self.author = author
        self.kind = kind
    }

    public var comment: String? { if case .comment(let t) = kind { t } else { nil } }

    /// Worth telling you of, as far as the entry goes: something an agent
    /// said — a comment — not your own, not Manifold's (asking stopped, a
    /// place moving under it), not a resolve or a reopen. Whether the
    /// thread makes it news is its own (`ThreadState.unseen`).
    public var isNotable: Bool {
        guard case .agent = author, case .comment = kind else { return false }
        return true
    }

    /// Whether a comment names you: `@you`, `@me`, `@user`.
    public var mentionsYou: Bool {
        guard let text = comment else { return false }
        return ThreadText.tags(in: text).contains { ["you", "me", "user"].contains($0.lowercased()) }
    }
}

/// Where a thread made in a diff was: the diff, the file and which side,
/// the lines on that side (from 1), and the commit if the diff is one.
public struct DiffPlace: Codable, Equatable, Sendable {
    public var block: BlockID
    public var file: String
    /// The new side (lines as the change made them), else the old.
    public var new: Bool
    public var start: Int
    public var end: Int
    public var commit: String?

    public init(block: BlockID, file: String, new: Bool, start: Int, end: Int, commit: String? = nil) {
        self.block = block
        self.file = file
        self.new = new
        self.start = start
        self.end = end
        self.commit = commit
    }
}

/// What a thread is about: a block, a place in it (its anchor), and what
/// it was written against — kept as it was, as the place drifts.
public struct ThreadPlace: Codable, Equatable, Sendable {
    /// The block (a space, for one about the space).
    public var block: BlockID
    public var anchor: String?
    /// The text it was written against: the lines as they were; a diff's
    /// rows, each with its mark (+, -, or a space).
    public var context: String?
    /// The first line (from 1) it was written at, in its file.
    public var line: Int?
    /// The file's path then, or the block's title.
    public var title: String?
    /// What the place is called: a declaration's path, a heading, "Page 3".
    public var name: String?
    /// Made in a diff: where.
    public var diff: DiffPlace?
    /// Made on a past version (the history strip, §7.1): the commit whose
    /// text it was written against.
    public var revision: String?

    public init(block: BlockID, anchor: String? = nil, context: String? = nil, line: Int? = nil, title: String? = nil, name: String? = nil, diff: DiffPlace? = nil) {
        self.block = block
        self.anchor = anchor
        self.context = context
        self.line = line
        self.title = title
        self.name = name
        self.diff = diff
    }
}

/// A thread block's state: what it's about, the space it's in, its
/// entries in order, and whether it's resolved.
public struct ThreadState: Codable, Equatable, Sendable {
    public var about: ThreadPlace?
    public var space: BlockID?
    public var entries: [ThreadEntry] = []
    public var resolved = false

    public init() {}

    public mutating func apply(_ event: Event) {
        switch event {
        case let .threadAbout(p): about = p
        case let .threadSpace(s): space = s
        case let .threadEntry(e):
            guard !entries.contains(where: { $0.id == e.id }) else { return }
            entries.append(e)
            switch e.kind {
            case .resolved: resolved = true
            case .reopened: resolved = false
            default: break
            }
        case let .threadEdit(id, text, by, at):
            // A comment, by whoever wrote it: no one else's words changed.
            guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].comment != nil, entries[i].author.same(as: by) else { return }
            entries[i].kind = .comment(text)
            entries[i].edited = at
        default: break
        }
    }

    public var comments: [ThreadEntry] { entries.filter { $0.comment != nil } }
    public var lastActivity: Stamp? { entries.last?.at }
    public var lastComment: ThreadEntry? { entries.last { $0.comment != nil } }

    /// What it's called: its first comment's first words.
    public var title: String? {
        guard let first = comments.first?.comment else { return nil }
        for line in first.split(separator: "\n") {
            let words = Block.plainWords(String(line))
            if !words.isEmpty { return String(words.prefix(80)) }
        }
        return nil
    }

    /// The agents that have written in it: those it follows to (§3.12).
    public var agents: [(block: BlockID, name: String)] {
        var seen: Set<BlockID> = []
        var out: [(BlockID, String)] = []
        for e in entries {
            if case let .agent(b, name, _) = e.author, e.comment != nil, seen.insert(b).inserted { out.append((b, name)) }
        }
        return out
    }

    /// The entries after a mark (all, for nil) that are news to you
    /// (§3.12): an agent's comments in a thread you're in, or one naming
    /// you anywhere — none once it's resolved. What the dot, ⌘J, the
    /// Dock's count and the Mac's notifications go by.
    public func unseen(after mark: Stamp?) -> [ThreadEntry] {
        guard !resolved else { return [] }
        let yours = involvesYou
        return entries.filter { e in e.isNotable && (yours || e.mentionsYou) && mark.map { e.at > $0 } ?? true }
    }

    /// Whether you're in it: you've written in it, or it was started for
    /// you — by an agent, its first words asking no one else (no `@`), as
    /// a question or a note left you is.
    public var involvesYou: Bool {
        if entries.contains(where: { $0.author.isYou && $0.comment != nil }) { return true }
        guard let first = entries.first(where: { $0.comment != nil }), let text = first.comment else { return false }
        return ThreadText.tags(in: text).isEmpty
    }

    /// Agents asked since you last wrote: how many asks in a row.
    public var asksSinceYou: Int {
        var n = 0
        for e in entries.reversed() {
            if e.author.isYou, e.comment != nil { break }
            if case .asked = e.kind { n += 1 }
        }
        return n
    }
}

public enum ThreadText {
    /// The relation of a thread's link to what it's about, and to what a
    /// comment of it mentions.
    public static let annotates = "annotates"
    public static let mentions = "mentions"

    /// What an agent was asked, as its card says it, when it was asked in
    /// a thread (the line Manifold types: "(You are Wren in these threads.)
    /// [Manifold thread <ref>, about <place>] The user wrote: "…" — read it
    /// with …"): the thread it's at work in and what was said there — not
    /// the instructions. Several asked at once, the first and how many
    /// more; threads handed over to address, how many. Nil for any other.
    public static func askShown(_ prompt: String) -> String? {
        let ns = prompt as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = handOver.firstMatch(in: prompt, range: all) {
            let n = ns.substring(with: m.range(at: 1))
            return n == "1" ? "Addressing a thread" : "Addressing \(n) threads"
        }
        let asks = ask.matches(in: prompt, range: all)
        guard let first = asks.first else { return nil }
        let about = ns.substring(with: first.range(at: 1)), who = ns.substring(with: first.range(at: 2)), said = ns.substring(with: first.range(at: 3))
        var out = "In the thread on \(about) — \(who): “\(said)”"
        if asks.count > 1 { out += " (and \(asks.count - 1) more)" }
        return out
    }

    private static let handOver = try! NSRegularExpression(pattern: #"\[Manifold\] Please address these (\d+) open threads?:"#)
    private static let ask = try! NSRegularExpression(pattern: #"\[Manifold thread [^,\]]+, about ([^\]]*)\] (.+?) wrote: "(.*?)" — "#)

    /// The words tagged in a comment, `@word` (not in an address, not in
    /// code): `@claude`, `@codex` — agents asked by kind.
    public static func tags(in text: String) -> [String] {
        var out: [String] = []
        var inCode = false
        var prev: Character = " "
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "`" { inCode.toggle() }
            if c == "@", !inCode, !(prev.isLetter || prev.isNumber || prev == "." || prev == "/") {
                var j = text.index(after: i)
                var word = ""
                while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "-" || text[j] == "_" {
                    word.append(text[j])
                    j = text.index(after: j)
                }
                if !word.isEmpty { out.append(word.lowercased()) }
                prev = word.last ?? c
                i = j
                continue
            }
            prev = c
            i = text.index(after: i)
        }
        var seen: Set<String> = []
        return out.filter { seen.insert($0).inserted }
    }
}

extension DeskState {
    /// Whether a thread has entries you haven't seen, as this desk keeps
    /// what you've seen.
    public func unseen(_ thread: Block) -> [ThreadEntry] {
        thread.thread?.unseen(after: threadsSeen[thread.id]) ?? []
    }
}
