import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `mani diff`, on the app's host or a remote one (where `manifoldd mani`
/// runs it): asks the host to make a diff block of a patch, for the app to
/// show beside the block the shell is in; and the paths `mani open` is
/// given, made whole.
public enum OpenCommand {
    /// `mani diff`: a patch, read from the input, shown as a diff block,
    /// over a connection already made to the host (a socket's fd). The
    /// exit status: 0 when done, 1 when it couldn't be, `ManiClient.absent`
    /// when the app wasn't there to ask.
    public static func runPatch(fd: Int32, patch: String, root: String, title: String?, beside: BlockID?, name: String = "mani") -> Int32 {
        run(fd: fd, wait: false, name: name) { .openPatch(id: $0, patch: patch, root: root, title: title, beside: beside) }
    }

    /// The patch on standard input, or why there is none.
    public static func readPatch() -> Result<String, ResolveError> {
        guard isatty(0) == 0 else { return .failure(ResolveError(message: "diff reads a patch from its input: git diff | mani diff")) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return .failure(ResolveError(message: "the patch isn't UTF-8")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(ResolveError(message: "the patch is empty")) }
        return .success(text)
    }

    private static func run(fd: Int32, wait: Bool, name: String, request: (Int) -> ClientMessage) -> Int32 {
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
                case let .welcome(version, _, _, _, _, _, _, _)?:
                    if version != protocolVersion {
                        return fail("Manifold's server is from another version; restart it (Manifold ▸ Restart Server)")
                    }
                    welcomed = true
                    guard send(request(1)) else { return fail("lost the connection to Manifold") }
                    deadline = Date().addingTimeInterval(15)
                case let .done(id, error)?:
                    guard id == 1 else { continue }
                    if let error, error.contains("isn't attached") { return ManiClient.absent }
                    if let error { return fail(error) }
                    return 0
                default:
                    continue
                }
            }
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("mani: \(message)\n".utf8))
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
            // A folder says so (a trailing slash): the app, on another
            // machine, can't look, and would take it for a file to edit.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, !path.hasSuffix("/") { path += "/" }
            out.append(path)
        }
        return .success(out)
    }
}

public struct ResolveError: Error { public var message: String }

/// A `mani` command the app does: asked of the host, which passes it on,
/// and its answer printed as it comes (some commands go on: `watch`).
public enum ManiClient {
    /// The status when the app wasn't there to ask (nothing printed): the
    /// caller may start it and ask again.
    public static let absent: Int32 = -1

    public static func run(fd: Int32, request: ManiRequest) -> Int32 {
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
        func say(_ s: String, to handle: FileHandle) {
            guard !s.isEmpty else { return }
            handle.write(Data(s.utf8))
        }
        func fail(_ message: String) -> Int32 {
            say("mani: \(message)\n", to: .standardError)
            return 1
        }
        guard send(.hello(version: protocolVersion, name: Mani.name)) else { return absent }
        var decoder = FrameDecoder()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var welcomed = false
        let deadline = Date().addingTimeInterval(10)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // Answered at once, once asked; then as long as it takes.
            let left = welcomed ? Int32(60_000) : Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard welcomed || left > 0 else { return fail("Manifold didn't answer") }
            let r = poll(&pfd, 1, left)
            if r == 0 { continue }
            guard r > 0 else { if errno == EINTR { continue }; return fail("lost the connection to Manifold") }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return welcomed ? fail("lost the connection to Manifold") : absent }
            decoder.append(Data(buf[0..<n]))
            while let frame = try? decoder.next() {
                switch frame.decode(ServerMessage.self) {
                case let .welcome(version, _, _, _, _, _, _, _)?:
                    if version != protocolVersion {
                        return fail("Manifold's server is from another version; restart it (Manifold ▸ Restart Server)")
                    }
                    welcomed = true
                    guard send(.command(id: 1, request)) else { return fail("lost the connection to Manifold") }
                case let .commandReply(id, reply)? where id == 1:
                    say(reply.out, to: .standardOutput)
                    say(reply.err, to: .standardError)
                    if let status = reply.status { return status }
                case let .done(id, error)? where id == 1:
                    // Only when the host couldn't pass it on: the app isn't there.
                    if let error, error.contains("isn't attached") { return absent }
                    return error.map(fail) ?? 0
                default:
                    continue
                }
            }
        }
    }
}
