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
}

public struct ThreadEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Stamp
    public var author: ThreadAuthor
    public var kind: ThreadEntryKind

    public init(id: String = ULID.make(), at: Stamp, author: ThreadAuthor, kind: ThreadEntryKind) {
        self.id = id
        self.at = at
        self.author = author
        self.kind = kind
    }

    public var comment: String? { if case .comment(let t) = kind { t } else { nil } }

    /// Worth telling you of: something someone else said or did to it — a
    /// comment, a resolve or a reopen, asking stopped — not your own, and
    /// not a place moving under it. What makes a thread unread.
    public var isNotable: Bool {
        guard !author.isYou else { return false }
        switch kind {
        case .comment, .resolved, .reopened, .stopped: return true
        default: return false
        }
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

    /// The entries after a mark (all, for nil) that are worth telling you of.
    public func unseen(after mark: Stamp?) -> [ThreadEntry] {
        entries.filter { e in e.isNotable && mark.map { e.at > $0 } ?? true }
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
