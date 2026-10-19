import Foundation

/// The encoding shared by the logs on disk and the wire: the same `Codable`
/// types as binary property lists, which are compact and need no schema.
public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return try e.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}

/// A host's logs on disk: one append-only file per shard, each entry a
/// length-prefixed record, with a snapshot beside it that says how far
/// into the log it reaches, so starting up reads only the tail.
public final class LogStore {
    public let directory: URL
    private var handles: [ShardID: FileHandle] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func logURL(_ shard: ShardID) -> URL { directory.appendingPathComponent(shard.fileName + ".log") }
    private func snapURL(_ shard: ShardID) -> URL { directory.appendingPathComponent(shard.fileName + ".snap") }
    /// The state at the start of a compacted log (§4): history begins here.
    private func baseURL(_ shard: ShardID) -> URL { directory.appendingPathComponent(shard.fileName + ".base") }

    /// Every shard with a log here.
    public func shards() -> [ShardID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".log") }.compactMap { ShardID(fileName: String($0.dropLast(4))) }
    }

    struct SnapshotFile: Codable {
        var snapshot: ShardSnapshot
        /// Where in the log the entries after the snapshot begin.
        var logOffset: UInt64
    }

    /// Loads a shard into `node`: its snapshot, then the entries after it.
    /// Returns false if there was nothing readable.
    @discardableResult
    public func load(_ shard: ShardID, into node: Node) -> Bool {
        var offset: UInt64 = 0
        if let data = try? Data(contentsOf: snapURL(shard)), let snap = try? Codec.decode(SnapshotFile.self, from: data) {
            node.load(snap.snapshot)
            offset = snap.logOffset
        }
        guard let handle = try? FileHandle(forReadingFrom: logURL(shard)) else { return node.has(shard) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let n = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
            guard n > 0, i + 4 + n <= data.endIndex else { break }
            if let entry = try? Codec.decode(Entry.self, from: data.subdata(in: i + 4..<i + 4 + n)) {
                node.apply(entry, to: shard)
            }
            i += 4 + n
        }
        return node.has(shard)
    }

    /// A shard's history: the state its log begins from, if the log was
    /// compacted, and every entry since.
    public func history(_ shard: ShardID) -> (base: ShardSnapshot?, entries: [Entry]) {
        (base(shard), entries(shard))
    }

    public func base(_ shard: ShardID) -> ShardSnapshot? {
        guard let data = try? Data(contentsOf: baseURL(shard)) else { return nil }
        return try? Codec.decode(ShardSnapshot.self, from: data)
    }

    /// Folds entries older than `cutoff` into a base state, keeping the
    /// rest, so a log holds only as much history as the settings say. The
    /// node's current state is what the snapshot keeps; the base is what
    /// history (and scrubbing) start from.
    public func compact(_ shard: ShardID, before cutoff: Stamp, node: Node) {
        let all = entries(shard)
        let k = all.firstIndex { $0.at >= cutoff } ?? all.count
        guard k > 0 else { return }
        let replay = Node()
        if let base = base(shard) { replay.load(base) }
        for e in all[..<k] where !replay.apply(e, to: shard) {
            // A gap the base doesn't cover: leave the log alone.
            return
        }
        guard let newBase = replay.snapshot(shard) else { return }
        try? handles.removeValue(forKey: shard)?.close()
        var out = Data()
        for e in all[k...] {
            guard let bytes = try? Codec.encode(e) else { continue }
            var n = UInt32(bytes.count).littleEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        guard let baseData = try? Codec.encode(newBase) else { return }
        try? baseData.write(to: baseURL(shard), options: .atomic)
        try? out.write(to: logURL(shard), options: .atomic)
        // The snapshot is the state now, past the whole (shorter) log.
        if let snap = node.snapshot(shard), let data = try? Codec.encode(SnapshotFile(snapshot: snap, logOffset: UInt64(out.count))) {
            try? data.write(to: snapURL(shard), options: .atomic)
        }
    }

    /// Folds a shard's whole log into its base, leaving the log empty:
    /// for shards whose entries only replace one another (a git block's
    /// refreshes), history isn't worth the room. Nothing is read.
    public func fold(_ shard: ShardID, node: Node) {
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL(shard).path))?[.size] as? UInt64 ?? 0
        guard size > 0, let snap = node.snapshot(shard), let baseData = try? Codec.encode(snap),
              let snapData = try? Codec.encode(SnapshotFile(snapshot: snap, logOffset: 0)) else { return }
        try? handles.removeValue(forKey: shard)?.close()
        try? baseData.write(to: baseURL(shard), options: .atomic)
        try? snapData.write(to: snapURL(shard), options: .atomic)
        try? Data().write(to: logURL(shard), options: .atomic)
    }

    /// Every entry in a shard's log, from the beginning (for history).
    public func entries(_ shard: ShardID) -> [Entry] {
        guard let data = try? Data(contentsOf: logURL(shard)) else { return [] }
        var out: [Entry] = []
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let n = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
            guard n > 0, i + 4 + n <= data.endIndex else { break }
            if let entry = try? Codec.decode(Entry.self, from: data.subdata(in: i + 4..<i + 4 + n)) { out.append(entry) }
            i += 4 + n
        }
        return out
    }

    public func append(_ entries: [Entry], to shard: ShardID) {
        guard !entries.isEmpty else { return }
        let handle: FileHandle
        if let h = handles[shard] {
            handle = h
        } else {
            let url = logURL(shard)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            try? h.seekToEnd()
            handles[shard] = h
            handle = h
        }
        var out = Data()
        for e in entries {
            guard let bytes = try? Codec.encode(e) else { continue }
            var n = UInt32(bytes.count).littleEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        try? handle.write(contentsOf: out)
    }

    /// Writes a shard's snapshot, marking the log as read up to its end.
    public func snapshot(_ node: Node, _ shard: ShardID) {
        guard let snap = node.snapshot(shard) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL(shard).path))?[.size] as? UInt64 ?? 0
        let file = SnapshotFile(snapshot: snap, logOffset: size)
        if let data = try? Codec.encode(file) {
            try? data.write(to: snapURL(shard), options: .atomic)
        }
    }

    public func delete(_ shard: ShardID) {
        try? handles.removeValue(forKey: shard)?.close()
        try? FileManager.default.removeItem(at: baseURL(shard))
        try? FileManager.default.removeItem(at: logURL(shard))
        try? FileManager.default.removeItem(at: snapURL(shard))
    }

    public func closeAll() {
        for h in handles.values { try? h.close() }
        handles = [:]
    }
}
