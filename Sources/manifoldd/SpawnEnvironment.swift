import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What the server sets in the environment of what it starts (§8.6): the
/// host's variables, by scope, and SSH_AUTH_SOCK as its agent link. Kept
/// here, applied at each start, rather than set in the server's own
/// environment: setenv isn't safe while other threads read it.
enum SpawnEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var variables: [EnvironmentVariable] = []
    nonisolated(unsafe) private static var agent: String?

    /// Set by a bridge for the server it starts: its environment is a
    /// connection's, which will end — its SSH_AUTH_SOCK with it.
    static let bridgedKey = "MANIFOLD_BRIDGED"

    static func set(_ vars: [EnvironmentVariable]) {
        lock.lock()
        variables = vars
        lock.unlock()
    }

    /// SSH_AUTH_SOCK as given, or nil to leave it as the server has it.
    static func setAgent(_ link: String?) {
        lock.lock()
        agent = link
        lock.unlock()
    }

    static func apply(to env: inout [String: String], scope: EnvironmentScope) {
        lock.lock()
        let (vars, agent) = (variables, Self.agent)
        lock.unlock()
        env.removeValue(forKey: bridgedKey)
        if let agent { env["SSH_AUTH_SOCK"] = agent }
        for v in vars where v.scope.covers(scope) { env[v.name] = v.value }
    }

    static func environment(_ scope: EnvironmentScope) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        apply(to: &env, scope: scope)
        return env
    }

    /// What `mani env` lists: the variables and the agent's link.
    static var current: (variables: [EnvironmentVariable], agent: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (variables, agent)
    }
}

/// The host's agent link (§8.6): a symlink the server gives its shells as
/// SSH_AUTH_SOCK, pointed at the newest forwarded agent that answers — so a
/// shell started under one connection signs with the next, once that one's
/// gone, and new shells don't start with a dead one. Agents are those
/// forwarded to the server's bridges (each says so as it starts), to ssh
/// logins (sshd's sockets, `/tmp/ssh-*/agent.*`), and those `mani env
/// agent` names. A host with an agent of its own (a Mac's, from launchd)
/// that the server wasn't started over a connection with keeps it.
enum AgentLink {
    /// The link: in Manifold's folder if its path can name a socket (104
    /// bytes at most, on macOS) and has no spaces; else in the home.
    static var path: String {
        let own = Paths.directory.appendingPathComponent("agent.sock").path
        if own.utf8.count <= 100, !own.contains(" ") { return own }
        let home = NSHomeDirectory() + "/.manifold-agent.sock"
        if home.utf8.count <= 100 { return home }
        let tmp = "/tmp/manifold-\(getuid())"
        mkdir(tmp, 0o700)
        return tmp + "/agent.sock"
    }

    /// Where agents are noted: a file for each, holding its socket.
    static var folder: URL { Paths.directory.appendingPathComponent("agents") }

    struct Note: Codable {
        var socket: String
        var from: String
        /// The bridge that noted it, gone with it; nil for one named.
        var pid: Int32?
    }

    /// An agent noted: by a bridge as it starts (`pid` its own), or named.
    static func note(_ socket: String, from: String, pid: Int32?) {
        guard socket != path, isSocket(socket) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let name = pid.map { "bridge-\($0)" } ?? "named" + socket.replacingOccurrences(of: "/", with: "_")
        if let data = try? JSONEncoder().encode(Note(socket: socket, from: from, pid: pid)) {
            try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    /// A bridge's note taken away as it ends.
    static func forget(pid: Int32) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("bridge-\(pid)"))
    }

    struct Candidate {
        var socket: String
        var from: String
        var at: Date
    }

    /// Every agent that answers, newest first; notes of those gone deleted.
    static func candidates() -> [Candidate] {
        var found: [String: Candidate] = [:]
        func add(_ c: Candidate) {
            // One noted and found both: when it was noted, and by whom.
            if let old = found[c.socket], old.at >= c.at { return }
            found[c.socket] = c
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), let n = try? JSONDecoder().decode(Note.self, from: data) else {
                try? fm.removeItem(at: file)
                continue
            }
            let bridgeAlive = n.pid.map { kill($0, 0) == 0 || errno == EPERM } ?? true
            guard bridgeAlive, answers(n.socket) else {
                try? fm.removeItem(at: file)
                continue
            }
            let at = ((try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date) ?? .distantPast
            add(Candidate(socket: n.socket, from: n.from, at: at))
        }
        // sshd's, for the logins with an agent forwarded.
        let uid = getuid()
        for dir in (try? fm.contentsOfDirectory(atPath: "/tmp")) ?? [] where dir.hasPrefix("ssh-") {
            let d = "/tmp/" + dir
            var st = stat()
            guard lstat(d, &st) == 0, st.st_uid == uid, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasPrefix("agent.") {
                let s = d + "/" + f
                var ss = stat()
                guard found[s] == nil, lstat(s, &ss) == 0, ss.st_uid == uid, answers(s) else { continue }
                #if canImport(Darwin)
                let at = Date(timeIntervalSince1970: TimeInterval(ss.st_mtimespec.tv_sec))
                #else
                let at = Date(timeIntervalSince1970: TimeInterval(ss.st_mtim.tv_sec))
                #endif
                add(Candidate(socket: s, from: "forwarded to an ssh login", at: at))
            }
        }
        return found.values.sorted { $0.at > $1.at }
    }

