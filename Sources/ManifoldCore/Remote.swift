import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How another machine is reached (DESIGN.md §8, after apex): a *provider*
/// is a command that runs a command line on a destination with stdio
/// connected and exits with its status — ssh's own convention. Providers
/// are configured in Remoting… as a name and a command template with `%h`
/// for the destination and `%c` for the command (appended when there is
/// no `%c`), kept in the hosts file; `ssh` is the built-in one, so
/// `user@host` needs nothing. A provider not in the table is an executable
/// `manifold-remote-<provider>` on the PATH, called with DESTINATION and
/// COMMAND. Destinations are `user@host` or `provider:name`.
public struct Destination: Hashable, Codable, Sendable, CustomStringConvertible {
    public var provider: String
    public var target: String

    public init(provider: String, target: String) {
        self.provider = provider
        self.target = target
    }

    /// `user@host` is ssh's; `provider:name` another's.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("@"), !s[..<colon].isEmpty,
           s[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            self.init(provider: String(s[..<colon]), target: String(s[s.index(after: colon)...]))
        } else {
            self.init(provider: "ssh", target: s)
        }
        if target.isEmpty { return nil }
    }

    public var description: String { provider == "ssh" ? target : "\(provider):\(target)" }

    /// A name for the host, from the destination: the host part of
    /// `user@host`, the name of `provider:name`, in letters, digits and
    /// dashes.
    public var suggestedHostName: String {
        var t = target
        if let at = t.firstIndex(of: "@") { t = String(t[t.index(after: at)...]) }
        if let dot = t.firstIndex(of: ".") { t = String(t[..<dot]) }
        let cleaned = t.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("-") }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty || name == "local" ? "remote" : name
    }

    /// The program and arguments that run `command` on the destination.
    /// `MANIFOLD_PROVIDER_<NAME>` (or `MANIFOLD_SSH`) names the program to
    /// use instead of the one on the PATH.
    public func invocation(_ command: String) -> [String] {
        let env = ProcessInfo.processInfo.environment
        let key = "MANIFOLD_PROVIDER_" + provider.uppercased().replacingOccurrences(of: "-", with: "_")
        if let p = HostsFile.load().provider(named: provider) {
            var argv = p.arguments(host: target, command: command)
            if let program = env[key] ?? (provider == "ssh" ? env["MANIFOLD_SSH"] : nil), !argv.isEmpty { argv[0] = program }
            return argv
        }
        if provider == "ssh" {
            return RemoteProvider.ssh.arguments(host: target, command: command)
        }
        let program = env[key] ?? "manifold-remote-\(provider)"
        return [program, target, command]
    }
}

/// A way to reach hosts: a name, and a command template with `%h` for
/// the destination and `%c` for the command to run there.
public struct RemoteProvider: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var command: String

    public var id: String { name }

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }

    public static let ssh = RemoteProvider(name: "ssh", command: "ssh -o BatchMode=yes -o ConnectTimeout=15 %h %c")
    public static let defaults = [ssh]

    /// The program and arguments for `command` on `host`: the template's
    /// words, `%h` and `%c` filled in (the command one argument, appended
    /// when the template has no `%c`).
    public func arguments(host: String, command: String) -> [String] {
        var out: [String] = []
        var sawCommand = false
        for word in self.command.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if word == "%c" { out.append(command); sawCommand = true; continue }
            out.append(word.replacingOccurrences(of: "%h", with: host))
        }
        if !sawCommand { out.append(command) }
        return out
    }
}

/// Where each remote host attached from this machine is reached, and the
/// providers that reach them, kept in the local directory for the app,
/// the attach helper and the command.
public struct HostsFile: Codable {
    /// By session id.
    public var hosts: [String: HostEntry] = [:]
    public var providers: [RemoteProvider] = RemoteProvider.defaults

    public init() {}

    enum CodingKeys: String, CodingKey { case hosts, providers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let entries = try? c.decode([String: HostEntry].self, forKey: .hosts) {
            hosts = entries
        } else if let old = try? c.decode([String: Destination].self, forKey: .hosts) {
            // Before sessions: keyed by the name the client gave the host.
            hosts = old.mapValues { HostEntry(destination: $0, label: nil) }
        }
        providers = (try? c.decodeIfPresent([RemoteProvider].self, forKey: .providers)) ?? RemoteProvider.defaults
    }

