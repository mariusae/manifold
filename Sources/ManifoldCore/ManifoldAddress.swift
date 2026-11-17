import Foundation

/// `manifold://` addresses: what another app is given for what's in
/// Manifold — a block, and a place in it (`manifold://host/<ulid>#line=12`),
/// or a file on a host Manifold has no block for yet
/// (`manifold://host/abs/path`) — which macOS hands back to Manifold to
/// open. A file on this Mac isn't one: it stays a file. The older form
/// without the slashes (`manifold:host/<ulid>`), as notes hold references,
/// is read the same.
public enum ManifoldAddress {
    public enum Target: Equatable {
        case block(BlockID, fragment: String?)
        case file(host: HostID, path: String, fragment: String?)
    }

    /// A block's address, at a place in it.
    public static func of(_ block: BlockID, fragment: String? = nil) -> String {
        "manifold://" + block.description + (fragment.map { "#" + $0 } ?? "")
    }

    /// A file's (or folder's, which ends in a slash) on a host, at a place in it.
    public static func of(file path: String, on host: HostID, isDirectory: Bool = false, fragment: String? = nil) -> String {
        var p = path.hasPrefix("/") ? path : "/" + path
        if isDirectory, !p.hasSuffix("/") { p += "/" }
        let encoded = p.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? p
        return "manifold://" + host.description + encoded + (fragment.map { "#" + $0 } ?? "")
    }

    /// What an address names: a block if what follows its host is an id,
    /// else a file there; nil for anything else.
    public static func parse(_ address: String) -> Target? {
        let s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("manifold:") else { return nil }
        var rest = s.dropFirst(9)
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash]), tail = String(rest[rest.index(after: slash)...])
        guard !host.isEmpty, !tail.isEmpty else { return nil }
        if isULID(tail) { return .block(BlockID(host: HostID(host), ulid: tail), fragment: fragment) }
        let path = "/" + (tail.removingPercentEncoding ?? tail)
        return .file(host: HostID(host), path: path, fragment: fragment)
    }

    /// A block's id as ids are made (ULID: 26 of Crockford's base 32).
    static func isULID(_ s: String) -> Bool {
        s.utf8.count == 26 && s.utf8.allSatisfy { c in
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90 && c != 73 && c != 76 && c != 79 && c != 85)
        }
    }

    /// A path's characters kept as they are: a URL path's, less `#` and `?`
    /// (and `%`, so a name holding one comes back as it was).
    private static let pathAllowed: CharacterSet = {
        var c = CharacterSet.urlPathAllowed
        c.remove(charactersIn: "#?%")
        return c
    }()
}
