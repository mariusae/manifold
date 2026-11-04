import Foundation

/// Who a host's environment variable is given to (§8.6): every program its
/// server starts, its shells (terminals, notebooks, panels' commands), or
/// its tools (what the server runs for itself: indexers, language servers,
/// git, Sapling) — a proxy only the indexers' fetches need, say.
public enum EnvironmentScope: String, Codable, CaseIterable, Sendable {
    case all, shells, tools

    /// A variable of this scope is given to programs of `kind`.
    public func covers(_ kind: EnvironmentScope) -> Bool { self == .all || kind == .all || self == kind }
}

/// A variable a host's server sets in what it starts (§8.6), kept in its
/// preferences: on the host, wherever it's reached from.
public struct EnvironmentVariable: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var scope: EnvironmentScope

    public init(name: String, value: String, scope: EnvironmentScope = .all) {
        self.name = name
        self.value = value
        self.scope = scope
    }

    /// A name a shell takes: a letter or _ first, then letters, digits, _.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// What the server keeps for itself or sets on its own: not set by hand.
    public static func isReserved(_ name: String) -> Bool {
        name.hasPrefix("MANIFOLD_") || name.hasPrefix("MANI_") || ["HOME", "USER", "LOGNAME", "SHELL", "TERM", "TERMINFO"].contains(name)
    }

    /// A value not to show whole: a secret's name, or a password in an
    /// address (`http://user:pass@proxy`).
    public var isSecret: Bool {
        let n = name.uppercased()
        if ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "CREDENTIAL", "PRIVATE"].contains(where: n.contains) { return true }
        return value.range(of: #"://[^/@\s]+:[^/@\s]+@"#, options: .regularExpression) != nil
    }

    /// The value as shown: a secret's hidden, an address's password only.
    public var shownValue: String {
        if let r = value.range(of: #"(?<=://)([^/@\s:]+):[^/@\s]+(?=@)"#, options: .regularExpression) {
            let user = value[r].split(separator: ":").first.map(String.init) ?? ""
            return value.replacingCharacters(in: r, with: user + ":••••")
        }
        return isSecret ? "••••••" : value
    }

    /// As a line a shell (sh, bash, zsh, fish) reads: `export NAME='value'`.
    public var exportLine: String {
        "export \(name)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// How a host's ssh agent stands (§8.6): where its shells' SSH_AUTH_SOCK
/// points — a link of the server's own, to the newest agent forwarded to
/// the host that answers — and what that is.
public struct AgentLinkStatus: Codable, Equatable, Sendable {
    /// The host's shells are given the link (an agent of its own, one that
    /// isn't forwarded, is left as it is: `local`).
    public var managed: Bool
    /// The link given as SSH_AUTH_SOCK.
    public var link: String
    /// The agent's socket it points to, and how it came: "forwarded to a
    /// Manifold connection", "forwarded to an ssh login", "named by mani env
    /// agent".
    public var target: String?
    public var from: String?
    /// The agent answers; how many keys it holds, when asked.
    public var live: Bool
    public var keys: Int?
    /// The host's own agent, given to its shells as it is.
    public var local: String?
    /// Others that answer, besides the one linked.
    public var others: Int

    public init(managed: Bool, link: String, target: String? = nil, from: String? = nil, live: Bool = false, keys: Int? = nil,
                local: String? = nil, others: Int = 0) {
        self.managed = managed
        self.link = link
        self.target = target
        self.from = from
        self.live = live
        self.keys = keys
        self.local = local
        self.others = others
    }

    /// In a line: "forwarded to a Manifold connection, 2 keys".
    public var summary: String {
        if !managed { return local.map { "the host's own (\($0))" } ?? "none" }
        guard target != nil else { return "none forwarded yet" }
        guard live else { return "gone (its connection ended); none other answers" }
        var s = from ?? "forwarded"
        if let keys { s += keys == 1 ? ", 1 key" : ", \(keys) keys" }
        if others > 0 { s += others == 1 ? " (1 other answers)" : " (\(others) others answer)" }
        return s
    }
}
