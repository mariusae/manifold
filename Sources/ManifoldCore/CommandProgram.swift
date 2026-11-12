import Foundation

/// The program a shell's command line runs (§3.7): its first word's name,
/// past what only sets it going — `sudo`, `env`, `time`, `nice`, `nohup`,
/// `exec`, `command`, `caffeinate`, a variable set before it (`FOO=1`) and
/// their flags — and through a runner to what it runs, when that's named
/// (`npx vite`, `uv run pytest`, `bunx`, `pnpm dlx`). What a terminal's tile
/// is marked with while it runs.
public enum CommandProgram {
    /// Words that only set the next going.
    static let wrappers: Set<String> = ["sudo", "env", "time", "nice", "nohup", "exec", "command", "caffeinate", "doas", "builtin", "noglob"]
    /// Runners: the word after them (past `run`, `exec`, `dlx`, flags) is the program.
    static let runners: Set<String> = ["npx", "bunx", "uvx", "pnpx"]
    static let runnersWithVerb: [String: Set<String>] = ["uv": ["run", "tool"], "pnpm": ["dlx", "exec"], "npm": ["exec"], "bun": ["x"],
                                                         "poetry": ["run"], "pipenv": ["run"], "bundle": ["exec"], "cargo": [], "go": []]

    public static func program(in line: String) -> String? {
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Only the first of a pipeline or a list of commands.
        if let cut = words.firstIndex(where: { ["|", "&&", "||", ";", "|&"].contains($0) }) { words = Array(words[..<cut]) }
        var i = 0
        func skipFlagsAndAssignments() {
            while i < words.count, words[i].hasPrefix("-") || (words[i].contains("=") && !words[i].hasPrefix("=")) { i += 1 }
        }
        skipFlagsAndAssignments()
        while i < words.count, wrappers.contains(name(words[i])) {
            i += 1
            skipFlagsAndAssignments()
            // A flag's value (`nice -n 5`): a number isn't a program.
            while i < words.count, Double(words[i]) != nil { i += 1; skipFlagsAndAssignments() }
        }
        guard i < words.count else { return nil }
        let first = name(words[i])
        // A runner: what it runs, if it says.
        if runners.contains(first) {
            i += 1
            skipFlagsAndAssignments()
            return i < words.count ? name(words[i]) : first
        }
        if let verbs = runnersWithVerb[first], !verbs.isEmpty, i + 1 < words.count, verbs.contains(words[i + 1]) {
            i += 2
            if first == "uv", words[i - 1] == "tool", i < words.count, words[i] == "run" { i += 1 }
            skipFlagsAndAssignments()
            return i < words.count ? name(words[i]) : first
        }
        return first.isEmpty ? nil : first
    }

    /// A word's program name: its path's last part, without quotes.
    static func name(_ word: String) -> String {
        let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
        return (w as NSString).lastPathComponent
    }
}
