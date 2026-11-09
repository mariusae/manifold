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
    /// Its index's indexer, by id ("none": no index), rather than the one
    /// its files' markers find; and its command, rather than the
    /// indexer's (`{out}` the index's file, `{name}` the root's name).
    public var indexer: String?
    public var indexCommand: String?
    /// Whether its index is made again when the repository's working copy
    /// moves (a checkout, a commit, a rebase); nil, yes.
    public var reindexOnCheckout: Bool?

    public init(root: String, made: Stamp) {
        self.root = root
        self.made = made
    }

    public var name: String { root.lastPathComponent.isEmpty ? root : root.lastPathComponent }

    /// Whether a path is the root or under it, in either spelling.
    public func holds(_ path: String) -> Bool {
        path.isUnder(root) || alias.map { path.isUnder($0) } == true
    }

    /// A path under the root, relative to it ("" for the root); a path
    /// not under it, as it is.
    public func relative(_ path: String) -> String {
        for r in [root] + (alias.map { [$0] } ?? []) {
            if let rel = path.relative(to: r) { return rel }
        }
        return path
    }

    /// The indexer it's indexed with (§2.5), among `indexers`: the one
    /// chosen for it, given its own command if it has one; else the one
    /// whose marker is at its root; else the one its files' language
    /// finds (`file`, a file in it); nil where it's to have none.
    public func indexer(among indexers: [SCIPIndexer], for file: String? = nil, has: (String) -> Bool) -> SCIPIndexer? {
        if indexer == "none" { return nil }
        var found = indexer.flatMap { id in indexers.first { $0.id == id } }
            ?? indexers.first { i in i.rootMarkers.contains { has(root.appendingPathComponent($0)) } }
            ?? file.flatMap { SCIPIndexer.forFile($0, among: indexers)?.0 }
        if let c = indexCommand?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            found = SCIPIndexer(id: found?.id ?? "custom", languages: found?.languages ?? [], rootMarkers: found?.rootMarkers ?? [], command: c)
        }
        return found
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
