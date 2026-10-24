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
