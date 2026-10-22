import Foundation
import GhosttyKit
import ManifoldCore

/// A terminal's stream to its block's shell, on its host's one connection
/// (§8) — what `manifoldd attach` was, in a process of its own: Ghostty
/// runs no command and has no pty here (the shell's is on the host); what
/// the shell prints goes into the surface on the terminal's own queue, off
/// the main thread, and what's typed and the size go up the stream.
final class TerminalLink {
    let block: BlockID
    private weak var client: HostClient?
    /// Where output goes into the surface.
    private let queue: DispatchQueue
    /// On `queue`: the surface output goes into (nil once it's freed).
    private var surface: ghostty_surface_t?

    /// Read from Ghostty's thread (typing, sizes) and the main thread.
    private let lock = NSLock()
    private var stream: MuxStream?
    /// The size: the last sent, or, before attaching, the one to attach at.
    private var size: (cols: UInt16, rows: UInt16) = (80, 24)
    private var attaching = false
    private var attached = false
    /// Typing waits until the shell's recent output has been replayed (its
    /// queries answered by the terminal as it was, not typed now).
    private var acceptInput = false

    /// The stream closed (the shell ended, or the link went): on the main
    /// thread.
    var onClosed: (() -> Void)?

    init(block: BlockID, client: HostClient?) {
        self.block = block
        self.client = client
        queue = DispatchQueue(label: "manifold.terminal.\(block.description)", qos: .userInteractive)
    }

    /// The surface made: output may go into it.
    func start(_ surface: ghostty_surface_t) {
        queue.async { self.surface = surface }
    }

    /// Before the surface is freed: nothing more goes into it, and the
    /// stream is closed (the session lives on in the host's server).
    func stop() {
        let s: MuxStream? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        s?.close()
        queue.sync { surface = nil }
    }

    /// Whether the host's link is up, so a stream can be opened.
    var linkUp: Bool { client?.mux != nil }

    // MARK: From Ghostty (its own threads)

    /// The terminal's size, cells then pixels: the first attaches (a moment
    /// later, as the tile settles to its size), later ones go up.
    func resized(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        let send: MuxStream? = lock.withLock {
            let changed = size != (cols, rows)
            size = (cols, rows)
            if !attached, !attaching {
                attaching = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self.attach() }
            }
            return attached && changed ? stream : nil
        }
        send?.send(.resize(cols: cols, rows: rows))
    }

    /// Typed (or the terminal's answer to a query): up to the shell.
    func typed(_ data: Data) {
        let s: MuxStream? = lock.withLock { acceptInput ? stream : nil }
        s?.send(Frame(.data, data))
    }

    // MARK: The stream

    private func attach() {
        guard let mux = client?.mux else {
            // No link yet: closed now, made again once there is one.
            lock.withLock { attaching = false }
            onClosed?()
            return
        }
        let stream = mux.open(bulk: false, callbackQueue: queue)
        stream.onFrame = { [weak self] frame in self?.received(frame) }
        stream.onClose = { [weak self] in
            DispatchQueue.main.async { self?.onClosed?() }
        }
        let size: (cols: UInt16, rows: UInt16) = lock.withLock {
            self.stream = stream
            attaching = false
            attached = true
            return self.size
        }
        stream.send(.message(ClientMessage.attach(AttachRequest(block: block, cols: size.cols, rows: size.rows, env: Self.environment))))
    }

    /// On `queue`.
    private func received(_ frame: Frame) {
        switch frame.kind {
        case .data:
            guard let surface else { return }
            frame.payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(raw.count))
            }
        case .replayDone:
            // A replay no one has seen yet is live output (a shell just
            // started, its queries waiting for answers): typing goes through
            // at once. One seen before holds queries the terminal answers
            // again now; those answers aren't for the shell, so typing
            // waits a moment longer.
            if frame.payload.first == 1 {
                lock.withLock { acceptInput = true }
            } else {
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.lock.withLock { self?.acceptInput = true } }
            }
        default:
            break
        }
    }

    /// What a shell started for a terminal here is told about it, as
    /// Ghostty would tell a shell it started: its type, its terminfo and
    /// shell integration (the server carries them over), the locale.
    static let environment: [String: String] = {
        var env: [String: String] = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_SHELL_FEATURES": "cursor:blink,path,title",
        ]
        if let res = Bundle.main.resourceURL {
            env["TERMINFO"] = res.appendingPathComponent("terminfo").path
            env["GHOSTTY_RESOURCES_DIR"] = res.appendingPathComponent("ghostty").path
        }
        if let bin = Bundle.main.executableURL?.deletingLastPathComponent() { env["GHOSTTY_BIN_DIR"] = bin.path }
        let ours = ProcessInfo.processInfo.environment
        for k in ["LANG", "LC_ALL", "LC_CTYPE"] { if let v = ours[k] { env[k] = v } }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }()
}