    public func provider(named name: String) -> RemoteProvider? { providers.first { $0.name == name } }

    public static var url: URL { Paths.directory.appendingPathComponent("hosts.json") }

    public static func load() -> HostsFile {
        guard let data = try? Data(contentsOf: url) else { return HostsFile() }
        return (try? JSONDecoder().decode(HostsFile.self, from: data)) ?? HostsFile()
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    public func destination(of host: HostID) -> Destination? { hosts[host.raw]?.destination }
    public func label(of host: HostID) -> String? { hosts[host.raw]?.label }
}

/// A child process with pipes to its stdin and stdout.
public struct Child {
    public let pid: pid_t
    /// Read the child's output here.
    public let output: Int32
    /// Write the child's input here.
    public let input: Int32

    /// Runs `argv` with pipes; the child's stderr is ours. Searches the PATH.
    public static func spawn(_ argv: [String], stderrToNull: Bool = false) throws -> Child {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { throw POSIXError(.EPIPE) }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        if stderrToNull { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
        for fd in [toChild[0], toChild[1], fromChild[0], fromChild[1]] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        var pid: pid_t = 0
        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer { for p in cenv { free(p) } }
        let err = posix_spawnp(&pid, argv[0], &actions, nil, cargs, cenv)
        posix_spawn_file_actions_destroy(&actions)
        close(toChild[0])
        close(fromChild[1])
        guard err == 0 else {
            close(toChild[1])
            close(fromChild[0])
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ENOENT)
        }
        return Child(pid: pid, output: fromChild[0], input: toChild[1])
    }

    /// Runs `argv` to completion with `input` on its stdin; its output and
    /// status. With `stall`, it's ended once nothing has moved (no input
    /// taken, no output given) for that long, `timeout` being the most it
    /// gets in all; `progress` is told how much of the input has been
    /// taken as it goes, from another thread.
    public static func run(_ argv: [String], input: Data = Data(), timeout: TimeInterval = 120, stall: TimeInterval? = nil,
                           progress: (@Sendable (Int) -> Void)? = nil, quiet: Bool = false) throws -> (output: Data, status: Int32) {
        let child = try spawn(argv, stderrToNull: quiet)
        let moved = Moved()
        let writer = Thread {
            input.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(child.input, raw.baseAddress! + off, min(raw.count - off, 1 << 16))
                    if n > 0 {
                        off += n
                        moved.touch()
                        progress?(off)
                    } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
            close(child.input)
        }
        writer.start()
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let end = Date().addingTimeInterval(timeout)
        while true {
            let deadline = stall.map { min(end, moved.last.addingTimeInterval($0)) } ?? end
            // A second at most between looks, to see whether input moved.
            let left = Int32(min(max(0, deadline.timeIntervalSinceNow), stall == nil ? .infinity : 1) * 1000)
            guard deadline.timeIntervalSinceNow > 0 else { kill(child.pid, SIGKILL); break }
            var pfd = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, left) > 0 else { continue }
            let n = read(child.output, &buf, buf.count)
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                moved.touch()
            } else if n == 0 || errno != EINTR { break }
        }
        close(child.output)
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (out, code)
    }
}

/// When bytes last moved through a child's pipes, as its threads see it.
private final class Moved: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date()

    var last: Date {
        lock.lock()
        defer { lock.unlock() }
        return at
    }

    func touch() {
        lock.lock()
        at = Date()
        lock.unlock()
    }
}

/// What a client asks of a host before attaching: which `manifoldd` to
/// carry there, and whether the one there is it.
public enum Bootstrap {
    /// What a destination says of itself before a server is carried there.
    public struct Probe: Sendable {
        public var os: String
        public var arch: String
        /// The hash of the server installed there, if any.
        public var hash: String?
        /// Whether it can take the server compressed.
        public var gunzip: Bool
    }

