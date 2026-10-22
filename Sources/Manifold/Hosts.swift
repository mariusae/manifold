import AppKit
import ManifoldCore
import Network

/// Every host the app is attached to: this machine's, and any reached
/// through a provider (DESIGN.md §8). Blocks are found by their id's host;
/// the desk, settings and new arrangements are the local host's.
final class Hosts {
    let local: HostClient
    private(set) var remotes: [HostID: HostClient] = [:]
    /// What is this client's alone (§8.2): the workspace shown, the
    /// order, the window, the appearance; in a file beside the hosts file.
    private(set) var state = ClientState()
    private static var stateURL: URL { Paths.directory.appendingPathComponent("client.json") }
    /// Hosts being attached to, by destination, until they say their name.
    private(set) var attaching: Set<String> = []
    private(set) var errors: [String: String] = [:]

    var onChange: (() -> Void)?
    var onTerminalEnded: ((BlockID) -> Void)?
    var onHistory: ((ShardID, ShardSnapshot?, [Entry]) -> Void)?
    /// A `manifold` command on `host` asks for paths to be opened.
    var onOpen: ((HostID, Int, Int, [String], BlockID?, Bool) -> Void)?
    var onShow: ((HostID, Int, Int, BlockID, BlockID?) -> Void)?
    var onDiagnostics: ((BlockID) -> Void)?
    var onGutter: ((BlockID) -> Void)?
    var onNotebookLive: ((BlockID, String, String) -> Void)?
    var onLanguageServer: ((HostID, String, String, String) -> Void)?
    private var pushedLanguageServers: [HostID: [LanguageServerConfig]] = [:]
    private var editing: Set<BlockID> = []

