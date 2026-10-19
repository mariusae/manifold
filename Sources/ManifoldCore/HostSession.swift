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
    /// rewritten to the new id, and that name kept as its label. Logs
    /// still under the old name on a later start — a rewrite cut short —
    /// are rewritten then.
    public static func identify(directory: URL, logs: URL) -> (id: HostID, label: String?) {
        let sessionFile = directory.appendingPathComponent("session")
        let labelFile = directory.appendingPathComponent("label")
        let nameFile = directory.appendingPathComponent("host")
        var label = read(labelFile)?.raw
        let minted = read(sessionFile)
        let id = minted ?? mint()
        let old = read(nameFile) ?? .local
        if minted == nil, label == nil, old != .local { label = old.raw }
        if old != id, hasShards(in: logs, of: old) { rewriteHost(in: logs, from: old, to: id) }
        if minted == nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(id.raw.utf8).write(to: sessionFile)
            if let label { try? Data(label.utf8).write(to: labelFile) }
        }
        return (id, label)
    }

    /// Whether any log file in `logs` is a shard of `host`.
    static func hasShards(in logs: URL, of host: HostID) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
        return names.contains { name in
            guard name.hasSuffix(".log") else { return false }
            return ShardID(fileName: String(name.dropLast(4)))?.host == host
        }
    }

    // MARK: Rewriting logs to a new host id

    /// Every file in `logs` with `old` in its name is renamed, and every
    /// string in it that is `old`, or a block id under it, is rewritten;
    /// a snapshot's offset into its log is moved with the log. Files
    /// already under `new` are gone through too, for what a rewrite cut
    /// short, or an older one, left in them. Logs are streamed, frame by
    /// frame, so one of any size takes little memory; each is replaced
    /// whole, so a rewrite cut short leaves every file either as it was
    /// or done. A log under the old name whose counterpart under the new
    /// one already exists is set aside (`.superseded`), never written over.
    public static func rewriteHost(in logs: URL, from old: HostID, to new: HostID) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        var landed: [String: UInt64] = [:]
        var aside: Set<String> = []
        // Logs first, remembering where each snapshot's offset landed.
        for name in names where name.hasSuffix(".log") {
            let base = (name as NSString).deletingPathExtension
            guard let shard = ShardID(fileName: base), shard.host == old || shard.host == new else { continue }
            let src = logs.appendingPathComponent(name)
            let dst = logs.appendingPathComponent(renamed(shard, to: new).fileName + ".log")
            let tmp = logs.appendingPathComponent(renamed(shard, to: new).fileName + ".log.rewriting")
            if shard.host == old, fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: logs.appendingPathComponent(name + ".superseded"))
                aside.insert(base)
                continue
            }
            let wanted = snapshotOffset(logs.appendingPathComponent(base + ".snap"))
            let size = (try? fm.attributesOfItem(atPath: src.path))?[.size] as? UInt64 ?? 0
            FileHandle.standardError.write(Data("rewriting \(name) (\(size) bytes) for \(new.raw)\n".utf8))
            guard let at = rewriteLog(from: src, to: tmp, old: old, new: new, wanting: wanted) else {
                try? fm.removeItem(at: tmp)
                continue
            }
            if src != dst { try? fm.removeItem(at: dst) }
            guard (try? fm.replaceItemAt(dst, withItemAt: tmp)) != nil || (try? fm.moveItem(at: tmp, to: dst)) != nil else { continue }
            if src != dst { try? fm.removeItem(at: src) }
            if let at { landed[base] = at }
        }
        for name in names where name.hasSuffix(".snap") || name.hasSuffix(".base") {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let shard = ShardID(fileName: base), shard.host == old || shard.host == new else { continue }
            if aside.contains(base) {
                try? fm.moveItem(at: logs.appendingPathComponent(name), to: logs.appendingPathComponent(name + ".superseded"))
                continue
            }
            guard let data = try? Data(contentsOf: logs.appendingPathComponent(name)) else { continue }
            var out = rewritePlist(data, from: old, to: new) ?? data
            if ext == "snap", var object = try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any] {
                // Unless its log was found again just now, the snapshot's
                // offset is lost with the log's shape: the whole is replayed.
                object["logOffset"] = NSNumber(value: landed[base] ?? (shard.host == new ? (object["logOffset"] as? NSNumber)?.uint64Value ?? 0 : 0))
                if let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) { out = data }
            }
            try? out.write(to: logs.appendingPathComponent(renamed(shard, to: new).fileName + "." + ext), options: .atomic)
            if shard.host == old { try? fm.removeItem(at: logs.appendingPathComponent(name)) }
        }
    }

    private static func snapshotOffset(_ snap: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: snap),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (object["logOffset"] as? NSNumber)?.uint64Value
    }

    private static func renamed(_ shard: ShardID, to new: HostID) -> ShardID {
        switch shard {
        case .block(let id): .block(BlockID(host: new, ulid: id.ulid))
        case .desk: .desk(new)
        case .registry: .registry(new)
        case .links: .links(new)
        }
    }

    /// A log's frames rewritten one by one from `src` into `dst`, streamed.
    /// Returns where the offset `wanted` (a snapshot's, into `src`) landed
    /// in `dst`, or nil if the log couldn't be read or written.
    static func rewriteLog(from src: URL, to dst: URL, old: HostID, new: HostID, wanting wanted: UInt64?) -> UInt64?? {
        guard let input = try? FileHandle(forReadingFrom: src) else { return nil }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: dst) else { return nil }
        defer { try? output.close() }
        let chunk = 4 << 20
        var buffer = Data()
        var pending = Data()
        var read: UInt64 = 0      // bytes of src consumed into frames
        var written: UInt64 = 0   // bytes of dst, counting what's pending
        var at: UInt64?
        if wanted == 0 { at = 0 }
        var done = false
        while !done {
            if let more = try? input.read(upToCount: chunk), !more.isEmpty { buffer.append(more) } else { done = true }
            var i = buffer.startIndex
            while i + 4 <= buffer.endIndex {
                let n = Int(buffer[i]) | Int(buffer[i + 1]) << 8 | Int(buffer[i + 2]) << 16 | Int(buffer[i + 3]) << 24
                guard n > 0 else { done = true; break }
                guard i + 4 + n <= buffer.endIndex else { break }
                // Each frame's property list objects released as we go:
                // nothing else drains them before the server's loop runs.
                let count: Int = autoreleasepool {
                    let frame = buffer.subdata(in: i + 4..<i + 4 + n)
                    let rewritten = rewritePlist(frame, from: old, to: new) ?? frame
                    var len = UInt32(rewritten.count).littleEndian
                    pending.append(Data(bytes: &len, count: 4))
                    pending.append(rewritten)
                    return rewritten.count
                }
                i += 4 + n
                read += UInt64(4 + n)
                written += UInt64(4 + count)
                if wanted == read { at = written }
            }
            buffer.removeSubrange(buffer.startIndex..<i)
            if pending.count >= 1 << 20 || done {
                guard (try? output.write(contentsOf: pending)) != nil else { return nil }
                pending.removeAll(keepingCapacity: true)
            }
        }
        return .some(at)
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
            // A block id: a ULID, or a UUID from before them.
            let rest = s.dropFirst(prefix.count)
            if !rest.isEmpty, rest.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) { return new + "/" + rest }
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
