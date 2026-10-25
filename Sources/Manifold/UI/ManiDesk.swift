import AppKit
import PDFKit
import ManifoldCore

/// `mani`'s commands that the app does (`Mani.verbs`, those `inApp`),
/// asked through a host (`ManiRequest`) and answered to it (`ManiReply`):
/// naming blocks (ids, paths, titles, `@` names and positions), listing the
/// layout, reading what blocks hold, making and placing blocks, typing
/// into terminals, and telling a `watch` what happens. Remembers what
/// commands need between them: where text was last selected, the block
/// made last, the commands waiting on something.
@MainActor
final class ManiDesk {
    private unowned let wc: MainWindowController
    private var hosts: Hosts { wc.hosts }

    /// Who asked: the host the command came through, its id there, and
    /// which of the host's clients.
    struct Asker: Hashable {
        var host: HostID
        var id: Int
        var client: Int
    }

    struct Failure: Error {
        var message: String
        var status: Int32 = 1
    }

    /// When text was last selected in each tile.
    private var selections: [PlacementID: Date] = [:]
    /// The block a command made last (`@last`).
    private var last: BlockID?
    /// `watch`es going on, and the events each wants (nil: all).
    private var watchers: [Asker: Set<String>?] = [:]
    /// `run --wait`s: the terminal, the last command before, and the deadline.
    private var runs: [Asker: (block: BlockID, after: Int, started: Date)] = [:]
    /// What a `watch` compares against, as of the last change.
    private var seen: Seen?
    /// What's been done in each panel that no `ui wait` has had yet.
    private var panelEvents: [BlockID: [String]] = [:]
    /// `ui wait`s: the panel, and the widget waited on, if one.
    private var panelWaits: [Asker: (block: BlockID, id: String?)] = [:]

    init(_ wc: MainWindowController) {
        self.wc = wc
        NotificationCenter.default.addObserver(forName: .manifoldSelectionMade, object: nil, queue: .main) { [weak self] note in
            guard let view = note.object as? PaneContent else { return }
            MainActor.assumeIsolated { self?.selected(in: view) }
        }
    }

    // MARK: Answering

    func reply(_ a: Asker, out: String = "", err: String = "", status: Int32?) {
        hosts.propose(.commandReply(id: a.id, client: a.client, ManiReply(out: out, err: err, status: status)), on: a.host)
    }

    /// A command, done, and answered: its output and status 0, or what
    /// went wrong and 1 — unless it answers later itself (nil).
    func handle(_ request: ManiRequest, from asker: Asker) {
        Task { @MainActor in
            do {
                if let out = try await run(request, asker) {
                    reply(asker, out: out.isEmpty || out.hasSuffix("\n") ? out : out + "\n", status: 0)
                }
            } catch let f as Failure {
                reply(asker, err: "mani: \(f.message)\n", status: f.status)
            } catch {
                reply(asker, err: "mani: \(error)\n", status: 1)
            }
        }
    }

    /// The client that asked has gone: a `watch` or a wait ends.
    func ended(_ asker: Asker) {
        watchers.removeValue(forKey: asker)
        runs.removeValue(forKey: asker)
        panelWaits.removeValue(forKey: asker)
    }