    static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Something listens at the socket.
    static func answers(_ path: String) -> Bool {
        guard isSocket(path) else { return false }
        guard let fd = try? UnixSocket.connect(path: path) else { return false }
        close(fd)
        return true
    }

    /// Where the link points now, if it's there.
    static var target: String? {
        guard let t = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        return t
    }

    /// The link pointed at `socket`, at once (made beside it, renamed over).
    static func point(at socket: String) {
        guard target != socket else { return }
        let tmp = path + ".\(getpid())"
        unlink(tmp)
        guard symlink(socket, tmp) == 0 else { return }
        if rename(tmp, path) != 0 { unlink(tmp) }
    }

    /// The link pointed at the newest agent that answers, if any does (if
    /// none, left as it was: the next to come will be pointed at). Returns
    /// those that answer.
    @discardableResult
    static func update() -> [Candidate] {
        let all = candidates()
        if let newest = all.first { point(at: newest.socket) }
        return all
    }

    /// How many keys the agent at the link holds (`ssh-add -l`); nil if it
    /// couldn't be asked.
    static func keys() -> Int? {
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = path
        guard let (out, status) = try? Child.run(["/usr/bin/env", "ssh-add", "-l"], timeout: 5, quiet: true, environment: env) else { return nil }
        // 1: the agent has no keys; 2: it couldn't be reached.
        switch status {
        case 0: return String(decoding: out, as: UTF8.self).split(separator: "\n").count
        case 1: return 0
        default: return nil
        }
    }
}

/// The server's keeper of the link: decides at its start whether its shells
/// get it, then looks again every few seconds, saying how it stands when
/// that changes.
final class AgentLinkKeeper {
    /// The agent the server was started with, if it's the host's own: not
    /// forwarded by a connection (the bridge says so), and answering.
    let local: String?
    private let queue = DispatchQueue(label: "agent-link", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var keysOf: (target: String, keys: Int?)?
    private(set) var status: AgentLinkStatus
    var onChange: ((AgentLinkStatus) -> Void)?

    init() {
        let env = ProcessInfo.processInfo.environment
        let inherited = env["SSH_AUTH_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
        // Started by a bridge: its agent is the connection's (the bridge
        // noted it), not the host's.
        let bridged = env[SpawnEnvironment.bridgedKey] != nil
        local = !bridged ? inherited.flatMap { $0 != AgentLink.path && AgentLink.answers($0) ? $0 : nil } : nil
        status = AgentLinkStatus(managed: local == nil, link: AgentLink.path, local: local)
    }

    func start() {
        queue.async { self.look() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.look() }
        t.resume()
        timer = t
    }

    /// Look again now (a bridge came, `mani env agent` named one).
    func lookNow(done: (() -> Void)? = nil) {
        queue.async {
            self.look()
            done?()
        }
    }

    private func look() {
        guard local == nil else { return }
        let answering = AgentLink.update()
        let target = AgentLink.target
        // Shells get the link once there is one, even if what it points to
        // has gone: the next agent to come is pointed at under them.
        SpawnEnvironment.setAgent(target != nil ? AgentLink.path : nil)
        let linked = answering.first { $0.socket == target }
        if let target, linked != nil, keysOf?.target != target {
            keysOf = (target, AgentLink.keys())
        }
        let s = AgentLinkStatus(managed: true, link: AgentLink.path, target: target, from: linked?.from, live: linked != nil,
                                keys: linked != nil ? keysOf?.keys : nil, local: nil, others: max(0, answering.count - (linked != nil ? 1 : 0)))
        if s != status {
            status = s
            log("agent link: \(s.summary)" + (target.map { " (\($0))" } ?? ""))
            onChange?(s)
        }
    }
}
