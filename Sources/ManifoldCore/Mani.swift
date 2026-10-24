import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `mani`, Manifold's command: `mani <command> [flags] [args]`. One table
/// of commands makes the parser, `mani help` and each command's `--help`,
/// so what's said and what's done can't drift apart. Shared by the app's
/// `mani` (in its Helpers) and a remote host's, which runs `manifoldd mani`;
/// each says how it reaches the host (`Platform`).
///
/// Strict: an unknown command or flag, a flag without its value, too many
/// or too few arguments are errors, with the command's usage, status 2;
/// a failure doing it is status 1. What's asked for goes to stdout, what
/// went wrong to stderr.
public enum Mani {
    public static let name = "mani"

    public struct Flag: Sendable {
        public var name: String
        public var short: Character?
        /// The value's name, for one that takes a value ("--title name").
        public var value: String?
        public var help: String
    }

    public struct Verb: Sendable {
        /// "open", or "skill install": a command of a group.
        public var words: [String]
        /// What follows the flags, as usage shows it: "[path ...]".
        public var args: String
        public var minArgs: Int
        public var maxArgs: Int?
        public var flags: [Flag]
        public var summary: String
        public var details: String

        public var name: String { words.joined(separator: " ") }

        /// "mani open [--wait] [path ...]".
        public var usage: String {
            let flagPart = flags.map { f in "[--\(f.name)\(f.value.map { " " + $0 } ?? "")]" }
            return ([Mani.name, name] + flagPart + (args.isEmpty ? [] : [args])).joined(separator: " ")
        }
    }