    init() {
        local = HostClient(transport: .local)
        wire(local)
        if let data = try? Data(contentsOf: Self.stateURL), let s = try? JSONDecoder().decode(ClientState.self, from: data) {
            state = s
        } else {
            // Before the split (§8.2) this lived in the local desk: taken
            // from there once, when the host first says what it has.
            local.onWelcome = { [weak self] in
                guard let self, !FileManager.default.fileExists(atPath: Self.stateURL.path) else { return }
                let d = self.local.desk
                self.state.selected = d.selected
                self.state.window = d.window
                self.state.appearance = d.appearance
                self.saveState()
            }
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }

    private func change(_ f: (inout ClientState) -> Void) {
        var s = state
        f(&s)
        guard s != state else { return }
        state = s
        saveState()
        onChange?()
    }

    /// Shows a workspace: it is this client's selection, and its host's
    /// desk has it.
    func select(_ workspace: BlockID?) {
        if let workspace { client(of: workspace)?.adoptWorkspace(workspace) }
        change { $0.selected = workspace }
    }

    /// Workspaces as the trail has them (§3.5), the one gone to most
    /// recently first: ⌃⇥'s order, and where a block is looked for first.
    func recentWorkspaces() -> [BlockID] {
        var steps: [Step] = []
        for c in all {
            for s in c.node.graph.recent(limit: 200) where c.block(s.block)?.kind == .arrangement { steps.append(s) }
        }
        var seen: Set<BlockID> = []
        return steps.sorted { $0.at > $1.at }.compactMap { seen.insert($0.block).inserted ? $0.block : nil }
    }

    /// This machine's host was `local` before it had a session (§8): the
    /// workspaces this client's state names under the old name follow it
    /// to the id the server welcomed us with.
    private func follow(_ old: HostID, to new: HostID) {
        guard old != new else { return }
        func moved(_ id: BlockID) -> BlockID { id.host == old ? BlockID(host: new, ulid: id.ulid) : id }
        change { s in
            s.selected = s.selected.map(moved)
        }
    }

    func setWindow(_ w: WindowState) { change { $0.window = w } }
    func setAppearance(_ a: Appearance) { change { $0.appearance = a } }

    private func wire(_ client: HostClient) {
        client.onChange = { [weak self] in self?.onChange?() }
        client.onTerminalEnded = { [weak self] block in self?.onTerminalEnded?(block) }
        client.onHistory = { [weak self] shard, base, entries in self?.onHistory?(shard, base, entries) }
        client.onShow = { [weak self, weak client] id, who, block, beside in
            guard let self, let client else { return }
            self.onShow?(client.host, id, who, block, beside)
        }
        client.onOpen = { [weak self, weak client] id, who, paths, beside, wait in
            guard let self, let client else { return }
            self.onOpen?(client.host, id, who, paths, beside, wait)
        }
        client.onConnected = { [weak self, weak client] in
            guard let self, let client else { return }
            if !client.isRemote { self.follow(.local, to: client.host) }
            self.pushedLanguageServers.removeValue(forKey: client.host)
            self.pushLanguageServers()
            client.propose(.editing(self.editing.filter { $0.host == client.host }))
        }
        client.onDiagnostics = { [weak self] block in self?.onDiagnostics?(block) }
        client.onGutter = { [weak self] block in self?.onGutter?(block) }
        client.onNotebookLive = { [weak self] block, cell, output in self?.onNotebookLive?(block, cell, output) }
        client.onLanguageServer = { [weak self, weak client] language, root, state in
            guard let self, let client else { return }
            self.onLanguageServer?(client.host, language, root, state)
        }
    }

    /// Every host runs the language servers the settings say, as they
    /// change (the settings are the local host's).
    func pushLanguageServers() {
        let configs = local.desk.settings.languageServers
        for c in all where c.isConnected && pushedLanguageServers[c.host] != configs {
            pushedLanguageServers[c.host] = configs
            c.propose(.languageServers(configs))
        }
    }

    /// The text blocks placed anywhere, told to each one's host as they
    /// change (and again when a host comes back).
    func setEditing(_ ids: Set<BlockID>) {
        guard ids != editing else { return }
        let changed = Set(ids.symmetricDifference(editing).map(\.host))
        editing = ids
        for c in all where changed.contains(c.host) && c.isConnected {
            c.propose(.editing(ids.filter { $0.host == c.host }))
        }
    }

    func diagnostics(_ block: BlockID) -> [Diagnostic] { client(of: block)?.diagnostics[block] ?? [] }
    func gutter(_ block: BlockID) -> [GutterMark] { client(of: block)?.gutters[block] ?? [] }

    func lsp(_ request: LSPRequest, done: @escaping (LSPResult) -> Void) {
        let block: BlockID
        switch request {
        case let .definition(b, _), let .references(b, _), let .hover(b, _), let .rename(b, _, _), let .format(b, _), let .completion(b, _),
             let .navigable(b):
            block = b
        }
        guard let c = client(of: block) else { return done(.error("the block's host isn't attached")) }
        c.lsp(request, done: done)
    }

    var all: [HostClient] { [local] + remotes.values.sorted { $0.host < $1.host } }

    /// Every host, in the order the sidebar shows them: as this client
    /// arranged them (dragging their rows), the rest after.
    var ordered: [HostClient] {
        let order = state.hostOrder
        return all.enumerated().sorted { a, b in
            let i = order.firstIndex(of: a.element.host.raw) ?? Int.max, j = order.firstIndex(of: b.element.host.raw) ?? Int.max
            return i != j ? i < j : a.offset < b.offset
        }.map(\.element)
    }

    /// The hosts' order in the sidebar, as this client arranges it.
    func setHostOrder(_ hosts: [HostID]) { change { $0.hostOrder = hosts.map(\.raw) } }
    func setCollapsedRows(_ rows: Set<String>) { if Set(state.collapsedRows) != rows { change { $0.collapsedRows = rows.sorted() } } }

    func client(_ host: HostID) -> HostClient? {
        if host == local.host || host == .local { return local }
        return remotes[host]
    }

    func client(of block: BlockID) -> HostClient? { client(block.host) }

    /// What to call a host: This Mac; what it calls itself; what it was
    /// called when attached; else its session id.
    func label(of host: HostID) -> String {
        if host == local.host || host == .local { return "This Mac" }
        if let c = remotes[host], let l = c.label ?? HostsFile.load().label(of: host) { return l }
        return HostsFile.load().label(of: host) ?? host.raw
    }

    /// Whether a block's host is one we're attached to.
    func isAttached(_ host: HostID) -> Bool { client(host) != nil }

    // MARK: Reading, across hosts

    var desk: DeskState { local.desk }
    func block(_ id: BlockID) -> Block? { client(of: id)?.block(id) }
    func arrangement(_ id: BlockID?) -> ArrangementState? { id.flatMap { client(of: $0)?.arrangement($0) } }
    var blocks: [Block] { all.flatMap { $0.node.blocks } }
    func registryEntry(_ id: BlockID) -> RegistryEntry? { client(of: id)?.registry.blocks[id] }
    var links: [Link] { all.flatMap { $0.links.links } }
    func isConnected(_ host: HostID) -> Bool { client(host)?.isConnected ?? false }

    // MARK: Keeping (§4), across hosts

    /// The roots as this client sees them: every host's own, and the
    /// workspaces its desks list from other hosts.
    func roots() -> Set<BlockID> {
        var roots: Set<BlockID> = []
        for c in all {
            roots.formUnion(c.node.roots(on: c.host))
            roots.formUnion(c.desk.order)
        }
        return roots
    }

    /// Everything the roots reach over strong edges, across hosts: a
    /// block's edges are in its own host's graph (its placements in its
    /// workspace's host's, its links by hand in its own links shard).
    func reachable() -> Set<BlockID> {
        local.node.graph.reachable(from: roots()) { [weak self] b in
            self?.client(of: b)?.node.graph.strongEdges(from: b) ?? []
        }
    }

    /// Whether a block exists and nothing reaches it: closed, and to be
    /// collected unless something takes it up again.
    func isUnreached(_ block: BlockID, reachable: Set<BlockID>) -> Bool {
        self.block(block) != nil && !reachable.contains(block)
    }

    func pin(_ block: BlockID, _ on: Bool) { propose(.pin(block, on)) }

    /// Holds (§4): each strong reference from one host's shards to a
    /// block on another — a workspace placing it, a link by hand to it,
    /// a desk listing a workspace of it — is told to that host, keyed by
    /// the edge, and taken back when the edge goes or its source is no
    /// longer reached. Only what this client can see is reconciled; the
    /// holds of hosts it doesn't have are left alone.
    func reconcileHolds() {
        guard remotes.count > 0 else { return }
        let reachable = reachable()
        let ours = Set(all.map(\.host))
        var wanted: [HostID: [String: Hold]] = [:]
        for c in all {
            let s = c.host
            for b in c.node.blocks where b.id.host == s && reachable.contains(b.id) {
                guard let a = b.arrangement else { continue }
                for p in a.placements where p.block.host != s {
                    wanted[p.block.host, default: [:]][p.id] = Hold(id: p.id, block: p.block, holder: s, at: c.clock.now())
                }
            }
            for l in c.links.links where l.kind == .linked && l.to.host != s && l.from.host == s && reachable.contains(l.from) {
                wanted[l.to.host, default: [:]][l.id] = Hold(id: l.id, block: l.to, holder: s, at: c.clock.now())
            }
            for id in c.desk.order where id.host != s {
                let hid = "desk:\(s.raw):\(id.ulid)"
                wanted[id.host, default: [:]][hid] = Hold(id: hid, block: id, holder: s, at: c.clock.now())
            }
        }
        for r in all where r.isConnected {
            let have = r.registry.holds.filter { ours.contains($0.value.holder) }
            let want = wanted[r.host] ?? [:]
            for (id, h) in want where have[id].map({ $0.block != h.block || $0.holder != h.holder }) ?? true {
                if r.block(h.block) != nil { r.propose(.hold(h)) }
            }
            for id in have.keys where want[id] == nil { r.propose(.release(id)) }
        }
    }

    // MARK: The graph, across hosts

    /// A block's neighborhood over every host's graph: its placements are
    /// in the local host's arrangements, links to it may sit in any host's
    /// links shard (each keeps the links its own blocks made), and the
    /// trail is the local desk's.
    func neighborhood(of block: BlockID, at stamp: Stamp? = nil) -> Neighborhood {
        var n = Neighborhood(block: block)
        for c in all {
            let part = c.node.graph.neighborhood(of: block, at: stamp)
            for (k, e) in part.outbound { n.outbound[k, default: []].append(contentsOf: e) }
            for (k, e) in part.inbound { n.inbound[k, default: []].append(contentsOf: e) }
            n.before += part.before
            n.after += part.after
        }
        for k in n.outbound.keys { n.outbound[k]!.sort { $0.at > $1.at } }
        for k in n.inbound.keys { n.inbound[k]!.sort { $0.at > $1.at } }
        n.before.sort { $0.last != $1.last ? $0.last > $1.last : $0.count > $1.count }
        n.after.sort { $0.last != $1.last ? $0.last > $1.last : $0.count > $1.count }
        return n
    }

    /// How many edges of a kind touch a block, over every host: constant
    /// time per host.
    func count(to block: BlockID, kind: EdgeKind) -> Int { all.reduce(0) { $0 + $1.node.graph.count(to: block, kind: kind) } }
    func count(from block: BlockID, kind: EdgeKind) -> Int { all.reduce(0) { $0 + $1.node.graph.count(from: block, kind: kind) } }

    /// Graph distance from a block to every block within reach, the
    /// nearest first, over every host's edges.
    func distances(from block: BlockID, limit: Int = 3) -> [BlockID: Int] {
        var out: [BlockID: Int] = [:]
        for c in all {
            for (b, d) in c.node.graph.distances(from: block, limit: limit) where out[b].map({ d < $0 }) ?? true { out[b] = d }
        }
        return out
    }

    /// One step back or forward along the local trail from a block.
    func step(from block: BlockID, offset: Int) -> Step? { local.node.graph.step(from: block, offset: offset) }

    // MARK: Writing

    /// Before a workspace changes at this client's hand: its state, for
    /// undo (§3.1). Not for changes that only move the focus.
    var onWorkspaceChange: ((BlockID, ArrangementState, [Event]) -> Void)?

    func append(_ events: [Event], to shard: ShardID) {
        if case let .block(id) = shard, let a = arrangement(id), events.contains(where: { if case .focus = $0 { return false } else { return true } }) {
            onWorkspaceChange?(id, a, events)
        }
        (client(shard.host) ?? local).append(events, to: shard)
    }

    func append(_ event: Event, to shard: ShardID) { append([event], to: shard) }

    /// Sends a proposal to the host it concerns.
    func propose(_ proposal: Proposal, done: ((String?) -> Void)? = nil) {
        switch proposal {
        case let .newTerminal(block, _), let .endTerminal(block), let .readFile(block), let .writeFile(block, _, _),
             let .directory(block, _), let .listDirectory(block), let .search(block, _), let .cancelSearch(block),
             let .git(block, _), let .refreshGit(block), let .smartlog(block, _), let .diff(block, _), let .reloadDiff(block), let .captureOutput(block, _, _, _),
             let .newAgent(block, _, _), let .processes(block),
             let .newNotebook(block, _), let .editNotebook(block, _), let .runCells(block, _), let .interruptNotebook(block),
             let .restartNotebook(block), let .startNotebook(block), let .captureTurn(_, block, _), let .undoTurn(block, _):
            (client(of: block) ?? local).propose(proposal, done: done)
        case .workspaces, .settings, .preferences, .indexAgents, .listFolder, .listTree, .makeFolder, .movePath, .showRevision:
            local.propose(proposal, done: done)
        case let .seen(ids):
            for (host, group) in Dictionary(grouping: ids, by: \.host) {
                client(host)?.propose(.seen(group))
            }
            done?(nil)
        case let .attend(block), let .clearStatus(block), let .pin(block, _), let .discard(block):
            (client(of: block) ?? local).propose(proposal, done: done)
        case let .hold(h):
            client(h.block.host)?.propose(proposal, done: done)
        case .release:
            // Said to the holding host (reconcileHolds); here, to every host,
            // which is harmless: a host without the hold does nothing.
            for c in all { c.propose(proposal) }
            done?(nil)
        case let .link(link):
            (client(of: link.from) ?? local).propose(proposal, done: done)
        case .unlink:
            for c in all { c.propose(proposal) }
            done?(nil)
        case .resetGraph:
            // Said to a host's own client (resetGraph(on:)); here, every host's.
            for c in all { c.propose(proposal) }
            done?(nil)
        case let .history(shard):
            (client(shard.host) ?? local).propose(proposal, done: done)
        case .openDone, .editFile, .signal:
            local.propose(proposal, done: done)
        case let .editing(ids):
            for c in all { c.propose(.editing(ids.filter { $0.host == c.host })) }
            done?(nil)
        case .languageServers:
            for c in all { c.propose(proposal) }
            done?(nil)
        case let .lsp(request):
            lsp(request) { _ in done?(nil) }
        }
    }

    func propose(_ proposal: Proposal, on host: HostID) {
        client(host)?.propose(proposal)
    }

    /// Sets a host's own preferences; `done` says why not, if the host
    /// refused them.
    func setPreferences(_ preferences: HostPreferences, on host: HostID, done: @escaping (String?) -> Void) {
        guard let c = client(host), c.isConnected else { return done("The host isn't connected.") }
        c.propose(.preferences(preferences), done: done)
    }

    func newTerminal(on host: HostID, cwd: String?) -> BlockID {
        (client(host) ?? local).newTerminal(cwd: cwd)
    }

    func textBlock(for path: String, on host: HostID) -> BlockID {
        (client(host) ?? local).textBlock(for: path)
    }

    /// A shown file's text, read in if it never came, asked until it is.
    func ensureRead(_ block: BlockID) {
        (client(of: block) ?? local).ensureRead(block)
    }

    func directoryBlock(for path: String, on host: HostID) -> BlockID {
        (client(host) ?? local).directoryBlock(for: path)
    }

    /// The pen for a block this client may lead, on focusing it (§8.2).
    func own(_ block: BlockID) { client(of: block)?.own(.block(block)) }

    func link(from: BlockID, to: BlockID, kind: LinkKind, context: String? = nil) {
        (client(of: from) ?? local).link(from: from, to: to, kind: kind, context: context)
    }

    // MARK: Attaching

    /// Attaches to a destination: on a background thread, asks it what it
    /// is, installs our server there if it isn't already, and bridges to it;
    /// then the host is one of ours, remembered for next time.
    /// `known`: a remembered host's id and label, so it stands in the
    /// app at once — connecting, then there, or unreachable with what
    /// was last seen — and is tried again every so often.
    func attach(_ dest: Destination, known: HostID? = nil, label: String? = nil, reset: Bool = false,
                completion: @escaping (Result<HostID, Error>) -> Void) {
        let key = dest.description
        guard !attaching.contains(key) else { return }
        attaching.insert(key)
        errors.removeValue(forKey: key)
        let name = label ?? uniqueName(dest.suggestedHostName)
        // The host stands in the app at once — connecting, then there, or
        // unreachable — a remembered one under its id, one attached to
        // for the first time under its name until it says its id.
        let isNew = known == nil
        let standingID = known ?? HostID(name)
        let standing: HostClient = remotes[standingID] ?? {
            let c = HostClient(transport: .remote(dest, name: name), known: standingID)
            wire(c)
            remotes[standingID] = c
            return c
        }()
        standing.onNeedsBootstrap = { [weak self, weak standing] in
            guard let self, let standing, self.remotes.values.contains(where: { $0 === standing }) else { return }
            self.attach(dest, known: standing.host, label: name) { _ in }
        }
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Child, Error>
            do {
                result = .success(try HostClient.bootstrap(dest, name: name, reset: reset, step: { [weak standing] what in
                    DispatchQueue.main.async { standing?.begin(what) }
                }, progress: { [weak standing] done, total in
                    DispatchQueue.main.async { standing?.progress(done, of: total) }
                }))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                // Detached while being reached: what came of it goes, and
                // the destination is free to attach to again.
                if self.remotes[standingID] !== standing {
                    if case .success(let child) = result { Self.discard(child) }
                    return
                }
                self.attaching.remove(key)
                switch result {
                case .failure(let error):
                    self.errors[key] = "\(error)"
                    if isNew {
                        // Never reached, never remembered: it goes, and says why.
                        self.remotes.removeValue(forKey: standingID)
                        standing.disconnect()
                    } else {
                        standing.markUnreachable("\(error)")
                        // Again in a while — longer each time — as long as
                        // it's still wanted.
                        standing.scheduleRetry(after: standing.nextRetryDelay()) { [weak self] in
                            guard let self, self.remotes[standingID] === standing, standing.link != .connected else { return }
                            self.attach(dest, known: standingID, label: name) { _ in }
                        }
                    }
                    self.onChange?()
                    completion(.failure(error))
                case .success(let child):
                    let client = standing
                    client.onWelcome = { [weak self, weak client] in
                        guard let self, let client else { return }
                        // The host names itself (§8): its session id is its key.
                        if standingID != client.host, self.remotes[standingID] === client { self.remotes.removeValue(forKey: standingID) }
                        self.remotes[client.host] = client
                        var file = HostsFile.load()
                        // The same destination under an older key (its name,
                        // before sessions) goes.
                        file.hosts = file.hosts.filter { $0.key == client.host.raw || $0.value.destination != dest }
                        file.hosts[client.host.raw] = HostEntry(destination: dest, label: client.label ?? name)
                        file.save()
                        self.onChange?()
                        completion(.success(client.host))
                    }
                    client.adopt(child)
                }
            }
        }
    }

