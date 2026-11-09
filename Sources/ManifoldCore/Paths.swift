import Foundation

public extension String {
    /// A word for sh: in single quotes, a quote in it closed, escaped and
    /// opened again.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Path pieces, as NSString has them, for every platform.
public extension String {
    var lastPathComponent: String {
        let trimmed = hasSuffix("/") && count > 1 ? String(dropLast()) : self
        if let i = trimmed.lastIndex(of: "/") { return String(trimmed[trimmed.index(after: i)...]) }
        return trimmed
    }

    var deletingLastPathComponent: String {
        let trimmed = hasSuffix("/") && count > 1 ? String(dropLast()) : self
        guard let i = trimmed.lastIndex(of: "/") else { return "" }
        if i == trimmed.startIndex { return "/" }
        return String(trimmed[..<i])
    }

    var pathExtension: String {
        let name = lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    func appendingPathComponent(_ component: String) -> String {
        if isEmpty { return component }
        if hasSuffix("/") { return self + component }
        return self + "/" + component
    }

    var expandingTildeInPath: String {
        guard hasPrefix("~") else { return self }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == "~" { return home }
        if hasPrefix("~/") { return home + dropFirst(1) }
        return self
    }

    /// Ordered as the Finder orders names: by number where numbers differ.
    func standardCompare(_ other: String) -> Bool {
        compare(other, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending
    }
}

/// Where Manifold keeps its socket, state, and logs. MANIFOLD_DIR overrides
/// it, so a second instance can run without touching the first.
public enum Paths {
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["MANIFOLD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Manifold")
        #else
        if let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state).appendingPathComponent("manifold")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".manifold")
        #endif
    }

    /// Where a host keeps the `manifoldd` a client installed on it (§8.1).
    public static var installedServer: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".manifold/bin/manifoldd")
    }

    /// The names of what says who a host is, in its folder (`HostSession`).
    public enum Name {
        public static let session = "session"
        public static let label = "label"
        public static let hostName = "host"
    }

    /// The host's name, as its first client named it (before sessions).
    public static var hostName: URL { directory.appendingPathComponent(Name.hostName) }
    /// The host's session id (§8), minted once.
    public static var session: URL { directory.appendingPathComponent(Name.session) }
    /// What the host calls itself, for clients to show.
    public static var label: URL { directory.appendingPathComponent(Name.label) }

    public static var socket: String { directory.appendingPathComponent("manifoldd.sock").path }
    public static var logs: URL { directory.appendingPathComponent("logs") }
    public static var log: URL { directory.appendingPathComponent("manifoldd.log") }

    // The server's.

    /// Held while a server runs here: one per folder.
    public static var lock: URL { directory.appendingPathComponent("manifoldd.lock") }
    /// The shape of what's on disk (`Server.dataFormat`).
    public static var format: URL { directory.appendingPathComponent("format") }
    /// Who the host is attached to (§8.2), and how many times it's been taken.
    public static var attached: URL { directory.appendingPathComponent("attached.json") }
    /// Terminals' scrollback, kept beside the logs.
    public static var history: URL { directory.appendingPathComponent("history") }
    /// Images a note shows, kept by Manifold on its host.
    public static var images: URL { directory.appendingPathComponent("Images") }
    /// Marks a one-time settling done (notes titled by their first line).
    public static var firstLineTitles: URL { directory.appendingPathComponent("first-line-titles") }
    /// The shells' startup layers, and the terminfo they're given.
    public static var zsh: URL { directory.appendingPathComponent("zsh") }
    public static var bash: URL { directory.appendingPathComponent("bash") }
    public static var terminfo: URL { directory.appendingPathComponent("terminfo") }
    /// The ssh agent link shells are given (§8.6), and the agents seen.
    public static var agentLink: URL { directory.appendingPathComponent("agent.sock") }
    public static var agents: URL { directory.appendingPathComponent("agents") }
    /// Projects' SCIP indexes (§2.5).
    public static var scip: URL { directory.appendingPathComponent("scip") }

    // The app's.

    /// The other hosts this Mac attaches to (`HostsFile`).
    public static var hosts: URL { directory.appendingPathComponent("hosts.json") }
    /// What is this client's alone (`ClientState`).
    public static var clientState: URL { directory.appendingPathComponent("client.json") }
    /// Launches not yet seen to end (`CrashGuard`).
    public static var unfinishedLaunches: URL { directory.appendingPathComponent("unfinished-launches") }
    public static var webHistory: URL { directory.appendingPathComponent("web-history.json") }
    public static var favicons: URL { directory.appendingPathComponent("favicons") }
    /// Where the app listens for debugging commands, unless told otherwise.
    public static var appDebugSocket: URL { directory.appendingPathComponent("app-debug.sock") }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
