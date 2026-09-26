import Foundation
import Testing
@testable import ManifoldCore

@Test func namesBeatDirectories() {
    let paths = ["Sources/Manifold/UI/TabContentView.swift", "Sources/ManifoldCore/Model.swift", "tabs/notes.md"]
    #expect(FileFinder.rank("tcv", paths).first == "Sources/Manifold/UI/TabContentView.swift")
    #expect(FileFinder.rank("model", paths).first == "Sources/ManifoldCore/Model.swift")
    #expect(FileFinder.rank("tab", paths).first == "Sources/Manifold/UI/TabContentView.swift" || FileFinder.rank("tab", paths).first == "tabs/notes.md")
}

@Test func slashesMatchWholePaths() {
    let paths = ["a/ui/view.swift", "b/core/view.swift"]
    #expect(FileFinder.rank("core/view", paths) == ["b/core/view.swift"])
}

@Test func nonMatchesAreDropped() {
    #expect(FileFinder.score("xyz", "Sources/main.swift") == nil)
    #expect(FileFinder.rank("", ["b", "a"]) == ["b", "a"])
}

@Test func runsAndStartsWin() {
    let a = FileFinder.score("read", "README.md")!
    let b = FileFinder.score("read", "src/r_e_a_d.txt")!
    #expect(a > b)
}

@Test func walkingListsNearestFirstAndSkipsHidden() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-\(UUID())")
    let fm = FileManager.default
    for dir in ["a/b", ".hidden", "node_modules/x"] {
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in ["top.txt", "a/mid.txt", "a/b/deep.txt", ".hidden/no.txt", "node_modules/x/no.js", ".dot"] {
        fm.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
    }
    defer { try? fm.removeItem(at: root) }
    #expect(FileFinder.list(root: root.path) == ["top.txt", "a/mid.txt", "a/b/deep.txt"])
    #expect(FileFinder.list(root: root.path, limit: 2).count == 2)
}

@Test func locationsSplitOffLinesAndColumns() {
    #expect(FileLocation.split("Sources/Manifold/UI/MainWindowController.swift:602:34:")
            == FileLocation(path: "Sources/Manifold/UI/MainWindowController.swift", line: 602, column: 34))
    #expect(FileLocation.split("main.swift:12") == FileLocation(path: "main.swift", line: 12))
    #expect(FileLocation.split("/tmp/a b.txt:7:") == FileLocation(path: "/tmp/a b.txt", line: 7))
    #expect(FileLocation.split("main.swift") == nil)
    #expect(FileLocation.split("12:34") == FileLocation(path: "12", line: 34))
    #expect(FileLocation.split("C:notes.txt") == nil)
}
