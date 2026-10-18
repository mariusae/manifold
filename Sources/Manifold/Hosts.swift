import AppKit
import ManifoldCore

/// Every host the app is attached to: this machine's, and any reached
/// through a provider (DESIGN.md §8). Blocks are found by their id's host;
/// the desk, settings and new arrangements are the local host's.
final class Hosts {
    let local: HostClient
    private(set) var remotes: [HostID: HostClient] = [:]
    /// Hosts being attached to, by destination, until they say their name.
    private(set) var attaching: Set<String> = []
    private var connecting: [String: HostClient] = [:]
    private(set) var errors: [String: String] = [:]

    var onChange: (() -> Void)?
    var onTerminalEnded: ((BlockID) -> Void)?
    var onHistory: ((ShardID, ShardSnapshot?, [Entry]) -> Void)?
    /// A `manifold` command on `host` asks for paths to be opened.
    var onOpen: ((HostID, Int, Int, [String], BlockID?, Bool) -> Void)?
    var onDiagnostics: ((BlockID) -> Void)?
    var onGutter: ((BlockID) -> Void)?
    var onLanguageServer: ((HostID, String, String, String) -> Void)?
    private var pushedLanguageServers: [HostID: [LanguageServerConfig]] = [:]
    private var editing: Set<BlockID> = []

    init() {
        local = HostClient(transport: .local)
        wire(local)
    }

    private func wire(_ client: HostClient) {
        client.onChange = { [weak self] in self?.onChange?() }
        client.onTerminalEnded = { [weak self] block in self?.onTerminalEnded?(block) }
        client.onHistory = { [weak self] shard, base, entries in self?.onHistory?(shard, base, entries) }
        client.onOpen = { [weak self, weak client] id, who, paths, beside, wait in
            guard let self, let client else { return }
            self.onOpen?(client.host, id, who, paths, beside, wait)
        }
        client.onConnected = { [weak self, weak client] in
            guard let self, let client else { return }
            self.pushedLanguageServers.removeValue(forKey: client.host)
            self.pushLanguageServers()
            client.propose(.editing(self.editing.filter { $0.host == client.host }))
        }
        client.onDiagnostics = { [weak self] block in self?.onDiagnostics?(block) }
        client.onGutter = { [weak self] block in self?.onGutter?(block) }
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
        case let .definition(b, _), let .references(b, _), let .hover(b, _), let .rename(b, _, _), let .format(b, _), let .completion(b, _):
            block = b
        }
        guard let c = client(of: block) else { return done(.error("the block's host isn't attached")) }
        c.lsp(request, done: done)
    }

    var all: [HostClient] { [local] + remotes.values.sorted { $0.host < $1.host } }

    func client(_ host: HostID) -> HostClient? {
        if host == local.host || host == .local { return local }
        return remotes[host]
    }

    func client(of block: BlockID) -> HostClient? { client(block.host) }

    // MARK: Reading, across hosts

    var desk: DeskState { local.desk }
    func block(_ id: BlockID) -> Block? { client(of: id)?.block(id) }
    func arrangement(_ id: BlockID?) -> ArrangementState? { id.flatMap { client(of: $0)?.arrangement($0) } }
    var blocks: [Block] { all.flatMap { $0.node.blocks } }
    func registryEntry(_ id: BlockID) -> RegistryEntry? { client(of: id)?.registry.blocks[id] }
    var links: [Link] { all.flatMap { $0.links.links } }
    func isConnected(_ host: HostID) -> Bool { client(host)?.isConnected ?? false }

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

    func append(_ events: [Event], to shard: ShardID) {
        (client(shard.host) ?? local).append(events, to: shard)
    }

    func append(_ event: Event, to shard: ShardID) { append([event], to: shard) }

    /// Sends a proposal to the host it concerns.
    func propose(_ proposal: Proposal, done: ((String?) -> Void)? = nil) {
        switch proposal {
        case let .newTerminal(block, _), let .endTerminal(block), let .readFile(block), let .writeFile(block, _, _),
             let .directory(block, _), let .listDirectory(block), let .search(block, _), let .cancelSearch(block),
             let .git(block, _), let .refreshGit(block), let .diff(block, _), let .reloadDiff(block),
             let .newAgent(block, _, _), let .readBytes(block), let .processes(block):
            (client(of: block) ?? local).propose(proposal, done: done)
        case let .seen(ids):
            for (host, group) in Dictionary(grouping: ids, by: \.host) {
                client(host)?.propose(.seen(group))
            }
            done?(nil)
        case let .link(link):
            (client(of: link.from) ?? local).propose(proposal, done: done)
        case .unlink:
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

    func newTerminal(on host: HostID, cwd: String?) -> BlockID {
        (client(host) ?? local).newTerminal(cwd: cwd)
    }

    func textBlock(for path: String, on host: HostID) -> BlockID {
        (client(host) ?? local).textBlock(for: path)
    }

    func directoryBlock(for path: String, on host: HostID) -> BlockID {
        (client(host) ?? local).directoryBlock(for: path)
    }

    func link(from: BlockID, to: BlockID, kind: LinkKind, context: String? = nil) {
        (client(of: from) ?? local).link(from: from, to: to, kind: kind, context: context)
    }

    // MARK: Attaching

    /// Attaches to a destination: on a background thread, asks it what it
    /// is, installs our server there if it isn't already, and bridges to it;
    /// then the host is one of ours, remembered for next time.
    func attach(_ dest: Destination, completion: @escaping (Result<HostID, Error>) -> Void) {
        let key = dest.description
        guard !attaching.contains(key) else { return }
        attaching.insert(key)
        errors.removeValue(forKey: key)
        onChange?()
        let name = uniqueName(dest.suggestedHostName)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Child, Error>
            do {
                result = .success(try HostClient.bootstrap(dest, name: name))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.attaching.remove(key)
                switch result {
                case .failure(let error):
                    self.errors[key] = "\(error)"
                    self.onChange?()
                    completion(.failure(error))
                case .success(let child):
                    let client = HostClient(transport: .remote(dest, name: name))
                    self.wire(client)
                    self.connecting[key] = client
                    client.onWelcome = { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.connecting.removeValue(forKey: key)
                        // The host may have a name already, from another client.
                        self.remotes[client.host] = client
                        var file = HostsFile.load()
                        file.hosts[client.host.raw] = dest
                        file.save()
                        self.onChange?()
                        completion(.success(client.host))
                    }
                    client.adopt(child)
                }
            }
        }
    }

    /// Attaches again to every host remembered.
    func reattachRemembered() {
        for (name, dest) in HostsFile.load().hosts where remotes[HostID(name)] == nil {
            attach(dest) { _ in }
        }
    }

    func detach(_ host: HostID) {
        guard let client = remotes.removeValue(forKey: host) else { return }
        client.disconnect()
        var file = HostsFile.load()
        file.hosts.removeValue(forKey: host.raw)
        file.save()
        onChange?()
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while name == local.host.raw || remotes[HostID(name)] != nil {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }
}
