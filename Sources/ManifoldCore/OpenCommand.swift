import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The `manifold` command's work, shared with `manifoldd open` (what a
/// remote host's shells have as `$EDITOR`): asks the host to have the app
/// open some paths, beside the block the shell is in, and with `wait`,
/// waits until they're put away again.
public enum OpenCommand {
    /// Runs over a connection already made to the host (a socket's fd).
    /// Returns the exit status: 0 when done, 1 when the host or app
    /// couldn't do it.
    public static func run(fd: Int32, paths: [String], beside: BlockID?, wait: Bool, name: String = "manifold") -> Int32 {
        func send(_ message: ClientMessage) -> Bool {
            let data = Frame.message(message).encoded
            return data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
        }
        guard send(.hello(version: protocolVersion, name: name)) else { return fail("lost the connection to Manifold") }
        var decoder = FrameDecoder()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var welcomed = false
        var deadline = Date().addingTimeInterval(10)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = wait && welcomed ? Int32(60_000) : Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0 || (wait && welcomed) else { return fail("Manifold didn't answer") }
            let r = poll(&pfd, 1, left)
            if r == 0 { continue }
            guard r > 0 else { if errno == EINTR { continue }; return fail("lost the connection to Manifold") }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return fail("lost the connection to Manifold") }
            decoder.append(Data(buf[0..<n]))
            while let frame = try? decoder.next() {
                switch frame.decode(ServerMessage.self) {
                case let .welcome(version, _, _, _, _, _)?:
                    if version != protocolVersion {
                        return fail("Manifold's server is from another version; restart it (Manifold ▸ Restart Server)")
                    }
                    welcomed = true
                    guard send(.open(id: 1, paths: paths, beside: beside, wait: wait)) else { return fail("lost the connection to Manifold") }
                    deadline = Date().addingTimeInterval(15)
                case let .done(id, error)?:
                    guard id == 1 else { continue }
                    if let error { return fail(error) }
                    return 0
                default:
                    continue
                }
            }
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("manifold: \(message)\n".utf8))
        return 1
    }

    /// Paths made absolute against the working directory, checked to exist.
    public static func resolve(_ args: [String]) -> Result<[String], ResolveError> {
        let cwd = FileManager.default.currentDirectoryPath
        var out: [String] = []
        for arg in args {
            var path = arg.expandingTildeInPath
            if !path.hasPrefix("/") { path = cwd.appendingPathComponent(path) }
            path = URL(fileURLWithPath: path).standardizedFileURL.path
            // A file to be made (git's COMMIT_EDITMSG exists; a new note may not).
            if !FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: path.deletingLastPathComponent) {
                return .failure(ResolveError(message: "no such file: \(arg)"))
            }
            out.append(path)
        }
        return .success(out)
    }
}

public struct ResolveError: Error { public var message: String }
