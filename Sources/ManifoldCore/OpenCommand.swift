import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What `mani diff` and `mani open` read where they run: the patch on
/// the input, and the paths given, made whole.
public enum OpenCommand {
    /// The patch on standard input, or why there is none.
    public static func readPatch() -> Result<String, ResolveError> {
        guard isatty(0) == 0 else { return .failure(ResolveError(message: "diff reads a patch from its input: git diff | mani diff")) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return .failure(ResolveError(message: "the patch isn't UTF-8")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(ResolveError(message: "the patch is empty")) }
        return .success(text)
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
            if FileManager.default.isDirectory(atPath: path) == true, !path.hasSuffix("/") { path += "/" }
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
        func say(_ s: String, to handle: FileHandle) {
            guard !s.isEmpty else { return }
            handle.write(Data(s.utf8))
        }
        var channel = BlockingChannel(fd: fd)
        guard channel.hello(Mani.name) else { return absent }
        var welcomed = false, taken = false
        var deadline = Date().addingTimeInterval(10)
        while true {
            // Welcomed at once; the command taken by the app (its first
            // reply) soon after it's asked; then as long as it takes.
            switch channel.next(until: taken ? nil : deadline) {
            case .timedOut:
                guard welcomed else { return fail("Manifold didn't answer") }
                return fail("Manifold took no notice of the command in \(Int(takenWithin)) s (this was pid \(getpid())); "
                    + "its log (~/Library/Logs/Manifold/Manifold.log) and its server's (manifoldd.log, in its data folder) say what became of it")
            case .closed:
                return welcomed ? fail("lost the connection to Manifold") : absent
            case let .message(.welcome(version, _, _, _, _, _, _, _, _, _)):
                if version != protocolVersion { return fail(otherVersion) }
                welcomed = true
                deadline = Date().addingTimeInterval(takenWithin)
                guard channel.send(.command(id: 1, request)) else { return fail("lost the connection to Manifold") }
            case let .message(.commandReply(id, reply)) where id == 1:
                taken = true
                say(reply.out, to: .standardOutput)
                say(reply.err, to: .standardError)
                if let status = reply.status { return status }
            case let .message(.reply(id, .done(error))) where id == 1:
                // Only when the host couldn't pass it on: the app isn't there.
                if let error, error.contains("isn't attached") { return absent }
                return error.map(fail) ?? 0
            case .message:
                continue
            }
        }
    }

    /// How long the app has to take a command (its first reply) before
    /// `mani` gives up on it: 30 s, or MANI_TIMEOUT's seconds.
    static var takenWithin: TimeInterval {
        ProcessInfo.processInfo.environment["MANI_TIMEOUT"].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil } ?? 30
    }

    /// Why `mani` stopped, on stderr; status 1.
    public static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("mani: \(message)\n".utf8))
        return 1
    }

    static let otherVersion = "Manifold's server is from another version; restart it (Manifold ▸ Restart Server)"
}
