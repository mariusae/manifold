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
    #expect(error(["skill"]) == Mani.UsageError(message: "skill needs a command: install, uninstall", verb: "skill"))
    #expect(error(["skill", "add"])?.message == "skill has no command add: install, uninstall")
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
