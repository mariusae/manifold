import Foundation

/// Where in a block a place is (§2.5): an anchor minted there, or a place
/// said as the block's kind knows it — a line, a stretch of lines or of
/// text, a command, a page. What a reference's fragment says: an anchor
/// by its id, the rest legibly (`line=12`, `page=3`, `command=7`), as
/// they were written before anchors. Every place a view offers is one
/// of these; a reference to it anchors it (the window's `anchor(_:in:)`).
public enum Locator: Hashable, Codable, Sendable {
    /// An anchor the block has, by its id.
    case anchor(String)
    /// A line of a text, from 1 (a heading's, the caret's).
    case line(Int)
    /// Lines of a text, from 1, both ends in it.
    case lines(Int, Int)
    /// A stretch of a text, by its bytes (a selection).
    case range(TextRange)
    /// One command of a terminal's (an agent's turn), by its id.
    case command(Int)
    /// A page of a PDF, from 1.
    case page(Int)
    /// A notebook's cell, by its id (kept as cells move: no anchor wanted).
    case cell(String)
    /// One comment of a thread's, by its entry's id (§3.12).
    case comment(String)

    /// A reference's fragment read: an anchor's id, or a legible place;
    /// nil for one that says neither.
    public init?(fragment: String) {
        guard !fragment.isEmpty else { return nil }
        if Anchor.isAnchor(fragment) { self = .anchor(fragment); return }
        let parts = fragment.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let value = parts[1]
        switch parts[0] {
        case "line":
            guard let n = Int(value) else { return nil }
            self = .line(n)
        case "lines":
            let ends = value.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            guard ends.count == 2, ends[0] <= ends[1] else { return nil }
            self = .lines(ends[0], ends[1])
        case "range":
            let ends = value.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
            guard ends.count == 2, ends[0] <= ends[1] else { return nil }
            self = .range(TextRange(ends[0], ends[1]))
        case "command":
            guard let n = Int(value) else { return nil }
            self = .command(n)
        case "page":
            guard let n = Int(value) else { return nil }
            self = .page(n)
        case "cell":
            guard !value.isEmpty else { return nil }
            self = .cell(value)
        case "comment":
            guard !value.isEmpty else { return nil }
            self = .comment(value)
        default:
            return nil
        }
    }

    /// As a reference's fragment says it.
    public var fragment: String {
        switch self {
        case let .anchor(id): id
        case let .line(n): "line=\(n)"
        case let .lines(a, b): "lines=\(a)-\(b)"
        case let .range(r): "range=\(r.start)-\(r.end)"
        case let .command(n): "command=\(n)"
        case let .page(n): "page=\(n)"
        case let .cell(id): "cell=\(id)"
        case let .comment(id): "comment=\(id)"
        }
    }

    /// As a person says it: "line 12", "lines 3–7", "page 3", "command 7"
    /// (an anchor, by its id: its name is its block's to say).
    public var words: String {
        switch self {
        case let .anchor(id): id
        case let .line(n): "line \(n)"
        case let .lines(a, b): a == b ? "line \(a)" : "lines \(a)–\(b)"
        case let .range(r): "bytes \(r.start)–\(r.end)"
        case let .command(n): "command \(n)"
        case let .page(n): "page \(n)"
        case .cell: "a cell"
        case .comment: "a comment"
        }
    }

    /// The anchor's id, if it's one.
    public var anchorID: String? { if case let .anchor(id) = self { id } else { nil } }

    /// The first line it's at, from 1, if it's a line or lines.
    public var line: Int? {
        switch self {
        case let .line(n), let .lines(n, _): n
        default: nil
        }
    }
}

extension Anchor {
    /// The legible place an anchor at a command or a page is, for what
    /// goes there as to that place; nil for one in a text.
    public var legible: Locator? {
        switch at {
        case let .command(n): .command(n)
        case let .page(n): .page(n)
        default: nil
        }
    }
}

/// A place (§2.5, §3.11): somewhere in a block, or in a file on a host
/// that isn't one yet (a search's hit, a diff's lines) — where, as its
/// kind knows it, and what it's called. What every view says is here
/// (its selection, else where it's at), what an outline's item, a hit,
/// a row is; a reference to it, a drag of it, a thread about it are
/// all made of it, the same way.
public struct Place: Equatable, Codable, Sendable {
    public enum Subject: Hashable, Codable, Sendable {
        case block(BlockID)
        /// A file on a host, named by its path: the block it opens as, once it's referred to.
        case file(host: HostID, path: String)
    }

    public var subject: Subject
    /// Where in it; nil, the whole of it.
    public var at: Locator?
    /// What the place is called: a declaration's path, a heading, a
    /// command's line, "Page 3".
    public var name: String?
    /// What the block or file is called.
    public var title: String?
    /// The words it holds as they were when it was taken (rows of a diff,
    /// with their marks; a past version's lines) — kept with a thread
    /// about it, as the place drifts.
    public var context: String?
    /// Taken in a diff: where.
    public var diff: DiffPlace?
    /// Taken from a past version (the history strip, §7.1): its commit.
    public var revision: String?
    /// Taken from text that may not be the block's now (a commit's, a
    /// past version's): its anchor's found again by its words.
    public var unsure = false

    public init(_ subject: Subject, at: Locator? = nil, name: String? = nil, title: String? = nil) {
        self.subject = subject
        self.at = at
        self.name = name
        self.title = title
    }

    public init(block: BlockID, at: Locator? = nil, name: String? = nil, title: String? = nil) {
        self.init(.block(block), at: at, name: name, title: title)
    }

    public init(file path: String, on host: HostID, at: Locator? = nil, name: String? = nil) {
        self.init(.file(host: host, path: path), at: at, name: name, title: (path as NSString).lastPathComponent)
    }

    /// The block it's in, if it's one's.
    public var block: BlockID? { if case let .block(id) = subject { id } else { nil } }
    /// The file it's in, if it names one by its path.
    public var file: (host: HostID, path: String)? { if case let .file(h, p) = subject { (h, p) } else { nil } }
    public var host: HostID {
        switch subject {
        case let .block(id): id.host
        case let .file(h, _): h
        }
    }
}
