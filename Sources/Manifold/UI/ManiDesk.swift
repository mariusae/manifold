import AppKit
import PDFKit
import ManifoldCore
import ManifoldSyntax

/// `mani`'s commands that the app does (`Mani.verbs`, those `inApp`),
/// asked through a host (`ManiRequest`) and answered to it (`ManiReply`):
/// naming blocks (ids, paths, titles, `@` names and positions), listing the
/// layout, reading what blocks hold, making and placing blocks, typing
/// into terminals, and telling a `watch` what happens. Remembers what
/// commands need between them: where text was last selected, the block
/// made last, the commands waiting on something.
@MainActor
final class ManiDesk {
    unowned let wc: MainWindowController
    var hosts: Hosts { wc.hosts }

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
        var scope = Scope(self, r, asker)
        if let name = r.flags["space"] { scope.act(in: try space(named: name), hosts: hosts) }
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
            // Places at either end, as anchors (a line of a text made one).
            let fromAnchor = wc.anchor(from.at, in: from.block)?.anchorID
            let toAnchor = wc.anchor(to.at, in: to.block)?.anchorID
            hosts.link(from: from.block, to: to.block, kind: .linked, context: r.flags["note"],
                       fromAnchor: fromAnchor, toAnchor: toAnchor, relation: r.flags["as"])
            return ""
        case "threads", "thread read", "thread new", "thread reply", "thread resolve", "thread reopen":
            return try await threads(r, scope)
        case "symbols": return try await symbols(r, scope)
        case "index": return try await index(r, scope)
        case "project": return try await project(r, scope)
        case "refs": return try await refs(r, scope)
        case "callers":
            let b = try await textBlock(r.args[0], scope)
            let at = try await symbolOffset(r, in: b)
            let depth = min(max(Int(r.flags["depth"] ?? "1") ?? 1, 1), 4)
            return try await callers(of: b, at: at, depth: depth, scope).markdown
        case "ref": return try await ref(r, scope)
        case "annotate":
            let t = try await target(r.args[0], scope)
            let pairs = r.args.dropFirst()
            if pairs.isEmpty {
                let a = hosts.block(t.block)?.annotations ?? [:]
                if r.flags["json"] != nil { return json(a) }
                return a.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            }
            var values: [String: String] = [:]
            for p in pairs {
                guard let (k, v) = Annotation.pair(p) else {
                    throw Failure(message: "\(p) isn't key=value (a key: a letter or _, then letters, digits, _ . : -)", status: 2)
                }
                values[k] = v
            }
            hosts.append(.annotate(values), to: .block(t.block))
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
        /// Told its space (`--space`, `MANI_SPACE`): what it places goes
        /// there whichever is shown, and the shown one stays.
        var spaceGiven = false

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

