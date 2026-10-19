import Foundation

/// A host's server is a **session**, and it names itself (DESIGN.md §8):
/// an id minted once, kept in its data directory, that every block made
/// there carries in its id (`session/ulid`). Names people use for hosts
/// are labels, kept by whoever attaches. A server that began life before
/// sessions, named by its first client or `local`, is given an id and its
/// logs rewritten to it once.
public enum HostSession {
    /// Ten characters of Crockford base32, lowercase, from random bytes:
    /// unique enough for the hosts one person has, and readable.
    public static func mint() -> HostID {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        var bytes = [UInt8](repeating: 0, count: 10)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return HostID("h" + String(bytes.map { alphabet[Int($0) % 32] }))
    }

    /// The session id in `file`, if one has been minted.
    public static func read(_ file: URL) -> HostID? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : HostID(s)
    }

    /// The host's session id, minted the first time; a server with logs
    /// under an older name (`local`, or as a client named it) has them
    /// rewritten to the new id, and that name kept as its label.
    public static func identify(directory: URL, logs: URL) -> (id: HostID, label: String?) {
        let sessionFile = directory.appendingPathComponent("session")
        let labelFile = directory.appendingPathComponent("label")
        let nameFile = directory.appendingPathComponent("host")
        var label = read(labelFile)?.raw
        if let id = read(sessionFile) { return (id, label) }
        let id = mint()
        let old = read(nameFile) ?? .local
        if label == nil, old != .local { label = old.raw }
        let shards = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
        if !shards.isEmpty { rewriteHost(in: logs, from: old, to: id) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(id.raw.utf8).write(to: sessionFile)
        if let label { try? Data(label.utf8).write(to: labelFile) }
        return (id, label)
    }

    // MARK: Rewriting logs to a new host id

    /// Every file in `logs` with `old` in its name is renamed, and every
    /// string in it that is `old`, or a block id under it, is rewritten;
    /// a snapshot's offset into its log is moved with the log.
    public static func rewriteHost(in logs: URL, from old: HostID, to new: HostID) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        var offsetMaps: [String: [UInt64: UInt64]] = [:]
        // Logs first, remembering where each old offset landed.
        for name in names where name.hasSuffix(".log") {
            let base = (name as NSString).deletingPathExtension
            guard let shard = ShardID(fileName: base), shard.host == old, let data = try? Data(contentsOf: logs.appendingPathComponent(name)) else { continue }
            let (out, map) = rewriteLog(data, from: old, to: new)
            offsetMaps[base] = map
            try? out.write(to: logs.appendingPathComponent(renamed(shard, to: new).fileName + ".log"), options: .atomic)
            try? fm.removeItem(at: logs.appendingPathComponent(name))
        }
        for name in names where name.hasSuffix(".snap") || name.hasSuffix(".base") {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let shard = ShardID(fileName: base), shard.host == old, let data = try? Data(contentsOf: logs.appendingPathComponent(name)) else { continue }
            var out = rewritePlist(data, from: old, to: new) ?? data
            if ext == "snap", let map = offsetMaps[base],
               var object = try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any],
               let offset = (object["logOffset"] as? NSNumber)?.uint64Value {
                object["logOffset"] = NSNumber(value: map[offset] ?? 0)
                if let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) { out = data }
            }
            try? out.write(to: logs.appendingPathComponent(renamed(shard, to: new).fileName + "." + ext), options: .atomic)
            try? fm.removeItem(at: logs.appendingPathComponent(name))
        }
    }

    private static func renamed(_ shard: ShardID, to new: HostID) -> ShardID {
        switch shard {
        case .block(let id): .block(BlockID(host: new, ulid: id.ulid))
        case .desk: .desk(new)
        case .registry: .registry(new)
        case .links: .links(new)
        }
    }

    /// A log's frames rewritten one by one.
    static func rewriteLog(_ data: Data, from old: HostID, to new: HostID) -> (data: Data, offsets: [UInt64: UInt64]) {
        var out = Data()
        var map: [UInt64: UInt64] = [:]
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            map[UInt64(i - data.startIndex)] = UInt64(out.count)
            let n = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
            guard n > 0, i + 4 + n <= data.endIndex else { break }
            let frame = data.subdata(in: i + 4..<i + 4 + n)
            let rewritten = rewritePlist(frame, from: old, to: new) ?? frame
            var len = UInt32(rewritten.count).littleEndian
            out.append(Data(bytes: &len, count: 4))
            out.append(rewritten)
            i += 4 + n
        }
        map[UInt64(data.count)] = UInt64(out.count)
        return (out, map)
    }

    /// A property list with every host string rewritten: `old` itself, and
    /// block ids `old/ULID`.
    static func rewritePlist(_ data: Data, from old: HostID, to new: HostID) -> Data? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        let rewritten = rewrite(object, from: old.raw, to: new.raw)
        return try? PropertyListSerialization.data(fromPropertyList: rewritten, format: .binary, options: 0)
    }

    private static func rewrite(_ object: Any, from old: String, to new: String) -> Any {
        switch object {
        case let s as String: return rewrite(s, from: old, to: new)
        case let a as [Any]: return a.map { rewrite($0, from: old, to: new) }
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[rewrite(k, from: old, to: new)] = rewrite(v, from: old, to: new) }
            return out
        default: return object
        }
    }

    private static func rewrite(_ s: String, from old: String, to new: String) -> String {
        if s == old { return new }
        let prefix = old + "/"
        if s.hasPrefix(prefix) {
            let rest = s.dropFirst(prefix.count)
            if rest.count == 26, rest.allSatisfy({ $0.isNumber || ($0.isLetter && $0.isUppercase) }) { return new + "/" + rest }
        }
        return s
    }
}

/// A host as a client knows it: how it is reached, and what to call it.
public struct HostEntry: Codable, Equatable, Sendable {
    public var destination: Destination
    public var label: String?

    public init(destination: Destination, label: String? = nil) {
        self.destination = destination
        self.label = label
    }
}
