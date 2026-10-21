import Foundation

/// `manifold --install-skill`: hooks in each coding agent found on this
/// machine (or those named) that run `manifold agent` on the agent's
/// events, so a Manifold terminal running it shows its status and each of
/// its turns. The hooks do nothing outside Manifold's terminals (no
/// MANIFOLD_BLOCK), and installing again replaces them; --uninstall-skill
/// takes them out. Whatever else the agents' settings hold is kept.
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
        /// What to tell the user once it's in.
        var note: String? = nil
    }

    /// The command a hook runs for `event`: nothing outside Manifold's
    /// terminals, else `manifold agent` — this `manifold`, by its full
    /// path, not whichever one comes first on the agent's PATH — which
    /// always succeeds.
    static func command(_ event: String, agent: String, tool: String = manifoldTool) -> String {
        "[ -z \"$MANIFOLD_BLOCK\" ] || \(shellQuoted(tool)) agent \(event) --agent \(agent)"
    }

    /// Whether a hook's command is one of ours (bare `manifold`, as they
    /// were once put in, or by its path), to replace or take out.
    static func isOurs(_ command: String) -> Bool {
        command.contains("manifold agent ") || command.contains("manifold' agent ")
    }

    /// The `manifold` command installing the hooks, by its full path: this
    /// program if it is `manifold` (the app's, in its Helpers), else the
    /// `manifold` beside it (on a remote host, the script that runs this
    /// server); the bare name only if there's none to be found.
    static var manifoldTool: String {
        guard let exe = ownExecutable else { return "manifold" }
        if exe.lastPathComponent == "manifold" { return exe.path }
        let dir = exe.deletingLastPathComponent()
        // The app's Helpers first; and the name exactly so, as the folder
        // lists it — on a disk that ignores case, the app's own `Manifold`
        // beside the server would answer to `manifold`.
        for folder in [dir.deletingLastPathComponent().appendingPathComponent("Helpers"), dir] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let candidate = folder.appendingPathComponent("manifold")
            if names.contains("manifold"), FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return "manifold"
    }

    /// This program's own file, wherever it was run from (argv[0] is only
    /// what was typed: `manifold`, found on the PATH).
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
        let museDir = env["MUSE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")).appendingPathComponent("muse")
        let muse = museDir.appendingPathComponent("settings.json")
        let piDir = env["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".pi/agent")
        let pi = piDir.appendingPathComponent("extensions/manifold.ts")
        func here(_ command: String, _ dir: URL) -> () -> Bool {
            { onPath(command) || FileManager.default.fileExists(atPath: dir.path) }
        }
        return [
            // MetaCode reads Claude Code's hooks too; `manifold agent` tells them apart.
            Target(name: "claude", file: claude, present: here("claude", claude.deletingLastPathComponent()),
                   install: { try installClaudeStyle(at: claude, agent: "claude", events: claudeEvents) },
                   uninstall: { try uninstallClaudeStyle(at: claude) }),
            Target(name: "codex", file: codex, present: here("codex", codexHome),
                   install: { try installClaudeStyle(at: codex, agent: "codex", events: codexEvents) },
                   uninstall: { try uninstallClaudeStyle(at: codex) },
                   note: "Codex asks to review new hooks once: choose Review hooks (or /hooks) and trust Manifold's."),
            Target(name: "muse", file: muse, present: here("muse", museDir),
                   install: { try installClaudeStyle(at: muse, agent: "muse", events: museEvents) },
                   uninstall: { try uninstallClaudeStyle(at: muse) }),
            Target(name: "pi", file: pi, present: here("pi", piDir),
                   install: { try installPiExtension(at: pi) },
                   uninstall: { try uninstallPiExtension(at: pi) },
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

    /// Installs (or takes out) the hooks, saying what it did; then exits.
    public static func runInstall(_ names: [String], uninstall: Bool) -> Never {
        let wanted = names.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        let unknown = wanted.filter { w in !targets.contains { $0.name == w } }
        if !unknown.isEmpty {
            print("manifold: no hooks known for \(unknown.joined(separator: ", ")); known: \(targets.map(\.name).joined(separator: ", "))")
        }
        var failed = false
        var did = 0
        for t in targets where wanted.isEmpty ? t.present() : wanted.contains(t.name) {
            do {
                if uninstall { try t.uninstall() } else { try t.install() }
                print("\(uninstall ? "took Manifold's hooks out of" : "installed Manifold's hooks for") \(t.name): \(short(t.file))")
                if !uninstall, let note = t.note { print("  \(note)") }
                did += 1
            } catch {
                print("manifold: couldn't \(uninstall ? "uninstall" : "install") hooks for \(t.name) (\(short(t.file))): \(error)")
                failed = true
            }
        }
        if did == 0, !failed { print("manifold: no coding agents found here (\(targets.map(\.name).joined(separator: ", ")))") }
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
    /// its user extensions, that runs `manifold agent` on its events
    /// without waiting for it (and does nothing outside Manifold).
    static func piExtension(tool: String = manifoldTool) -> String {
        // The path as a JavaScript string.
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [tool], options: .withoutEscapingSlashes), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"manifold\""
        return piExtensionTemplate.replacingOccurrences(of: "\"manifold\", [\"agent\"", with: "\(quoted), [\"agent\"")
    }

    static let piExtensionTemplate = """
        // Manifold's hooks for pi (manifold --install-skill): a Manifold terminal
        // shows pi's status and each of its turns on its scrubber and outline.
        // Put here by `manifold --install-skill`; `manifold --uninstall-skill`
        // takes it out.
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        export default function (pi: ExtensionAPI) {
          if (!process.env.MANIFOLD_BLOCK) return;
          const tell = (event: string, data: Record<string, unknown> = {}) => {
            void pi.exec("manifold", ["agent", event, "--agent", "pi", "--no-input", JSON.stringify(data)], { timeout: 5000 }).catch(() => {});
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
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("manifold --install-skill") else { return }
        try FileManager.default.removeItem(at: url)
    }

    struct SkillError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }
}
