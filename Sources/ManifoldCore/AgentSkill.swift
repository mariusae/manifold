import Foundation

/// `mani skill install`: hooks in each coding agent found on this
/// machine (or those named) that run `mani agent` on the agent's
/// events, so a Manifold terminal running it shows its status and each of
/// its turns. The hooks do nothing outside Manifold's terminals (no
/// MANIFOLD_BLOCK), and installing again replaces them; `mani skill
/// uninstall` takes them out. Whatever else the agents' settings hold is
/// kept. Hooks put in when the command was `manifold` are moved over to
/// `mani` (`refresh`).
public enum AgentSkill {
    /// An agent's hooks: where they go, and how.
    struct Target {
        var name: String
        /// Where its settings are, for the user.
        var file: URL
        /// Whether the agent is here at all.
        var present: () -> Bool
        var install: () throws -> Void
        var uninstall: () throws -> Void
        /// Moves hooks put in as `manifold`'s over to `mani` (`refresh`).
        var refresh: () throws -> Void
        /// What to tell the user once it's in.
        var note: String? = nil
    }

    /// The agents there are hooks for.
    public static var known: [String] { targets.map(\.name) }

    /// The command a hook runs for `event`: nothing outside Manifold's
    /// terminals, else `mani agent` — this `mani`, by its full path, not
    /// whichever one comes first on the agent's PATH — which always
    /// succeeds.
    static func command(_ event: String, agent: String, tool: String = maniTool) -> String {
        "[ -z \"$MANIFOLD_BLOCK\" ] || \(shellQuoted(tool)) agent \(event) --agent \(agent)"
    }

    /// Whether a hook's command is one of ours (bare, as they were once
    /// put in, or by its path; `mani`, or `manifold` as it was), to replace
    /// or take out.
    static func isOurs(_ command: String) -> Bool {
        ["mani", "manifold"].contains { command.contains("\($0) agent ") || command.contains("\($0)' agent ") }
    }

    /// The `mani` command installing the hooks, by its full path: this
    /// program if it is `mani` (the app's, in its Helpers), else the
    /// `mani` beside it (on a remote host, the script that runs this
    /// server); the bare name only if there's none to be found.
    static var maniTool: String {
        guard let exe = ownExecutable else { return "mani" }
        if exe.lastPathComponent == "mani" { return exe.path }
        let dir = exe.deletingLastPathComponent()
        // The app's Helpers first; and the name exactly so, as the folder
        // lists it (a disk that ignores case answers to any spelling).
        for folder in [dir.deletingLastPathComponent().appendingPathComponent("Helpers"), dir] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let candidate = folder.appendingPathComponent("mani")
            if names.contains("mani"), FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return "mani"
    }

    /// This program's own file, wherever it was run from (argv[0] is only
    /// what was typed: `mani`, found on the PATH).
    static var ownExecutable: URL? {
        #if os(Linux)
        if let p = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return URL(fileURLWithPath: p) }
        #endif
        return Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

