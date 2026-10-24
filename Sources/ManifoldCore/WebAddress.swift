import Foundation

/// What's typed in a page's address bar, made sense of: an address to load
/// (`localhost:3000`, `10.0.0.5`, `example.com/x` as a browser takes them,
/// with or without their scheme), a port on an attached host's own
/// localhost (`slowbox:3000/x`, forwarded here and loaded), or words to
/// search for.
public enum WebAddress: Equatable {
    case page(String)
    /// `name:port` and what follows (a path, from its slash): the name may
    /// be a host's (its label), else it's an address like any other.
    case hostPort(name: String, port: Int, rest: String)
    case search(String)

    private static let namePort = try! NSRegularExpression(pattern: #"^([A-Za-z0-9][A-Za-z0-9._-]*|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})(/.*)?$"#)

    public static func parse(_ typed: String) -> WebAddress {
        let s = typed.trimmingCharacters(in: .whitespaces)
        if s.contains("://") || s.range(of: #"^(about|mailto|file|data):"#, options: .regularExpression) != nil { return .page(s) }
        if s.isEmpty || s.contains(where: \.isWhitespace) { return .search(s) }
        let ns = s as NSString
        if let m = Self.namePort.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
           let port = Int(ns.substring(with: m.range(at: 2))), (1...65535).contains(port) {
            let rest = m.range(at: 3).location == NSNotFound ? "/" : ns.substring(with: m.range(at: 3))
            return .hostPort(name: ns.substring(with: m.range(at: 1)), port: port, rest: rest)
        }
        // This Mac's (or the network's) by name or number: plain http, as a dev server is.
        if s.range(of: #"^(localhost|\d{1,3}(\.\d{1,3}){3}|\[[0-9A-Fa-f:]+\])([:/].*)?$"#, options: .regularExpression) != nil {
            return .page("http://" + s)
        }
        return s.contains(".") ? .page("https://" + s) : .search(s)
    }

    /// Whether a command's argument is a web address rather than a path:
    /// with a scheme of the web's, or localhost and a port.
    public static func looksLikeURL(_ s: String) -> Bool {
        s.hasPrefix("http://") || s.hasPrefix("https://") || s.range(of: #"^localhost:\d+"#, options: .regularExpression) != nil
    }

    /// An address as it's shown and matched: without its scheme, a
    /// leading www., or a lone trailing slash.
    public static func plain(_ address: String) -> String {
        var s = address
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/"), s.filter({ $0 == "/" }).count == 1 { s.removeLast() }
        return s
    }
}