    /// Asks the destination its OS and architecture, whether it has
    /// gunzip, and the hash of the server installed there, if any. Each
    /// answer on a line of its own, tagged, so what a login shell prints
    /// on its way in is passed over.
    public static func probe(_ dest: Destination) throws -> Probe {
        let script = """
            echo "os $(uname -sm)"
            if command -v gunzip >/dev/null 2>&1; then echo gunzip; fi
            if [ -x ~/.manifold/bin/manifoldd ]; then
              echo "hash $( (sha256sum ~/.manifold/bin/manifoldd 2>/dev/null || shasum -a 256 ~/.manifold/bin/manifoldd) | cut -d' ' -f1)"
            fi
            """
        let (out, status) = try Child.run(dest.invocation(posix(script)), timeout: 60)
        let text = String(decoding: out, as: UTF8.self)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func tagged(_ tag: String) -> String? { lines.first { $0.hasPrefix(tag + " ") }.map { String($0.dropFirst(tag.count + 1)) } }
        guard status == 0, let os = tagged("os") else { throw RemoteError.unreachable(text) }
        let parts = os.split(separator: " ")
        guard parts.count == 2 else { throw RemoteError.unreachable(os) }
        return Probe(os: String(parts[0]).lowercased(), arch: String(parts[1]).lowercased(),
                     hash: tagged("hash"), gunzip: lines.contains("gunzip"))
    }

    /// Installs `binary` as the destination's server, with a `manifold`
    /// script beside it that runs `manifoldd open`, so terminals there
    /// have the command on their PATH as terminals here do. Compressed
    /// on the way if the destination has gunzip; into a file of this
    /// upload's own, any left by earlier ones taken away first (one that
    /// was still going then has nothing to put in place), and put in
    /// place only if it hashes as what was sent. It gives up once nothing
    /// has moved for a minute, however long it has gone on; `progress` is
    /// told how much of the binary has gone, from another thread.
    public static func upload(_ dest: Destination, binary: Data, compressed: Bool, progress: (@Sendable (Int) -> Void)? = nil) throws {
        let script = """
            cd ~/.manifold/bin 2>/dev/null || { mkdir -p ~/.manifold/bin && cd ~/.manifold/bin; } || exit 1
            rm -f manifoldd.new.*
            new=manifoldd.new.$$
            \(compressed ? "gunzip -c" : "cat") > "$new" || { rm -f "$new"; exit 1; }
            got=$( (sha256sum "$new" 2>/dev/null || shasum -a 256 "$new") | cut -d' ' -f1)
            if [ "$got" != \(sha256(binary)) ]; then size=$(wc -c < "$new"); rm -f "$new"; echo "what arrived isn't what was sent ($size of \(binary.count) bytes)"; exit 1; fi
            chmod +x "$new" && mv "$new" manifoldd || exit 1
            printf '%s\\n' '#!/bin/sh' 'exec "$(dirname "$0")/manifoldd" open "$@"' > manifold && chmod +x manifold
            """
        var argv = dest.invocation(posix(script))
        // Compressed here as it goes: gzip takes the binary, the provider
        // takes what gzip makes.
        if compressed { argv = ["/bin/sh", "-c", "gzip -c | \"$@\"", "sh"] + argv }
        let (out, status) = try Child.run(argv, input: binary, timeout: 6 * 3600, stall: 60, progress: progress)
        guard status == 0 else {
            let said = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError.uploadFailed(said.isEmpty ? "it stopped (status \(status))" : said)
        }
    }

    /// A POSIX shell script as one command for a provider: whatever shell
    /// the destination logs in with, sh runs it.
    static func posix(_ script: String) -> String {
        "sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command that bridges stdio to the destination's server.
    public static func bridgeCommand(name: String) -> String {
        "~/.manifold/bin/manifoldd bridge --name \(name)"
    }

    /// The file name of the server binary we carry for an OS and
    /// architecture, as `uname -sm` names them.
    public static func binaryName(os: String, arch: String) -> String {
        let a: String
        switch arch {
        case "arm64", "aarch64": a = "aarch64"
        case "x86_64", "amd64": a = "x86_64"
        default: a = arch
        }
        return "manifoldd-\(os)-\(a)"
    }

    public static func sha256(_ data: Data) -> String {
        // A small SHA-256, so the core needs no CryptoKit (not on Linux).
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                w[i] = UInt32(message[chunk + i * 4]) << 24 | UInt32(message[chunk + i * 4 + 1]) << 16
                    | UInt32(message[chunk + i * 4 + 2]) << 8 | UInt32(message[chunk + i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

public enum RemoteError: Error, CustomStringConvertible {
    case unreachable(String)
    case uploadFailed(String)
    case noBinary(String)

    public var description: String {
        switch self {
        case .unreachable(let s): "The host couldn't be reached: \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .uploadFailed(let s): "The server couldn't be installed there: \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .noBinary(let s): "Manifold has no server built for \(s)."
        }
    }
}
