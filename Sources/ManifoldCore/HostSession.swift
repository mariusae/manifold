import Foundation

/// A host's server is a **session**, and it names itself (DESIGN.md §8):
/// an id minted once, kept in its data directory, that every block made
/// there carries in its id (`session/ulid`). Names people use for hosts
/// are labels, kept by whoever attaches.
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

    /// The host's session id, minted the first time. A server from before
    /// sessions kept the name its first client gave it in `host`: that's
    /// its label, if it has none yet. (Its logs, under that name, the
    /// format's reset set aside long since.)
    public static func identify(directory: URL) -> (id: HostID, label: String?) {
        let sessionFile = directory.appendingPathComponent(Paths.Name.session)
        let labelFile = directory.appendingPathComponent(Paths.Name.label)
        var label = read(labelFile)?.raw
        if let minted = read(sessionFile) { return (minted, label) }
        let id = mint()
        if label == nil, let old = read(directory.appendingPathComponent(Paths.Name.hostName)), old != .local { label = old.raw }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(id.raw.utf8).write(to: sessionFile)
        if let label { try? Data(label.utf8).write(to: labelFile) }
        return (id, label)
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