    /// A word for sh, in single quotes.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// A path with the home folder as ~.
    static func short(_ url: URL) -> String {
        url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    static func onPath(_ name: String) -> Bool {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    static var targets: [Target] {
        let env = ProcessInfo.processInfo.environment
        let claude = home.appendingPathComponent(".claude/settings.json")
        let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let codex = codexHome.appendingPathComponent("hooks.json")
        let codexAgents = codexHome.appendingPathComponent("AGENTS.md")
        let claudeSkill = claude.deletingLastPathComponent().appendingPathComponent("skills/manifold/SKILL.md")
        let museDir = env["MUSE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")).appendingPathComponent("muse")
        let muse = museDir.appendingPathComponent("settings.json")
        let piDir = env["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".pi/agent")
        let pi = piDir.appendingPathComponent("extensions/manifold.ts")
        func here(_ command: String, _ dir: URL) -> () -> Bool {
            { onPath(command) || FileManager.default.fileExists(atPath: dir.path) }
        }
        return [
            // MetaCode reads Claude Code's hooks too; `mani agent` tells them apart.
            Target(name: "claude", file: claude, present: here("claude", claude.deletingLastPathComponent()),
                   install: { try installClaudeStyle(at: claude, agent: "claude", events: claudeEvents); try installSkillFile(at: claudeSkill) },
                   uninstall: { try uninstallClaudeStyle(at: claude); try uninstallSkillFile(at: claudeSkill) },
                   refresh: { try refreshClaudeStyle(at: claude); try refreshSkillFile(at: claudeSkill) }),
            Target(name: "codex", file: codex, present: here("codex", codexHome),
                   install: { try installClaudeStyle(at: codex, agent: "codex", events: codexEvents); try installAgentsNote(at: codexAgents) },
                   uninstall: { try uninstallClaudeStyle(at: codex); try uninstallAgentsNote(at: codexAgents) },
                   refresh: { try refreshClaudeStyle(at: codex); try refreshAgentsNote(at: codexAgents) },
                   note: "Codex asks to review new hooks once: choose Review hooks (or /hooks) and trust Manifold's."),
            Target(name: "muse", file: muse, present: here("muse", museDir),
                   install: { try installClaudeStyle(at: muse, agent: "muse", events: museEvents) },
                   uninstall: { try uninstallClaudeStyle(at: muse) },
                   refresh: { try refreshClaudeStyle(at: muse) }),
            Target(name: "pi", file: pi, present: here("pi", piDir),
                   install: { try installPiExtension(at: pi) },
                   uninstall: { try uninstallPiExtension(at: pi) },
                   refresh: { try refreshPiExtension(at: pi) },
                   note: "In a running pi, /reload picks it up."),
        ]
    }

    /// Claude Code's events, and what each says.
    static let claudeEvents: [(hook: String, event: String)] = [
        ("SessionStart", "start"),
        ("UserPromptSubmit", "prompt"),
        ("PostToolUse", "working"),
        ("PermissionRequest", "waiting"),
        ("Notification", "waiting"),
        ("Stop", "stop"),
        ("SessionEnd", "end"),
    ]

    /// Codex's: Claude Code's, less Notification (it has none).
    static let codexEvents: [(hook: String, event: String)] = claudeEvents.filter { $0.hook != "Notification" }

    /// Muse's: Claude Code's.
    static let museEvents = claudeEvents

    /// Installs (or takes out) the hooks of the agents named (known ones),
    /// or of those found here, saying what it did; then exits.
    public static func runInstall(_ wanted: [String], uninstall: Bool) -> Never {
        var failed = false
        var did = 0
        for t in targets where wanted.isEmpty ? t.present() : wanted.contains(t.name) {
            do {
                if uninstall { try t.uninstall() } else { try t.install() }
                print("\(uninstall ? "took Manifold's hooks out of" : "installed Manifold's hooks for") \(t.name): \(short(t.file))")
                if !uninstall, let note = t.note { print("  \(note)") }
                did += 1
            } catch {
                print("mani: couldn't \(uninstall ? "uninstall" : "install") hooks for \(t.name) (\(short(t.file))): \(error)")
                failed = true
            }
        }
        if did == 0, !failed { print("mani: no coding agents found here (\(targets.map(\.name).joined(separator: ", ")))") }
        exit(failed ? 1 : 0)
    }

    // MARK: Claude Code's format (and those that took it up)

    /// Settings as JSON, `{"hooks": {"<Event>": [{"hooks": [{"type":
    /// "command", "command": "…"}]}]}}`: ours replaced, the rest kept. A
    /// copy of the file as it was is left beside it, the first time.
    static func installClaudeStyle(at url: URL, agent: String, events: [(hook: String, event: String)]) throws {
        var settings = try readJSON(url)
        var hooks = withoutOurs(settings["hooks"] as? [String: Any] ?? [:])
        for (hook, event) in events {
            var groups = hooks[hook] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command(event, agent: agent), "timeout": 10]]])
            hooks[hook] = groups
        }
        settings["hooks"] = hooks
        try writeJSON(settings, to: url)
    }

    static func uninstallClaudeStyle(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var settings = try readJSON(url)
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let rest = withoutOurs(hooks)
        if rest.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = rest }
        try writeJSON(settings, to: url)
    }

    /// Hooks with ours taken out (and groups or events left empty with them).
    static func withoutOurs(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let others = list.filter { !isOurs(($0["command"] as? String) ?? "") }
                if others.isEmpty { return nil }
                var g = group
                g["hooks"] = others
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkillError("isn't a JSON object")
        }
        return object
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        backUp(url)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// The file as it was before Manifold first touched it, beside it.
    static func backUp(_ url: URL) {
        let copy = url.appendingPathExtension("before-manifold")
        guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    // MARK: Pi

    /// Pi has no command hooks: an extension of its own, in TypeScript, in
    /// its user extensions, that runs `mani agent` on its events
    /// without waiting for it (and does nothing outside Manifold).
    static func piExtension(tool: String = maniTool) -> String {
        // The path as a JavaScript string.
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [tool], options: .withoutEscapingSlashes), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"mani\""
        return piExtensionTemplate.replacingOccurrences(of: "\"mani\", [\"agent\"", with: "\(quoted), [\"agent\"")
    }

    static let piExtensionTemplate = """
        // Manifold's hooks for pi: a Manifold terminal shows pi's status and
        // each of its turns on its scrubber and outline. Put here by
        // `mani skill install`; `mani skill uninstall` takes it out.
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        export default function (pi: ExtensionAPI) {
          if (!process.env.MANIFOLD_BLOCK) return;
          const tell = (event: string, data: Record<string, unknown> = {}) => {
            void pi.exec("mani", ["agent", event, "--agent", "pi", "--no-input", JSON.stringify(data)], { timeout: 5000 }).catch(() => {});
          };
          pi.on("session_start", async () => tell("start"));
          pi.on("input", async (event) => {
            tell("prompt", { prompt: event.text });
            return { action: "continue" };
          });
          pi.on("agent_start", async () => tell("working"));
          pi.on("agent_settled", async () => tell("stop"));
          pi.on("session_shutdown", async () => tell("end"));
        }

        """

    static func installPiExtension(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(piExtension().utf8).write(to: url, options: .atomic)
    }

    static func uninstallPiExtension(at url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8), isOurPiExtension(text) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Whether pi's extension file is the one put there (by `mani`, or
    /// by `manifold` as it was).
    static func isOurPiExtension(_ text: String) -> Bool {
        text.contains("mani skill install") || text.contains("manifold --install-skill")
    }

    // MARK: Moving hooks over

    /// Hooks put in when the command was `manifold`, moved over to `mani`:
    /// one running `<folder>/manifold` runs `<folder>/mani` once that's
    /// there (the same copy of Manifold, renamed, never another); a bare
    /// `manifold`, a bare `mani`. Nothing else is touched. Run as the app
    /// and each host's server start.
    /// A second instance (MANIFOLD_DIR) leaves them be: they're the user's,
    /// for the Manifold they use.
    public static func refresh() {
        guard (ProcessInfo.processInfo.environment["MANIFOLD_DIR"] ?? "").isEmpty else { return }
        for t in targets { try? t.refresh() }
    }

    /// A hook's command moved over to `mani`; nil if it needn't (or can't
    /// yet) be.
    static func movedOver(_ command: String) -> String? {
        if command.contains("|| manifold agent ") {
            return command.replacingOccurrences(of: "|| manifold agent ", with: "|| mani agent ")
        }
        guard let end = command.range(of: "/manifold' agent "),
              let start = command.range(of: "|| '", options: .backwards, range: command.startIndex..<end.lowerBound) else { return nil }
        let folder = command[start.upperBound..<end.lowerBound].replacingOccurrences(of: "'\\''", with: "'")
        guard FileManager.default.isExecutableFile(atPath: folder + "/mani") else { return nil }
        return command.replacingCharacters(in: end, with: "/mani' agent ")
    }

    static func refreshClaudeStyle(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var settings = try readJSON(url)
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        var changed = false
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            out[event] = groups.map { group -> [String: Any] in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                var g = group
                g["hooks"] = list.map { hook -> [String: Any] in
                    guard let c = hook["command"] as? String, isOurs(c), let moved = movedOver(c) else { return hook }
                    changed = true
                    var h = hook
                    h["command"] = moved
                    return h
                }
                return g
            }
        }
        guard changed else { return }
        settings["hooks"] = out
        try writeJSON(settings, to: url)
    }

    static func refreshPiExtension(at url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8), isOurPiExtension(text),
              let call = text.range(of: "pi.exec("), let args = text.range(of: ", [\"agent\"", range: call.upperBound..<text.endIndex),
              let data = ("[" + text[call.upperBound..<args.lowerBound] + "]").data(using: .utf8),
              let tool = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first else { return }
        let moved: String
        if tool == "manifold" {
            moved = "mani"
        } else if tool.hasSuffix("/manifold") {
            moved = String(tool.dropLast("manifold".count)) + "mani"
            guard FileManager.default.isExecutableFile(atPath: moved) else { return }
        } else {
            return
        }
        try Data(piExtension(tool: moved).utf8).write(to: url, options: .atomic)
    }

    // MARK: The guide, where agents read it

    /// Claude Code's skill: the guide, with what it's for, which Claude
    /// Code reads to know when to load it.
    static var skillFile: String {
        """
        ---
        name: manifold
        description: Use when running in a Manifold terminal (MANIFOLD_BLOCK is set) and the user refers to what's on their screen — "the code I highlighted", "the diff on my right", "this PDF", "the page I have open", "the tests in the other terminal" — or asks to show, render or open something beside you, run something in another terminal, or make a small UI (a form, a choice, progress). The mani command reads and drives Manifold.
        ---

        \(Mani.guide)
        """
    }

    static let agentsBegin = "<!-- manifold: put here by `mani skill install`; `mani skill uninstall` takes it out -->"
    static let agentsEnd = "<!-- /manifold -->"

    /// What goes in Codex's AGENTS.md (which it reads every time): a few
    /// lines that say where the guide is.
    static var agentsNote: String {
        """
        \(agentsBegin)
        ## Manifold

        In a Manifold terminal (MANIFOLD_BLOCK is set), the `mani` command reads and drives
        what's on the user's screen: `mani read @selection` is the text they highlighted,
        `mani read @right:diff` the diff to the right of this terminal, `mani context` all of
        it at once; `… | mani new note --preview` shows a result beside you; `mani run <terminal>
        --wait <command>` runs a command in another terminal; `mani ui new` makes a small UI.
        Run `mani skill show` for the whole guide before using it.
        \(agentsEnd)
        """
    }

    static func installSkillFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(skillFile.utf8).write(to: url, options: .atomic)
    }

    static func uninstallSkillFile(at url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---\nname: manifold\n") else { return }
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The skill rewritten when the guide has changed (a new Manifold).
    static func refreshSkillFile(at url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---\nname: manifold\n"), text != skillFile else { return }
        try installSkillFile(at: url)
    }

    /// AGENTS.md with Manifold's lines in it (in place of any before), the
    /// rest as it was.
    static func installAgentsNote(at url: URL) throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var rest = withoutAgentsNote(old)
        if !rest.isEmpty, !rest.hasSuffix("\n\n") { rest += rest.hasSuffix("\n") ? "\n" : "\n\n" }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        backUp(url)
        try Data((rest + agentsNote + "\n").utf8).write(to: url, options: .atomic)
    }

    static func uninstallAgentsNote(at url: URL) throws {
        guard let old = try? String(contentsOf: url, encoding: .utf8), old.contains(agentsBegin) else { return }
        let rest = withoutAgentsNote(old)
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try Data(rest.utf8).write(to: url, options: .atomic)
        }
    }

    static func refreshAgentsNote(at url: URL) throws {
        guard let old = try? String(contentsOf: url, encoding: .utf8), old.contains(agentsBegin), !old.contains(agentsNote) else { return }
        try installAgentsNote(at: url)
    }

    /// A file's text with Manifold's lines taken out.
    static func withoutAgentsNote(_ text: String) -> String {
        guard let start = text.range(of: agentsBegin), let end = text.range(of: agentsEnd, range: start.upperBound..<text.endIndex) else { return text }
        let out = (String(text[..<start.lowerBound]) + String(text[end.upperBound...])).trimmingCharacters(in: .newlines)
        return out.isEmpty ? "" : out + "\n"
    }

    struct SkillError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }
}
