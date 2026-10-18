import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How another machine is reached (DESIGN.md §8, after apex): a *provider*
/// is an executable `manifold-remote-<provider>` on the PATH, called as
/// `manifold-remote-<provider> DESTINATION COMMAND`, which runs COMMAND, one
/// shell command line, on the destination with stdio connected and exits
/// with its status. That is ssh's own convention, and `ssh` is the built-in
/// provider, so `user@host` needs nothing. Other destinations are
/// `provider:name`. The provider script is the whole configuration.
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
        if provider == "ssh" {
            let ssh = env["MANIFOLD_SSH"] ?? env[key] ?? "ssh"
            return [ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", target, command]
        }
        let program = env[key] ?? "manifold-remote-\(provider)"
        return [program, target, command]
    }
}

/// Where each remote host attached from this machine is reached, kept in
/// the local directory for the attach helper and the command.
public struct HostsFile: Codable {
    public var hosts: [String: Destination] = [:]

    public static var url: URL { Paths.directory.appendingPathComponent("hosts.json") }

    public static func load() -> HostsFile {
        guard let data = try? Data(contentsOf: url) else { return HostsFile() }
        return (try? JSONDecoder().decode(HostsFile.self, from: data)) ?? HostsFile()
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    public func destination(of host: HostID) -> Destination? { hosts[host.raw] }
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
    /// status.
    public static func run(_ argv: [String], input: Data = Data(), timeout: TimeInterval = 120) throws -> (output: Data, status: Int32) {
        let child = try spawn(argv, stderrToNull: false)
        let writer = Thread {
            input.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(child.input, raw.baseAddress! + off, min(raw.count - off, 1 << 16))
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
                }
            }
            close(child.input)
        }
        writer.start()
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var pfd = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0 else { kill(child.pid, SIGKILL); break }
            guard poll(&pfd, 1, left) > 0 else { continue }
            let n = read(child.output, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n == 0 || errno != EINTR { break }
        }
        close(child.output)
        var status: Int32 = 0
        waitpid(child.pid, &status, 0)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (out, code)
    }
}

/// What a client asks of a host before attaching: which `manifoldd` to
/// carry there, and whether the one there is it.
public enum Bootstrap {
    /// Asks the destination its OS and architecture, and the hash of the
    /// server installed there, if any.
    public static func probe(_ dest: Destination) throws -> (os: String, arch: String, hash: String?) {
        let cmd = "uname -sm; if [ -x ~/.manifold/bin/manifoldd ]; then (sha256sum ~/.manifold/bin/manifoldd 2>/dev/null || shasum -a 256 ~/.manifold/bin/manifoldd) | cut -d' ' -f1; fi"
        let (out, status) = try Child.run(dest.invocation(cmd), timeout: 60)
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard status == 0, let first = lines.first else {
            throw RemoteError.unreachable(String(decoding: out, as: UTF8.self))
        }
        let parts = first.split(separator: " ")
        guard parts.count == 2 else { throw RemoteError.unreachable(first) }
        return (String(parts[0]).lowercased(), String(parts[1]).lowercased(), lines.count > 1 ? lines[1] : nil)
    }

    /// Installs `binary` as the destination's server.
    public static func upload(_ dest: Destination, binary: Data) throws {
        let cmd = "mkdir -p ~/.manifold/bin && cat > ~/.manifold/bin/manifoldd.new && chmod +x ~/.manifold/bin/manifoldd.new && mv ~/.manifold/bin/manifoldd.new ~/.manifold/bin/manifoldd"
        let (out, status) = try Child.run(dest.invocation(cmd), input: binary, timeout: 600)
        guard status == 0 else { throw RemoteError.uploadFailed(String(decoding: out, as: UTF8.self)) }
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
