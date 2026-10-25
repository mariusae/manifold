import Foundation

/// A block in a few lines (§3.1): what a stack's column shows of each of
/// its tiles, and, in time, a tile down to its bar, a sidebar row's hover
/// card, a finder result, `mani ls`. Each kind says what's worth knowing
/// of it at a glance — a terminal its last command and how it ended, a note
/// its first lines, a diff its files and lines changed — from its state
/// alone, so a block not on screen (or on another host) has one too.
public struct BlockSummary: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, Sendable {
        case plain, running, done, failed, attention
    }

    public var title: String
    /// Where it is: a folder, a site.
    public var place: String?
    /// What it holds, two or three lines of it.
    public var lines: [String]
    /// At the right of the title: when it last did something, or its state.
    public var note: String?
    public var tone: Tone
    /// 0…1, for a block with progress to show (a panel's, a status's).
    public var progress: Double?
    /// Whether a picture of it says more than its words (a page, a PDF, an
    /// image): the card leaves room for one.
    public var wantsThumbnail: Bool
    /// Its lines are code — a command and what it printed — and set so.
    public var code = false

    public init(title: String, place: String? = nil, lines: [String] = [], note: String? = nil, tone: Tone = .plain,
                progress: Double? = nil, wantsThumbnail: Bool = false) {
        self.title = title
        self.place = place
        self.lines = lines
        self.note = note
        self.tone = tone
        self.progress = progress
        self.wantsThumbnail = wantsThumbnail
    }

    /// How long ago, as a note says it: "now", "4m", "3h", "2d".
    public static func ago(_ stamp: Stamp?, now: Date) -> String? {
        guard let stamp else { return nil }
        let s = max(0, now.timeIntervalSince1970 - Double(stamp.wall) / 1000)
        switch s {
        case ..<45: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        default: return "\(Int(s / 86400))d"
        }
    }
}

