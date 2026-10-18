import Foundation

/// Brings a `state.json` from before blocks (tabs of columns of panes) into
/// logs: each tab an arrangement, each pane a block (terminals keeping
/// their ids, so their transcripts carry over), each editor's draft its
/// text's unsaved version.
public enum Migration {
    struct LegacyWorkspace: Decodable {
        var tabs: [LegacyTab]
        var selectedTab: UUID?
        var window: WindowState?
        var appearance: Appearance?
    }

    struct LegacyTab: Decodable {
        var id: UUID
        var customTitle: String?
        var columns: [LegacyColumn]?
        var panes: [LegacyPane]?
        var focusedPane: UUID?
        var fractions: [Double]?
    }

    struct LegacyColumn: Decodable {
        var id: UUID
        var panes: [LegacyPane]
    }

    struct LegacyPane: Decodable {
        var id: UUID
        var kind: String
        var title: String?
        var cwd: String?
        var path: String?
    }

    struct LegacyEditorState: Decodable {
        var draft: String?
    }

    /// The entries to write, shard by shard, in order.
    public static func migrate(stateJSON: Data, editorsDirectory: URL?, readFile: (String) -> String?,
                               host: HostID, clock: Clock) -> [(ShardID, [Entry])] {
        guard let ws = try? JSONDecoder().decode(LegacyWorkspace.self, from: stateJSON) else { return [] }
        var out: [(ShardID, [Entry])] = []
        var seqs: [ShardID: Int] = [:]
        func emit(_ shard: ShardID, _ event: Event) {
            let seq = (seqs[shard] ?? 0) + 1
            seqs[shard] = seq
            let entry = Entry(seq: seq, at: clock.now(), event: event)
            if let i = out.firstIndex(where: { $0.0 == shard }) { out[i].1.append(entry) } else { out.append((shard, [entry])) }
        }

        var textBlocks: [String: BlockID] = [:]
        var registry: [RegistryEntry] = []
        var order: [BlockID] = []
        var arrangementOf: [UUID: BlockID] = [:]

        for tab in ws.tabs {
            let arrangement = BlockID(host: host, ulid: tab.id.uuidString)
            arrangementOf[tab.id] = arrangement
            let shard = ShardID.block(arrangement)
            emit(shard, .create(kind: .arrangement, title: tab.customTitle, path: nil))
            let columns = tab.columns ?? (tab.panes ?? []).map { LegacyColumn(id: UUID(), panes: [$0]) }
            var focusedPlacement: PlacementID?
            for (c, column) in columns.enumerated() {
                for pane in column.panes {
                    let block: BlockID
                    let lens: Lens
                    switch pane.kind {
                    case "terminal":
                        block = BlockID(host: host, ulid: pane.id.uuidString)
                        lens = .terminal
                        let bs = ShardID.block(block)
                        emit(bs, .create(kind: .terminal, title: nil, path: nil))
                        if let cwd = pane.cwd { emit(bs, .cwd(cwd)) }
                        if let t = pane.title { emit(bs, .title(t)) }
                        registry.append(RegistryEntry(id: block, kind: .terminal, title: pane.title, created: clock.now(), lastSeen: clock.now()))
                    default:
                        guard let path = pane.path else { continue }
                        lens = pane.kind == "markdown" ? .preview : .editor
                        if let existing = textBlocks[path] {
                            block = existing
                        } else {
                            block = BlockID(host: host)
                            textBlocks[path] = block
                            let bs = ShardID.block(block)
                            emit(bs, .create(kind: .text, title: nil, path: path))
                            let disk = readFile(path) ?? ""
                            emit(bs, .content(disk, encoding: "utf-8", lineEnding: "\n", fingerprint: Fingerprint.of(disk)))
                            if let dir = editorsDirectory,
                               let data = try? Data(contentsOf: dir.appendingPathComponent("\(pane.id.uuidString).json")),
                               let state = try? JSONDecoder().decode(LegacyEditorState.self, from: data),
                               let draft = state.draft, draft != disk {
                                emit(bs, .content(draft, encoding: "utf-8", lineEnding: "\n", fingerprint: nil))
                            }
                            registry.append(RegistryEntry(id: block, kind: .text, path: path, created: clock.now(), lastSeen: clock.now()))
                        }
                    }
                    let placement = Placement(block: block, lens: lens)
                    emit(shard, .place(placement, column: c, at: Int.max / 2))
                    if pane.id == tab.focusedPane { focusedPlacement = placement.id }
                }
            }
            if let f = tab.fractions, f.count == columns.count { emit(shard, .fractions(f)) }
            if let f = focusedPlacement { emit(shard, .focus(f)) }
            registry.append(RegistryEntry(id: arrangement, kind: .arrangement, title: tab.customTitle, created: clock.now(), lastSeen: clock.now()))
            order.append(arrangement)
        }

        let desk = ShardID.desk(host)
        emit(desk, .order(order))
        if let s = ws.selectedTab.flatMap({ arrangementOf[$0] }) { emit(desk, .select(s)) }
        if let w = ws.window { emit(desk, .window(w)) }
        if let a = ws.appearance { emit(desk, .appearance(a)) }
        let reg = ShardID.registry(host)
        for e in registry { emit(reg, .register(e)) }
        return out
    }
}

/// Enough to tell whether a file's text changed.
public enum Fingerprint {
    public static func of(_ s: String) -> String { of(Array(s.utf8)) }

    public static func of<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(bytes.count)-\(String(hash, radix: 16))"
    }
}
