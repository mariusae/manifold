import Foundation
import Testing
@testable import ManifoldCore

@Test func maniTakesACommandItsFlagsAndItsArguments() {
    func run(_ argv: [String]) -> Mani.Invocation? {
        if case .success(.run(let i)) = Mani.parse(argv) { return i }
        return nil
    }
    func error(_ argv: [String]) -> Mani.UsageError? {
        if case .failure(let e) = Mani.parse(argv) { return e }
        return nil
    }
    #expect(run(["open", "-w", "a.md", "b/"]) == Mani.Invocation(verb: "open", flags: ["wait": ""], args: ["a.md", "b/"]))
    #expect(run(["open", "a.md", "--wait"])?.has("wait") == true)
    // After --, everything is an argument; `-` is one too.
    #expect(run(["open", "--", "--wait", "-"])?.args == ["--wait", "-"])
    #expect(run(["diff", "--title", "before lunch"])?.value("title") == "before lunch")
    #expect(run(["diff", "--title=lunch"])?.value("title") == "lunch")
    #expect(run(["diff", "-t", "lunch"])?.value("title") == "lunch")
    #expect(run(["skill", "install", "claude", "pi"]) == Mani.Invocation(verb: "skill install", flags: [:], args: ["claude", "pi"]))
    #expect(run(["agent", "stop", "--agent", "codex", #"{"a":1}"#])?.args == ["stop", #"{"a":1}"#])
    // A space made and filled: its flags, and the ones that place things there.
    #expect(run(["new", "space", "--title", "app", "--cwd", "~/src/app"]) == Mani.Invocation(verb: "new", flags: ["title": "app", "cwd": "~/src/app"], args: ["space"]))
    #expect(run(["new", "terminal", "--run", "make test", "--size", "0.3", "--space", "app"])?.flags == ["run": "make test", "size": "0.3", "space": "app"])
    #expect(run(["ls", "--space", "app"])?.value("space") == "app")
    #expect(run(["run", "@last", "ls", "--space", "app"])?.args == ["@last", "ls"])
    #expect(Mani.help("new").contains("smartlog") && Mani.help("new").contains("MANI_SPACE"))
    // Help: about mani, a command, a group.
    #expect(Mani.parse([]) == .success(.help(nil)))
    #expect(Mani.parse(["--help"]) == .success(.help(nil)))
    #expect(Mani.parse(["open", "x", "--help"]) == .success(.help("open")))
    #expect(Mani.parse(["help", "skill", "install"]) == .success(.help("skill install")))
    #expect(Mani.parse(["skill", "-h"]) == .success(.help("skill")))
    #expect(Mani.help("skill").contains("usage: mani skill install") && Mani.help("skill").contains("usage: mani skill uninstall"))
    // Every command in the overview; each one's flags in its own.
    let overview = Mani.help(nil)
    for v in Mani.verbs { #expect(overview.contains("  " + v.name)) }
    #expect(Mani.help("open").contains("-w, --wait"))
    #expect(Mani.verb("diff")?.usage == "mani diff [--title name] < patch")

    // Errors, with the command they're about.
    #expect(error(["frobnicate"]) == Mani.UsageError(message: "no command frobnicate"))
    #expect(error(["--wait", "a"])?.message.contains("the command comes first") == true)
    #expect(error(["open", "--wiat"]) == Mani.UsageError(message: "open has no flag --wiat", verb: "open"))
    #expect(error(["open", "-x"])?.verb == "open")
    #expect(error(["diff", "--title"]) == Mani.UsageError(message: "--title needs a value", verb: "diff"))
    #expect(error(["open", "--wait=yes"]) == Mani.UsageError(message: "--wait takes no value", verb: "open"))
    #expect(error(["diff", "lunch"])?.verb == "diff")
    #expect(error(["agent"]) == Mani.UsageError(message: "agent needs <event> [json]", verb: "agent"))
    #expect(error(["skill"]) == Mani.UsageError(message: "skill needs a command: install, show, uninstall", verb: "skill"))
    #expect(error(["skill", "add"])?.message == "skill has no command add: install, show, uninstall")
    #expect(error(["help", "nope"])?.verb == "help")
    // A path given as it was before `open`: said how.
    #expect(error(["/tmp"])?.message == "no command /tmp (to open it: mani open /tmp)")
}

@Test func positionsAreTakenFromTheLayout() {
    // Two columns: a diff at the left over its whole height; at the right
    // a terminal (60%) over an editor (40%), a note stacked under the
    // terminal.
    let h = HostID("h")
    func p(_ id: String) -> Placement { Placement(id: id, block: BlockID(host: h), lens: .editor) }
    let diff = p("diff"), term = p("term"), note = p("note"), editor = p("editor")
    var a = ArrangementState()
    a.columns = [[diff], [term, note, editor]]
    a.fractions = [0.4, 0.6]
    a.heights = ["diff": 1, "term": 0.6, "note": 0, "editor": 0.4]
    let layout = ManiLayout(a)
    #expect(layout.order == ["diff", "term", "editor"])
    #expect(layout.frames["editor"] == ManiLayout.Frame(x: 0.4, y: 0.6, width: 0.6, height: 0.4))
    #expect(layout.frames["note"] == nil)
    #expect(layout.stack(behind: "term") == ["note"])
    // From the terminal.
    #expect(layout.resolve("left", from: "term") == .tile("diff"))
    #expect(layout.resolve("below", from: "term") == .tile("editor"))
    #expect(layout.resolve("under", from: "term") == .tile("note"))
    #expect(layout.resolve("right", from: "term") == .none("nothing to the right of it"))
    #expect(layout.resolve("2", from: "term") == .tile("term"))
    #expect(layout.resolve("rightmost", from: "editor") == .tile("editor"))
    #expect(layout.resolve("top", from: "diff") == .tile("diff"))
    // The diff touches both on its right.
    #expect(layout.adjacent("diff") == [.right: ["term", "editor"]])
    #expect(layout.adjacent("editor") == [.left: ["diff"], .above: ["term"]])
    #expect(layout.names(of: "diff", from: "term") == ["@left", "@leftmost", "@1"])
    // Both at the top: the one nearer across, the terminal itself.
    #expect(layout.resolve("top", from: "term") == .tile("term"))
    // A kind narrows: the one that matches, or which, if more than one.
    #expect(layout.resolve("", from: "term") { $0 == "editor" } == .tile("editor"))
    #expect(layout.resolve("", from: "term") { $0 != "diff" } == .ambiguous(["term", "editor"]))
    #expect(layout.resolve("", from: "term") { $0 == "note" } == .tile("note"))
    #expect(layout.resolve("left", from: "editor") { $0 == "term" } == .none("nothing to the left of it"))
    #expect(ManiName("@right:diff") == .at("right", kind: "diff"))
    #expect(ManiName("@:PDF") == .at("", kind: "pdf"))
    #expect(ManiName("@here") == .at("here", kind: nil))
    #expect(ManiName("notes.md") == .other("notes.md"))
}

@Test func aUnifiedDiffHasContextAndMergesNearChanges() {
    let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
    var lines = (1...20).map { "line \($0)" }
    lines[4] = "five"
    lines[7] = "eight"
    lines[18] = "nineteen"
    let diff = UnifiedDiff.make(old: old, new: lines.joined(separator: "\n"), path: "x")
    #expect(diff.hasPrefix("--- a/x\n+++ b/x\n@@ -2,10 +2,10 @@\n line 2\n"))
    #expect(diff.contains("-line 5\n+five\n line 6\n line 7\n-line 8\n+eight"))
    #expect(diff.contains("@@ -16,5 +16,5 @@"))
    #expect(UnifiedDiff.make(old: "a", new: "a", path: "x") == "")
}

@Test func theGuideGoesInAgentsMdAndComesOutLeavingTheRest() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mani-agents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("AGENTS.md")
    let mine = "# Mine\n\nUse tabs.\n"
    try Data(mine.utf8).write(to: url)
    try AgentSkill.installAgentsNote(at: url)
    let once = try String(contentsOf: url, encoding: .utf8)
    #expect(once.hasPrefix(mine + "\n" + AgentSkill.agentsBegin))
    #expect(once.contains("mani skill show"))
    // Again: in place of the old, not beside it.
    try AgentSkill.installAgentsNote(at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == once)
    try AgentSkill.uninstallAgentsNote(at: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == mine)
    // A file that held only ours goes with it.
    let only = dir.appendingPathComponent("only/AGENTS.md")
    try AgentSkill.installAgentsNote(at: only)
    try AgentSkill.uninstallAgentsNote(at: only)
    #expect(!FileManager.default.fileExists(atPath: only.path))
    // The skill: written, rewritten when the guide changes, taken out.
    let skill = dir.appendingPathComponent("skills/manifold/SKILL.md")
    try AgentSkill.installSkillFile(at: skill)
    #expect(try String(contentsOf: skill, encoding: .utf8).contains("mani read @selection"))
    try Data("---\nname: manifold\n---\nold\n".utf8).write(to: skill)
    try AgentSkill.refreshSkillFile(at: skill)
    #expect(try String(contentsOf: skill, encoding: .utf8) == AgentSkill.skillFile)
    try AgentSkill.uninstallSkillFile(at: skill)
    #expect(!FileManager.default.fileExists(atPath: skill.deletingLastPathComponent().path))
}

