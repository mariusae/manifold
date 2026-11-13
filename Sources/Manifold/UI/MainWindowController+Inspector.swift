import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: The Inspector (§3.5)

    /// What a diff compares, in words.
    static func describe(_ s: DiffSubject) -> String {
        switch s {
        case let .sides(old, new): return old.path == new.path ? "\(new.path.lastPathComponent): \(old.revision ?? "working tree") → \(new.revision ?? "working tree")" : "\(old.path.lastPathComponent) → \(new.path.lastPathComponent)"
        case let .commit(_, sha): return "commit " + String(sha.prefix(10))
        case .versions: return "a text's versions"
        case let .patch(_, title): return title ?? "a patch"
        case .uncommitted: return "what's not committed"
        case let .since(_, _, title), let .trees(_, _, _, title): return title
        }
    }


    /// Debugging: "toggle" (⌥⌘I), "rows" its rows, "click <row>"; else how it stands.
    func debugInspector(_ arg: String) -> String {
        if arg == "toggle" { toggleInspector(nil) }
        guard let p = inspector else { return "never shown" }
        if arg == "rows" { return p.list.debugRows }
        if arg.hasPrefix("click "), let row = Int(arg.dropFirst(6)) { return p.list.debugClick(row) }
        if arg.hasPrefix("set ") { return p.list.debugSet(String(arg.dropFirst(4))) }
        if arg.hasPrefix("fold ") { return p.list.debugToggle(String(arg.dropFirst(5))) }
        if arg.hasPrefix("picture ") { return p.debugPicture(to: String(arg.dropFirst(8))) }
        if arg.hasPrefix("host ") {
            let name = String(arg.dropFirst(5))
            guard let c = hosts.all.first(where: { $0.host.raw == name || hosts.label(of: $0.host) == name }) else { return "no host \(name)" }
            organizationInspect(host: c.host.raw)
        }
        if arg.hasPrefix("space") {
            // "space": the one shown; "space <name>": the one so named.
            let name = arg.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let w = name.isEmpty ? selected : allWorkspaces.first(where: { hosts.arrangement($0).map(self.title(of:)) == name }) else { return "no space \(name)" }
            inspect(.space(w))
        }
        return p.debugState
    }
    /// What the inspector shows instead of the focused tile: a host or a
    /// space whose row was clicked (or asked for by its menu).
    enum Inspected { case host(String), space(BlockID) }

    func organizationInspect(host: String) { inspect(.host(host)) }

    /// `what` in the inspector, until the focus moves; `open`, its window
    /// shown if it isn't.
    func inspect(_ what: Inspected, open: Bool = false) {
        inspected = (what, focusedShown?.id)
        if open, inspector?.isVisible != true { return toggleInspector(nil) }
        refreshInspector(now: true)
    }

    /// A space's own rows: its name, where it is among the spaces, its
    /// layout (columns and their widths, what's docked, a tile maximized, the
    /// focus), what its tiles are and how they stand.
    private func spaceRows(_ id: BlockID, _ a: ArrangementState, _ make: (String, String, String, (() -> Void)?) -> OrgNode) -> (own: [OrgNode], layout: [OrgNode]) {
        func row(_ value: String, _ label: String, _ symbol: String) -> OrgNode { make(value, label, symbol, nil) }
        var own: [OrgNode] = [], layout: [OrgNode] = []
        own.append(row(a.isNamed ? a.title! : "None — called by what it holds", "name", "textformat"))
        let order = hosts.client(of: id)?.desk.order ?? []
        if let i = order.firstIndex(of: id) { layout.append(row("\(i + 1) of \(order.count) on \(hosts.label(of: id.host))", "place", "list.number")) }
        else { layout.append(row("Not on the desk", "place", "tray")) }
        own.append(row(id == selected ? "Yes, in this window" : "No", "shown", "eye"))
        let blocks = a.placements.compactMap { hosts.block($0.block) }
        layout.append(row("\(a.placements.count)", "tiles", "rectangle.split.3x1"))
        let widths = a.fractions.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " · ")
        layout.append(row("\(a.columns.count)" + (widths.isEmpty ? "" : " (\(widths))"), "columns", "rectangle.split.3x1"))
        if !a.docked.isEmpty { layout.append(row("\(a.docked.count)", "docked", "dock.arrow.down.rectangle")) }
        if let full = a.full, let p = a.placement(full), let fb = hosts.block(p.block) { layout.append(row(Self.linkTitle(fb), "maximized", "arrow.up.left.and.arrow.down.right")) }
        if let p = a.focusedPlacement, let fb = hosts.block(p.block) {
            let n = row(Self.linkTitle(fb), "focused", Theme.symbolName(for: fb))
            n.arrangement = id
            n.placement = p.id
            own.append(n)
        }
        // What it holds, by kind, the most first.
        func noun(_ b: Block) -> (one: String, many: String) {
            switch b.kind {
            case .text: return b.path == nil ? ("note", "notes") : ("file", "files")
            case .web: return ("page", "pages")
            case .pdf: return ("PDF", "PDFs")
            case .search: return ("search", "searches")
            case .git: return ("repository", "repositories")
            case .process: return ("process list", "process lists")
            case .notebook: return ("notebook", "notebooks")
            case .output: return ("output", "outputs")
            case .ui: return ("panel", "panels")
            default: let k = b.kind.defaultTitle.lowercased(); return (k, k + "s")
            }
        }
        var kinds: [String: (count: Int, many: String)] = [:]
        for b in blocks { let n = noun(b); kinds[n.one, default: (0, n.many)].count += 1 }
        let held = kinds.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { "\($0.value.count) \($0.value.count == 1 ? $0.key : $0.value.many)" }.joined(separator: ", ")
        if !held.isEmpty { own.append(row(held, "holds", "square.grid.2x2")) }
        let elsewhere = Set(blocks.map(\.id.host)).subtracting([id.host])
        if !elsewhere.isEmpty { own.append(row(elsewhere.map { hosts.label(of: $0) }.sorted().joined(separator: ", "), "also from", "network")) }
        let unsaved = blocks.filter { $0.text?.isDirty == true }.count
        if unsaved > 0 { own.append(row("\(unsaved)", "unsaved", "pencil")) }
        let running = blocks.filter { $0.terminal?.commands?.contains(where: \.isRunning) == true }.count
        if running > 0 { own.append(row("\(running)", "running", "play")) }
        var states: [String: Int] = [:]
        for b in blocks { if let r = b.statusRecord { states[r.state.rawValue, default: 0] += 1 } }
        if !states.isEmpty { own.append(row(states.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "), "statuses", "circle.dotted")) }
        let pinned = pins(of: id).count
        if pinned > 0 { layout.append(row("\(pinned)", "pinned", "pin")) }
        return (own, layout)
    }

    /// A host's properties: what machine it is and how it's reached, what
    /// its server and this app are (protocol, build), its server's process.
    private func hostInspectorTree(_ c: HostClient) -> [OrgNode] {
        let name = hosts.label(of: c.host)
        let machine = c.machineLatest
        inspectorHeader = (name, c.isRemote ? "Remote host" : "The host on this Mac", Theme.hostSymbol(remote: c.isRemote), [])
        var sections: [OrgNode] = []
        func row(_ value: String, _ label: String, _ symbol: String, copies: String? = nil) -> OrgNode {
            let n = OrgNode(id: "insp/\(sections.count)/\(label)/\(value)", title: value, symbol: symbol, detail: label)
            n.tooltip = "\(label): \(value)"
            if let copies {
                n.copies = copies
                n.action = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copies, forType: .string) }
            }
            return n
        }
        func section(_ title: String, _ id: String, _ symbol: String, _ rows: [OrgNode]) {
            guard !rows.isEmpty else { return }
            let s = OrgNode(id: "insp:\(id)", title: title, symbol: symbol, isGroup: true, children: rows)
            s.style = .section
            sections.append(s)
        }
        // The date, and how long ago within the hour (past it, the date says when).
        func when(_ d: Date) -> String { Self.inspectorDate.string(from: d) + (BlockSummary.isRelative(d, now: Date()) ? " (" + Age.ago(d) + ")" : "") }

        // What it is at a glance (open); its machine in detail (folded).
        var about: [OrgNode] = [], hardware: [OrgNode] = []
        if let m = machine {
            about.append(row(m.hostname, "machine", "desktopcomputer"))
            about.append(row(m.system, "system", "gearshape"))
            hardware.append(row(m.processor + (m.frequency.map { String(format: " · %.1f GHz", $0) } ?? ""), "processor", "cpu"))
            hardware.append(row("\(m.cores.count)", "cores", "square.grid.3x3"))
            hardware.append(row(HostDashboard.duration(m.uptime), "machine up", "clock"))
        }
        if let d = c.destination { about.append(row(d.description, "reached by", "network", copies: d.description)) }
        about.append(row(HostDashboard.standing(c), "link", "antenna.radiowaves.left.and.right"))
        if let home = c.home { about.append(row(home.abbreviatingHome, "home", "house", copies: home)) }
        section("About", "About", "info.circle", about)
        section("Machine", "host-machine", "cpu", hardware)

        // What each side is: the protocol it speaks, what it was built
        // from and when — the server's as it said, this app's its own.
        var builds: [OrgNode] = []
        let app = BuildStamp.current
        if let v = c.serverVersion {
            builds.append(row("\(v)" + (v == protocolVersion ? "" : " — not the app's"), "server protocol", "arrow.left.arrow.right"))
        }
        if let s = c.serverBuild {
            builds.append(row(s.revisionName + (s.revision == app.revision ? "" : " — not the app's"), "server build", "hammer", copies: s.revision))
            if let t = s.built { builds.append(row(when(t), "server built", "calendar")) }
        } else if c.isConnected {
            builds.append(row("not said (a server from before)", "server build", "hammer"))
        }
        builds.append(row("\(protocolVersion)", "app protocol", "arrow.left.arrow.right"))
        builds.append(row(app.revisionName, "app build", "hammer", copies: app.revision))
        if let t = app.built { builds.append(row(when(t), "app built", "calendar")) }
        section("Versions", "versions", "number", builds)

        // Its server's process.
        var server: [OrgNode] = []
        if let pid = c.serverPID { server.append(row("\(pid)", "process", "gearshape.2", copies: "\(pid)")) }
        if c.isConnected, let started = c.serverStarted { server.append(row(HostDashboard.duration(Date().timeIntervalSince(started)) + " (since " + Self.inspectorDate.string(from: started) + ")", "server up", "clock")) }
        if !c.features.isEmpty { server.append(row(c.features.sorted().joined(separator: ", "), "features", "puzzlepiece")) }
        if c.watching { server.append(row(c.fencedBy ?? "another Manifold", "taken over by", "eye")) }
        if let since = c.connectedSince { server.append(row(when(since), "connected", "link")) }
        if let rtt = c.pings.last?.rtt { server.append(row(HostDashboard.ms(rtt), "round trip", "stopwatch")) }
        if let last = c.drops.last { server.append(row("\(last.why), " + Age.ago(last.at), "last dropped", "bolt.horizontal")) }
        section("Server", "host-server", "server.rack", server)

        // What its server sets in what it starts, and its ssh agent (§8.6).
        if c.keepsEnvironment {
            var env: [OrgNode] = []
            // Each edited in place: its name, its value, its scope at the right.
            let refused: (String?) -> Void = { [weak self] error in
                guard let self, let error else { return }
                self.toast.say(error)
            }
            let scopes = EnvironmentScope.allCases.map(\.rawValue)
            let help = "Given to all the host starts; its shells (terminals, notebooks, panels' commands); or its tools (the code indexer and its fetches, language servers, git)"
            for v in c.desk.preferences.environment ?? [] {
                let n = OrgNode(id: "insp/env/\(v.name)", title: v.name + "=" + v.shownValue, symbol: "dollarsign", detail: v.name)
                let e = InspectorEditable(name: v.name, value: v.value, choice: v.scope.rawValue, choices: scopes) { name, value, choice in
                    // Renamed: the old one taken away.
                    if name != v.name { c.propose(.environment(name: v.name, value: nil, scope: nil)) }
                    c.propose(.environment(name: name, value: value, scope: EnvironmentScope(rawValue: choice)), done: refused)
                }
                e.shown = { EnvironmentVariable(name: $0, value: $1).shownValue }
                e.remove = { c.propose(.environment(name: v.name, value: nil, scope: nil), done: refused) }
                e.help = help
                n.editable = e
                env.append(n)
            }
            let add = OrgNode(id: "insp/env/add", title: "Add Variable…", symbol: "plus", detail: "")
            let template = InspectorEditable(choice: EnvironmentScope.all.rawValue, choices: scopes, valuePlaceholder: "value") { name, value, choice in
                c.propose(.environment(name: name, value: value, scope: EnvironmentScope(rawValue: choice)), done: refused)
            }
            template.shown = { EnvironmentVariable(name: $0, value: $1).shownValue }
            template.help = help
            add.adds = template
            env.append(add)
            if let a = c.agentLink {
                let n = row(a.summary, "ssh agent", "key", copies: a.managed ? a.link : a.local)
                n.tooltip = a.managed ? "SSH_AUTH_SOCK=\(a.link)" + (a.target.map { " → \($0)" } ?? "") : "the host's own agent"
                env.append(n)
            }
            section("Environment", "host-environment", "dollarsign.square", env)
        }

        // What its link carries, as this Mac sees it: bytes a second now, by
        // what they're for; and each stream open on it. Kept up to date
        // while it's shown (`inspectorIsLive`).
        if let mux = c.mux {
            inspectorIsLive = true
            let (traffic, streams) = linkRows(mux, row)
            section("Traffic", "host-traffic", "arrow.up.arrow.down", traffic)
            section("Streams", "host-streams", "point.3.connected.trianglepath.dotted", streams)
        }

        section("For Tools", "tools", "wrench.and.screwdriver", [row(c.host.raw, "host id", "number", copies: c.host.raw)])
        return sections
    }

    /// A link's traffic (each way, now and lately, by what it's for) and
    /// its streams (what each is for, how long it's been open, what it's
    /// carried, whether it's held up), as inspector rows.
    private func linkRows(_ mux: Mux, _ row: (String, String, String, String?) -> OrgNode) -> (traffic: [OrgNode], streams: [OrgNode]) {
        func bytes(_ n: Int) -> String { Self.linkBytes.string(fromByteCount: Int64(n)) }
        func rate(_ f: Flow) -> String { "↓ \(bytes(f.received))/s · ↑ \(bytes(f.sent))/s" }
        func amount(_ f: Flow) -> String { "↓ \(bytes(f.received)) · ↑ \(bytes(f.sent))" }
        /// A kind's label, for its traffic (many) or a stream of it.
        func label(_ k: StreamPurpose.Kind, one: Bool = false) -> String {
            switch k {
            case .control: "state"
            case .terminal: one ? "terminal" : "terminals"
            case .replay: one ? "replay" : "replays"
            case .file: one ? "file" : "files"
            case .forward: one ? "forward" : "forwards"
            case .page: one ? "page" : "pages"
            case .other: "other"
            }
        }
        func symbol(_ k: StreamPurpose.Kind) -> String {
            switch k {
            case .control: "arrow.triangle.2.circlepath"
            case .terminal: "terminal"
            case .replay: "clock.arrow.circlepath"
            case .file: "doc"
            case .forward: "arrow.left.arrow.right"
            case .page: "globe"
            case .other: "questionmark.circle"
            }
        }
        let t = mux.traffic
        var traffic: [OrgNode] = [row(rate(LinkTraffic.sum(t.rate)), "now", "speedometer", nil)]
        // Each kind that carried anything in the last minute: its rate now,
        // and the minute's bytes.
        for k in StreamPurpose.Kind.allCases {
            guard let minute = t.lastMinute[k] else { continue }
            let n = row(rate(t.rate[k] ?? Flow()), label(k), symbol(k), nil)
            n.tooltip = "\(k.noun.many.capitalized) now: \(rate(t.rate[k] ?? Flow()))\nIn the last minute: \(amount(minute))"
                + "\nSince the link was made: \(amount(t.total[k] ?? Flow()))"
            traffic.append(n)
        }
        traffic.append(row(amount(LinkTraffic.sum(t.lastMinute)), "last minute", "clock", nil))
        let up = HostDashboard.duration(Date().timeIntervalSince(t.since))
        traffic.append(row(amount(LinkTraffic.sum(t.total)) + " in \(up)", "since linked", "sum", nil))
        let st = mux.stats
        traffic.append(row("\(bytes(st.inFlight)) of \(bytes(st.budget))", "in flight", "paperplane", nil))

        let open = mux.openStreams
        var kinds: [StreamPurpose.Kind: Int] = [:]
        for s in open { kinds[s.purpose.kind, default: 0] += 1 }
        let held = kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.value == 1 ? $0.key.noun.one : $0.key.noun.many)" }
        var streams: [OrgNode] = [row("\(open.count)" + (held.isEmpty ? "" : ": " + held.joined(separator: ", ")), "open", "number", nil)]
        // By kind, then oldest first; as many as are worth reading.
        let now = Date()
        let shown = 60
        for s in open.sorted(by: { ($0.purpose.kind, $0.id) < ($1.purpose.kind, $1.id) }).prefix(shown) {
            var what = s.purpose.detail
            if let b = s.purpose.block, let block = hosts.block(b) { what = Self.linkTitle(block) }
            if what.isEmpty { what = "stream \(s.id)" }
            var parts = [what, HostDashboard.duration(now.timeIntervalSince(s.opened)), amount(s.flow)]
            if s.heldForCredit { parts.append("held") } else if s.queued > 0 { parts.append("\(bytes(s.queued)) waiting") }
            let n = row(parts.joined(separator: " · "), label(s.purpose.kind, one: true), symbol(s.purpose.kind), nil)
            n.block = s.purpose.block
            let pacing = s.urgent ? "paced, ahead of the others" : s.bulk ? "paced" : "not paced"
            n.tooltip = "\(what)\nStream \(s.id): \(pacing)\(s.compresses ? ", compressed" : "")"
                + "\nOpen \(HostDashboard.duration(now.timeIntervalSince(s.opened))), since \(Self.inspectorDate.string(from: s.opened))"
                + "\nCarried \(amount(s.flow))"
                + (s.heldForCredit ? "\nHeld: the other end hasn't taken what it was sent" : s.queued > 0 ? "\n\(bytes(s.queued)) waiting to go" : "")
            streams.append(n)
        }
        if open.count > shown { streams.append(row("and \(open.count - shown) more", "", "ellipsis", nil)) }
        return (traffic, streams)
    }

    /// Bytes as a link's rows say them: "0 bytes", not "Zero KB".
    private static let linkBytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()


    private static let inspectorDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()


    /// The inspector shown again, a moment after the last change (it
    /// follows the focus).
    func refreshInspector(now: Bool = false) {
        guard inspector?.isVisible == true else { return }
        let show = { [weak self] in
            guard let self, let panel = self.inspector, panel.isVisible else { return }
            self.inspectorIsLive = false
            let nodes = self.inspectorTree().0
            panel.show(title: self.inspectorHeader.title, subtitle: self.inspectorHeader.subtitle, symbol: self.inspectorHeader.symbol,
                       tags: self.inspectorHeader.tags, nodes: nodes)
            // Live: again in a second (one tick waiting at a time).
            self.inspectorTick.cancel()
            guard self.inspectorIsLive else { return }
            self.inspectorTick.schedule(after: 1) { [weak self] in self?.refreshInspector(now: true) }
        }
        if now { inspectorWork.runNow(show) } else { inspectorWork.schedule(after: 0.1, show) }
    }

    /// The focused block's properties (⌥⌘I), Star's property sheet for any
    /// block: what it is, and what only its kind has; where it's placed and
    /// pinned (a click goes there); what keeps it (§4); its links, either
    /// way (a click opens one by the one rule); its history; and what can be
    /// done with it. Each a row, by sections; a value first, what it is in
    /// grey after it.
    private func inspectorTree() -> ([OrgNode], Set<String>) {
        // A host's or a space's row clicked: it, until the focus moves.
        if let i = inspected {
            if i.focus == focusedShown?.id {
                switch i.what {
                case .host(let h):
                    if let c = hosts.all.first(where: { $0.host.raw == h }) { return (hostInspectorTree(c), []) }
                case .space(let w):
                    if let b = hosts.block(w), b.arrangement != nil { return inspectorTree(of: b, tile: nil) }
                }
            }
            inspected = nil
        }
        guard let f = focusedShown, let b = f.block else {
            // An empty space: the space.
            if let w = selected, let b = hosts.block(w), b.arrangement != nil { return inspectorTree(of: b, tile: nil) }
            inspectorHeader = ("Nothing to inspect", "", "info.circle", [])
            return ([OrgNode(id: "insp:none", title: "Focus a tile to see what it is", symbol: "info.circle")], [])
        }
        return inspectorTree(of: b, tile: f)
    }

    /// A block's properties — as `tile` shows it, if one does (a space
    /// inspected is shown by none).
    private func inspectorTree(of b: Block, tile f: Shown?) -> ([OrgNode], Set<String>) {
        let hostName = hosts.label(of: b.id.host)
        let space = b.arrangement
        let kindName = space != nil ? "Space" : b.kind.defaultTitle == "Untitled" ? "Note" : b.kind.defaultTitle
        inspectorHeader = (space.map(title(of:)) ?? Self.linkTitle(b), "\(kindName) on \(hostName)" + (f?.offline == true ? ", out of reach" : ""),
                           space != nil ? Theme.spaceSymbol : Theme.symbolName(for: b), (b.annotations ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        var sections: [OrgNode] = []
        func row(_ value: String, _ label: String, _ symbol: String, _ action: (() -> Void)? = nil) -> OrgNode {
            let n = OrgNode(id: "insp/\(sections.count)/\(label)/\(value)", title: value, symbol: symbol, detail: label)
            n.tooltip = "\(label): \(value)"
            n.action = action
            return n
        }
        func section(_ title: String, _ symbol: String, _ rows: [OrgNode], id: String? = nil) {
            guard !rows.isEmpty else { return }
            let s = OrgNode(id: "insp:\(id ?? title)", title: title, symbol: symbol, isGroup: true, children: rows)
            s.style = .section
            sections.append(s)
        }
        /// A row that copies `text`: a click, or its copy button.
        func copyRow(_ value: String, _ label: String, _ symbol: String, _ text: String) -> OrgNode {
            let n = row(value, label, symbol, copying(text))
            n.copies = text
            return n
        }
        func copying(_ text: String) -> () -> Void {
            { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }
        let graph = hosts.client(of: b.id)?.node.graph

        // What it is.
        var about: [OrgNode] = [row(hostName, "host", "desktopcomputer")]
        if let p = b.path { about.append(copyRow(p.abbreviatingHome, "path", "doc", p)) }
        if let u = b.web?.url { about.append(copyRow(u, "address", "globe", u)) }
        if let d = b.terminal?.cwd { about.append(copyRow(d.abbreviatingHome, "directory", "folder", d)) }
        about.append(row(Age.ago(b.created), "made", "calendar"))
        if let seen = graph?.seen(b.id) { about.append(row(Age.ago(seen), "last seen", "eye")) }
        if let t = StatusGlyph.tooltip(b), !t.isEmpty { about.append(row(t, "status", "circle.dotted")) }
        section("About", "info.circle", about)

        // What tools know it by: its ids, its reference, what it's
        // annotated with (`mani annotate`) — each copied as a click.
        var tools: [OrgNode] = []
        let reference = "manifold:" + b.id.description
        tools.append(copyRow(reference, "reference", "link", reference))
        tools.append(copyRow(b.id.ulid, space != nil ? "space id" : "block id", "number", b.id.description))
        if let f { tools.append(copyRow(f.id, "tile id", "rectangle", f.id)) }
        if let w = selected, space == nil { tools.append(copyRow(w.ulid, "space id", Theme.spaceSymbol, w.description)) }
        for (k, v) in (b.annotations ?? [:]).sorted(by: { $0.key < $1.key }) {
            tools.append(copyRow(v, k + " — annotation", "tag", "\(k)=\(v)"))
        }
        section("For Tools", "wrench.and.screwdriver", tools)

        // Its status as its record has it (§3.7), all of it.
        if let r = b.statusRecord {
            var st: [OrgNode] = [row(r.state.rawValue, "state", "circle.dotted")]
            if let k = r.kind { st.append(row(k.rawValue, "blocked on", "hand.raised")) }
            if let p = r.progress { st.append(row("\(p)%", "progress", "chart.bar")) }
            if let app = r.app { st.append(row(app, "said by", "app")) }
            if let t = r.title, !t.isEmpty { st.append(row(t, "title", "textformat")) }
            if let m = r.msg, !m.isEmpty { st.append(row(m, "message", "text.bubble")) }
            st.append(row(Age.ago(r.at), "since", "clock"))
            if r.read == true { st.append(row("Read", "", "checkmark")) }
            section("Status", "circle.dotted", st)
        }

        // This tile: how it shows the block, where it is, what it keeps.
        if let f, let a = arrangement, let (c, i) = a.locate(f.id) {
            var tile: [OrgNode] = [row(f.lens.rawValue, "lens", Theme.symbolName(for: f.lens))]
            tile.append(row("column \(c + 1) of \(a.columns.count), \(i + 1) of \(a.columns[c].count)", "place", "square.grid.2x2"))
            let width = c < a.fractions.count ? a.fractions[c] : 0
            let height = a.height(of: f.id)
            tile.append(row(String(format: "%.0f%% wide, %.0f%% of its column", width * 100, height * 100), "size", "arrow.up.left.and.arrow.down.right"))
            if a.full == f.id { tile.append(row("Maximized", "", "arrow.up.left.and.arrow.down.right")) }
            if a.isDocked(f.id) { tile.append(row("Docked", "", "dock.arrow.down.rectangle")) }
            if let at = f.placement.placedAt { tile.append(row(Age.ago(at), "placed", "calendar")) }
            // What the lens keeps for it: its scroll, selection, mode…
            for (k, v) in (b.views?[f.id] ?? [:]).sorted(by: { $0.key < $1.key }) {
                tile.append(row(v.count > 60 ? String(v.prefix(59)) + "…" : v, k + " — kept", "tray"))
            }
            if let sel = b.text?.selections[f.id]?.first, let rope = b.text?.text, sel.start <= rope.count {
                tile.append(row("line \(rope.line(at: sel.start) + 1)" + (sel.start == sel.end ? "" : ", \(abs(sel.end - sel.start)) characters"), "selection", "text.cursor"))
            }
            section("This Tile", "rectangle", tile)
        }

        // What only its kind has: at a glance (open), and in detail (folded).
        var own: [OrgNode] = [], more: [OrgNode] = []
        switch b.kind {
        case .text:
            if let t = b.text {
                let s = t.text.string
                own.append(row("\(s.split(separator: "\n", omittingEmptySubsequences: false).count)", "lines", "text.alignleft"))
                own.append(row("\(s.split { $0.isWhitespace || $0.isNewline }.count)", "words", "textformat"))
                more.append(row("\(s.count)", "characters", "character"))
                more.append(row(ByteCountFormatter.string(fromByteCount: Int64(s.utf8.count), countStyle: .file), "size", "internaldrive"))
                if let p = b.path, let lang = CodeLanguage.forPath(p) { own.append(row(lang.name, "language", "chevron.left.forwardslash.chevron.right")) }
                if t.isDirty { own.append(row("Unsaved", "edits", "pencil")) }
                more.append(row("\(t.version)" + (t.isDirty ? " (saved at \(t.cleanVersion))" : ""), "version", "number"))
                if let n = b.anchors?.count, n > 0 { own.append(row("\(n)", "places", "mappin")) }
                if t.unreadable { own.append(row("Unreadable", "file", "exclamationmark.triangle")) }
                if t.stale { own.append(row("Changed on disk", "file", "exclamationmark.triangle")) }
                more.append(row(t.encoding, "encoding", "doc.text"))
                more.append(row(t.lineEnding == "\r\n" ? "CRLF" : "LF", "line endings", "return"))
            }
        case .terminal, .agent:
            if let t = b.terminal {
                if let pid = t.pid { more.append(row("\(pid)", "shell's process", "number")) }
                if let title = t.title, !title.isEmpty { more.append(row(title, "shell's title", "textformat")) }
                if let cmd = t.command { own.append(row(cmd, "runs", "terminal")) }
                if let agent = b.agent { own.append(row(agent.name, "agent", "sparkle")) }
                if let c = t.commands?.last(where: { $0.isRunning }) { own.append(row(c.text, "running", "play")) }
                if let c = t.commands?.last(where: { !$0.isRunning }) {
                    let how = c.status.map { $0 == 0 ? "ok" : "exit \($0)" } ?? "?"
                    let took = BlockSummary.took(from: c.at, to: c.ended).map { " · " + $0 } ?? ""
                    own.append(row("\(c.text) · \(how)\(took) · \(Age.ago(c.ended ?? c.at))", "last command", c.status == 0 ? "checkmark" : "xmark"))
                }
                if let after = t.dormantAfter { more.append(row("\(after) h", "dormant after", "moon.zzz")) }
                if t.snapshot != nil { more.append(row("Kept, for its changes", "start's tree", "camera")) }
                more.append(row("\(t.commands?.count ?? 0)", "commands run", "list.bullet"))
                if let turns = t.turns, !turns.isEmpty { more.append(row("\(turns.count)", "turns", "bubble.left.and.bubble.right")) }
                if let d = t.dormantSince { own.append(row(Age.ago(d), "dormant since", "moon")) }
            }
        case .web:
            if let w = b.web {
                if let t = w.title { own.append(row(t, "page's title", "textformat")) }
                if w.viaHost == true { more.append(row(hostName, "loaded via", "network")) }
            }
        case .search:
            if let s = b.search {
                if let q = s.query { own.append(row(q.text, "query", "magnifyingglass")); own.append(row(q.root.abbreviatingHome, "under", "folder")) }
                own.append(row("\(s.hits.count)" + (s.truncated ? "+" : ""), "hits", "text.magnifyingglass"))
                own.append(row("\(Set(s.hits.map(\.path)).count)", "files", "doc.on.doc"))
                if let k = s.query?.kinds { more.append(row(k.joined(separator: ", "), "looks for", "line.3.horizontal.decrease")) }
                if let n = s.symbols?.count { more.append(row("\(n)", "symbols", "function")) }
                if let n = s.files?.count { more.append(row("\(n)", "files by name", "doc")) }
                if let at = s.ranAt { more.append(row(Age.ago(at), "asked", "clock")) }
                if let e = s.error { own.append(row(e, "error", "exclamationmark.triangle")) }
                if s.running { own.append(row("Searching", "now", "hourglass")) }
            }
        case .directory:
            own.append(row("\(b.directory?.entries.count ?? 0)", "entries", "list.bullet"))
            if let at = b.directory?.listedAt { more.append(row(Age.ago(at), "listed", "clock")) }
            if let e = b.directory?.error { own.append(row(e, "error", "exclamationmark.triangle")) }
            if let path = b.path, let p = hosts.client(of: b.id)?.desk.project(holding: path) {
                own.append(row(p.name, p.root == path ? "a project" : "in project", "shippingbox"))
            }
        case .notebook:
            if let n = b.notebook {
                own.append(row("\(n.cells.count)", "cells", "square.stack"))
                if let sh = n.shell { more.append(row(sh, "shell", "terminal")) }
                if let pid = n.pid { more.append(row("\(pid)", "shell's process", "number")) }
                if let at = n.shellStarted { more.append(row(Age.ago(at), "shell started", "clock")) }
                if n.running != nil { own.append(row("A cell", "running", "play")) }
                if !n.queued.isEmpty { own.append(row("\(n.queued.count)", "queued", "list.number")) }
                more.append(row("\(n.runs)", "runs", "play"))
            }
        case .output:
            if let o = b.output {
                own.append(row(o.line, "command", "terminal"))
                if let st = o.status { own.append(row(st == 0 ? "OK" : "Exit \(st)", "ended", st == 0 ? "checkmark" : "xmark")) }
                if let took = BlockSummary.took(from: o.ran, to: o.ended) { own.append(row(took, "took", "timer")) }
                more.append(row(ByteCountFormatter.string(fromByteCount: Int64(o.output.utf8.count), countStyle: .file), "output", "doc.plaintext"))
                if let src = o.source, let s = hosts.block(src) {
                    let n = row(Self.linkTitle(s), "ran in", Theme.symbolName(for: s))
                    n.block = src
                    own.append(n)
                }
            }
        case .git:
            if let g = b.git {
                if let vcs = g.vcs { more.append(row(vcs.rawValue, "vcs", "shippingbox")) }
                if let br = g.branch { own.append(row(br, "branch", "arrow.triangle.branch")) }
                if let scope = g.scope { more.append(row(scope, "scoped to", "folder")) }
                own.append(row("\(g.status.count)", "changes", "plusminus"))
                let staged = g.status.filter { !$0.isUntracked && $0.index != " " }.count, untracked = g.status.filter(\.isUntracked).count
                if staged > 0 { more.append(row("\(staged)", "staged", "tray.and.arrow.down")) }
                if untracked > 0 { more.append(row("\(untracked)", "untracked", "questionmark.folder")) }
                more.append(row("\(g.log.count)", "commits", "clock.arrow.circlepath"))
                if let at = g.refreshedAt { more.append(row(Age.ago(at), "looked", "clock")) }
                if let e = g.error { own.append(row(e, "error", "exclamationmark.triangle")) }
                if g.ahead > 0 || g.behind > 0 { own.append(row("\(g.ahead) ahead, \(g.behind) behind", "upstream", "arrow.up.arrow.down")) }
            }
        case .diff:
            if let d = b.diff {
                if let subject = d.subject { own.append(row(Self.describe(subject), "compares", "plus.forwardslash.minus")) }
                if let p = d.patch {
                    more.append(row("\(p.components(separatedBy: "\ndiff --git").count)", "files", "doc.on.doc"))
                    let lines = p.split(separator: "\n")
                    let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                    own.append(row("+\(added) −\(removed)", "lines", "plusminus"))
                }
                if let at = d.loadedAt { more.append(row(Age.ago(at), "read", "clock")) }
                if let e = d.error { own.append(row(e, "error", "exclamationmark.triangle")) }
            }
        case .process:
            own.append(row("\(b.processes?.entries.count ?? 0)", "processes", "cpu"))
            if let at = b.processes?.listedAt { more.append(row(Age.ago(at), "listed", "clock")) }
        case .arrangement:
            if let a = b.arrangement { (own, more) = spaceRows(b.id, a, row) }
        default:
            break
        }
        section(b.kind == .text ? "Text" : space != nil ? "Space" : b.kind.defaultTitle, space != nil ? Theme.spaceSymbol : Theme.symbolName(for: b), own, id: "kind")
        section(space != nil ? "Layout" : "Details", space != nil ? "rectangle.split.3x1" : "list.bullet.rectangle", more, id: space != nil ? "space-layout" : "kind-details")

        // A space's tiles, column by column (a click goes to one), and what's
        // pinned in it.
        if let a = space {
            var tiles: [OrgNode] = []
            for (c, column) in a.columns.enumerated() {
                for p in column {
                    guard let o = hosts.block(p.block) else { continue }
                    var how = "column \(c + 1)"
                    if a.full == p.id { how += ", maximized" }
                    if a.focused == p.id { how += ", focused" }
                    if o.id.host != b.id.host { how += ", on \(hosts.label(of: o.id.host))" }
                    let n = node(for: o, id: "insp/tile/\(p.id)", detail: how)
                    n.arrangement = b.id
                    n.placement = p.id
                    tiles.append(n)
                }
            }
            for d in a.docked.reversed() {
                guard let o = hosts.block(d.placement.block) else { continue }
                let n = node(for: o, id: "insp/tile/\(d.placement.id)", detail: "docked" + (d.at.map { " " + Age.ago($0) } ?? ""))
                n.arrangement = b.id
                n.placement = d.placement.id
                tiles.append(n)
            }
            section("Tiles", "rectangle.split.3x1", Array(tiles.prefix(60)), id: "space-tiles")
            let pinned = pins(of: b.id).compactMap { e -> OrgNode? in
                guard let o = hosts.block(e.to) else { return nil }
                return node(for: o, id: "insp/pin/\(e.to)", detail: "pinned " + Age.ago(e.at))
            }
            section("Pinned", "pin", pinned, id: "space-pinned")
        }

        // Where it is: each space it's placed in, and pinned in.
        var whereRows: [OrgNode] = []
        var placedIn = 0, pinnedIn = 0
        for w in allWorkspaces {
            guard let a = hosts.arrangement(w) else { continue }
            for p in a.placements where p.block == b.id {
                placedIn += 1
                let how = a.isDocked(p.id) ? "docked" : a.full == p.id ? "maximized" : w == selected && a.focused == p.id ? "this tile" : "a tile"
                let n = row(title(of: a), how, Theme.spaceSymbol)
                n.arrangement = w
                n.placement = p.id
                whereRows.append(n)
            }
            if isPinned(b.id, in: w) {
                pinnedIn += 1
                let n = row(title(of: a), "pinned", "pin")
                n.arrangement = w
                whereRows.append(n)
            }
        }
        section("Where", "map", whereRows)

        // What keeps it (§4): a space that places or pins it, a link by
        // hand to it; else it's let go of, and collected in a while.
        var strongIn = 0
        for c in hosts.all {
            for kind in [LinkKind.linked, .embeds] { strongIn += c.node.graph.edges(to: b.id, kind: .link(kind)).filter(\.isLive).count }
        }
        var kept: [String] = []
        if space != nil, hosts.client(of: b.id)?.desk.order.contains(b.id) == true { kept.append("on the desk") }
        if space?.isNamed == true { kept.append("named") }
        if placedIn > 0 { kept.append("placed in \(placedIn) space\(placedIn == 1 ? "" : "s")") }
        if pinnedIn > 0 || b.isPinned { kept.append("pinned") }
        if strongIn > 0 { kept.append("linked to by \(strongIn)") }
        let reached = hosts.reachable().contains(b.id)
        section("Kept", "lock", [kept.isEmpty
            ? row(reached ? "By what reaches it" : "Not kept: collected in a while", "", reached ? "lock" : "clock.arrow.circlepath")
            : row(kept.joined(separator: ", ").capitalizingFirst, "", "lock")])

        // Its links, either way, the latest first.
        var edges: [(Edge, out: Bool)] = []
        for c in hosts.all {
            edges += c.node.graph.edges(from: b.id).filter { $0.isLive }.map { ($0, true) }
            edges += c.node.graph.edges(to: b.id).filter { $0.isLive }.map { ($0, false) }
        }
        var seenLinks = Set<String>()
        let linkRows: [OrgNode] = edges.filter { e, _ in
            if case .link(let k) = e.kind { return k != .pinned }
            return false
        }.sorted { $0.0.at > $1.0.at }.compactMap { e, out in
            let other = out ? e.to : e.from
            guard seenLinks.insert("\(other)\(out)\(e.kind)").inserted, let o = hosts.block(other) else { return nil }
            let how: String
            switch e.kind {
            case .link(.linked): how = out ? "links to" : "linked from"
            case .link(.embeds): how = out ? "shows" : "shown in"
            default: how = out ? "opened" : "opened from"
            }
            let n = node(for: o, id: "insp/link/\(e.id)/\(out)", detail: how)
            if let c = e.context, !c.isEmpty { n.tooltip = "\(how): \(c)" }
            return n
        }
        section("Links", "link", Array(linkRows.prefix(30)))

        // Its history: its log (how long, what changed last), the trail's
        // visits, and this tile's back and forward (⌘[ ⌘]).
        let visits = hosts.all.flatMap { $0.node.graph.visits(b.id) }.sorted { $0.at > $1.at }
        var history: [OrgNode] = []
        if let replica = hosts.client(of: b.id)?.node.replica(.block(b.id)) {
            history.append(row("\(replica.seq) changes", "log", "list.number"))
            // Its log's latest, from its host once (then what's come since).
            if !inspectorAsked.contains(b.id) {
                inspectorAsked.insert(b.id)
                hosts.propose(.history(.block(b.id)))
            }
            let kept = inspectorLogs[b.id] ?? []
            let newer = replica.entries.filter { $0.seq > (kept.last?.seq ?? -1) }
            // The latest, a few, newest first — the same kind in a row once, counted.
            var runs: [(name: String, at: Stamp, count: Int)] = []
            for e in (kept + newer).reversed().prefix(200) {
                let name = e.event.name
                if let last = runs.last, last.name == name { runs[runs.count - 1].count += 1 } else { runs.append((name, e.at, 1)) }
                if runs.count > 8 { runs.removeLast(); break }
            }
            for r in runs { history.append(row(Age.ago(r.at), r.name + (r.count > 1 ? " ×\(r.count)" : ""), "circle.fill")) }
        }
        history.append(row("\(visits.count) times", "gone to", "arrow.uturn.right"))
        if let last = visits.first { history.append(row(Age.ago(last.at), "last gone to", "clock")) }
        if let f, let trail = trails[f.id] {
            for id in trail.back.suffix(5).reversed() {
                guard let o = hosts.block(id) else { continue }
                history.append(node(for: o, id: "insp/back/\(id)", detail: "back (⌘[)"))
            }
            for id in trail.forward.suffix(3).reversed() {
                guard let o = hosts.block(id) else { continue }
                history.append(node(for: o, id: "insp/forward/\(id)", detail: "forward (⌘])"))
            }
        }
        section("History", "clock", history)

        // What can be done with it: Copy Contents, and what its menu offers.
        var actions: [OrgNode] = []
        if f != nil { actions.append(row("Copy Contents", "⇧⌘C", "doc.on.doc") { [weak self] in self?.copyContents(nil) }) }
        if space != nil {
            if b.id != selected { actions.append(row("Go to Space", "", Theme.spaceSymbol) { [weak self] in self?.hosts.select(b.id) }) }
            actions.append(row("Rename Space…", "", "pencil") { [weak self] in self?.renameSpace(b.id) })
            actions.append(row("Remove Space", "", "xmark") { [weak self] in self?.removeFromDesk(b.id) })
        }
        for item in copyItems(for: b.id) {
            guard let c = item as? ClosureMenuItem else { continue }
            let n = row(item.title, "", "circle")
            n.image = item.image
            n.action = { c.perform() }
            actions.append(n)
        }
        actions.append(row("Show the Neighborhood Map", "⇧⌥⌘M", "point.3.connected.trianglepath.dotted") { [weak self] in self?.showNeighborhood(around: b.id) })
        if let w = selected, b.kind != .arrangement {
            let pinnedHere = isPinned(b.id, in: w)
            actions.append(row(pinnedHere ? "Unpin from This Space" : "Pin in This Space", "⌃⌘T", "pin") { [weak self] in self?.setPinned(b.id, in: w, !pinnedHere) })
        }
        section("Actions", "bolt", actions)
        return (sections, Set(sections.map(\.id)))
    }

    /// Recently Closed (§4), the list: what exists and nothing reaches,
    /// dimmed, each brought back by a click, until collected.
    func closedTree() -> ([OrgNode], Set<String>) {
        let reachable = hosts.reachable()
        return hostedRows({ c in
            closedItems(on: c, reachable: reachable).prefix(100).map { b -> OrgNode in
                let n = b.kind == .arrangement
                    ? OrgNode(id: "closed/\(b.id)", block: b.id, title: title(of: b.arrangement!), symbol: Theme.spaceSymbol, count: b.arrangement!.placements.count)
                    : node(for: b, id: "closed/\(b.id)", detail: b.place?.abbreviatingHome ?? "")
                n.dimmed = true
                n.trailing = c.node.graph.seen(b.id).map(Age.short)
                return n
            }
        }, prefix: "closed")
    }

    /// The sidebar's New row: New Terminal, below the focused tile; the
    /// pointer on it, a chevron for ⌘N's picker (another kind).
    private func newTileRow(in space: BlockID) -> OrgNode {
        let terminal = BlockKinds.named("terminal")!
        let n = OrgNode(id: "arr/\(space)/new", title: "New " + terminal.title, symbol: "plus", detail: "")
        n.dimmed = true
        n.age = nil
        n.action = { [weak self] in self?.makeFromPicker(terminal, nil) }
        n.tooltip = "A new \(terminal.title.lowercased()), below the focused tile"
        n.accessories = [.init(symbol: "chevron.down", tip: "Another Kind… (⌘N)", run: { [weak self] in self?.newBlockPicker(nil) })]
        return n
    }

    /// The space shown (§3.6), one at a time — the others are the strip's,
    /// at the sidebar's top: nothing nested, nothing to fold. Its pinned
    /// blocks first, in the order pinned (each its tile, or, closed, a row
    /// to recall it here); then what's on screen, as the grid has it —
    /// column by column, top to bottom, a hairline between columns; then
    /// those docked (§3.1), the latest first. The focused tile marked: the
    /// table of contents of the screen.
    func deskTree() -> ([OrgNode], Set<String>) {
        guard let id = selected, let a = hosts.arrangement(id) else { return ([], []) }
        let aid = "arr/\(id)"
        let pinned = pins(of: id).map(\.to)
        func tile(_ p: Placement, docked isDock: Bool, column c: Int?) -> OrgNode? {
            let b = hosts.block(p.block)
            // An untitled note by its first words, as its links name it.
            let title = b.map(Self.linkTitle) ?? "On \(hosts.label(of: p.block.host))"
            // What its status says beyond its glyph (not "Done"); else
            // its state — docked, maximized — as a small symbol. Edits
            // unsaved: the bar's dot after its name.
            var notes: [String] = []
            if let status = StatusGlyph.remark(b) { notes.append(status) }
            if b == nil { notes.append("not attached") }
            if let t = b?.terminal, t.hasExited { notes.append(TerminalView.exitedWords(t.exitStatus).capitalizingFirst) }
            let n = OrgNode(id: "\(aid)/tile/\(p.id)", block: p.block, title: title,
                            symbol: b.map { Theme.symbolName(for: $0) } ?? "questionmark.square.dashed",
                            detail: notes.joined(separator: " · "))
            n.dirty = b?.text?.isDirty == true
            n.stale = b?.text?.stale == true
            n.image = b?.web.flatMap { Favicons.image(forPage: $0.url) }
            n.look = StatusGlyph.look(of: b); n.blocked = b?.statusRecord?.kind; n.tooltip = StatusGlyph.tooltip(b)
            n.trailing = StatusGlyph.at(of: b).map(Age.short)
            if isDock {
                n.docked = true
                n.tooltip = (n.tooltip.map { $0 + "\n" } ?? "") + "Docked — click to put it back where it was (⌃⇥ goes to it too)"
            } else if a.full == p.id { n.detailSymbol = "arrow.up.left.and.arrow.down.right" }
            n.arrangement = id
            n.column = c
            n.placement = p.id
            n.emphasis = p.id == a.focused
            // An $EDITOR's tile as the terminal it's over, editing.
            if let t = stackedTerminal(p.id) {
                n.title = t.displayTitle
                n.symbol = Theme.symbolName(for: t)
                n.image = nil
                n.pill = .note("Editing")
                n.badge = "doc.fill"
                n.trailing = nil
            }
            // The pointer on it: close it (⌘W's), or delete its block.
            let pid = p.id, block = p.block
            n.accessories = [
                .init(symbol: "trash", tip: "Delete", run: { [weak self] in self?.deleteBlock(block) }),
                .init(symbol: "xmark", tip: "Close Tile", run: { [weak self] in self?.closeTile(pid, in: id) }),
            ]
            return n
        }
        func label(_ title: String, _ key: String, count: Int? = nil) -> OrgNode {
            let n = OrgNode(id: "\(aid)/\(key)", title: title, symbol: "", detail: "", count: count)
            n.style = .section
            return n
        }
        func rule(_ key: String) -> OrgNode {
            let n = OrgNode(id: "\(aid)/\(key)", title: "", symbol: "", detail: "")
            n.style = .divider
            return n
        }
        var out: [OrgNode] = []
        // Pinned: each its tile (on screen or docked), else a row to recall it.
        var top: [OrgNode] = []
        for block in pinned {
            let shown = a.columns.enumerated().flatMap { c, col in col.filter { $0.block == block }.compactMap { tile($0, docked: false, column: c) } }
                + a.docked.filter { $0.placement.block == block }.compactMap { tile($0.placement, docked: true, column: nil) }
            top += shown
            guard shown.isEmpty, let b = hosts.block(block) else { continue }
            let title = Self.linkTitle(b)
            let n = node(for: b, id: "\(aid)/pin/\(block)", detail: StatusGlyph.remark(b) ?? "")
            n.arrangement = id
            n.dimmed = true
            n.age = nil
            n.action = { [weak self] in self?.recallPinned(block, in: id) }
            top.append(n)
        }
        if !top.isEmpty { out += [label("Pinned", "pinned")] + top }
        // On screen, column by column.
        var grid: [OrgNode] = []
        for (c, column) in a.columns.enumerated() {
            let rows = column.filter { !pinned.contains($0.block) }.compactMap { tile($0, docked: false, column: c) }
            guard !rows.isEmpty else { continue }
            if !grid.isEmpty { grid.append(rule("col/\(c)")) }
            grid += rows
        }
        if !grid.isEmpty { out += [label("On Screen", "screen")] + grid }
        // A new tile, as Dia's New Tab: the kind last made (⌘N's picker
        // the first time, and from its button for another kind).
        out.append(newTileRow(in: id))
        // Docked, the latest first.
        let docked = a.docked.reversed().filter { !pinned.contains($0.placement.block) && !stacked.contains($0.placement.id) }.compactMap { tile($0.placement, docked: true, column: nil) }
        if !docked.isEmpty {
            // Its label stands for the space, for a tile flown to it before its row is made.
            let l = label("Docked", "docked", count: docked.count)
            l.arrangement = id
            out += [l] + docked
        }
        return (out, [])
    }

    /// Files: each host's sparse tree, roots open.
    func filesTree() -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        // What is on a workspace now comes first in every folder; what is
        // kept otherwise (§4) after, dimmed — a folder with something active
        // among its blocks counts as active. What nothing keeps isn't here:
        // it's in Recently Closed, at the sidebar's foot.
        let placed = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        let reachable = hosts.reachable()
        var active: [ObjectIdentifier: Bool] = [:]
        func convert(_ f: FileNode) -> OrgNode? {
            if let b = f.block, !f.isFolder, !reachable.contains(b) { return nil }
            let made = f.children.compactMap(convert)
            var children = made.filter { active[ObjectIdentifier($0)] == true }
            children += made.filter { active[ObjectIdentifier($0)] != true }
            let block = f.block.flatMap { hosts.block($0) }
            let id = "file:\(f.host.raw):\(f.path)"
            let isActive = f.block.map { placed.contains($0) } ?? false || children.contains { active[ObjectIdentifier($0)] == true }
            if f.isFolder {
                let node = OrgNode(id: id, block: f.block, title: f.name, symbol: f.kind == .git ? "arrow.triangle.branch" : "folder",
                               detail: "", count: children.isEmpty ? nil : f.count, age: Self.age(f.latest), isGroup: true, children: children)
                if f.block == nil {
                    // A folder with no listing yet: clicked, it's listed on
                    // its host (the disclosure, or a double-click, opens it).
                    let path = f.path, on = f.host
                    node.action = { [weak self] in self?.openDirectory(path, on: on) }
                }
                node.dimmed = !isActive
                active[ObjectIdentifier(node)] = isActive
                return node
            }
            if f.isPlace, let block {
                // At the folder, not a file in it: by its own title (a
                // terminal whose title is only its folder says "Terminal").
                let shown = block.displayTitle
                let title = block.terminal != nil && (shown.hasPrefix("~") || shown.hasPrefix("/")) ? block.kind.defaultTitle : shown
                let node = OrgNode(id: "place:\(block.id)", block: f.block, title: title, symbol: Theme.symbolName(for: block),
                                   detail: "", age: Self.age(f.latest))
                node.dirty = block.text?.isDirty == true
                node.stale = block.text?.stale == true
                node.look = StatusGlyph.look(of: block)
                node.blocked = block.statusRecord?.kind
                node.trailing = StatusGlyph.at(of: block).map(Age.short)
                node.dimmed = !isActive
                active[ObjectIdentifier(node)] = isActive
                return node
            }
            let node = OrgNode(id: id, block: f.block, title: f.name, symbol: block.map { Theme.symbolName(for: $0) } ?? "doc",
                               detail: "", age: Self.age(f.latest))
            node.dirty = block?.text?.isDirty == true
            node.stale = block?.text?.stale == true
            node.dimmed = !isActive
            active[ObjectIdentifier(node)] = isActive
            return node
        }
        var roots: [OrgNode] = []
        let clients = hosts.ordered
        for c in clients {
            let home = c.transport.isLocal ? NSHomeDirectory() : nil
            var tree = c.node.graph.fileTree(host: c.host, home: home ?? c.home).compactMap(convert)
            if tree.isEmpty, let home = home ?? c.home {
                // Nothing of the host yet: its home folder, to start from.
                let n = OrgNode(id: "file:\(c.host.raw):\(home)", title: "~", symbol: "house", isGroup: false)
                n.action = { [weak self] in self?.openDirectory(home, on: c.host) }
                tree = [n]
            }
            if clients.count > 1 {
                let id = "host:\(c.host.raw)"
                open.insert(id)
                let n = OrgNode(id: id, title: hosts.label(of: c.host), symbol: Theme.hostSymbol(remote: c.isRemote),
                                count: tree.reduce(0) { $0 + ($1.count ?? 0) }, isGroup: true, children: tree)
                hostStanding(n, c)
                roots.append(n)
            } else {
                roots += tree
                for r in tree { open.insert(r.id) }
            }
        }
        return (roots, open)
    }

    /// A host's row says how it stands (§8): a spinner while being
    /// reached, a slashed ring when it can't be, dimmed; clicked, its
    /// home folder opens there.
    private func hostStanding(_ n: OrgNode, _ c: HostClient) {
        // Its ping times lately, by its name (a remote host's).
        if c.isRemote { n.pings = { [weak c] in c?.pings ?? [] } }
        switch c.link {
        case .connected:
            // Another Manifold leads it: an eye (the word would crowd out
            // its ping times), and who in its tooltip and card, Take Over in
            // its menu. (Quiet as well, the broken ring says that first.)
            if c.watching {
                n.look = .watching
                n.tooltip = "\(c.fencedBy ?? "Another Manifold") took over this host: what you do here doesn't take. Take Over is in its menu."
            }
            // Up, but quiet a while: a broken ring, and on hover, how long.
            guard c.silence != nil else { break }
            n.look = .quiet
            n.liveTooltip = { [weak c] in c?.silenceDescription ?? "Heard from again." }
        case .connecting:
            n.look = .connecting
            n.detail = "connecting…"
            // The step under way and how long so far, as of the hover; and
            // when it was last heard from, if it was connected before.
            n.liveTooltip = { [weak c] in
                [c?.stepDescription ?? "Connecting…", c?.silenceDescription].compactMap { $0 }.joined(separator: "\n")
            }
            n.dimmed = true
        case .unreachable(let why):
            n.look = .offline
            n.detail = "unreachable"
            let when = c.nextTry.map { " · trying again in \(max(Int($0.timeIntervalSinceNow.rounded()), 0)) s" } ?? ""
            n.tooltip = (why.map { "Can't be reached: \($0)" } ?? "Can't be reached now") + when
            n.dimmed = true
        }
        // Its row opens and closes its workspaces; its home folder is in its menu.
    }

    /// A folder listed on its host, beside what's focused.
    func openDirectory(_ path: String, on host: HostID) {
        show(hosts.directoryBlock(for: path, on: host), lens: .directory, .here)
    }
}