extension Block {
    /// The block in a few lines, as of `now`.
    public func summary(now: Date = Date()) -> BlockSummary {
        var s = BlockSummary(title: displayTitle, place: place)
        if let r = statusRecord, r.state != .idle {
            s.tone = r.state == .error ? .failed : r.state == .blocked ? .attention : r.state == .working ? .running : .done
            if let p = r.progress { s.progress = Double(p) / 100 }
        }
        switch kind {
        case .text:
            guard let t = text else { break }
            if isNote, (title ?? "").isEmpty {
                // An untitled note is called by its first line, as everywhere.
                let first = Self.firstLines(t.text.string, skipping: "", count: 4)
                s.title = String((first.first ?? displayTitle).prefix(60))
                s.lines = Array(first.dropFirst())
            } else {
                s.lines = Self.firstLines(t.text.string, skipping: displayTitle, count: 3)
            }
            if t.stale { s.note = "changed on disk"; s.tone = .attention } else if t.isDirty { s.note = "unsaved" }
            if path != nil { s.place = path?.deletingLastPathComponent }
        case .terminal, .agent:
            guard let term = terminal else { break }
            s.code = term.turns?.isEmpty ?? true
            if let turn = term.turns?.last {
                // An agent: what it was asked, and what it said or is doing.
                s.lines = [Self.oneLine(turn.prompt)]
                if let m = statusRecord?.msg, !m.isEmpty { s.lines.append(Self.oneLine(m)) } else if let m = turn.message { s.lines.append(Self.oneLine(m)) }
                if let files = turn.files, !files.isEmpty { s.lines.append("\(files.count) file\(files.count == 1 ? "" : "s") changed") }
                s.note = turn.ended == nil ? "working" : BlockSummary.ago(turn.ended, now: now)
                if turn.ended == nil, s.tone == .plain { s.tone = .running }
            } else if let c = term.commands?.last {
                s.lines = ["$ " + Self.oneLine(c.text)]
                if c.isRunning {
                    s.note = "running"
                    s.tone = .running
                    s.lines.append("running for \(BlockSummary.ago(c.at, now: now) ?? "a moment")")
                } else {
                    let status = c.status ?? 0
                    s.note = BlockSummary.ago(c.ended ?? c.at, now: now)
                    s.lines.append(status == 0 ? "ok" : "exit \(status)")
                    if status != 0, s.tone == .plain { s.tone = .failed }
                }
                if let earlier = term.commands?.dropLast().last { s.lines.append("$ " + Self.oneLine(earlier.text)) }
            } else {
                s.lines = [term.dormantSince != nil ? "dormant" : "no commands yet"]
            }
            s.place = term.cwd
        case .web:
            if let url = web?.url {
                s.place = URL(string: url)?.host
                s.lines = [WebAddress.plain(url)]
            }
            s.wantsThumbnail = true
        case .pdf, .image:
            s.place = path?.deletingLastPathComponent
            s.lines = [path?.lastPathComponent ?? ""]
            s.wantsThumbnail = true
        case .diff:
            guard let d = diff else { break }
            if let patch = d.patch {
                let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
                let files = lines.filter { $0.hasPrefix("+++ ") }.count
                let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                s.lines = ["\(files) file\(files == 1 ? "" : "s"), +\(added) −\(removed)"]
                s.lines += lines.filter { $0.hasPrefix("+++ ") }.prefix(2).map { String($0.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored) }
            } else if let e = d.error {
                s.lines = [e]
                s.tone = .failed
            }
            s.note = BlockSummary.ago(d.loadedAt, now: now)
        case .search:
            guard let q = search else { break }
            s.lines = ["“\(q.query?.text ?? "")”: \(q.hits.count)\(q.truncated ? "+" : "") hit\(q.hits.count == 1 ? "" : "s")"]
            if let h = q.hits.first { s.lines.append("\(h.path.lastPathComponent):\(h.line)  \(Self.oneLine(h.text))") }
            s.note = q.running ? "searching" : BlockSummary.ago(q.ranAt, now: now)
            s.place = q.query?.root
        case .directory:
            let entries = directory?.entries ?? []
            s.lines = ["\(entries.count) item\(entries.count == 1 ? "" : "s")", entries.prefix(4).map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: "  ")]
            s.place = path?.deletingLastPathComponent
        case .output:
            guard let o = output else { break }
            s.code = true
            s.lines = ["$ " + Self.oneLine(o.line), o.status.map { $0 == 0 ? "ok" : "exit \($0)" } ?? "running"]
            if let first = o.output.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                s.lines.append(Self.oneLine(String(first)))
            }
            if let st = o.status, st != 0 { s.tone = .failed }
            s.note = BlockSummary.ago(o.ended ?? o.ran, now: now)
        case .notebook:
            s.code = true
            let cells = notebook?.cells ?? []
            s.lines = ["\(cells.count) cell\(cells.count == 1 ? "" : "s")"]
            if let c = cells.last(where: { $0.ran != nil }) ?? cells.last {
                s.lines.append("$ " + Self.oneLine(c.source))
                if let st = c.status { s.lines.append(st == 0 ? "ok" : "exit \(st)"); if st != 0 { s.tone = .failed } }
                s.note = BlockSummary.ago(c.ended ?? c.ran, now: now)
            }
            if notebook?.running != nil { s.note = "running"; s.tone = .running }
        case .ui:
            s.lines = Self.panelLines(self)
        case .git:
            guard let g = git else { break }
            s.lines = [g.branch.map { "on \($0)" } ?? "", "\(g.status.count) change\(g.status.count == 1 ? "" : "s")"]
            s.note = BlockSummary.ago(g.refreshedAt, now: now)
        case .process:
            s.lines = ["\(processes?.entries.count ?? 0) processes"]
        case .smartlog:
            s.wantsThumbnail = true
        case .arrangement:
            break
        }
        s.lines = s.lines.filter { !$0.isEmpty }
        return s
    }

    /// A text's first lines worth showing: not blank, the title's own line
    /// left out, Markdown's marks taken off.
    static func firstLines(_ text: String, skipping title: String, count: Int) -> [String] {
        var out: [String] = []
        var inFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            guard !line.isEmpty else { continue }
            var plain = inFence ? line : line.replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|>\s*|\d+\.\s+)"#, with: "", options: .regularExpression)
            if !inFence {
                plain = plain.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            }
            if out.isEmpty, plain == title { continue }
            out.append(oneLine(plain))
            if out.count == count { break }
        }
        return out
    }

    /// A panel's values, as words: its progress and labels first.
    static func panelLines(_ b: Block) -> [String] {
        guard let ui = b.ui else { return [] }
        let values = ui.values.compactMap { k, v -> (String, String)? in
            let shown = v.hasPrefix("\"") && v.hasSuffix("\"") ? String(v.dropFirst().dropLast()) : v
            return (k, shown)
        }.sorted { $0.0 < $1.0 }
        return values.prefix(3).map { "\($0.0): \($0.1)" }
    }

    /// A line as it fits on one: a terminal's escapes taken out, whitespace
    /// run together, cut at a length.
    static func oneLine(_ s: String, max: Int = 140) -> String {
        let plain = s.replacingOccurrences(of: #"\x{1B}(\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|\[[0-?]*[ -/]*[@-~]|.)|[\x{00}-\x{08}\x{0E}-\x{1F}\x{7F}]"#,
                                           with: "", options: .regularExpression)
        let flat = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