    public static let verbs: [Verb] = [
        Verb(words: ["open"], args: "[path ...]", minArgs: 0, maxArgs: nil,
             flags: [Flag(name: "wait", short: "w", help: "return once they've been put away again (what $EDITOR runs)")],
             summary: "Open files and folders in Manifold",
             details: """
                 Markdown opens in a live preview, a folder in a listing, anything
                 else in an editor. Run in one of Manifold's terminals, they open
                 beside it; anywhere else, in the shown workspace, with Manifold
                 brought forward (and started if need be). With no paths, brings
                 Manifold forward.
                 """),
        Verb(words: ["diff"], args: "< patch", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "title", short: "t", value: "name", help: "the diff block's title")],
             summary: "Show a patch as a diff block",
             details: """
                 Reads a patch from the input (git diff | mani diff) and shows it
                 beside this terminal as a diff block; double-click a line to open
                 the file there.
                 """),
        Verb(words: ["skill", "install"], args: "[agent ...]", minArgs: 0, maxArgs: nil, flags: [],
             summary: "Put Manifold's hooks in coding agents",
             details: """
                 Hooks in the coding agents found here, or those named (of
                 \(AgentSkill.known.joined(separator: ", "))), so a Manifold terminal running one shows
                 its status, and each of its turns on the scrubber and in the
                 outline. The hooks run `mani agent`, and do nothing outside
                 Manifold's terminals. Installing again replaces them.
                 """),
        Verb(words: ["skill", "uninstall"], args: "[agent ...]", minArgs: 0, maxArgs: nil, flags: [],
             summary: "Take Manifold's hooks out of coding agents",
             details: "Takes out what `mani skill install` put in: of the agents found here, or those named."),
        Verb(words: ["agent"], args: "<event> [json]", minArgs: 1, maxArgs: 2,
             flags: [Flag(name: "agent", value: "name", help: "the agent the hook is in (claude, codex, ...)"),
                     Flag(name: "no-input", help: "read nothing from the input")],
             summary: "What agents' hooks run",
             details: """
                 Tells the terminal it runs in what its agent is doing, so the
                 terminal shows its status and turns. The event is one of
                 \(AgentHookCommand.events.joined(separator: ", ")). Reads the hook's JSON from the
                 input, or as the last argument. Prints nothing and always
                 succeeds once it's understood: no agent waits on it.
                 """),
        Verb(words: ["help"], args: "[command]", minArgs: 0, maxArgs: 2, flags: [],
             summary: "Say what mani does, or what a command does",
             details: "With a command, its usage, flags and what it does."),
    ]

    /// What was asked for.
    public enum Parsed: Equatable, Sendable {
        case run(Invocation)
        /// Help: about a command (its name), or about mani.
        case help(String?)
    }

    public struct Invocation: Equatable, Sendable {
        public var verb: String
        /// Flags given, by name: a value, or "" for one that takes none.
        public var flags: [String: String]
        public var args: [String]

        public func has(_ flag: String) -> Bool { flags[flag] != nil }
        public func value(_ flag: String) -> String? { flags[flag] }
    }

    public struct UsageError: Error, Equatable, Sendable {
        public var message: String
        /// The command it's about, whose usage goes with it.
        public var verb: String?
    }

    public static func verb(_ name: String) -> Verb? { verbs.first { $0.name == name } }

    /// The argument list (less the program's name) as a command.
    public static func parse(_ argv: [String]) -> Result<Parsed, UsageError> {
        guard let first = argv.first else { return .success(.help(nil)) }
        if first == "-h" || first == "--help" { return .success(.help(nil)) }
        if first.hasPrefix("-") {
            return .failure(UsageError(message: "\(first) isn't a command; the command comes first"))
        }
        let groups = Set(verbs.filter { $0.words.count > 1 }.map { $0.words[0] })
        // The longest command the words begin with.
        guard let verb = verbs.filter({ argv.starts(with: $0.words) }).max(by: { $0.words.count < $1.words.count }) else {
            if groups.contains(first) {
                let next = argv.dropFirst().first
                if next == "-h" || next == "--help" { return .success(.help(first)) }
                let subs = verbs.filter { $0.words[0] == first }.map { $0.words[1] }
                let message = next.map { "\(first) has no command \($0)" } ?? "\(first) needs a command"
                return .failure(UsageError(message: message + ": " + subs.joined(separator: ", "), verb: first))
            }
            var message = "no command \(first)"
            if FileManager.default.fileExists(atPath: first.expandingTildeInPath) { message += " (to open it: mani open \(first))" }
            return .failure(UsageError(message: message))
        }
        var flags: [String: String] = [:]
        var args: [String] = []
        var rest = argv.dropFirst(verb.words.count).makeIterator()
        var onlyArgs = false
        while let a = rest.next() {
            if onlyArgs || a == "-" || !a.hasPrefix("-") {
                args.append(a)
                continue
            }
            if a == "--" {
                onlyArgs = true
                continue
            }
            if a == "-h" || a == "--help" { return .success(.help(verb.name)) }
            var given = a
            var inline: String?
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                given = String(a[..<eq])
                inline = String(a[a.index(after: eq)...])
            }
            let flag = given.hasPrefix("--")
                ? verb.flags.first { "--" + $0.name == given }
                : verb.flags.first { $0.short.map { "-\($0)" } == given }
            guard let flag else {
                return .failure(UsageError(message: "\(verb.name) has no flag \(given)", verb: verb.name))
            }
            if flag.value != nil {
                guard let value = inline ?? rest.next() else {
                    return .failure(UsageError(message: "--\(flag.name) needs a value", verb: verb.name))
                }
                flags[flag.name] = value
            } else {
                guard inline == nil else {
                    return .failure(UsageError(message: "--\(flag.name) takes no value", verb: verb.name))
                }
                flags[flag.name] = ""
            }
        }
        if args.count < verb.minArgs {
            return .failure(UsageError(message: "\(verb.name) needs \(verb.args)", verb: verb.name))
        }
        if let max = verb.maxArgs, args.count > max {
            let extra = args[max]
            return .failure(UsageError(message: max == 0 ? "\(verb.name) takes no arguments (\(extra))" : "\(verb.name) takes at most \(max) (\(extra))", verb: verb.name))
        }
        if verb.name == "help" {
            guard !args.isEmpty else { return .success(.help(nil)) }
            let name = args.joined(separator: " ")
            guard Self.verb(name) != nil || groups.contains(name) else {
                return .failure(UsageError(message: "no command \(name)", verb: "help"))
            }
            return .success(.help(name))
        }
        return .success(.run(Invocation(verb: verb.name, flags: flags, args: args)))
    }

    /// What `mani help` says: every command, a line each; or a command's
    /// (or a group's) usage, what it does and its flags.
    public static func help(_ name: String?) -> String {
        guard let name else {
            let width = verbs.map { ($0.name + " " + $0.args).count }.max() ?? 0
            let lines = verbs.map { v -> String in
                let left = v.name + (v.args.isEmpty ? "" : " " + v.args)
                return "  " + left.padding(toLength: width + 2, withPad: " ", startingAt: 0) + v.summary
            }
            return """
                usage: mani <command> [flags] [args]

                Manifold, from a shell. Run in one of Manifold's terminals, mani acts
                beside it.

                \(lines.joined(separator: "\n"))

                mani <command> --help says more about one.
                """
        }
        let matching = verbs.filter { $0.name == name || $0.words.first == name && $0.words.count > 1 }
        return matching.map { v in
            var out = "usage: \(v.usage)\n\n\(v.details)"
            if !v.flags.isEmpty {
                let names = v.flags.map { f in (f.short.map { "-\($0), " } ?? "") + "--\(f.name)" + (f.value.map { " " + $0 } ?? "") }
                let width = names.map(\.count).max() ?? 0
                out += "\n\n" + zip(names, v.flags).map { "  " + $0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $1.help }.joined(separator: "\n")
            }
            return out
        }.joined(separator: "\n\n")
    }

    /// How a platform's `mani` reaches the host.
    public struct Platform {
        /// Has the host do `body` over a connection to it (a socket's fd),
        /// starting what must be started and asking again if it was:
        /// the exit status.
        public var request: (_ body: (Int32) -> Int32) -> Int32
        /// Brings Manifold forward, starting it if need be; nil where
        /// there's no app (a remote host).
        public var bringForward: (() -> Void)?

        public init(request: @escaping (_ body: (Int32) -> Int32) -> Int32, bringForward: (() -> Void)?) {
            self.request = request
            self.bringForward = bringForward
        }
    }

    /// The block this runs in: one of Manifold's terminals says (MANIFOLD_BLOCK).
    public static var here: BlockID? {
        ProcessInfo.processInfo.environment["MANIFOLD_BLOCK"].flatMap(BlockID.init(string:))
    }

    /// Runs the command line and exits.
    public static func main(_ argv: [String], platform: Platform) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let invocation: Invocation
        switch parse(argv) {
        case .failure(let error): usageError(error)
        case .success(.help(let name)):
            print(help(name))
            exit(0)
        case .success(.run(let i)): invocation = i
        }
        switch invocation.verb {
        case "open":
            let paths: [String]
            switch OpenCommand.resolve(invocation.args) {
            case .success(let p): paths = p
            case .failure(let error): fail(error.message)
            }
            if paths.isEmpty {
                guard let bringForward = platform.bringForward else {
                    usageError(UsageError(message: "open needs a path here: there's no Manifold on this host to bring forward", verb: "open"))
                }
                bringForward()
                exit(0)
            }
            let wait = invocation.has("wait")
            exit(platform.request { OpenCommand.run(fd: $0, paths: paths, beside: here, wait: wait) })
        case "diff":
            let patch: String
            switch OpenCommand.readPatch() {
            case .success(let p): patch = p
            case .failure(let error): fail(error.message)
            }
            let root = FileManager.default.currentDirectoryPath
            let title = invocation.value("title")
            exit(platform.request { OpenCommand.runPatch(fd: $0, patch: patch, root: root, title: title, beside: here) })
        case "skill install", "skill uninstall":
            let names = invocation.args.map { $0.lowercased() }
            if let unknown = names.first(where: { !AgentSkill.known.contains($0) }) {
                usageError(UsageError(message: "no hooks known for \(unknown); known: \(AgentSkill.known.joined(separator: ", "))", verb: invocation.verb))
            }
            AgentSkill.runInstall(names, uninstall: invocation.verb == "skill uninstall")
        case "agent":
            let event = invocation.args[0]
            guard AgentHookCommand.events.contains(event) else {
                usageError(UsageError(message: "no event \(event); events: \(AgentHookCommand.events.joined(separator: ", "))", verb: "agent"))
            }
            AgentHookCommand.run(event: event, agent: invocation.value("agent") ?? "agent",
                                 readsInput: !invocation.has("no-input"), payload: invocation.args.dropFirst().first)
        default:
            fail("\(invocation.verb) isn't done yet")
        }
    }

    /// What went wrong and the usage that goes with it, on stderr; status 2.
    public static func usageError(_ error: UsageError) -> Never {
        var out = "mani: \(error.message)\n"
        let group = verbs.filter { $0.words.count > 1 && $0.words[0] == error.verb }
        if let name = error.verb, let v = verb(name) {
            out += "usage: \(v.usage)\n(mani \(name) --help says more)\n"
        } else if let name = error.verb, !group.isEmpty {
            out += group.map { "usage: \($0.usage)\n" }.joined() + "(mani \(name) --help says more)\n"
        } else {
            out += "commands: \(verbs.map(\.name).joined(separator: ", "))\n(mani help says more)\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
        exit(2)
    }

    public static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("mani: \(message)\n".utf8))
        exit(1)
    }
}