    private func run(_ r: ManiRequest, _ asker: Asker) async throws -> String? {
        let scope = Scope(self, r, asker)
        switch r.verb {
        case "ls": return try ls(r, scope)
        case "info": return json(try await info(try await target(r.args[0], scope), scope))
        case "read": return try await read(r, scope)
        case "context": return try await context(r, scope)
        case "open": return try open(r, scope, asker)
        case "new": return try make(r, scope)
        case "write": return try write(r, scope)
        case "show": return try show(r, scope)
        case "close": return try close(r, scope)
        case "run": return try runCommand(r, scope, asker)
        case "pin", "unpin":
            let t = try await target(r.args[0], scope)
            guard let ws = t.workspace ?? scope.workspace else { throw Failure(message: "\(r.args[0]) isn't in a space to be pinned in") }
            wc.setPinned(t.block, in: ws, r.verb == "pin")
            return ""
        case "link":
            let from = try await target(r.args[0], scope), to = try await target(r.args[1], scope)
            hosts.link(from: from.block, to: to.block, kind: .linked, context: r.flags["note"])
            return ""
        case "rename":
            let t = try await target(r.args[0], scope)
            hosts.append(.title(r.args[1].isEmpty ? nil : r.args[1]), to: .block(t.block))
            return ""
        case "ui new": return try newPanel(r, scope)
        case "ui set": return try setPanel(r, scope)
        case "ui get": return try getPanel(r, scope)
        case "ui wait": return try waitPanel(r, scope, asker)
        case "watch":
            let only = r.flags["only"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            watchers[asker] = only
            if seen == nil { seen = Seen(self) }
            return nil
        default:
            throw Failure(message: "\(r.verb) isn't something the app does")
        }
    }

    // MARK: Names

    /// Where a command runs from: the tile it runs in (`@here`), the
    /// workspace it's about (that tile's, else the one shown), the tile
    /// positions are taken from (`@here`'s, else the focused).
    struct Scope {
        var request: ManiRequest
        var here: BlockID?
        var hereTile: PlacementID?
        var workspace: BlockID?
        var arrangement: ArrangementState?
        var reference: PlacementID?
        var host: HostID

        @MainActor init(_ desk: ManiDesk, _ r: ManiRequest, _ asker: Asker) {
            request = r
            here = r.here
            host = r.here?.host ?? asker.host
            let hosts = desk.hosts
            let order = [desk.wc.selected].compactMap { $0 } + desk.wc.allWorkspaces
            if let here = r.here, let ws = order.first(where: { hosts.arrangement($0)?.placements.contains { $0.block == here } == true }) {
                workspace = ws
                hereTile = hosts.arrangement(ws)?.placements.first { $0.block == here }?.id
            } else {
                workspace = desk.wc.selected
            }
            arrangement = workspace.flatMap { hosts.arrangement($0) }
            reference = hereTile ?? arrangement?.focused
        }
    }

    /// What a name came to: a block, its tile (and workspace) if it's
    /// placed, and for @selection what's selected.
    struct Target {
        var block: BlockID
        var tile: PlacementID?
        var workspace: BlockID?
        var selection: ManiSelected?
    }

    /// The words a tile's kind answers to (`@:pdf`, `@right:diff`).
    func kinds(_ b: Block?, lens: Lens) -> [String] {
        guard let b else { return [lens.rawValue] }
        var out: [String]
        switch b.kind {
        case .text: out = [b.isNote ? "note" : "file"]
        case .directory: out = ["folder"]
        case .terminal: out = ["terminal"]
        case .arrangement: out = ["space"]
        default: out = [b.kind.rawValue]
        }
        if b.agent != nil { out.append("agent") }
        if lens == .editor || lens == .preview { out.append(lens.rawValue) }
        return out
    }

    func kindName(_ b: Block?, lens: Lens) -> String { kinds(b, lens: lens).first ?? lens.rawValue }

    /// A name, as a block: `@` names and positions, a tile's or block's id,
    /// a path, a title.
    func target(_ name: String, _ scope: Scope) async throws -> Target {
        if case .at("selection", _) = ManiName(name) { return try await selection(excluding: scope.here) }
        return try resolve(name, scope)
    }

    /// A name, as `target`, but for @selection (which asks views).
    func resolve(_ name: String, _ scope: Scope) throws -> Target {
        switch ManiName(name) {
        case let .at(position, kind):
            switch position {
            case "here":
                guard let here = scope.here else { throw Failure(message: "@here is a terminal of Manifold's, and mani isn't running in one") }
                return Target(block: here, tile: scope.hereTile, workspace: scope.hereTile == nil ? nil : scope.workspace)
            case "focused":
                guard let ws = scope.workspace, let p = hosts.arrangement(ws)?.focusedPlacement else { throw Failure(message: "nothing is focused") }
                return Target(block: p.block, tile: p.id, workspace: ws)
            case "space", "workspace":
                guard let ws = scope.workspace else { throw Failure(message: "no space is shown") }
                return Target(block: ws, workspace: ws)
            case "last":
                guard let last else { throw Failure(message: "mani hasn't made anything yet") }
                return located(last, scope)
            case "selection":
                throw Failure(message: "@selection is for read and info")
            default:
                guard let a = scope.arrangement, let ws = scope.workspace else { throw Failure(message: "no space is shown") }
                let layout = ManiLayout(a)
                if let kind, !Self.kindWords.contains(kind) {
                    throw Failure(message: "no kind \(kind); kinds: \(Self.kindWords.sorted().joined(separator: ", "))", status: 2)
                }
                let matches: (PlacementID) -> Bool = { id in
                    guard let kind else { return true }
                    guard let p = a.placement(id) else { return false }
                    return self.kinds(self.hosts.block(p.block), lens: p.lens).contains(kind)
                }
                switch layout.resolve(position, from: scope.reference, matches: matches) {
                case .tile(let id):
                    return Target(block: a.placement(id)!.block, tile: id, workspace: ws)
                case .none(let why):
                    throw Failure(message: "\(name): \(why)")
                case .ambiguous(let ids):
                    throw Failure(message: "\(name) could be any of these; name one:\n" + ids.map { describe($0, in: a) }.joined(separator: "\n"))
                }
            }
        case .other(let s):
            return try other(s, scope)
        }
    }

    static let kindWords: Set<String> = ["note", "file", "terminal", "agent", "folder", "web", "image", "pdf", "search", "diff",
                                         "output", "notebook", "git", "smartlog", "process", "preview", "editor", "ui"]

    /// A row naming a tile, for a choice to be made among them.
    private func describe(_ id: PlacementID, in a: ArrangementState) -> String {
        guard let p = a.placement(id) else { return "  \(id)" }
        let b = hosts.block(p.block)
        return "  \(p.block)  \(kindName(b, lens: p.lens))  \(b?.displayTitle ?? "")"
    }

    /// A block, with its tile if one shows it (in the command's workspace
    /// first).
    private func located(_ block: BlockID, _ scope: Scope) -> Target {
        let order = [scope.workspace].compactMap { $0 } + wc.allWorkspaces
        for ws in order {
            if let p = hosts.arrangement(ws)?.placements.first(where: { $0.block == block }) {
                return Target(block: block, tile: p.id, workspace: ws)
            }
        }
        return Target(block: block)
    }

    /// An id, a path, a title.
    private func other(_ s: String, _ scope: Scope) throws -> Target {
        // A tile's id.
        for ws in [scope.workspace].compactMap({ $0 }) + wc.allWorkspaces {
            if let p = hosts.arrangement(ws)?.placement(s) { return Target(block: p.block, tile: p.id, workspace: ws) }
        }
        // A block's id, whole or without its host.
        if let id = BlockID(string: s), hosts.block(id) != nil { return located(id, scope) }
        if s.count >= 20, !s.contains("/"), let b = hosts.blocks.first(where: { $0.id.description.hasSuffix("/" + s) }) {
            return located(b.id, scope)
        }
        // A path, as the command's directory has it.
        if s.contains("/") || s.contains(".") || s.hasPrefix("~") {
            var path = s.expandingTildeInPath
            if !path.hasPrefix("/") { path = scope.request.cwd.appendingPathComponent(path) }
            path = URL(fileURLWithPath: path).standardizedFileURL.path
            let blocks = hosts.blocks.filter { $0.id.host == scope.host && ($0.path == path || $0.path == path + "/") }
            if let shown = blocks.lazy.map({ self.located($0.id, scope) }).first(where: { $0.tile != nil }) { return shown }
            if let b = blocks.first { return located(b.id, scope) }
        }
        // A title: in the workspace, else anywhere.
        let lower = s.lowercased()
        if let a = scope.arrangement, let ws = scope.workspace {
            let named = a.placements.filter { hosts.block($0.block)?.displayTitle.lowercased() == lower }
            if named.count == 1 { return Target(block: named[0].block, tile: named[0].id, workspace: ws) }
            if named.count > 1 {
                throw Failure(message: "\(s) could be any of these; name one:\n" + named.map { describe($0.id, in: a) }.joined(separator: "\n"))
            }
        }
        let named = hosts.blocks.filter { $0.kind != .arrangement && $0.displayTitle.lowercased() == lower }
        if named.count == 1 { return located(named[0].id, scope) }
        if named.count > 1 {
            throw Failure(message: "\(s) could be any of these; name one:\n" + named.map { "  \($0.id)  \(kindName($0, lens: Lens.default(for: $0.kind, path: $0.path)))  \($0.displayTitle)" }.joined(separator: "\n"))
        }
        throw Failure(message: "nothing is named \(s)")
    }

    // MARK: Selection

    private func selected(in view: PaneContent) {
        selections[view.placement] = Date()
        tell("selection", ["tile": view.placement, "block": view.block.description])
    }

    /// The last text selected anywhere but `excluding` (the terminal mani
    /// runs in), and where: the tiles, latest first, asked what they have
    /// selected now.
    private func selection(excluding: BlockID?) async throws -> Target {
        for (tile, _) in selections.sorted(by: { $0.value > $1.value }) {
            guard let view = wc.views[tile], view.block != excluding else { continue }
            if let s = await view.maniSelection(), !s.text.isEmpty {
                let ws = wc.allWorkspaces.first { hosts.arrangement($0)?.placement(tile) != nil }
                return Target(block: view.block, tile: tile, workspace: ws, selection: s)
            }
        }
        throw Failure(message: "nothing is selected (outside this terminal)")
    }

    // MARK: Listing

    /// A tile as `ls --json` has it.
    private func tile(_ p: Placement, layout: ManiLayout, scope: Scope, deep: Bool = true) -> [String: Any] {
        let b = hosts.block(p.block)
        var out: [String: Any] = ["tile": p.id, "block": p.block.description, "kind": kindName(b, lens: p.lens),
                                  "lens": p.lens.rawValue, "title": b?.displayTitle ?? ""]
        if let path = b?.path { out["path"] = path }
        if let cwd = b?.terminal?.cwd ?? b?.home { out["cwd"] = cwd }
        if let agent = b?.agent { out["agent"] = agent.name }
        if let s = b?.statusRecord, s.state != .idle { out["status"] = s.state.rawValue }
        if b?.text?.isDirty == true { out["dirty"] = true }
        if p.block.host != wc.host.host { out["host"] = hosts.label(of: p.block.host) }
        if p.block == scope.here { out["here"] = true }
        if p.id == layout.arrangement.focused { out["focused"] = true }
        if let summary = summaryJSON(p.block, view: wc.views[p.id]) { out["summary"] = summary }
        guard deep else { return out }
        if let f = layout.frames[p.id] {
            out["frame"] = f.array.map(Self.decimal)
            out["names"] = layout.names(of: p.id, from: scope.reference)
            out["adjacent"] = Dictionary(uniqueKeysWithValues: layout.adjacent(p.id).map { ($0.key.rawValue, $0.value) })
        }
        let stack = layout.stack(behind: p.id).compactMap { layout.arrangement.placement($0) }
        if !stack.isEmpty { out["stack"] = stack.map { tile($0, layout: layout, scope: scope, deep: false) } }
        return out
    }

    private func layoutJSON(_ ws: BlockID, scope: Scope) -> [String: Any] {
        guard let a = hosts.arrangement(ws) else { return [:] }
        let layout = ManiLayout(a)
        var out: [String: Any] = ["id": ws.description, "title": wc.title(of: a)]
        if ws.host != wc.host.host { out["host"] = hosts.label(of: ws.host) }
        if let full = a.full { out["full"] = full }
        if let f = a.focused { out["focused"] = f }
        out["columns"] = a.columns.enumerated().map { c, column -> [String: Any] in
            let w = c < a.fractions.count ? a.fractions[c] : 0
            return ["width": Self.decimal(w),
                    "tiles": column.filter { !a.isStashed($0.id) }.map { tile($0, layout: layout, scope: scope) }]
        }
        let pins = wc.pins(of: ws).map(\.to).map { b -> [String: Any] in
            let blk = hosts.block(b)
            return ["block": b.description, "kind": kindName(blk, lens: Lens.default(for: blk?.kind ?? .text, path: blk?.path)), "title": blk?.displayTitle ?? ""]
        }
        if !pins.isEmpty { out["pinned"] = pins }
        return out
    }

    private func ls(_ r: ManiRequest, _ scope: Scope) throws -> String {
        guard let ws = scope.workspace, let a = scope.arrangement else { throw Failure(message: "no space is shown") }
        if r.flags["json"] != nil {
            var out = layoutJSON(ws, scope: scope)
            if let t = scope.hereTile { out["here"] = t }
            if r.flags["all"] != nil {
                out = ["space": out, "spaces": wc.allWorkspaces.map { layoutJSON($0, scope: scope) }, "shown": wc.selected?.description ?? ""]
            }
            return json(out)
        }
        let layout = ManiLayout(a)
        func rows(_ ws: BlockID, _ a: ArrangementState) -> [String] {
            let layout = ManiLayout(a)
            return layout.order.enumerated().flatMap { n, id -> [String] in
                guard let p = a.placement(id) else { return [] }
                let b = hosts.block(p.block)
                let mark = id == a.focused ? "*" : " "
                var title = b?.displayTitle ?? ""
                if title.count > 36 { title = String(title.prefix(35)) + "…" }
                let names = layout.names(of: id, from: ws == scope.workspace ? scope.reference : nil).filter { $0 != "@\(n + 1)" }
                let here = p.block == scope.here ? ["@here"] : []
                var row = ["\(mark)\(n + 1)", kindName(b, lens: p.lens), title, p.block.description, (here + names).joined(separator: " ")]
                row[1] = row[1].padding(toLength: 9, withPad: " ", startingAt: 0)
                row[2] = row[2].padding(toLength: 37, withPad: " ", startingAt: 0)
                var lines = [row.joined(separator: "  ")]
                if let summary = summaryLine(p.block, view: wc.views[id]) { lines.append("      " + String(summary.prefix(140))) }
                for s in layout.stack(behind: id).compactMap({ a.placement($0) }) {
                    let sb = hosts.block(s.block)
                    lines.append("      under: \(kindName(sb, lens: s.lens)) \(sb?.displayTitle ?? "")  \(s.block)")
                }
                return lines
            }
        }
        var out = ["\(wc.title(of: a))  (\(ws))"] + rows(ws, a)
        _ = layout
        if r.flags["all"] != nil {
            for other in wc.allWorkspaces where other != ws {
                guard let oa = hosts.arrangement(other) else { continue }
                out.append("")
                out.append("\(wc.title(of: oa))  (\(other))")
                out += rows(other, oa)
            }
        }
        return out.joined(separator: "\n")
    }

    private func info(_ t: Target, _ scope: Scope) async throws -> [String: Any] {
        guard let b = hosts.block(t.block) else { throw Failure(message: "\(t.block) isn't known here") }
        var out: [String: Any]
        if let tileID = t.tile, let ws = t.workspace, let a = hosts.arrangement(ws), let p = a.placement(tileID) {
            out = tile(p, layout: ManiLayout(a), scope: scope)
            out["space"] = ws.description
        } else {
            out = ["block": b.id.description, "kind": kindName(b, lens: Lens.default(for: b.kind, path: b.path)), "title": b.displayTitle]
            if let path = b.path { out["path"] = path }
            if let cwd = b.terminal?.cwd ?? b.home { out["cwd"] = cwd }
            out["shown"] = false
        }
        if out["summary"] == nil, let summary = summaryJSON(b.id, view: nil) { out["summary"] = summary }
        if let s = t.selection {
            var sel: [String: Any] = ["text": s.text]
            if let l = s.lines { sel["lines"] = [l.lowerBound, l.upperBound] }
            if let p = s.page { sel["page"] = p }
            out["selection"] = sel
        }
        if let commands = b.terminal?.commands?.suffix(5), !commands.isEmpty {
            out["commands"] = commands.map(commandJSON)
        }
        let n = hosts.neighborhood(of: b.id)
        let links = n.outbound.values.flatMap { $0 }.filter { hosts.block($0.to)?.kind != .arrangement }.prefix(30).map { l -> [String: Any] in
            var o: [String: Any] = ["to": l.to.description, "title": hosts.block(l.to)?.displayTitle ?? ""]
            if let c = l.context { o["context"] = c }
            return o
        }
        if !links.isEmpty { out["links"] = Array(links) }
        if let tileID = t.tile, let outline = wc.views[tileID]?.outline, !outline.items.isEmpty {
            out["outline"] = outline.items.indices.prefix(200).map { i -> [String: Any] in
                var o: [String: Any] = ["title": outline.items[i].title, "level": outline.items[i].level]
                if let place = outline.placeFor?(i) { o["at"] = place }
                return o
            }
        }
        return out
    }

    private func commandJSON(_ c: ShellCommand) -> [String: Any] {
        var o: [String: Any] = ["id": c.id, "command": c.text]
        if let s = c.status { o["status"] = Int(s) }
        if c.isRunning { o["running"] = true }
        return o
    }

    /// A block's summary card, as JSON: title, place, lines, note, tone (and
    /// progress) — the terminal's last screen lines, where it's shown.
    private func summaryJSON(_ block: BlockID, view: PaneContent?) -> [String: Any]? {
        guard let c = wc.cardContent(for: block, view: view), let data = try? JSONEncoder().encode(c.summary),
              var o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        o.removeValue(forKey: "wantsThumbnail")
        o.removeValue(forKey: "code")
        if o["tone"] as? String == "plain" { o.removeValue(forKey: "tone") }
        return o
    }

    /// A block's summary as a line: its lines and its note, run together.
    private func summaryLine(_ block: BlockID, view: PaneContent?) -> String? {
        guard let s = wc.cardContent(for: block, view: view)?.summary else { return nil }
        let line = (s.lines.prefix(2) + [s.note].compactMap { $0 }).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    // MARK: Reading

    private func read(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        let t = try await target(r.args[0], scope)
        if let s = t.selection { return lines(s.text, r.flags["lines"]) }
        guard let b = hosts.block(t.block) else { throw Failure(message: "\(r.args[0]) isn't known here") }
        let view = t.tile.flatMap { wc.views[$0] }
        if r.flags["outline"] != nil {
            guard let outline = view?.outline, !outline.items.isEmpty else { throw Failure(message: "\(b.displayTitle) has no outline\(view == nil ? " (it isn't shown)" : "")") }
            return outline.items.indices.map { i in
                String(repeating: "  ", count: outline.items[i].level) + outline.items[i].title + (outline.placeFor?(i).map { "\t" + $0 } ?? "")
            }.joined(separator: "\n")
        }
        let pages = try r.flags["pages"].map { try range($0, what: "pages") }
        switch b.kind {
        case .text:
            guard let text = b.text, !b.needsRead else { throw Failure(message: "\(b.displayTitle) hasn't been read from disk yet") }
            return lines(text.text.string, r.flags["lines"])
        case .terminal, .agent:
            if let n = r.flags["command"] {
                guard let k = Int(n), let commands = b.terminal?.commands, !commands.isEmpty else { throw Failure(message: "no command \(n) in \(b.displayTitle)") }
                let i = k < 0 ? commands.count + k : k - 1
                guard i >= 0, i < commands.count else { throw Failure(message: "\(b.displayTitle) has \(commands.count) commands") }
                return lines(try await output(of: commands[i], in: b.id, view: view), r.flags["lines"])
            }
            guard let view, let s = await view.maniText(ManiReadOptions(all: r.flags["all"] != nil)) else {
                throw Failure(message: "\(b.displayTitle) isn't shown, so its screen can't be read; --command n reads a command's output")
            }
            return lines(s, r.flags["lines"])
        case .pdf:
            if let view, let s = await view.maniText(ManiReadOptions(pages: pages)) { return lines(s, r.flags["lines"]) }
            guard b.id.host == wc.host.host, let path = b.path, let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
                throw Failure(message: "\(b.displayTitle) can't be read here")
            }
            return lines(MediaView.text(of: doc, pages: pages), r.flags["lines"])
        case .web:
            guard let view, let s = await view.maniText(ManiReadOptions()) else { throw Failure(message: "\(b.displayTitle) isn't shown, so its page can't be read") }
            return lines(s, r.flags["lines"])
        case .diff:
            guard let d = b.diff else { throw Failure(message: "\(b.displayTitle) has nothing yet") }
            if let patch = d.patch { return lines(patch, r.flags["lines"]) }
            if let old = d.oldText, let new = d.newText {
                return lines(UnifiedDiff.make(old: old, new: new, path: b.path ?? b.displayTitle), r.flags["lines"])
            }
            throw Failure(message: d.error ?? "\(b.displayTitle) hasn't loaded")
        case .directory:
            let entries = b.directory?.entries ?? []
            return entries.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: "\n")
        case .search:
            guard let s = b.search else { return "" }
            return lines(s.hits.map { "\($0.path):\($0.line):\($0.column): \($0.text)" }.joined(separator: "\n"), r.flags["lines"])
        case .output:
            guard let o = b.output else { return "" }
            return lines("$ " + o.line + "\n" + (o.plain ? o.output : Self.plain(o.output)), r.flags["lines"])
        case .notebook:
            let cells = b.notebook?.cells ?? []
            return cells.enumerated().map { i, c in
                var s = "[\(i + 1)] $ " + c.source
                if let o = c.output, !o.isEmpty { s += "\n" + Self.plain(o) }
                if let st = c.status, st != 0 { s += "\n(status \(st))" }
                return s
            }.joined(separator: "\n\n")
        case .process:
            return (b.processes?.entries ?? []).map { "\($0.pid)\t\($0.user)\t\($0.command)" }.joined(separator: "\n")
        case .git:
            guard let g = b.git else { return "" }
            let head = (g.branch.map { "on \($0)" } ?? "") + (g.ahead > 0 ? ", \(g.ahead) ahead" : "") + (g.behind > 0 ? ", \(g.behind) behind" : "")
            return ([head] + g.status.map { "\($0.index)\($0.workTree) \($0.path)" }).joined(separator: "\n")
        case .arrangement:
            return try ls(ManiRequest(verb: "ls", flags: [:], args: [], cwd: r.cwd, here: r.here), scope)
        case .ui:
            return json(panelValues(b))
        default:
            throw Failure(message: "\(b.displayTitle) (\(b.kind.rawValue)) has no text to read")
        }
    }

    /// A command's output: off the screen if its terminal is shown, else
    /// what its host kept of it.
    private func output(of c: ShellCommand, in terminal: BlockID, view: PaneContent?) async throws -> String {
        if let view, let s = await view.maniText(ManiReadOptions(command: c.id)) { return s }
        let block = wc.outputBlockID(of: c, in: terminal)
        for _ in 0..<50 {
            if let o = hosts.block(block)?.output { return "$ " + c.text + "\n" + (o.plain ? o.output : Self.plain(o.output)) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure(message: "the host didn't give the command's output")
    }

    /// Terminal output as text: escapes (colors, cursor moves) taken out,
    /// carriage returns' overwrites settled.
    static func plain(_ s: String) -> String {
        let noEscapes = s.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
        return noEscapes.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: "\r", omittingEmptySubsequences: false).last(where: { !$0.isEmpty }).map(String.init) ?? ""
        }.joined(separator: "\n")
    }

    /// "a-b", "a-", "a" as a range from 1.
    private func range(_ s: String, what: String) throws -> ClosedRange<Int> {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let a = Int(parts[0]), a >= 1 else { throw Failure(message: "--\(what) is a-b, from 1", status: 2) }
        if parts.count == 1 { return a...a }
        let b = parts[1].isEmpty ? Int.max : (Int(parts[1]) ?? -1)
        guard parts.count == 2, b >= a else { throw Failure(message: "--\(what) is a-b, from 1", status: 2) }
        return a...b
    }

    private func lines(_ text: String, _ spec: String?) -> String {
        guard let spec, let r = try? range(spec, what: "lines") else { return text }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard r.lowerBound <= all.count else { return "" }
        return all[(r.lowerBound - 1)..<min(all.count, r.upperBound == Int.max ? all.count : r.upperBound)].joined(separator: "\n")
    }

    // MARK: Context

    private func context(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        var out: [String: Any] = [:]
        if let ws = scope.workspace { out["space"] = layoutJSON(ws, scope: scope) }
        if let t = scope.hereTile { out["here"] = t }
        if let sel = try? await selection(excluding: scope.here), let b = hosts.block(sel.block) {
            var o: [String: Any] = ["block": b.id.description, "kind": kindName(b, lens: .editor), "title": b.displayTitle,
                                    "text": String(sel.selection?.text.prefix(2000) ?? "")]
            if let tile = sel.tile { o["tile"] = tile }
            if let p = b.path { o["path"] = p }
            if let l = sel.selection?.lines { o["lines"] = [l.lowerBound, l.upperBound] }
            if let p = sel.selection?.page { o["page"] = p }
            out["selection"] = o
        }
        let shown = scope.arrangement?.placements.map(\.block) ?? []
        let terminals = shown.compactMap { hosts.block($0) }.filter { $0.terminal != nil }
        out["commands"] = terminals.compactMap { b -> [String: Any]? in
            guard let cs = b.terminal?.commands?.suffix(3), !cs.isEmpty else { return nil }
            return ["block": b.id.description, "title": b.displayTitle, "commands": cs.map(commandJSON)]
        }
        let dirty = hosts.blocks.filter { $0.kind == .text && $0.path != nil && $0.text?.isDirty == true }
        if !dirty.isEmpty { out["unsaved"] = dirty.map { ["block": $0.id.description, "title": $0.displayTitle, "path": $0.path ?? ""] } }
        if r.flags["json"] != nil { return json(out) }
        // As words.
        var lines: [String] = []
        if let ws = scope.workspace, let a = scope.arrangement {
            lines.append("space: \(wc.title(of: a)) (\(ws))")
            lines.append(try ls(ManiRequest(verb: "ls", flags: [:], args: [], cwd: r.cwd, here: r.here), scope).split(separator: "\n").dropFirst().joined(separator: "\n"))
        }
        if let sel = out["selection"] as? [String: Any] {
            var w = "selection: in \(sel["title"] ?? "") (\(sel["block"] ?? ""))"
            if let l = sel["lines"] as? [Int] { w += ", lines \(l[0])–\(l[1])" }
            if let p = sel["page"] as? Int { w += ", page \(p)" }
            lines.append(w)
            let text = (sel["text"] as? String) ?? ""
            lines.append(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).map { "  | " + $0 }.joined(separator: "\n"))
        } else {
            lines.append("selection: none")
        }
        for t in terminals {
            guard let cs = t.terminal?.commands?.suffix(3), !cs.isEmpty else { continue }
            lines.append("\(t.displayTitle) (\(t.id)):")
            for c in cs { lines.append("  $ \(c.text)" + (c.isRunning ? "  (running)" : c.status.map { "  (status \($0))" } ?? "")) }
        }
        if !dirty.isEmpty { lines.append("unsaved: " + dirty.map(\.displayTitle).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Placing

    /// Where `block` goes, by the flags: by `--at`, else @here's tile, else
    /// the focused; below it unless told otherwise.
    private func place(_ block: BlockID, lens: Lens, _ r: ManiRequest, _ scope: Scope, context: String) throws {
        var ref = scope.reference
        var ws = scope.workspace
        if let at = r.flags["at"] {
            let t = try resolve(at, scope)
            guard let id = t.tile else { throw Failure(message: "--at \(at) isn't shown") }
            ref = id
            ws = t.workspace ?? ws
        }
        if let ws2 = ws, ws2 != wc.selected { hosts.select(ws2) }
        ws = wc.selected
        guard let ws, let a = hosts.arrangement(ws) else { return wc.show(block, lens: lens, .here, context: context) }
        guard let ref, let (c, i) = a.locate(ref) else { return wc.show(block, lens: lens, .here, context: context) }
        let refBlock = a.placement(ref)?.block
        if r.flags["over"] != nil { return wc.show(block, lens: lens, .over(ref), context: context) }
        if r.flags["right"] != nil {
            return wc.show(block, lens: lens, c + 1 < a.columns.count ? .inColumn(c + 1) : .inNewColumn(c + 1), context: context)
        }
        if r.flags["left"] != nil { return wc.show(block, lens: lens, c > 0 ? .inColumn(c - 1) : .inNewColumn(0), context: context) }
        if r.flags["column"] != nil { return wc.show(block, lens: lens, .inNewColumn(c + 1), context: context) }
        if r.flags["above"] != nil {
            if let t = a.tile(of: block, lens: lens) { return wc.focus(t.id) }
            let p = Placement(block: block, lens: lens)
            let h = a.height(of: ref)
            hosts.append([.place(p, column: c, at: i), .heights([p.id: h / 2, ref: h / 2]), .focus(p.id)], to: .block(ws))
            if let refBlock, refBlock != block { hosts.link(from: refBlock, to: block, kind: .opened, context: context) }
            return
        }
        wc.show(block, lens: lens, .besideOpener(ref), context: context)
    }

    /// After a block is placed: gone to its line, and the app brought
    /// forward for a command run elsewhere.
    private func shown(_ block: BlockID, line: String?, scope: Scope) {
        if let line, let n = Int(line) { wc.goToLine(n, in: block) }
        if scope.here == nil { NSApp.activate() }
    }

    // MARK: Making

    private func open(_ r: ManiRequest, _ scope: Scope, _ asker: Asker) throws -> String? {
        let wait = r.flags["wait"] != nil
        var placed: [PlacementID] = []
        var made: [BlockID] = []
        let on = scope.host
        for arg in r.args {
            let (block, lens, isNew) = wc.blockAndLens(forPath: arg, on: on, wait: wait)
            if wait, isNew { made.append(block) }
            let before = Set(hosts.arrangement(wc.selected)?.placements.map(\.id) ?? [])
            if wait, placed.isEmpty, let opener = scope.hereTile, r.flags.keys.allSatisfy({ !["below", "above", "right", "left", "column", "over", "at"].contains($0) }) {
                // $EDITOR: over the terminal that ran it, which comes back
                // when the editing is done.
                if let ws = scope.workspace, ws != wc.selected { hosts.select(ws) }
                wc.showOver(block, lens: lens, over: opener, again: true, context: arg.lastPathComponent)
            } else {
                try place(block, lens: lens, r, scope, context: "mani open")
            }
            last = block
            if let a = hosts.arrangement(wc.selected),
               let p = a.placements.first(where: { $0.block == block && !before.contains($0.id) }) ?? a.placements.first(where: { $0.block == block }) {
                placed.append(p.id)
            }
            shown(block, line: r.flags["line"], scope: scope)
        }
        guard wait, !placed.isEmpty else { return "" }
        wc.openWaits.append((asker.host, asker.id, asker.client, placed, made))
        return nil
    }

    private func make(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let kind = r.args[0]
        let what = r.args.count > 1 ? r.args[1] : nil
        let on = scope.host
        guard let client = hosts.client(on) else { throw Failure(message: "that host isn't attached") }
        let cwd = r.flags["cwd"].map { $0.hasPrefix("/") ? $0 : r.cwd.appendingPathComponent($0) } ?? r.cwd
        let block: BlockID
        var lens: Lens
        switch kind {
        case "note":
            guard what == nil else { throw Failure(message: "a note's text comes from --text or the input", status: 2) }
            block = client.newNote(home: cwd, text: r.flags["text"] ?? r.input ?? "")
            lens = r.flags["preview"] != nil ? .preview : .editor
        case "terminal":
            block = hosts.newTerminal(on: on, cwd: cwd)
            lens = .terminal
        case "agent":
            block = client.newAgent(cwd: cwd, command: what ?? wc.host.desk.settings.agentCommand)
            lens = .agent
        case "web":
            guard let url = what else { throw Failure(message: "new web needs an address", status: 2) }
            if case let .page(u) = WebAddress.parse(url) { block = wc.host.newWeb(url: u) } else { block = wc.host.newWeb(url: url) }
            lens = .web
        case "search":
            guard let text = what else { throw Failure(message: "new search needs what to look for", status: 2) }
            block = client.newSearch(SearchQuery(text: text, root: cwd))
            lens = .search
        default:
            throw Failure(message: "no kind \(kind) to make: note, terminal, agent, web, search", status: 2)
        }
        if let title = r.flags["title"] { hosts.append(.title(title), to: .block(block)) }
        try place(block, lens: lens, r, scope, context: "mani new \(kind)")
        last = block
        shown(block, line: nil, scope: scope)
        return block.description
    }

    private func write(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let t = try resolve(r.args[0], scope)
        guard let b = hosts.block(t.block), b.kind == .text, let text = b.text else {
            throw Failure(message: "\(r.args[0]) isn't a note or a file's text")
        }
        guard !b.needsRead else { throw Failure(message: "\(b.displayTitle) hasn't been read from disk yet") }
        let new = r.flags["text"] ?? r.input ?? ""
        let end = text.text.count
        let edit = r.flags["append"] != nil ? TextEdit(TextRange(end, end), new) : TextEdit(TextRange(0, end), new)
        hosts.append(.edit([edit]), to: .block(b.id))
        if r.flags["save"] != nil {
            guard b.path != nil else { throw Failure(message: "a note has no file to save to") }
            if let tile = t.tile { wc.save(b.id, from: tile) } else if let v = hosts.block(b.id)?.text?.version { hosts.propose(.writeFile(b.id, version: v)) }
        }
        return ""
    }

    private func show(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let t = try resolve(r.args[0], scope)
        if let tile = t.tile, let ws = t.workspace {
            if ws != wc.selected { hosts.select(ws) }
            wc.arrive(atTile: tile)
        } else {
            guard let b = hosts.block(t.block) else { throw Failure(message: "\(r.args[0]) isn't known here") }
            try place(b.id, lens: Lens.default(for: b.kind, path: b.path), r, scope, context: "mani show")
        }
        shown(t.block, line: r.flags["line"], scope: scope)
        return ""
    }

    private func close(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let t = try resolve(r.args[0], scope)
        guard let tile = t.tile, let ws = t.workspace else { throw Failure(message: "\(r.args[0]) isn't shown") }
        if ws == wc.selected { wc.gridClose(tile) } else { hosts.append([.remove(tile)], to: .block(ws)) }
        return ""
    }

    // MARK: Running

    private func runCommand(_ r: ManiRequest, _ scope: Scope, _ asker: Asker) throws -> String? {
        let t = try resolve(r.args[0], scope)
        guard let b = hosts.block(t.block), let term = b.terminal else { throw Failure(message: "\(r.args[0]) isn't a terminal") }
        let command = r.args.dropFirst().joined(separator: " ")
        let after = term.commands?.last?.id ?? -1
        hosts.propose(.input(block: b.id, text: command + "\r")) { [weak self] error in
            guard let self, let error else { return }
            self.runs.removeValue(forKey: asker)
            self.reply(asker, err: "mani: \(error)\n", status: 1)
        }
        guard r.flags["wait"] != nil else { return "" }
        runs[asker] = (b.id, after, Date())
        if let s = r.flags["timeout"] {
            guard let seconds = Double(s), seconds > 0 else { throw Failure(message: "--timeout is a number of seconds", status: 2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.runs.removeValue(forKey: asker) != nil else { return }
                self.reply(asker, err: "mani: it didn't end in \(s) seconds\n", status: 124)
            }
        }
        return nil
    }

    /// `run --wait`s whose command has ended: answered with its output.
    private func checkRuns() {
        for (asker, run) in runs {
            guard let c = hosts.block(run.block)?.terminal?.commands?.first(where: { $0.id > run.after }), !c.isRunning else { continue }
            runs.removeValue(forKey: asker)
            let view = located(run.block, Scope(self, ManiRequest(verb: "run", flags: [:], args: [], cwd: "/", here: nil), asker)).tile.flatMap { wc.views[$0] }
            Task { @MainActor in
                // A moment for the screen to show the end of it.
                try? await Task.sleep(nanoseconds: 150_000_000)
                let out = (try? await self.output(of: c, in: run.block, view: view)) ?? ""
                // Its output, less the command line it starts with.
                let body = out.hasPrefix("$ ") ? out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined() : out
                self.reply(asker, out: body.isEmpty || body.hasSuffix("\n") ? body : body + "\n", status: c.status ?? 0)
            }
        }
    }

    // MARK: Watching

    /// The model changed: waits that were waiting on it answered, and
    /// watchers told what happened.
    func modelChanged() {
        if !runs.isEmpty { checkRuns() }
        guard !watchers.isEmpty else { seen = nil; return }
        let now = Seen(self)
        if let before = seen { now.events(since: before).forEach { tell($0.0, $0.1) } }
        seen = now
    }

    private func tell(_ event: String, _ fields: [String: Any]) {
        guard !watchers.isEmpty else { return }
        var o = fields
        o["event"] = event
        o["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let line = String(decoding: data, as: UTF8.self) + "\n"
        for (asker, only) in watchers where only?.contains(event) ?? true {
            reply(asker, out: line, status: nil)
        }
    }

    /// What a watch compares, from one change to the next.
    private struct Seen {
        var workspace: BlockID?
        var focused: PlacementID?
        var tiles: [PlacementID: BlockID] = [:]
        var commands: [BlockID: (id: Int, running: Bool, status: Int32?, text: String)] = [:]
        var statuses: [BlockID: StatusState] = [:]
        var dirty: Set<BlockID> = []

        @MainActor init(_ desk: ManiDesk) {
            let hosts = desk.hosts
            workspace = desk.wc.selected
            let a = hosts.arrangement(workspace)
            focused = a?.focused
            for p in a?.placements ?? [] { tiles[p.id] = p.block }
            for b in hosts.blocks {
                if let c = b.terminal?.commands?.last { commands[b.id] = (c.id, c.isRunning, c.status, c.text) }
                if let s = b.statusRecord?.state, s != .idle { statuses[b.id] = s }
                if b.text?.isDirty == true { dirty.insert(b.id) }
            }
        }

        func events(since old: Seen) -> [(String, [String: Any])] {
            var out: [(String, [String: Any])] = []
            if workspace != old.workspace { out.append(("space", ["space": workspace?.description ?? ""])) }
            if focused != old.focused, let f = focused { out.append(("focus", ["tile": f, "block": tiles[f]?.description ?? ""])) }
            if workspace == old.workspace {
                for (t, b) in tiles where old.tiles[t] == nil { out.append(("open", ["tile": t, "block": b.description])) }
                for (t, b) in old.tiles where tiles[t] == nil { out.append(("close", ["tile": t, "block": b.description])) }
            }
            for (b, c) in commands {
                let was = old.commands[b]
                if was == nil || was!.id != c.id, c.running {
                    out.append(("command", ["block": b.description, "id": c.id, "command": c.text, "state": "started"]))
                }
                if !c.running, was == nil || was!.id != c.id || was!.running {
                    var o: [String: Any] = ["block": b.description, "id": c.id, "command": c.text, "state": "ended"]
                    if let s = c.status { o["status"] = Int(s) }
                    out.append(("command", o))
                }
            }
            for (b, s) in statuses where old.statuses[b] != s { out.append(("status", ["block": b.description, "status": s.rawValue])) }
            for b in old.statuses.keys where statuses[b] == nil { out.append(("status", ["block": b.description, "status": "idle"])) }
            for b in old.dirty.subtracting(dirty) { out.append(("save", ["block": b.description])) }
            return out
        }
    }

    // MARK: Panels

    private func newPanel(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let spec = try panelSpec(r.flags["text"] ?? r.input)
        guard let client = hosts.client(scope.host) else { throw Failure(message: "that host isn't attached") }
        let block = client.newPanel(home: r.cwd, spec: spec.json)
        if let title = r.flags["title"] ?? spec.object["title"] as? String { hosts.append(.title(title), to: .block(block)) }
        try place(block, lens: .ui, r, scope, context: "mani ui new")
        last = block
        shown(block, line: nil, scope: scope)
        return block.description
    }

    /// Widgets as JSON, checked: an object (with items), or a list of items.
    private func panelSpec(_ text: String?) throws -> (json: String, object: [String: Any]) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "a panel's widgets come as JSON, from --text or the input: {\"items\": [...]}", status: 2)
        }
        guard let data = text.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure(message: "the widgets aren't JSON", status: 2)
        }
        let object: [String: Any]
        if let o = parsed as? [String: Any] { object = o } else if let items = parsed as? [Any] { object = ["items": items] } else {
            throw Failure(message: "the widgets are an object with items, or a list of them", status: 2)
        }
        return (json(object), object)
    }

    private func panel(_ name: String, _ scope: Scope) throws -> Block {
        let t = try resolve(name, scope)
        guard let b = hosts.block(t.block), b.kind == .ui else { throw Failure(message: "\(name) isn't a panel") }
        return b
    }

    private func setPanel(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let b = try panel(r.args[0], scope)
        let assignments = Array(r.args.dropFirst())
        var spec = b.ui.flatMap { $0.spec.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var specChanged = false
        if r.flags["text"] != nil || (r.input.map { !$0.isEmpty } ?? false) {
            spec = try panelSpec(r.flags["text"] ?? r.input).object
            specChanged = true
        } else if assignments.isEmpty {
            throw Failure(message: "ui set needs values (id=value, id.property=value) or widgets on its input", status: 2)
        }
        var values: [String: String] = [:]
        for a in assignments {
            guard let eq = a.firstIndex(of: "="), eq != a.startIndex else { throw Failure(message: "\(a) isn't id=value", status: 2) }
            let key = String(a[..<eq]), raw = String(a[a.index(after: eq)...])
            let value: Any = PanelView.parse(raw) ?? raw
            if let dot = key.firstIndex(of: ".") {
                let id = String(key[..<dot]), prop = String(key[key.index(after: dot)...])
                guard Self.setProperty(&spec, id: id, prop, value) else { throw Failure(message: "no widget \(id) in the panel") }
                specChanged = true
            } else {
                values[key] = PanelView.json(value)
            }
        }
        if specChanged { hosts.append(.uiSpec(json(spec)), to: .block(b.id)) }
        if !values.isEmpty { hosts.append(.uiValues(values), to: .block(b.id)) }
        return ""
    }

    /// A widget's property set, wherever it is among the items.
    private static func setProperty(_ node: inout [String: Any], id: String, _ prop: String, _ value: Any) -> Bool {
        if node["id"] as? String == id {
            node[prop] = value
            return true
        }
        guard var items = node["items"] as? [Any] else { return false }
        for i in items.indices {
            guard var child = items[i] as? [String: Any] else { continue }
            if setProperty(&child, id: id, prop, value) {
                items[i] = child
                node["items"] = items
                return true
            }
        }
        return false
    }

    /// A panel's values: those set or changed, else those its widgets began with.
    private func panelValues(_ b: Block) -> [String: Any] {
        var out: [String: Any] = [:]
        func walk(_ node: [String: Any]) {
            if let id = node["id"] as? String, let v = node["value"] { out[id] = v }
            for child in node["items"] as? [[String: Any]] ?? [] { walk(child) }
        }
        if let data = b.ui?.spec.data(using: .utf8), let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { walk(spec) }
        for (k, v) in b.ui?.values ?? [:] { out[k] = PanelView.parse(v) ?? NSNull() }
        return out
    }

    private func getPanel(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let b = try panel(r.args[0], scope)
        let values = panelValues(b)
        guard r.args.count > 1 else { return json(values) }
        guard let v = values[r.args[1]] else { throw Failure(message: "the panel has no value \(r.args[1])") }
        return (v as? String) ?? PanelView.json(v)
    }

    private func waitPanel(_ r: ManiRequest, _ scope: Scope, _ asker: Asker) throws -> String? {
        let b = try panel(r.args[0], scope)
        let id = r.flags["id"]
        if var queue = panelEvents[b.id], let i = queue.firstIndex(where: { id == nil || Self.eventID($0) == id }) {
            let line = queue.remove(at: i)
            panelEvents[b.id] = queue
            return line
        }
        panelWaits[asker] = (b.id, id)
        if let s = r.flags["timeout"] {
            guard let seconds = Double(s), seconds > 0 else { throw Failure(message: "--timeout is a number of seconds", status: 2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.panelWaits.removeValue(forKey: asker) != nil else { return }
                self.reply(asker, err: "mani: nothing happened in \(s) seconds\n", status: 124)
            }
        }
        return nil
    }

    private static func eventID(_ line: String) -> String? {
        (line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["id"] as? String
    }

    /// Something done in a panel: its values kept, its widget's command
    /// run, and told to a `ui wait` on it (else kept for the next) and to
    /// watchers.
    func panelEvent(_ block: BlockID, event: [String: Any], changed: [String: String], run: String?) {
        if !changed.isEmpty { hosts.append(.uiValues(changed), to: .block(block)) }
        var e = event
        e["block"] = block.description
        if let b = hosts.block(block) {
            var values = panelValues(b)
            for (k, v) in changed { values[k] = PanelView.parse(v) ?? NSNull() }
            e["values"] = values
        }
        guard let data = try? JSONSerialization.data(withJSONObject: PanelView.tidy(e), options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let line = String(decoding: data, as: UTF8.self)
        if let run { hosts.propose(.runPanel(block: block, command: run, event: line)) }
        tell("panel", e)
        let id = event["id"] as? String
        if let waiting = panelWaits.first(where: { $0.value.block == block && ($0.value.id == nil || $0.value.id == id) }) {
            panelWaits.removeValue(forKey: waiting.key)
            reply(waiting.key, out: line + "\n", status: 0)
        } else {
            panelEvents[block, default: []].append(line)
            if panelEvents[block]!.count > 200 { panelEvents[block]!.removeFirst() }
        }
    }

    // MARK: JSON

    /// A share, to three places, as JSON writes it exactly (a Double's
    /// 0.227 comes out 0.22700000000000001).
    static func decimal(_ d: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", d)).rounding(accordingToBehavior: nil)
    }

    private func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: PanelView.tidy(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
