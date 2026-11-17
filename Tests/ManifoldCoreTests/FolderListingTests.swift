import Foundation
import Testing
@testable import ManifoldCore

/// A git repository in a temporary folder: a tracked file, an untracked
/// one, an ignored file and an ignored folder, a nested folder.
private func scratchRepository() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-listing-\(UUID().uuidString)").path
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/src/deep", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root + "/build/out", withIntermediateDirectories: true)
    for (path, text) in [(".gitignore", "build/\n*.log\n"), ("README.md", "hi"), ("src/main.swift", "x"), ("src/deep/a.txt", "a"),
                         ("notes.txt", "untracked"), ("debug.log", "ignored"), ("build/out/bin", "ignored")] {
        try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
    }
    _ = try Child.run(["git", "-C", root, "init", "-q"], quiet: true)
    _ = try Child.run(["git", "-C", root, "add", "README.md", "src", ".gitignore"], quiet: true)
    return root
}

@Test func folderChildrenMarkWhatGitIgnores() throws {
    let root = try scratchRepository()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let entries = try #require(FolderListing.children(of: root))
    let ignored = Set(entries.filter { $0.isIgnored == true }.map(\.name))
    #expect(ignored == ["build", "debug.log"])
    #expect(entries.first?.isDirectory == true)
    let src = try #require(FolderListing.children(of: root + "/src"))
    #expect(src.map(\.name).sorted() == ["deep", "main.swift"])
    #expect(src.allSatisfy { $0.isIgnored == false })
}

@Test func folderTreeLeavesOutWhatGitIgnores() throws {
    let root = try scratchRepository()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let (entries, complete) = FolderListing.tree(of: root)
    #expect(complete)
    let names = Set(entries.map(\.name))
    #expect(names.isSuperset(of: ["README.md", "notes.txt", "src", "src/main.swift", "src/deep", "src/deep/a.txt"]))
    #expect(!names.contains("debug.log") && !names.contains { $0.hasPrefix("build") })
    #expect(entries.first { $0.name == "src/deep" }?.isDirectory == true)
    let (some, partial) = FolderListing.tree(of: root, limit: 2)
    #expect(!partial && some.filter { !$0.isDirectory }.count == 2)
}

@Test func folderTreeOutsideARepositoryWalks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-walk-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/a/node_modules/x", withIntermediateDirectories: true)
    try "1".write(toFile: root + "/a/one.txt", atomically: true, encoding: .utf8)
    try "2".write(toFile: root + "/a/node_modules/x/two.js", atomically: true, encoding: .utf8)
    let names = Set(FolderListing.tree(of: root).entries.map(\.name))
    #expect(names == ["a", "a/one.txt"])
}

@Test func folderChildrenFollowTheIgnoreFileAsItChanges() throws {
    let root = try scratchRepository()
    defer { try? FileManager.default.removeItem(atPath: root) }
    func ignored() throws -> Set<String> { Set(try #require(FolderListing.children(of: root)).filter { $0.isIgnored == true }.map(\.name)) }
    #expect(try ignored() == ["build", "debug.log"])
    // Asked again, as a folder shown is: kept (the same answer).
    #expect(try ignored() == ["build", "debug.log"])
    // The ignore file changed: asked of the repository again.
    try "build/\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    #expect(try ignored() == ["build"])
    // A file came: the folder changed.
    try "x".write(toFile: root + "/more.log", atomically: true, encoding: .utf8)
    try "build/\n*.log\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    #expect(try ignored() == ["build", "debug.log", "more.log"])
}

/// The same in a Sapling repository, if Sapling's here: the ignored folder
/// holding a file it tracks isn't ignored.
private func scratchSapling() throws -> String? {
    guard (try? Child.run(["sl", "--version"], timeout: 20, quiet: true))?.status == 0 else { return nil }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sl-\(UUID().uuidString)").path
    let fm = FileManager.default
    for d in ["src/deep", "build/out", "dist", "src/node_modules"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
    for (path, text) in [(".gitignore", "build/\ndist/\n*.log\nnode_modules\n"), ("README.md", "hi"), ("src/main.swift", "x"), ("src/deep/a.txt", "a"),
                         ("notes.txt", "untracked"), ("debug.log", "ignored"), ("kept.log", "tracked"), ("build/out/bin", "ignored"),
                         ("dist/shipped", "tracked"), ("src/x.log", "ignored")] {
        try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
    }
    _ = try Child.run(["sl", "init", "--git", root], quiet: true)
    _ = try Child.run(["sl", "--cwd", root, "add", "README.md", "src/main.swift", "src/deep", ".gitignore", "kept.log", "dist/shipped"], quiet: true)
    return root
}

@Test func saplingFolderChildrenAreAskedAboutByName() throws {
    guard let root = try scratchSapling() else { return }
    defer { try? FileManager.default.removeItem(atPath: root) }
    let entries = try #require(FolderListing.children(of: root))
    // Tracked though ignored (kept.log, dist with its tracked file): not.
    #expect(Set(entries.filter { $0.isIgnored == true }.map(\.name)) == ["build", "debug.log"])
    let src = try #require(FolderListing.children(of: root + "/src"))
    #expect(Set(src.filter { $0.isIgnored == true }.map(\.name)) == ["node_modules", "x.log"])
}

@Test func saplingTreeIsTrackedAndNewFiles() throws {
    guard let root = try scratchSapling() else { return }
    defer { try? FileManager.default.removeItem(atPath: root) }
    let (entries, complete) = FolderListing.tree(of: root)
    #expect(complete)
    let files = Set(entries.filter { !$0.isDirectory }.map(\.name))
    #expect(files == ["README.md", "src/main.swift", "src/deep/a.txt", ".gitignore", "kept.log", "dist/shipped", "notes.txt"])
    let (some, all) = FolderListing.tree(of: root, limit: 3)
    #expect(!all && some.filter { !$0.isDirectory }.count == 3)
    // What's changed: what's added and new, not every file.
    #expect(Set(FolderListing.changed(under: root) ?? []) == ["README.md", "src/main.swift", "src/deep/a.txt", ".gitignore", "kept.log", "dist/shipped", "notes.txt"])
    #expect(FolderListing.changed(under: root + "/src") == ["deep/a.txt", "main.swift"])
}

@Test func gitChangedFilesAreWhatsModifiedOrNew() throws {
    let root = try scratchRepository()
    defer { try? FileManager.default.removeItem(atPath: root) }
    _ = try Child.run(["git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"], quiet: true)
    try "changed".write(toFile: root + "/src/main.swift", atomically: true, encoding: .utf8)
    #expect(FolderListing.changed(under: root) == ["notes.txt", "src/main.swift"])
}

@Test func aLargeRepositoryIsNeitherWalkedNorLookedAtFileByFile() throws {
    let root = try scratchRepository()
    defer { try? FileManager.default.removeItem(atPath: root) }
    // As EdenFS has it.
    try FileManager.default.createDirectory(atPath: root + "/.eden", withIntermediateDirectories: true)
    #expect(Repositories.isLarge(root))
    let (entries, _) = FolderListing.tree(of: root)
    let readme = try #require(entries.first { $0.name == "README.md" })
    #expect(readme.size == 0 && readme.modified == 0)
}
