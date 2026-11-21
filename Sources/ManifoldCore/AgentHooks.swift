import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What an agent's hook says happened (§3.7, §3.8), for agents that don't
/// say it themselves in OSC 7501: each turn becomes a mark on the
/// terminal's scrubber and outline, as a shell's command does, and the
/// agent's status the block's.
public enum AgentEvent: Codable, Equatable, Sendable {
    /// A session began: the agent is there, waiting.
    case started(agent: String)
    /// The user's prompt: a turn begins, named by it; where the agent's
    /// transcript is, if it says.
    case prompt(agent: String, text: String, transcript: String?)
    /// Working again (a tool ran, a permission was given).
    case working(agent: String)
    /// The turn is over: its last words, if the hook has them.
    case finished(agent: String, message: String?, transcript: String?)
    /// The agent's to-do list as it now stands (Claude Code's TodoWrite).
    case todos(agent: String, [AgentTodo])
    /// Waiting on the user: a permission, a question.
    case waiting(agent: String, message: String?)
    /// The session ended.
    case ended(agent: String)
    /// A tool wrote a file (Edit, Write): working, and which file — so an
    /// edit to a thread's place there is the agent's (§3.12).
    case wrote(agent: String, path: String)
    /// About to use a tool: what it's doing, as it says it (the tool's
    /// description — Claude Code's Bash and Task carry one — its to-do
    /// item's "active form"), else in a few words ("Reading main.swift").
    case doing(agent: String, what: String)

    public var agent: String {
        switch self {
        case let .started(a), let .prompt(a, _, _), let .working(a), let .finished(a, _, _), let .todos(a, _), let .waiting(a, _), let .ended(a), let .wrote(a, _), let .doing(a, _): a
        }
    }