        /// About another space: positions from its focused tile (or @here,
        /// if it's there).
        @MainActor mutating func act(in ws: BlockID, hosts: Hosts) {
            workspace = ws
            arrangement = hosts.arrangement(ws)
            hereTile = here.flatMap { h in arrangement?.placements.first { $0.block == h }?.id }
            reference = hereTile ?? arrangement?.focused
            spaceGiven = true
        }
    }

    /// A space by what it's called (as the sidebar names it, or as named),
    /// its id, or @space.
    private func space(named name: String) throws -> BlockID {
        let spaces = wc.allWorkspaces
        if name == "@space", let ws = wc.selected { return ws }
        if let id = BlockID(string: name), spaces.contains(id) { return id }
        // What it's annotated with.
        if let (key, value) = Annotation.pair(name), !value.isEmpty {
            let marked = spaces.filter { hosts.block($0).map { Annotation.matches($0, key: key, value: value) } ?? false }
            if marked.count == 1 { return marked[0] }
            if marked.isEmpty { throw Failure(message: "no space is annotated \(name)") }
            throw Failure(message: "more than one space is annotated \(name): " + marked.map(\.description).joined(separator: ", "))
        }
        let called = spaces.filter { ws in
            guard let a = hosts.arrangement(ws) else { return false }
            return wc.title(of: a).caseInsensitiveCompare(name) == .orderedSame || hosts.block(ws)?.title?.caseInsensitiveCompare(name) == .orderedSame
        }
        if called.count == 1 { return called[0] }
        if called.isEmpty { throw Failure(message: "no space called \(name)") }
        throw Failure(message: "more than one space is called \(name): " + called.map(\.description).joined(separator: ", "))
    }

    /// What a name came to: a block, its tile (and workspace) if it's
    /// placed, and for @selection what's selected.
    struct Target {
        var block: BlockID
        var tile: PlacementID?
        var workspace: BlockID?
        var selection: ManiSelected?
        /// A place in it, as a reference names one (an anchor, `line=12`, `page=3`, `command=7`).
        var at: Locator?
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

    /// The block annotated `key=value`: the one in the space if one is
    /// there, else the one anywhere; more than one, an error naming them.
    private func annotated(_ key: String, _ value: String, name: String, _ scope: Scope) throws -> Target {
        let all = hosts.blocks.filter { Annotation.matches($0, key: key, value: value) }
        guard !all.isEmpty else { throw Failure(message: "no block is annotated \(name)") }
        if all.count == 1 { return located(all[0].id, scope) }
        if let a = scope.arrangement {
            let here = all.filter { b in a.placements.contains { $0.block == b.id } }
            if here.count == 1 { return located(here[0].id, scope) }
        }
        throw Failure(message: "\(name) could be any of these; name one:\n" + all.map { "  \($0.id)  \($0.displayTitle)" }.joined(separator: "\n"))
    }

    /// A reference, an id, a path, a title.
    private func other(_ s: String, _ scope: Scope) throws -> Target {
        // A reference — `manifold:host/id`, a place in it after `#` — as a
        // link, a ⇧-drop or Copy Link gives one; or a Markdown link to one,
        // as notes hold them.
        if let (id, fragment) = BlockID.reference(s) {
            if let why = hosts.whyMissing(id) { throw Failure(message: "\(s): \(why)") }
            var t = located(id, scope)
            t.at = fragment.flatMap(Locator.init(fragment:))
            return t
        }
        // What it's annotated with: the one block with key=value, in the
        // space first (`*`: any value).
        if let (key, value) = Annotation.pair(s), !value.isEmpty {
            return try annotated(key, value, name: s, scope)
        }
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

    // MARK: Places (§2.5)

    /// A text block for a name: one known, or a file by its path, made a
    /// block (and read from disk, waited for a moment).
    private func textBlock(_ name: String, _ scope: Scope) async throws -> Block {
        var id: BlockID
        do {
            id = try resolve(name, scope).block
        } catch {
            guard name.contains("/") || name.contains("."), !name.hasPrefix("manifold:") else { throw error }
            var path = name.expandingTildeInPath
            if !path.hasPrefix("/") { path = scope.request.cwd.appendingPathComponent(path) }
            path = URL(fileURLWithPath: path).standardizedFileURL.path
            if scope.host == hosts.local.host, !FileManager.default.fileExists(atPath: path) { throw Failure(message: "no file \(name)") }
            id = hosts.textBlock(for: path, on: scope.host)
        }
        for _ in 0..<100 {
            if let b = hosts.block(id) {
                guard b.kind == .text else { throw Failure(message: "\(name) isn't a file's text or a note") }
                if !b.needsRead { return b }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure(message: "\(name) hasn't been read from disk yet")
    }

    /// `mani symbols`: a file's declarations, by path, each with its line;
    /// a Markdown text's headings, indented by level.
    private func symbols(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        let b = try await textBlock(r.args[0], scope)
        guard let rope = b.text?.text else { return "" }
        if let path = b.path, let language = SyntaxLanguage.forPath(path) {
            let decls = SyntaxTree(language, text: rope, background: false).declarations()
            if decls.isEmpty { throw Failure(message: "no declarations in \(b.displayTitle)") }
            return decls.map { "\($0.path)\t\(rope.line(at: $0.range.start) + 1)" }.joined(separator: "\n")
        }
        let headings = NoteOutlineMarkdown.items(in: rope.string).filter(\.isHeading)
        guard !headings.isEmpty else { throw Failure(message: "\(b.displayTitle) has no grammar here, and no headings") }
        return headings.map { String(repeating: "  ", count: max($0.level - 1, 0)) + $0.title + "\t\($0.line + 1)" }.joined(separator: "\n")
    }

    /// `mani ref`: a reference to a place in a file — a declaration, a
    /// heading, a line — its anchor found or minted.
    private func ref(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        let b = try await textBlock(r.args[0], scope)
        guard let rope = b.text?.text else { throw Failure(message: "\(r.args[0]) has no text") }
        var line: Int?
        if let want = r.flags["symbol"] {
            guard let path = b.path, let language = SyntaxLanguage.forPath(path) else { throw Failure(message: "\(b.displayTitle) has no grammar to find declarations by") }
            let decls = SyntaxTree(language, text: rope, background: false).declarations()
            let found = decls.filter { $0.path == want }.first ?? decls.filter { $0.path.hasSuffix("." + want) || $0.name == want }.first
            guard let d = found else { throw Failure(message: "no declaration \(want) in \(b.displayTitle) (mani symbols lists them)") }
            line = rope.line(at: d.range.start)
        } else if let want = r.flags["heading"] {
            let headings = NoteOutlineMarkdown.items(in: rope.string).filter(\.isHeading)
            guard let h = headings.first(where: { $0.title == want }) ?? headings.first(where: { $0.title.lowercased() == want.lowercased() }) else {
                throw Failure(message: "no heading \(want) in \(b.displayTitle)")
            }
            line = h.line
        } else if let n = r.flags["line"] {
            guard let k = Int(n), k >= 1, k <= rope.lineCount else { throw Failure(message: "\(b.displayTitle) has \(rope.lineCount) lines") }
            line = k - 1
        }
        guard let line else { throw Failure(message: "say where: --symbol, --heading or --line", status: 2) }
        guard let address = wc.reference(toLine: line, in: b.id) else { throw Failure(message: "no place at line \(line + 1)") }
        guard r.flags["markdown"] != nil else { return address }
        let anchor = BlockID.link(address)?.fragment
        let name = anchor.flatMap { hosts.block(b.id)?.anchors?[$0] }.map(Anchoring.name(of:))
            ?? Anchoring.anchor(atLine: line, of: b).map(Anchoring.name(of:)) ?? b.displayTitle
        return "[\(name.replacingOccurrences(of: "]", with: "\\]"))](\(address))"
    }

    // MARK: SCIP (§2.5)

    private func scip(_ request: SCIPRequest, on host: HostID) async -> SCIPResult {
        await withCheckedContinuation { c in hosts.scip(request, on: host) { c.resume(returning: $0) } }
    }

    private func describe(_ s: SCIPStatus) -> String {
        let root = s.root?.abbreviatingHome ?? "no project"
        let by = s.indexer.map { " (\($0))" } ?? ""
        switch s.state {
        case .none: return "\(root)\(by): no index yet" + (s.message.map { " — " + $0 } ?? "")
        case .indexing: return "\(root)\(by): indexing…"
        case .current: return "\(root)\(by): indexed" + (s.at.map { " " + Age.ago(Stamp(wall: Int64($0.timeIntervalSince1970 * 1000))) } ?? "")
            + (s.changed.flatMap { $0 > 0 ? " — \($0) code file\($0 == 1 ? "" : "s") changed since; `mani index` makes it again" : nil } ?? "")
        case .failed: return "\(root)\(by): the indexer failed:\n" + (s.message ?? "")
        }
    }

    /// `mani project`: the project a folder is in (§2.6), made one, or
    /// no longer.
    private func project(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        guard let client = hosts.client(scope.host) else { throw Failure(message: "that host isn't attached") }
        var path = (r.args.first ?? ".").expandingTildeInPath
        if !path.hasPrefix("/") { path = r.cwd.appendingPathComponent(path) }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        func propose(_ p: Proposal) async throws {
            let error: String? = await withCheckedContinuation { c in client.propose(p) { c.resume(returning: $0) } }
            if let error { throw Failure(message: error) }
        }
        if r.flags["remove"] != nil {
            guard let p = client.project(holding: path) else { throw Failure(message: "\(path.abbreviatingHome) isn't in a project") }
            try await propose(.unproject(root: p.root))
            return "\(p.root.abbreviatingHome) is no longer a project"
        }
        if r.flags["make"] != nil {
            try await propose(.project(Project(root: path, made: Stamp(wall: Int64(Date().timeIntervalSince1970 * 1000)))))
            for _ in 0..<40 where client.desk.projects.first(where: { $0.root == path || $0.alias == path }) == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard let p = client.project(holding: path) else {
            throw Failure(message: "\(path.abbreviatingHome) isn't in a project (`mani project --make` makes this folder one)")
        }
        var lines = [p.root.abbreviatingHome + " — a project since " + Age.ago(p.made)]
        // Its repository's state, scoped to it: its git block's, once it's looked.
        let git = client.projectGitBlock(for: p)
        for _ in 0..<60 where hosts.block(git)?.git?.refreshedAt == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        if let b = hosts.block(git), let g = b.git, let repo = b.path {
            if let e = g.error {
                lines.append("repository: " + e)
            } else {
                var branch = g.branch ?? "detached"
                if g.ahead > 0 { branch += " ↑\(g.ahead)" }
                if g.behind > 0 { branch += " ↓\(g.behind)" }
                lines.append((g.vcs == .sapling ? "Sapling" : "git") + " at " + repo.abbreviatingHome + (g.scope.map { ", the project its \($0)/" } ?? "") + ": " + branch)
                let scope = g.scope.map { $0 + "/" } ?? ""
                lines.append(g.status.isEmpty ? "no changes" : (g.status.count == 1 ? "1 change:" : "\(g.status.count) changes:"))
                for s in g.status.prefix(20) {
                    lines.append("  \(s.isUntracked ? "?" : s.workTree != " " ? s.workTree : s.index) " + (s.path.hasPrefix(scope) ? String(s.path.dropFirst(scope.count)) : s.path))
                }
                if let c = g.log.first { lines.append("last commit: \(c.short) \(c.summary)") }
            }
        } else {
            lines.append("not in a repository")
        }
        if case .status(let s) = await scip(.status(path: p.root.appendingPathComponent(".")), on: scope.host) {
            lines.append("index: " + (s.root == nil ? "none (" + (s.message ?? "no indexer for its language") + ")" : describe(s)))
        }
        return lines.joined(separator: "\n")
    }

    /// `mani index`: the project a file (or this folder) is in indexed.
    private func index(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        var path = (r.args.first ?? ".").expandingTildeInPath
        if !path.hasPrefix("/") { path = r.cwd.appendingPathComponent(path) }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        // A folder: the project at it (a file in it, as far as finding goes).
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { path = path.appendingPathComponent(".") }
        let request: SCIPRequest = r.flags["status"] != nil ? .status(path: path) : .index(path: path)
        guard case .status(var s) = await scip(request, on: scope.host) else {
            if case .error(let m) = await scip(.status(path: path), on: scope.host) { throw Failure(message: m) }
            throw Failure(message: "no indexer for \(path.abbreviatingHome)")
        }
        if r.flags["wait"] != nil, r.flags["status"] == nil {
            for _ in 0..<1200 where s.state == .indexing {
                try await Task.sleep(nanoseconds: 500_000_000)
                if case .status(let now) = await scip(.status(path: path), on: scope.host) { s = now }
            }
            if s.state == .failed { throw Failure(message: describe(s)) }
        }
        return describe(s)
    }

    /// Where a symbol's name is in a file, as a command names it: the
    /// declaration --symbol or --line names, or a reference's place.
    private func symbolOffset(_ r: ManiRequest, in b: Block) async throws -> Int {
        guard let path = b.path, let rope = b.text?.text else { throw Failure(message: "\(b.displayTitle) isn't a file") }
        let fragment = BlockID.reference(r.args[0])?.fragment
        // Where the symbol's name is: the declaration a reference, --symbol
        // or --line names, else the reference's place itself.
        var at: Int?
        let decls = SyntaxLanguage.forPath(path).map { SyntaxTree($0, text: rope, background: false).declarations() } ?? []
        if let want = r.flags["symbol"] {
            at = (decls.first { $0.path == want } ?? decls.first { $0.path.hasSuffix("." + want) || $0.name == want })?.nameRange.start
            if at == nil { throw Failure(message: "no declaration \(want) in \(b.displayTitle)") }
        } else if let n = r.flags["line"].flatMap(Int.init) {
            guard n >= 1, n <= rope.lineCount else { throw Failure(message: "\(b.displayTitle) has \(rope.lineCount) lines") }
            let range = rope.lineRange(n - 1)
            at = decls.last { $0.range.start >= range.start && $0.range.start <= range.end }?.nameRange.start
                ?? rope.offset(ofLine: n - 1) + (rope.lineText(n - 1).utf8.prefix { $0 == 32 || $0 == 9 }.count)
        } else if let f = fragment.flatMap(Locator.init(fragment:))?.anchorID, let a = b.anchors?[f], let (range, _) = Anchoring.locate(a, in: b) {
            at = decls.first { $0.range == range }?.nameRange.start ?? range.start
        }
        guard let at else { throw Failure(message: "say which symbol: a reference to it, or --symbol, or --line", status: 2) }
        return at
    }

    /// The symbol the index has at a byte of a file.
    private func indexSymbol(in b: Block, at offset: Int) async throws -> SCIPSymbol {
        guard let path = b.path, let rope = b.text?.text else { throw Failure(message: "\(b.displayTitle) isn't a file") }
        let line = rope.line(at: offset)
        guard case .symbol(let found) = await scip(.symbol(path: path, line: line, byte: offset - rope.offset(ofLine: line)), on: b.id.host) else {
            if case .error(let m) = await scip(.status(path: path), on: b.id.host) { throw Failure(message: m) }
            throw Failure(message: "\(path.abbreviatingHome)'s project has no index (mani index makes one)")
        }
        guard let s = found else { throw Failure(message: "the index knows no symbol there (it may be out of date: mani index)") }
        return s
    }

    /// The functions that use the symbol at a byte of a file — each found
    /// by the index, named by its file's grammar — with where, `depth`
    /// levels up: as Markdown, each a reference.
    func callers(of b: Block, at offset: Int, depth: Int, _ scope: Scope) async throws -> (name: String, markdown: String) {
        let s = try await indexSymbol(in: b, at: offset)
        var lines: [String] = []
        var seen: Set<String> = [s.symbol]
        func up(_ symbol: String, in path: String, host: HostID, level: Int) async throws {
            guard case .locations(let places) = await scip(.references(symbol: symbol, path: path), on: host) else { return }
            // By the function each use is in.
            var groups: [(key: String, block: Block, decl: Declaration?, uses: [SCIPLocation])] = []
            for p in places where !p.isDefinition {
                let fb = try await textBlock(p.path, scope)
                guard let rope = fb.text?.text, p.line < rope.lineCount else { continue }
                let lineStart = rope.offset(ofLine: p.line)
                let decls = fb.path.flatMap(SyntaxLanguage.forPath).map { SyntaxTree($0, text: rope, background: false).declarations() } ?? []
                let decl = decls.last { $0.range.start <= lineStart && $0.range.end > lineStart }
                let key = "\(fb.id)#\(decl?.path ?? "")"
                if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].uses.append(p) } else { groups.append((key, fb, decl, [p])) }
            }
            for g in groups {
                let pad = String(repeating: "  ", count: level)
                let rope = g.block.text!.text
                var head = "\(pad)- "
                if let d = g.decl, let ref = wc.reference(toLine: rope.line(at: d.range.start), in: g.block.id) {
                    head += "[\(d.path)](\(ref)) in \(g.block.displayTitle)"
                } else {
                    head += "the top of \(g.block.displayTitle)"
                }
                let uses = g.uses.prefix(6).compactMap { u -> String? in
                    wc.reference(toLine: u.line, in: g.block.id, exactly: true).map { "[line \(u.line + 1)](\($0))" }
                }
                lines.append(head + " — " + uses.joined(separator: ", ") + (g.uses.count > 6 ? ", …" : ""))
                // Its own callers, a level up.
                if level + 1 < depth, let d = g.decl, let path = g.block.path {
                    let inner = try? await indexSymbol(in: g.block, at: d.nameRange.start)
                    if let inner, seen.insert(inner.symbol).inserted { try await up(inner.symbol, in: path, host: g.block.id.host, level: level + 1) }
                }
            }
        }
        try await up(s.symbol, in: b.path ?? "", host: b.id.host, level: 0)
        let title = "Callers of \(s.name)"
        return (s.name, "# \(title)\n\n" + (lines.isEmpty ? "Nothing in the project calls it (as of its index)." : lines.joined(separator: "\n")) + "\n")
    }

    /// A symbol's relation as hits (§2.5), for the search lens:
    /// "references", where it's used; "callers", each use that's in a
    /// definition, said as in it — and, `depth` deep, theirs ("in main →
    /// serve"). From the project's index, as `mani refs` and `mani callers`
    /// have them.
    func relationHits(_ relation: String, symbol: String, path: String, host: HostID, depth: Int = 2, _ scope: Scope) async throws -> [SearchHit] {
        if relation == "references" {
            guard case .locations(let places) = await scip(.references(symbol: symbol, path: path), on: host) else {
                throw Failure(message: "the index couldn't say where it's used")
            }
            return places.map { p in
                var h = SearchHit(path: p.path, line: p.line + 1, column: p.character + 1, text: p.text)
                if p.isDefinition { h.context = "definition" }
                return h
            }
        }
        var hits: [SearchHit] = []
        var seen: Set<String> = [symbol]
        func up(_ symbol: String, in path: String, through: [String]) async throws {
            guard case .locations(let places) = await scip(.references(symbol: symbol, path: path), on: host) else { return }
            var inner: [(Block, Declaration)] = []
            for p in places where !p.isDefinition {
                let fb = try await textBlock(p.path, scope)
                guard let rope = fb.text?.text, p.line < rope.lineCount else { continue }
                let lineStart = rope.offset(ofLine: p.line)
                let decls = fb.path.flatMap(SyntaxLanguage.forPath).map { SyntaxTree($0, text: rope, background: false).declarations() } ?? []
                let decl = decls.last { $0.range.start <= lineStart && $0.range.end > lineStart }
                var h = SearchHit(path: p.path, line: p.line + 1, column: p.character + 1, text: p.text.isEmpty ? rope.lineText(p.line) : p.text)
                h.context = "in " + ([decl?.path ?? "the top of \(fb.displayTitle)"] + through).joined(separator: " → ")
                hits.append(h)
                if let decl, !inner.contains(where: { $0.0.id == fb.id && $0.1.path == decl.path }) { inner.append((fb, decl)) }
            }
            // Their own callers, a level up.
            guard through.count + 1 < depth else { return }
            for (fb, d) in inner {
                guard let p = fb.path, let s = try? await indexSymbol(in: fb, at: d.nameRange.start), seen.insert(s.symbol).inserted else { continue }
                try await up(s.symbol, in: p, through: [d.path] + through)
            }
        }
        try await up(symbol, in: path, through: [])
        return hits
    }

    /// The index's name for the symbol at a place in a text, and what it's called.
    func symbolAt(_ b: Block, offset: Int) async throws -> (symbol: String, name: String) {
        let s = try await indexSymbol(in: b, at: offset)
        return (s.symbol, s.name)
    }

    /// `mani refs`: where a symbol is used across its project.
    private func refs(_ r: ManiRequest, _ scope: Scope) async throws -> String {
        let b = try await textBlock(r.args[0], scope)
        guard let path = b.path else { throw Failure(message: "\(b.displayTitle) isn't a file") }
        let s = try await indexSymbol(in: b, at: try await symbolOffset(r, in: b))
        guard case .locations(let places) = await scip(.references(symbol: s.symbol, path: path), on: b.id.host) else {
            throw Failure(message: "the index couldn't say where \(s.name) is used")
        }
        // Paths as from the command's folder (whichever way /tmp is spelled).
        let base = URL(fileURLWithPath: r.cwd).resolvingSymlinksInPath().path + "/"
        func shown(_ p: String) -> String {
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            return real.hasPrefix(base) ? String(real.dropFirst(base.count)) : p.abbreviatingHome
        }
        guard r.flags["markdown"] != nil else {
            return places.map { "\(shown($0.path)):\($0.line + 1):\($0.isDefinition ? " (definition)" : "") \($0.text)" }.joined(separator: "\n")
        }
        // Each a reference to its place (its line's anchor, in its file's block).
        var out: [String] = []
        for p in places.prefix(100) {
            let fb = try await textBlock(p.path, scope)
            guard let address = wc.reference(toLine: p.line, in: fb.id, exactly: true) else { continue }
            out.append("[\(shown(p.path)):\(p.line + 1)](\(address))\(p.isDefinition ? " (definition)" : "") — `\(p.text)`")
        }
        return out.joined(separator: "\n")
    }

    /// An anchor's lines, as the text is now (found again if it moved).
    private func anchorText(_ anchor: String, in b: Block) throws -> String {
        guard let a = b.anchors?[anchor] else { throw Failure(message: "no such place in \(b.displayTitle)") }
        guard let (range, putRight) = Anchoring.locate(a, in: b), let rope = b.text?.text else {
            throw Failure(message: "“\(Anchoring.name(of: a))” is no longer in \(b.displayTitle)")
        }
        if let putRight { hosts.append([.anchor(putRight)], to: .block(b.id)) }
        let first = rope.offset(ofLine: rope.line(at: range.start))
        return rope[TextRange(first, range.end)]
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
        var out: [String: Any] = ["tile": p.id, "block": p.block.description, "ref": "manifold:" + p.block.description, "kind": kindName(b, lens: p.lens),
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
        if let a = b?.annotations { out["annotations"] = a }
        guard deep else { return out }
        if let f = layout.frames[p.id] {
            out["frame"] = f.array.map(Self.decimal)
            out["names"] = layout.names(of: p.id, from: scope.reference)
            out["adjacent"] = Dictionary(uniqueKeysWithValues: layout.adjacent(p.id).map { ($0.key.rawValue, $0.value) })
        }
        if let d = layout.arrangement.dockedTile(p.id) {
            out["docked"] = true
            if let above = d.above { out["dockedUnder"] = above }
        }
        return out
    }

    private func layoutJSON(_ ws: BlockID, scope: Scope) -> [String: Any] {
        guard let a = hosts.arrangement(ws) else { return [:] }
        let layout = ManiLayout(a)
        var out: [String: Any] = ["id": ws.description, "title": wc.title(of: a)]
        if let marks = hosts.block(ws)?.annotations { out["annotations"] = marks }
        if ws.host != wc.host.host { out["host"] = hosts.label(of: ws.host) }
        if let full = a.full { out["full"] = full }
        if let f = a.focused { out["focused"] = f }
        out["columns"] = a.columns.enumerated().map { c, column -> [String: Any] in
            let w = c < a.fractions.count ? a.fractions[c] : 0
            return ["width": Self.decimal(w),
                    "tiles": column.map { tile($0, layout: layout, scope: scope) }]
        }
        // Docked (§3.1): out of the grid, still in the space, the latest first.
        if !a.docked.isEmpty { out["docked"] = a.docked.reversed().map { tile($0.placement, layout: layout, scope: scope) } }
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
                if let a = b?.annotations, !a.isEmpty { lines.append("      " + a.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
                return lines
            } + docked(a)
        }
        /// What's docked, under the grid's rows: a row each, the latest first.
        func docked(_ a: ArrangementState) -> [String] {
            guard !a.docked.isEmpty else { return [] }
            return ["  docked:"] + a.docked.reversed().map { d in
                let b = hosts.block(d.placement.block)
                return "      \(kindName(b, lens: d.placement.lens).padding(toLength: 9, withPad: " ", startingAt: 0))  \(b?.displayTitle ?? "")  \(d.placement.block)"
            }
        }
        func heading(_ ws: BlockID, _ a: ArrangementState) -> String {
            let marks = (hosts.block(ws)?.annotations ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return "\(wc.title(of: a))  (\(ws))" + (marks.isEmpty ? "" : "  " + marks.joined(separator: " "))
        }
        var out = [heading(ws, a)] + rows(ws, a)
        _ = layout
        if r.flags["all"] != nil {
            for other in wc.allWorkspaces where other != ws {
                guard let oa = hosts.arrangement(other) else { continue }
                out.append("")
                out.append(heading(other, oa))
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
            if let a = b.annotations { out["annotations"] = a }
            out["shown"] = false
        }
        if out["summary"] == nil, let summary = summaryJSON(b.id, view: nil) { out["summary"] = summary }
        // How to name it to the user and to mani: its reference (a place in
        // it, if one was named), and as a link a note shows.
        let ref = "manifold:" + b.id.description + (t.at.map { "#" + $0.fragment } ?? "")
        out["ref"] = ref
        out["link"] = "[\(b.displayTitle.replacingOccurrences(of: "]", with: "\\]"))](\(ref))"
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
            // Its places (§2.5): references to them, and what they're called.
            if let a = l.toAnchor {
                o["to"] = MainWindowController.address(l.to, anchor: a)
                if let anchor = hosts.block(l.to)?.anchors?[a] { o["place"] = Anchoring.name(of: anchor) }
            }
            if let a = l.fromAnchor { o["from"] = MainWindowController.address(b.id, anchor: a) }
            if let r = l.relation { o["relation"] = r }
            return o
        }
        if !links.isEmpty { out["links"] = Array(links) }
        // Its places referred to, and what links to each.
        if let anchors = b.anchors, !anchors.isEmpty {
            let inbound = n.inbound.values.flatMap { $0 }
            out["places"] = anchors.values.sorted { ($0.range?.start ?? 0) < ($1.range?.start ?? 0) }.prefix(100).map { a -> [String: Any] in
                var o: [String: Any] = ["ref": MainWindowController.address(b.id, anchor: a.id), "name": Anchoring.name(of: a)]
                if let r = a.range, let rope = b.text?.text, r.start <= rope.count { o["line"] = rope.line(at: r.start) + 1 }
                if let symbol = a.scip { o["scip"] = symbol }
                let from = inbound.filter { $0.toAnchor == a.id }.map { e -> [String: Any] in
                    var f: [String: Any] = ["from": e.from.description, "title": hosts.block(e.from)?.displayTitle ?? ""]
                    if let r = e.relation { f["relation"] = r }
                    return f
                }
                if !from.isEmpty { o["linkedFrom"] = from }
                return o
            }
        }
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
        var t = try await target(r.args[0], scope)
        if let s = t.selection { return lines(s.text, r.flags["lines"]) }
        guard let b = hosts.block(t.block) else { throw Failure(message: "\(r.args[0]) isn't known here") }
        let view = t.tile.flatMap { wc.views[$0] }
        // A reference to an anchor: a command's or a page's read as that
        // place is; one in a text, its lines (a declaration whole).
        if let f = t.at?.anchorID, let legible = b.anchors?[f]?.legible { t.at = legible }
        if r.flags["outline"] != nil {
            guard let outline = view?.outline, !outline.items.isEmpty else { throw Failure(message: "\(b.displayTitle) has no outline\(view == nil ? " (it isn't shown)" : "")") }
            return outline.items.indices.map { i in
                String(repeating: "  ", count: outline.items[i].level) + outline.items[i].title + (outline.placeFor?(i).map { "\t" + $0.fragment } ?? "")
            }.joined(separator: "\n")
        }
        // A reference to a place: that command's output; that page.
        if r.flags["command"] == nil, case let .command(id)? = t.at,
           let c = b.terminal?.commands?.first(where: { $0.id == id }) {
            return lines(try await output(of: c, in: b.id, view: view), r.flags["lines"])
        }
        // Any other place (an anchor, lines, a heading's line, a cell): what's there.
        switch t.at {
        case .anchor?, .line?, .lines?, .range?, .cell?: return lines(try await contents(of: b, at: t.at, view: view), r.flags["lines"])
        default: break
        }
        var pageFlag = r.flags["pages"]
        if pageFlag == nil, case let .page(n)? = t.at { pageFlag = String(n) }
        let pages = try pageFlag.map { try range($0, what: "pages") }
        if b.kind == .terminal || b.kind == .agent, let n = r.flags["command"] {
            guard let k = Int(n), let commands = b.terminal?.commands, !commands.isEmpty else { throw Failure(message: "no command \(n) in \(b.displayTitle)") }
            let i = k < 0 ? commands.count + k : k - 1
            guard i >= 0, i < commands.count else { throw Failure(message: "\(b.displayTitle) has \(commands.count) commands") }
            return lines(try await output(of: commands[i], in: b.id, view: view), r.flags["lines"])
        }
        if b.kind == .arrangement { return try ls(ManiRequest(verb: "ls", flags: [:], args: [], cwd: r.cwd, here: r.here), scope) }
        return lines(try await contents(of: b, view: view, pages: pages, all: r.flags["all"] != nil), r.flags["lines"])
    }

    /// What a place in a block holds (a reference's `#…`): a command's
    /// output, a page's text, a heading's section or an item's; without
    /// one, the whole block's (a terminal's whole history).
    func contents(of b: Block, at: Locator?, view: PaneContent?) async throws -> String {
        // A command's or a page's anchor: that place, as it reads.
        var at = at
        if let f = at?.anchorID, let legible = b.anchors?[f]?.legible { at = legible }
        switch at {
        case let .anchor(f)?:
            return try anchorText(f, in: b)
        case let .command(id)?:
            if let c = b.terminal?.commands?.first(where: { $0.id == id }) { return try await output(of: c, in: b.id, view: view) }
        case let .page(n)?:
            return try await contents(of: b, view: view, pages: n...n)
        case let .cell(id)?:
            if let c = b.notebook?.cells.first(where: { $0.id == id }) { return c.source + (c.output.map { "\n\n" + $0 } ?? "") }
        case .line?, .lines?, .range?:
            guard b.kind == .text, let text = b.text, !b.needsRead else { break }
            if case let .range(r) = at!, r.end <= text.text.count { return text.text[r] }
            if case let .lines(s, e) = at!, s >= 1, s <= text.text.lineCount {
                return (s - 1...min(e, text.text.lineCount) - 1).map { text.text.lineText($0) }.joined(separator: "\n")
            }
            return NoteOutlineMarkdown.section(of: text.text.string, line: at!.line ?? 1)
        case nil:
            break
        }
        return try await contents(of: b, view: view, all: true)
    }

    /// A block's content as text, whatever it is — a file's or note's
    /// text, a terminal's transcript, a page's or a PDF's text, a diff's
    /// patch, a listing, a search's hits, a command's output, a notebook's
    /// cells: what `mani read` prints, and Copy Contents (⇧⌘C) copies.
    /// `view`: its tile's, where only what's shown has it (a terminal's
    /// screen, a page). `all`: a terminal's whole history, not its screen.
    func contents(of b: Block, view: PaneContent?, pages: ClosedRange<Int>? = nil, all: Bool = false) async throws -> String {
        switch b.kind {
        case .text:
            guard let text = b.text, !b.needsRead else { throw Failure(message: "\(b.displayTitle) hasn't been read from disk yet") }
            return text.text.string
        case .terminal, .agent:
            guard let view, let s = await view.maniText(ManiReadOptions(all: all)) else {
                throw Failure(message: "\(b.displayTitle) isn't shown, so its screen can't be read")
            }
            return s
        case .pdf:
            if let view, let s = await view.maniText(ManiReadOptions(pages: pages)) { return s }
            guard b.id.host == wc.host.host, let path = b.path, let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
                throw Failure(message: "\(b.displayTitle) can't be read here")
            }
            return MediaView.text(of: doc, pages: pages)
        case .web:
            guard let view, let s = await view.maniText(ManiReadOptions()) else { throw Failure(message: "\(b.displayTitle) isn't shown, so its page can't be read") }
            return s
        case .diff:
            guard let d = b.diff else { throw Failure(message: "\(b.displayTitle) has nothing yet") }
            if let patch = d.patch { return patch }
            if let old = d.oldText, let new = d.newText { return UnifiedDiff.make(old: old, new: new, path: b.path ?? b.displayTitle) }
            throw Failure(message: d.error ?? "\(b.displayTitle) hasn't loaded")
        case .directory:
            let entries = b.directory?.entries ?? []
            return entries.map { $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: "\n")
        case .search:
            guard let s = b.search else { return "" }
            return s.hits.map { "\($0.path):\($0.line):\($0.column): \($0.text)" }.joined(separator: "\n")
        case .output:
            guard let o = b.output else { return "" }
            return "$ " + o.line + "\n" + (o.plain ? o.output : Self.plain(o.output))
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
            // A space: its tiles, a line each.
            guard let a = hosts.arrangement(b.id) else { return "" }
            return a.placements.compactMap { hosts.block($0.block) }.map { $0.displayTitle + ($0.path.map { "\t" + $0 } ?? "") }.joined(separator: "\n")
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
        let size = try r.flags["size"].map { s -> Double in
            guard let f = Double(s), f > 0, f < 1 else { throw Failure(message: "--size is a share, between 0 and 1", status: 2) }
            return f
        }
        var ref = scope.reference
        var ws = scope.workspace
        if let at = r.flags["at"] {
            let t = try resolve(at, scope)
            guard let id = t.tile else { throw Failure(message: "--at \(at) isn't shown") }
            ref = id
            ws = t.workspace ?? ws
        }
        // Told its space, placed there, the one shown staying; else the
        // space it goes in is shown.
        if !scope.spaceGiven {
            if let ws2 = ws, ws2 != wc.selected { hosts.select(ws2) }
            ws = wc.selected
        }
        put(block, lens: lens, r, ws: ws, ref: ref, context: context)
        if let size, let ws { sized(block, lens: lens, in: ws, size) }
    }

    private func put(_ block: BlockID, lens: Lens, _ r: ManiRequest, ws: BlockID?, ref: PlacementID?, context: String) {
        guard let ws, let a = hosts.arrangement(ws) else { return wc.show(block, lens: lens, .here, context: context) }
        guard let ref, let (c, i) = a.locate(ref) else { return wc.show(block, lens: lens, .here, context: context, in: ws) }
        let refBlock = a.placement(ref)?.block
        if r.flags["over"] != nil {
            if ws == wc.selected { return wc.show(block, lens: lens, .over(ref), context: context) }
            // Over a tile of a space not shown: placed after it, which goes behind it.
            let p = Placement(block: block, lens: lens)
            hosts.append([.place(p, column: c, at: i + 1), .stash(ref, behind: p.id), .focus(p.id)], to: .block(ws))
            if let refBlock, refBlock != block { hosts.link(from: refBlock, to: block, kind: .opened, context: context) }
            return
        }
        if r.flags["right"] != nil {
            return wc.show(block, lens: lens, c + 1 < a.columns.count ? .inColumn(c + 1) : .inNewColumn(c + 1), context: context, in: ws)
        }
        if r.flags["left"] != nil { return wc.show(block, lens: lens, c > 0 ? .inColumn(c - 1) : .inNewColumn(0), context: context, in: ws) }
        if r.flags["column"] != nil { return wc.show(block, lens: lens, .inNewColumn(c + 1), context: context, in: ws) }
        if r.flags["above"] != nil {
            if let t = a.tile(of: block, lens: lens) { return ws == wc.selected ? wc.focus(t.id) : () }
            let p = Placement(block: block, lens: lens)
            let h = a.height(of: ref)
            hosts.append([.place(p, column: c, at: i), .heights([p.id: h / 2, ref: h / 2]), .focus(p.id)], to: .block(ws))
            if let refBlock, refBlock != block { hosts.link(from: refBlock, to: block, kind: .opened, context: context) }
            return
        }
        wc.show(block, lens: lens, .besideOpener(ref), context: context, in: ws)
    }

    /// `--size`: a block's tile given a share of its column — or, alone in
    /// a column, its column that share of the width — the others the rest,
    /// in proportion.
    private func sized(_ block: BlockID, lens: Lens, in ws: BlockID, _ share: Double) {
        guard let a = hosts.arrangement(ws),
              let p = a.tile(of: block, lens: lens) ?? a.placements.first(where: { $0.block == block }),
              let (c, _) = a.locate(p.id) else { return }
        let shown = a.columns[c]
        if shown.count == 1, a.columns.count > 1 {
            let n = a.columns.count
            let fractions = a.fractions.count == n ? a.fractions : Array(repeating: 1 / Double(n), count: n)
            let rest = fractions.enumerated().filter { $0.offset != c }.reduce(0) { $0 + $1.element }
            let new = fractions.enumerated().map { i, f in i == c ? share : (rest > 0 ? f / rest : 1 / Double(n - 1)) * (1 - share) }
            hosts.append(.fractions(new), to: .block(ws))
        } else if shown.count > 1 {
            let sum = shown.reduce(0.0) { $0 + a.height(of: $1.id) }
            let others = shown.filter { $0.id != p.id }
            let rest = others.reduce(0.0) { $0 + a.height(of: $1.id) }
            var heights: [PlacementID: Double] = [p.id: share * sum]
            for o in others { heights[o.id] = (rest > 0 ? a.height(of: o.id) / rest : 1 / Double(others.count)) * (1 - share) * sum }
            hosts.append(.heights(heights), to: .block(ws))
        }
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
                wc.showOver(block, lens: lens, over: opener, again: true, stack: true, context: arg.lastPathComponent)
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

    /// `new <kind> [what]`: a kind from `BlockKinds` (the table File ▸ New
    /// and the picker are made from), made as the app makes it, and placed
    /// by the flags; or a space.
    private func make(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let on = scope.host
        let cwd = r.flags["cwd"].map { $0.hasPrefix("/") ? $0 : r.cwd.appendingPathComponent($0) } ?? r.cwd
        if r.args[0] == "space" { return try makeSpace(r, on: on, cwd: cwd, scope: scope) }
        guard let kind = BlockKinds.named(r.args[0]) else {
            let names = BlockKinds.all.map(\.name) + ["space"]
            throw Failure(message: "no kind \(r.args[0]) to make: " + names.joined(separator: ", "), status: 2)
        }
        if r.flags["run"] != nil, !["terminal", "agent"].contains(kind.name) {
            throw Failure(message: "--run is for a terminal, an agent or a space's terminal", status: 2)
        }
        // What it takes: the word after its kind, as the picker reads it;
        // a note's text from --text or the input too; a terminal's command
        // from --run; an agent's first prompt from --run, to its command.
        var what = r.args.count > 1 ? r.args[1] : nil
        if what != nil, kind.what == nil { throw Failure(message: "new \(kind.name) takes nothing after it", status: 2) }
        switch kind.name {
        case "note": what = what ?? r.flags["text"] ?? r.input ?? ""
        case "terminal": what = r.flags["run"] ?? what
        case "agent": if let prompt = r.flags["run"] { what = (what ?? wc.host.desk.settings.agentCommand) + " " + Self.quoted(prompt) }
        default: break
        }
        let made: (block: BlockID, lens: Lens, later: Bool)
        do { made = try wc.makeBlock(kind, what: what, cwd: cwd, on: on) } catch let f as MainWindowController.MakeFailure { throw Failure(message: f.message) }
        let block = made.block
        // A note an agent makes is to be read: rendered, unless it's to be
        // typed into (--edit); anyone else's, as asked.
        let byAgent = scope.here.flatMap { hosts.block($0)?.agent } != nil
        let lens = kind.name == "note" && r.flags["edit"] == nil && (r.flags["preview"] != nil || byAgent) ? .preview : made.lens
        if let title = r.flags["title"] { hosts.append(.title(title), to: .block(block)) }
        if made.later {
            // Placed once the host has made it (a notebook), as the menu's is.
            wc.whenMade(block, what: "the " + kind.title.lowercased(), made: { [weak self] in self?.hosts.block(block) != nil }) { [weak self] in
                try? self?.place(block, lens: lens, r, scope, context: "mani new \(kind.name)")
            }
        } else {
            try place(block, lens: lens, r, scope, context: "mani new \(kind.name)")
        }
        last = block
        shown(block, line: nil, scope: scope)
        return block.description
    }

    /// `new space`: a space with a terminal in `cwd`, shown and named; its
    /// id printed (for `MANI_SPACE`), the terminal `@last`.
    private func makeSpace(_ r: ManiRequest, on: HostID, cwd: String, scope: Scope) throws -> String {
        guard r.args.count == 1 else { throw Failure(message: "a space's name comes from --title", status: 2) }
        guard let ws = wc.newWorkspace(on: on, cwd: cwd) else { throw Failure(message: "that host isn't attached") }
        if let title = r.flags["title"] { hosts.append(.title(title), to: .block(ws)) }
        last = hosts.arrangement(ws)?.placements.first?.block
        if let run = r.flags["run"], let t = last { type(run, into: t) }
        if scope.here == nil { NSApp.activate() }
        return ws.description
    }

    /// A command typed into a terminal, as `run` does — once its shell is
    /// up, if it's only now starting.
    private func type(_ command: String, into terminal: BlockID) {
        hosts.propose(.input(block: terminal, text: command + "\r"))
    }

    /// A word for a shell, quoted as it must be.
    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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
        // A reference's place in it: gone to.
        if r.flags["line"] == nil, let at = t.at { wc.goTo(at, in: t.block) }
        return ""
    }

    private func close(_ r: ManiRequest, _ scope: Scope) throws -> String {
        let t: Target
        do { t = try resolve(r.args[0], scope) } catch {
            // Not a tile's or block's name: a space's, as the sidebar has it.
            let ws: BlockID
            do { ws = try space(named: r.args[0]) } catch let f as Failure where f.message.hasPrefix("more than one") { throw f } catch _ { throw error }
            wc.closeSpace(ws)
            return ""
        }
        // A space named (not a tile showing one): the space removed, as ⇧⌘W.
        if t.tile == nil, hosts.block(t.block)?.kind == .arrangement, wc.allWorkspaces.contains(t.block) {
            wc.closeSpace(t.block)
            return ""
        }
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
    /// A share as JSON says it: three places, no more (0.6, not
    /// 0.59999999999999998) — and not rounded to a whole number, as a
    /// decimal's default rounding does.
    static func decimal(_ d: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", d))
    }

    func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: PanelView.tidy(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
