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
    var onHistory: ((ShardID, [Entry]) -> Void)?
    /// A `manifold` command on `host` asks for paths to be opened.
    var onOpen: ((HostID, Int, Int, [String], BlockID?, Bool) -> Void)?

    init() {
        local = HostClient(transport: .local)
        wire(local)
    }

    private func wire(_ client: HostClient) {
        client.onChange = { [weak self] in self?.onChange?() }
        client.onTerminalEnded = { [weak self] block in self?.onTerminalEnded?(block) }
        client.onHistory = { [weak self] shard, entries in self?.onHistory?(shard, entries) }
        client.onOpen = { [weak self, weak client] id, who, paths, beside, wait in
            guard let self, let client else { return }
            self.onOpen?(client.host, id, who, paths, beside, wait)
        }
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

    // MARK: Writing

    func append(_ events: [Event], to shard: ShardID) {
        (client(shard.host) ?? local).append(events, to: shard)
    }

    func append(_ event: Event, to shard: ShardID) { append([event], to: shard) }

    /// Sends a proposal to the host it concerns.
    func propose(_ proposal: Proposal, done: ((String?) -> Void)? = nil) {
        switch proposal {
        case let .newTerminal(block, _), let .endTerminal(block), let .readFile(block), let .writeFile(block, _, _),
             let .directory(block, _), let .listDirectory(block):
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
        case .openDone:
            local.propose(proposal, done: done)
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

    func link(from: BlockID, to: BlockID, kind: LinkKind) {
        (client(of: from) ?? local).link(from: from, to: to, kind: kind)
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