    /// Reset Server: the host's server uploaded afresh, whatever is
    /// there, and restarted — its shells end, its terminals start new ones
    /// in their folders. For a server that's wedged, or not the one it
    /// should be. The host stays remembered; its client is made anew.
    func resetServer(_ host: HostID) {
        guard let client = remotes[host], let dest = client.destination else { return }
        let label = HostsFile.load().hosts[host.raw]?.label ?? client.label ?? dest.suggestedHostName
        remotes.removeValue(forKey: host)
        client.disconnect()
        attaching.remove(dest.description)
        errors.removeValue(forKey: dest.description)
        attach(dest, known: host, label: label, reset: true) { _ in }
    }

    /// Reset Graph: the host's links and trail forgotten, its graph left
    /// empty (workspaces keep what's on them).
    func resetGraph(on host: HostID, done: ((String?) -> Void)? = nil) {
        guard let c = client(host), c.isConnected else { done?("The host isn't connected."); return }
        c.propose(.resetGraph, done: done)
    }

    // MARK: Waking and moving networks

    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    private var nudgeWork: DispatchWorkItem?

    /// After sleep, or when the network comes back or changes (another
    /// Wi-Fi, a VPN up or down), the hosts are tried at once rather than
    /// when their back-off ends: remote terminals come back as the lid opens.
    func watchNetwork() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.nudgeHosts(after: 2)
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let key = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPath = key }
                guard let last = self.lastPath, last != key, path.status == .satisfied else { return }
                self.nudgeHosts(after: 1)
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    /// Each host asked to try (or check) now, once things have settled.
    func nudgeHosts(after delay: TimeInterval) {
        nudgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            for c in self?.all ?? [] { c.networkMayHaveChanged() }
        }
        nudgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Attaches again to every host remembered.
    func reattachRemembered() {
        for (id, entry) in HostsFile.load().hosts where remotes[HostID(id)] == nil {
            attach(entry.destination, known: HostID(id), label: entry.label) { _ in }
        }
    }

    /// How a host stands: this Mac's is always there.
    func link(of host: HostID) -> HostClient.Standing {
        client(host)?.link ?? .unreachable(nil)
    }

    /// Whether blocks on the host can be worked on now.
    func isReachable(_ host: HostID) -> Bool { link(of: host) == .connected }

    /// Detaches from a host and forgets it, so it isn't attached again at
    /// start; its server and blocks stay there. A host still being
    /// reached is given up on.
    func detach(_ host: HostID) {
        guard let client = remotes.removeValue(forKey: host) else { return }
        client.disconnect()
        var file = HostsFile.load()
        file.hosts.removeValue(forKey: host.raw)
        if let dest = client.destination {
            file.hosts = file.hosts.filter { $0.value.destination != dest }
            attaching.remove(dest.description)
            errors.removeValue(forKey: dest.description)
        }
        file.save()
        onChange?()
    }

    /// A bridge no longer wanted: ended, and reaped.
    private static func discard(_ child: Child) {
        close(child.input)
        close(child.output)
        kill(child.pid, SIGTERM)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(child.pid, &status, 0)
        }
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while name == local.host.raw || remotes.values.contains(where: { $0.label == name }) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }
}
