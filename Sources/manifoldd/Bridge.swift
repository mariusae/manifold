import CPTY
import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `manifoldd bridge`: copies bytes between its stdio and the server's
/// socket, starting the server if there isn't one. A client on another
/// machine runs this over ssh (or any provider) and speaks frames to it
/// exactly as to the socket; the bridge knows nothing of them. `--name`
/// names the host, the first time.
enum Bridge {
    static func run(name: String?) -> Never {
        signal(SIGPIPE, SIG_IGN)
        Paths.ensureDirectory()
        if let name, !FileManager.default.fileExists(atPath: Paths.hostName.path) {
            try? Data(name.utf8).write(to: Paths.hostName)
        }
        var fd = try? UnixSocket.connect(path: Paths.socket)
        if fd == nil {
            startServer()
            for _ in 0..<100 {
                usleep(100_000)
                if let f = try? UnixSocket.connect(path: Paths.socket) { fd = f; break }
            }
        }
        guard let sock = fd else {
            FileHandle.standardError.write(Data("manifoldd bridge: the server didn't start (see \(Paths.log.path))\n".utf8))
            exit(1)
        }
        let debug = ProcessInfo.processInfo.environment["MANIFOLD_BRIDGE_DEBUG"] != nil
        if debug { FileHandle.standardError.write(Data("bridge: connected to \(Paths.socket)\n".utf8)) }
        let up = Thread {
            pump(from: 0, to: sock, debug: debug, label: "in")
            shutdown(sock, Int32(SHUT_WR))
        }
        up.start()
        pump(from: sock, to: 1, debug: debug, label: "out")
        exit(0)
    }

    private static func pump(from: Int32, to: Int32, debug: Bool, label: String) {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(from, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if debug { FileHandle.standardError.write(Data("bridge \(label): read \(n) errno \(errno)\n".utf8)) }
            guard n > 0 else { return }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { raw in write(to, raw.baseAddress! + off, n - off) }
                if w > 0 { off += w } else if w < 0 && errno == EINTR { continue } else {
                    if debug { FileHandle.standardError.write(Data("bridge \(label): write failed errno \(errno)\n".utf8)) }
                    return
                }
            }
        }
    }

    private static func startServer() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let path = exe.hasPrefix("/") ? exe : Paths.installedServer.path
        _ = withCStrings([path, "serve"]) { argv in
            mf_spawn_detached(path, argv, Paths.log.path)
        }
    }
}
