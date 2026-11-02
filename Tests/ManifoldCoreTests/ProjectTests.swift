import Foundation
import Testing
@testable import ManifoldCore

@Test func aPathsProjectIsTheNearestRootAboveIt() {
    let mono = Project(root: "/src/mono", made: Stamp(wall: 1))
    var app = Project(root: "/tmp/mono/app", made: Stamp(wall: 2))
    app.alias = "/private/tmp/mono/app"
    let all = [mono, app]
    #expect(Project.holding("/src/mono/README.md", in: all)?.root == "/src/mono")
    #expect(Project.holding("/src/mono", in: all)?.root == "/src/mono")
    #expect(Project.holding("/src/monolith/x", in: all) == nil)
    // Either spelling of a folder behind a link.
    #expect(Project.holding("/private/tmp/mono/app/src/main.rs", in: all)?.root == "/tmp/mono/app")
    #expect(app.relative("/private/tmp/mono/app/src/main.rs") == "src/main.rs")
    #expect(app.relative("/tmp/mono/app") == "")
    #expect(app.relative("/elsewhere") == "/elsewhere")
    // Nested: the nearer wins.
    let inner = Project(root: "/src/mono/lib", made: Stamp(wall: 3))
    #expect(Project.holding("/src/mono/lib/a.rs", in: all + [inner])?.root == "/src/mono/lib")
}

@Test func aFolderLooksLikeAProjectByItsRepositoryOrManifest() {
    #expect(Project.looksLikeRoot([".git", "README.md"]))
    #expect(Project.looksLikeRoot(["Cargo.toml", "src"]))
    #expect(Project.looksLikeRoot(["go.mod"]))
    #expect(!Project.looksLikeRoot(["notes.md", "pictures"]))
}

@Test func theDeskKeepsProjectsByTheirRoot() throws {
    var desk = DeskState()
    desk.apply(.project(Project(root: "/a", made: Stamp(wall: 1))))
    desk.apply(.project(Project(root: "/b", made: Stamp(wall: 2))))
    var changed = Project(root: "/a", made: Stamp(wall: 1))
    changed.alias = "/private/a"
    desk.apply(.project(changed))
    #expect(desk.projects.map(\.root) == ["/a", "/b"])
    #expect(desk.projects[0].alias == "/private/a")
    desk.apply(.unproject("/a"))
    #expect(desk.project(holding: "/a/x") == nil)
    #expect(desk.project(holding: "/b/x")?.root == "/b")
    // A desk from before projects reads as having none.
    let old = try JSONDecoder().decode(DeskState.self, from: Data(#"{"order":[]}"#.utf8))
    #expect(old.projects.isEmpty)
}

@Test func aGitBlockKeepsItsScope() {
    var g = GitState()
    g.apply(.gitScope("app"))
    #expect(g.scope == "app")
    g.apply(.gitScope(nil))
    #expect(g.scope == nil)
}
