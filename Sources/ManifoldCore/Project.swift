import Foundation

/// A project (§2.6): a folder on a host made one by hand — its root —
/// kept in the host's desk, so every client and the host itself find
/// the same one. What's under the root is the project's: its index, its
/// commits and changes (the root may be deep in a repository), its
/// searches. The project of a path is the nearest root at or above it.
public struct Project: Codable, Equatable, Sendable {
    /// Its folder, as its tile names it.
    public var root: String
    /// The same folder as the host spells it with links resolved (/tmp
    /// is /private/tmp), where that's different: a terminal's directory
    /// may say either.
    public var alias: String?
    public var made: Stamp

    public init(root: String, made: Stamp) {
        self.root = root
        self.made = made
    }

    public var name: String { root.lastPathComponent.isEmpty ? root : root.lastPathComponent }

    /// Whether a path is the root or under it, in either spelling.
    public func holds(_ path: String) -> Bool {
        Self.under(path, root) || alias.map { Self.under(path, $0) } == true
    }

    /// A path under the root, relative to it ("" for the root); a path
    /// not under it, as it is.
    public func relative(_ path: String) -> String {
        for r in [root] + (alias.map { [$0] } ?? []) where Self.under(path, r) {
            return path == r ? "" : String(path.dropFirst(r == "/" ? 1 : r.count + 1))
        }
        return path
    }

    static func under(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// The project holding a path: the nearest root at or above it.
    public static func holding(_ path: String, in projects: [Project]) -> Project? {
        projects.filter { $0.holds(path) }.max { $0.root.count < $1.root.count }
    }

    /// Whether a folder's entries say it's a project's root, to offer
    /// making it one: a repository's own folder, or a language's manifest
    /// (an indexer's marker).
    public static func looksLikeRoot(_ names: Set<String>) -> Bool {
        if VCS.markers.contains(where: { names.contains($0.directory) }) { return true }
        return SCIPIndexer.defaults.contains { $0.rootMarkers.contains(where: names.contains) }
    }
}

extension DeskState {
    /// The project holding a path on this host, if any.
    public func project(holding path: String) -> Project? { Project.holding(path, in: projects) }
}