@Test func theKindsOfBlockAreOneTable() {
    // What the picker reads, as `mani new` reads its words.
    #expect(BlockKinds.parse("web example.com") == ("web", "example.com"))
    #expect(BlockKinds.parse("  search  TODO later ") == ("search", "TODO later"))
    #expect(BlockKinds.parse("term") == ("term", nil))
    // A name, an alias, or the start of one.
    #expect(BlockKinds.named("ps")?.name == "process")
    #expect(BlockKinds.named("page")?.name == "web")
    #expect(BlockKinds.named("term", exact: false)?.name == "terminal")
    #expect(BlockKinds.named("s", exact: false) == nil)  // search, smartlog, shell notebook, source control
    #expect(BlockKinds.matching("").count == BlockKinds.all.count)
    #expect(BlockKinds.matching("s").map(\.name).contains("smartlog"))
    #expect(BlockKinds.matching("notebook").map(\.name) == ["notebook"])
    // Every kind in `mani new`'s help.
    let help = Mani.help("new")
    for k in BlockKinds.all { #expect(help.contains("  " + k.name)) }
}

@Test func whatIsFoundIsNarrowedByKind() {
    // ⇥ after a start: the kinds it begins, in the table's order.
    #expect(FindKinds.starting("te").map(\.name) == ["terminal"])
    #expect(FindKinds.starting("t").map(\.name) == ["terminal", "turn"])
    #expect(FindKinds.starting("s").map(\.name) == ["space", "search", "smartlog", "terminal", "git"])  // then shell, source
    #expect(FindKinds.starting("page").map(\.name) == ["web"])
    #expect(FindKinds.starting("").isEmpty)
    // A block is found as its kind; a text as a note or a file; a
    // terminal an agent works in, as an agent's too.
    #expect(FindKinds.of(.text, path: nil, agent: false) == ["note"])
    #expect(FindKinds.of(.text, path: "/a/b.md", agent: false) == ["file"])
    #expect(FindKinds.of(.terminal, path: nil, agent: true) == ["terminal", "agent"])
    #expect(FindKinds.of(.arrangement, path: nil, agent: false) == ["space"])
    #expect(FindKinds.of(.process, path: nil, agent: false).isEmpty)
    // Every kind's name is one ⇥ can reach, and its own.
    for k in FindKinds.all { #expect(FindKinds.starting(k.name).contains(k)) }
    #expect(Set(FindKinds.all.map(\.name)).count == FindKinds.all.count)
}

@Test func pathsAreFoundNearestFirstAndOnlyAsWanted() {
    // A tree: each folder's entries, by absolute path.
    func e(_ name: String, _ dir: Bool) -> DirectoryEntry { DirectoryEntry(name: name, isDirectory: dir, size: 0, modified: 0, isHidden: name.hasPrefix(".")) }
    let tree: [String: [DirectoryEntry]] = [
        "/h": [e("a", true), e("b", true), e("top.txt", false), e(".hidden", true), e("node_modules", true), e("X.app", true), e("Library", true)],
        "/h/a": [e("a1.txt", false), e("deep", true)],
        "/h/a/deep": [e("d.txt", false)],
        "/h/b": [e("c", true), e("b1.txt", false)],
        "/h/b/c": [e("c1.txt", false)],
        "/h/.hidden": [e("no.txt", false)], "/h/node_modules": [e("no.txt", false)], "/h/X.app": [e("no", false)], "/h/Library": [e("no", false)],
    ]
    var asked: [String] = []
    func lister(_ path: String, _ done: @escaping ([DirectoryEntry]?) -> Void) { asked.append(path); done(tree[path]) }

    // The root's own entries only, until it's asked to go on.
    let crawl = PathCrawl(root: "/h", home: "/h", concurrency: 1, list: lister)
    #expect(asked == ["/h"])
    #expect(crawl.found.map(\.path).contains("top.txt") && crawl.found.allSatisfy { $0.depth == 1 })
    crawl.going = true
    #expect(crawl.finished)
    // Nearest first: a level at a time; hidden, dependency, package and a
    // home's Library folders listed as entries but never gone into.
    #expect(asked == ["/h", "/h/a", "/h/b", "/h/a/deep", "/h/b/c"])
    let depths = crawl.found.map(\.depth)
    #expect(depths == depths.sorted())
    #expect(crawl.children["b"].map { $0.map { crawl.found[$0].path } } == ["b/b1.txt", "b/c"])

    // A folder looked for is listed before the rest.
    asked = []
    let toward = PathCrawl(root: "/h", home: nil, concurrency: 1, list: lister)
    toward.toward = "b/c"
    toward.going = true
    #expect(Array(asked.prefix(3)) == ["/h", "/h/b", "/h/b/c"])
    #expect(asked.contains("/h/Library"))  // not this host's home: gone into

    // As far as it's let go.
    let little = PathCrawl(root: "/h", home: "/h", maxFound: 9, concurrency: 1, list: lister)
    little.going = true
    #expect(little.found.count == 9 && little.finished)
}
