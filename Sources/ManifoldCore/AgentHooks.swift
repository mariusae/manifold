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

    public var agent: String {
        switch self {
        case let .started(a), let .prompt(a, _, _), let .working(a), let .finished(a, _, _), let .todos(a, _), let .waiting(a, _), let .ended(a): a
        }
    }
}

/// `manifold agent <event> --agent <name>`: what an agent's hook runs.
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
    public static let usage = """
        usage: manifold agent <start|prompt|working|stop|waiting|end> [--agent name]

        What an agent's hooks run, so a Manifold terminal shows the agent's
        status and each of its turns on the scrubber and in the outline.
        Reads the hook's JSON from the input (or the last argument).
        `manifold --install-skill` puts these hooks in the agents found here.
        """

    /// Runs and exits.
    public static func run(_ args: [String]) -> Never {
        var rest = args
        var agent = "agent"
        if let i = rest.firstIndex(of: "--agent"), i + 1 < rest.count {
            agent = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
        }
        // MetaCode runs Claude Code's hooks as its own.
        if agent == "claude", ProcessInfo.processInfo.environment["METACODE_SESSION_ID"] != nil { agent = "metacode" }
        // A caller that hands over nothing on the input (pi's extension).
        let readsInput = !rest.contains("--no-input")
        rest.removeAll { $0 == "--no-input" }
        guard let name = rest.first else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(0)
        }
        // Outside Manifold's terminals there is no one to tell.
        guard let block = ProcessInfo.processInfo.environment["MANIFOLD_BLOCK"].flatMap(BlockID.init(string:)) else { exit(0) }
        var input = readsInput ? readInput() : [:]
        if let last = rest.dropFirst().last, last.hasPrefix("{"), let data = last.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            input.merge(json) { _, new in new }
        }
        guard let event = event(name, agent: agent, input: input) else { exit(0) }
        send(event, about: block)
        exit(0)
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
        case "working":
            // A tool ran; the to-do list one (TodoWrite), with the list.
            if string("tool_name") == "TodoWrite", let tool = input["tool_input"] as? [String: Any], let items = tool["todos"] as? [[String: Any]] {
                return .todos(agent: agent, items.compactMap { i in
                    (i["content"] as? String).map { AgentTodo(text: $0, status: i["status"] as? String ?? "pending") }
                })
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
        let data = Frame.message(ClientMessage.agent(block: block, event)).encoded
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return }
            }
        }
    }
}
