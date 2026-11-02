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

@Test func aSymbolIsFoundByItsNameFirst() {
    let save = SymbolHit.score("save", name: "save", container: "store", kind: "func")
    let saver = SymbolHit.score("save", name: "saver", container: "", kind: "value")
    let inside = SymbolHit.score("save", name: "autosave", container: "", kind: "func")
    #expect(save > saver && saver > inside && inside > 0)
    #expect(SymbolHit.score("Card.save", name: "save", container: "Card", kind: "func") > 0)
    #expect(SymbolHit.score("zzz", name: "save", container: "store", kind: "func") == 0)
    // A type over a value, matched alike.
    #expect(SymbolHit.score("card", name: "Card", container: "", kind: "type") > SymbolHit.score("card", name: "card", container: "", kind: "value") - 100)
}

@Test func aSCIPSymbolsKindIsItsLastDescriptor() {
    #expect(SymbolHit.kind(scip: "rust-analyzer cargo cards 0.1.0 store/save().") == "func")
    #expect(SymbolHit.kind(scip: "rust-analyzer cargo cards 0.1.0 Card#") == "type")
    #expect(SymbolHit.kind(scip: "rust-analyzer cargo cards 0.1.0 store/") == "module")
    #expect(SymbolHit.kind(scip: "rust-analyzer cargo cards 0.1.0 Card#title.") == "value")
    // Not looked for by name: a parameter, a type parameter.
    #expect(SymbolHit.kind(scip: "scip-typescript npm a 1 f().(x)") == nil)
    #expect(SymbolHit.kind(scip: "scip-typescript npm a 1 F#[T]") == nil)
}

@Test func symbolsFromTheIndexAndAServerAreOneList() {
    func hit(_ name: String, _ line: Int, _ source: SymbolHit.Source, _ score: Int) -> SymbolHit {
        SymbolHit(name: name, container: "", kind: "func", path: "/p/a.rs", line: line, character: 0, text: "", source: source, score: score)
    }
    let merged = SymbolHit.merge([[hit("save", 3, .index, 600)], [hit("save", 3, .server, 600), hit("saved", 9, .server, 520)]], limit: 10)
    #expect(merged.map(\.line) == [3, 9])
    #expect(merged[0].source == .index)
}

@Test func aProjectQuerySaysWhatItLooksFor() {
    #expect(ProjectQuery("save").kinds == ["symbols", "files", "text"])
    #expect(ProjectQuery("sym: save") == ProjectQuery(text: "save", kinds: ["symbols"]))
    #expect(ProjectQuery("file:main.rs").kinds == ["files"])
    #expect(ProjectQuery("text:fn main").text == "fn main")
}

@Test func aSearchsNamesGoWhenItsAskedAgain() {
    var s = SearchState()
    s.apply(.search(SearchQuery(text: "a", root: "/p"), at: Stamp(wall: 1)))
    s.apply(.searchSymbols([]))
    s.apply(.searchFiles(["a.rs"]))
    #expect(s.symbols == [] && s.files == ["a.rs"])
    s.apply(.search(SearchQuery(text: "b", root: "/p"), at: Stamp(wall: 2)))
    #expect(s.symbols == nil && s.files == nil)
}