    /// What a tool about to be used is doing, in a line: as the agent
    /// describes it, else made from what it works on; nil for one with
    /// nothing to say (an MCP tool's call).
    public static func doing(tool: String, input: [String: Any]) -> String? {
        func s(_ k: String) -> String? { (input[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ p: String) -> String { p.split(separator: "/").last.map(String.init) ?? p }
        func cap(_ t: String) -> String { String(t.split(whereSeparator: \.isNewline).first ?? "").prefix(160).description }
        if tool == "TodoWrite", let items = input["todos"] as? [[String: Any]],
           let now = items.first(where: { $0["status"] as? String == "in_progress" }) {
            return ((now["activeForm"] as? String) ?? (now["content"] as? String)).map(cap)
        }
        if let d = s("description") { return cap(d) }
        let path = s("file_path") ?? s("notebook_path") ?? s("path")
        switch tool {
        case "Read", "NotebookRead": return path.map { "Reading " + file($0) } ?? "Reading"
        case "Edit", "MultiEdit", "NotebookEdit": return path.map { "Editing " + file($0) } ?? "Editing"
        case "Write": return path.map { "Writing " + file($0) } ?? "Writing"
        case "Grep", "Glob": return s("pattern").map { "Searching for " + cap($0).prefix(60) } ?? "Searching"
        case "LS": return path.map { "Looking in " + file($0) } ?? "Looking around"
        case "WebFetch": return s("url").flatMap { URL(string: $0)?.host }.map { "Reading " + $0 } ?? "Reading the web"
        case "WebSearch": return s("query").map { "Searching the web for " + cap($0).prefix(60) } ?? "Searching the web"
        case "Bash": return s("command").map { "Running " + cap($0).prefix(60) }
        case "Task", "Agent": return "Asking a subagent"
        default: return nil
        }
    }
}

/// `mani agent <event> --agent <name>`: what an agent's hook runs.
/// It reads what the agent hands its hooks (JSON on the input, or as the
/// last argument, as Codex's notify has it), tells the host the block it
/// runs in what happened, and gets out of the way: it prints nothing and
/// always succeeds, so no agent ever waits on it or shows its errors.
/// An item of an agent's to-do list.
public struct AgentTodo: Codable, Equatable, Sendable {
    public var text: String
    /// "pending", "in_progress" or "completed".
    public var status: String
    public init(text: String, status: String) {
        self.text = text
        self.status = status
    }
}

public enum AgentHookCommand {
    /// The events a hook can say.
    public static let events = ["start", "prompt", "doing", "working", "stop", "waiting", "end"]

    /// Tells the host `name` happened in the block this runs in, and exits:
    /// `input` read from the input unless not `readsInput` (pi's extension
    /// hands over nothing there), `payload` the JSON a caller passes as an
    /// argument instead (Codex's notify).
    public static func run(event name: String, agent: String, readsInput: Bool, payload: String?) -> Never {
        var agent = agent
        // MetaCode runs Claude Code's hooks as its own.
        if agent == "claude", ProcessInfo.processInfo.environment["METACODE_SESSION_ID"] != nil { agent = "metacode" }
        // Outside Manifold's terminals there is no one to tell.
        guard let block = ProcessInfo.processInfo.environment["MANIFOLD_BLOCK"].flatMap(BlockID.init(string:)) else { exit(0) }
        var input = readsInput ? readInput() : [:]
        if let payload, payload.hasPrefix("{"), let data = payload.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            input.merge(json) { _, new in new }
        }
        guard let event = event(name, agent: agent, input: input) else { exit(0) }
        // A prompt, in an agent whose hook's output is read into its turn
        // (Claude Code's): what's happened in its threads, printed for it.
        if case .prompt = event, ["claude", "metacode"].contains(agent) {
            if let news = sendForNews(event, about: block), !news.isEmpty { print(news) }
            exit(0)
        }
        send(event, about: block)
        exit(0)
    }

    /// The event sent, and the agent's news waited for — a moment at most,
    /// a prompt not to be held up.
    private static func sendForNews(_ event: AgentEvent, about block: BlockID) -> String? {
        guard let fd = try? UnixSocket.connect(path: Paths.socket) else { return nil }
        defer { close(fd) }
        var channel = BlockingChannel(fd: fd)
        guard channel.send(.agent(block: block, event)) else { return nil }
        let until = Date().addingTimeInterval(1.5)
        while true {
            switch channel.next(until: until) {
            case let .message(.agentNews(text)): return text
            case .message: continue
            case .timedOut, .closed: return nil
            }
        }
    }

    /// The event a hook's name and input stand for; nil for one to let be
    /// (an idle reminder, say).
    public static func event(_ name: String, agent: String, input: [String: Any]) -> AgentEvent? {
        func string(_ keys: String...) -> String? {
            for k in keys { if let s = input[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        switch name {
        case "start": return .started(agent: agent)
        case "prompt":
            // Codex's notify names the turn's input messages; hooks, the prompt.
            let text = string("prompt", "user_prompt", "input")
                ?? (input["input-messages"] as? [String])?.last ?? (input["input_messages"] as? [String])?.last
            return .prompt(agent: agent, text: text ?? "", transcript: string("transcript_path"))
        case "doing":
            // A tool about to run: what it's for.
            guard let tool = string("tool_name"), let what = AgentEvent.doing(tool: tool, input: input["tool_input"] as? [String: Any] ?? [:]) else { return nil }
            return .doing(agent: agent, what: what)
        case "working":
            // A tool ran; the to-do list one (TodoWrite), with the list.
            if string("tool_name") == "TodoWrite", let tool = input["tool_input"] as? [String: Any], let items = tool["todos"] as? [[String: Any]] {
                return .todos(agent: agent, items.compactMap { i in
                    (i["content"] as? String).map { AgentTodo(text: $0, status: i["status"] as? String ?? "pending") }
                })
            }
            // A file written: which.
            if let tool = input["tool_input"] as? [String: Any], let path = (tool["file_path"] ?? tool["notebook_path"] ?? tool["path"]) as? String, !path.isEmpty,
               ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "write"].contains(string("tool_name") ?? "") {
                return .wrote(agent: agent, path: path)
            }
            return .working(agent: agent)
        case "stop":
            return .finished(agent: agent, message: string("last_assistant_message", "last-assistant-message", "message", "response"), transcript: string("transcript_path"))
        case "waiting":
            // A reminder that the agent is idle isn't waiting on anything.
            let kind = string("notification_type", "type") ?? ""
            if kind.contains("idle") { return nil }
            let message = string("message", "title")
            if let m = message?.lowercased(), m.contains("waiting for your input") { return nil }
            return .waiting(agent: agent, message: message)
        case "end": return .ended(agent: agent)
        default: return nil
        }
    }

    /// The hook's JSON on the input, if it's piped and comes at once.
    private static func readInput() -> [String: Any] {
        guard isatty(0) == 0 else { return [:] }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(1)
        while data.count < 4 << 20 {
            var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&pfd, 1, left) > 0 else { break }
            let n = read(0, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// The event, to the host this command runs on, as a connection's one
    /// message (no hello, nothing back): quick, for hooks that run often.
    private static func send(_ event: AgentEvent, about block: BlockID) {
        guard let fd = try? UnixSocket.connect(path: Paths.socket) else { return }
        defer { close(fd) }
        FD.writeAll(fd, Frame.message(ClientMessage.agent(block: block, event)).encoded)
    }
}
