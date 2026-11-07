import AppKit
import ManifoldCore

/// `mani threads` and `mani thread …` (§3.12): threads listed, read,
/// started, replied to, resolved — each entry's author the one the host
/// the command ran on found (an agent, by its terminal; else you).
extension ManiDesk {
    func threads(_ r: ManiRequest, _ scope: Scope) async throws -> String? {
        let author = r.author ?? Hosts.you
        switch r.verb {
        case "threads":
            var list: [Block]
            if let place = r.flags["place"] {
                let t = try await target(place, scope)
                let anchor = wc.anchored(t.fragment, in: t.block).flatMap { Anchor.isAnchor($0) ? $0 : nil }
                list = anchor == nil ? hosts.threads(about: t.block, anyPlace: true) : hosts.threads(about: t.block, anchor: anchor)
            } else if r.flags["project"] != nil {
                let host = scope.host
                guard let root = hosts.client(host)?.node.graph.project(holding: r.cwd, on: host) else {
                    throw Failure(message: "\(r.cwd) isn't in a project (mani project --make makes one)")
                }
                list = hosts.threads(inProject: root, on: host)
            } else {
                guard let ws = scope.workspace else { throw Failure(message: "no space is shown") }
                list = hosts.threads(inSpace: ws)
            }
            if r.flags["all"] == nil { list = list.filter { $0.thread?.resolved != true } }
            list.sort { ($0.thread?.lastActivity ?? $0.created) < ($1.thread?.lastActivity ?? $1.created) }
            if r.flags["json"] != nil { return json(list.map(threadJSON)) }
            if list.isEmpty { return r.flags["all"] == nil ? "No open threads." : "No threads." }
            return list.map(threadText).joined(separator: "\n\n")
        case "thread read":
            let t = try await thread(r.args[0], scope)
            return r.flags["json"] != nil ? json(threadJSON(t)) : threadText(t)
        case "thread new":
            let target = try await target(r.args[0], scope)
            guard let text = (r.args.count > 1 ? r.args[1] : r.input)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw Failure(message: "no text: give it, or pipe it in", status: 2)
            }
            let place = threadPlace(target)
            let id = hosts.newThread(about: place, space: scope.workspace, text: text, author: author)
            return MainWindowController.address(id)
        case "thread reply":
            let t = try await thread(r.args[0], scope)
            guard let text = (r.args.count > 1 ? r.args[1] : r.input)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw Failure(message: "no text: give it, or pipe it in", status: 2)
            }
            hosts.addToThread(t.id, .comment(text), author: author)
            if r.flags["resolve"] != nil { hosts.addToThread(t.id, .resolved, author: author) }
            return ""
        case "thread resolve", "thread reopen":
            let t = try await thread(r.args[0], scope)
            hosts.addToThread(t.id, r.verb == "thread resolve" ? .resolved : .reopened, author: author)
            return ""
        default:
            return nil
        }
    }

    /// A thread by its reference (or any name of it).
    private func thread(_ name: String, _ scope: Scope) async throws -> Block {
        let t = try await target(name, scope)
        guard let b = hosts.block(t.block), b.kind == .thread else { throw Failure(message: "\(name) isn't a thread (mani threads lists them)") }
        return b
    }

    /// A place named, as a thread would be about it: the place's anchor
    /// (a line of a text made one), and the text there.
    private func threadPlace(_ t: Target) -> ThreadPlace {
        let b = hosts.block(t.block)
        let anchor = wc.anchored(t.fragment, in: t.block).flatMap { Anchor.isAnchor($0) ? $0 : nil }
        var place = ThreadPlace(block: t.block, anchor: anchor, title: b?.path?.lastPathComponent ?? b?.displayTitle)
        if let a = anchor.flatMap({ b?.anchors?[$0] }) {
            place.name = Anchoring.name(of: a)
            if let b, let rope = b.text?.text, let (range, _) = Anchoring.locate(a, in: b) {
                let first = rope.line(at: range.start), last = rope.line(at: max(range.start, range.end))
                place.line = first + 1
                place.context = (first...min(last, first + 11)).map { rope.lineText($0).trimmingCharacters(in: .newlines) }.joined(separator: "\n")
            }
        } else if let s = t.selection {
            place.context = s.text
            place.line = s.lines?.lowerBound
        }
        return place
    }

    /// A thread as text: its reference and state, where it is, what it
    /// was written against, and every entry with who made it.
    private func threadText(_ b: Block) -> String {
        guard let t = b.thread else { return "" }
        var out = [MainWindowController.address(b.id) + (t.resolved ? "  (resolved)" : "")]
        if let p = t.about {
            let d = wc.describe(p)
            out.append("about: " + d.title + (d.drift.map { " (\($0))" } ?? "") + (d.gone ? " — GONE: read the text it was written against" : ""))
            out.append("at: " + MainWindowController.address(p.block, anchor: p.anchor))
            if let diff = p.diff { out.append("made in a diff: \(diff.file), \(diff.new ? "new" : "old") lines \(diff.start)-\(diff.end)" + (diff.commit.map { ", commit \($0)" } ?? "")) }
            if let c = p.context, !c.isEmpty {
                out.append("written against:")
                out += c.split(separator: "\n", omittingEmptySubsequences: false).map { "  | " + $0 }
            }
        }
        for e in t.entries {
            let ago = BlockSummary.ago(e.at, now: Date()) ?? ""
            let when = ago == "now" ? "just now" : ago + " ago"
            switch e.kind {
            case .comment(let text):
                out.append("\(e.author.name) (\(when)):")
                out += text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
            case .resolved: out.append("— resolved by \(e.author.name) (\(when))")
            case .reopened: out.append("— reopened by \(e.author.name) (\(when))")
            case let .asked(_, name): out.append("— \(name) asked (\(when))")
            case let .edited(a, r): out.append("— edited by \(e.author.name), +\(a) −\(r) (\(when))")
            case .gone: out.append("— its lines were deleted (\(when))")
            case .stopped(let why): out.append("— \(why) (\(when))")
            }
        }
        return out.joined(separator: "\n")
    }

    private func threadJSON(_ b: Block) -> [String: Any] {
        guard let t = b.thread else { return [:] }
        var o: [String: Any] = ["thread": MainWindowController.address(b.id), "resolved": t.resolved]
        if let p = t.about {
            let d = wc.describe(p)
            o["about"] = d.title
            o["place"] = MainWindowController.address(p.block, anchor: p.anchor)
            o["moved"] = d.drift ?? NSNull()
            o["gone"] = d.gone
            o["context"] = p.context ?? NSNull()
            o["line"] = p.line ?? NSNull()
        }
        o["entries"] = t.entries.map { e -> [String: Any] in
            var x: [String: Any] = ["author": e.author.name, "you": e.author.isYou, "at": e.at.date.timeIntervalSince1970]
            if let a = e.author.agentBlock { x["agent"] = MainWindowController.address(a) }
            switch e.kind {
            case .comment(let c): x["comment"] = c
            default: x["event"] = "\(e.kind)"
            }
            return x
        }
        return o
    }
}
