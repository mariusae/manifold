import CPTY
import Foundation
import ManifoldCore

/// `manifoldd attach <block>`: the program each terminal in the app runs. It
/// connects the terminal it runs in to the block's shell in the server,
/// passing bytes both ways, like dtach or tmux attach.
enum Attach {
    private static var original = termios()
    private static var acceptInput = false

    static func run(block: BlockID) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let local = (try? Data(contentsOf: Paths.hostName)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "local"
        let conn: Connection
        if block.host.raw != local, block.host != .local {
            // Another host's: through its provider, to a bridge there.
            guard let dest = HostsFile.load().destination(of: block.host) else {
                FileHandle.standardError.write(Data("manifold: no way to reach \(block.host)\r\n".utf8))
                exit(1)
            }
            guard let child = try? Child.spawn(dest.invocation(Bootstrap.bridgeCommand(name: block.host.raw)), stderrToNull: true) else {
                FileHandle.standardError.write(Data("manifold: can't reach \(block.host)\r\n".utf8))
                exit(1)
            }
            conn = Connection(fd: child.output, writeFD: child.input, queue: .main)
        } else {
            guard let fd = connect() else {
                FileHandle.standardError.write(Data("manifold: can't reach the server\r\n".utf8))
                exit(1)
            }
            conn = Connection(fd: fd, queue: .main)
        }

        tcgetattr(0, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        atexit { tcsetattr(0, TCSANOW, &Attach.original) }

        conn.onFrame = { frame in
            switch frame.kind {
            case .data:
                writeAll(1, frame.payload)
            case .replayDone:
                // The replay can contain queries the terminal has now answered;
                // those answers aren't for the shell, so drop input a moment
                // longer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { acceptInput = true }
            default:
                break
            }
        }
        conn.onClose = { exit(0) }
        conn.start()

        // The terminal is resized to fit its pane just after it starts us;
        // attaching at the final size saves the shell a redraw.
        usleep(40_000)
        let (cols, rows) = terminalSize()
        var env: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment
        where ["TERM", "TERMINFO", "COLORTERM", "LANG", "LC_ALL", "LC_CTYPE"].contains(k) || k.hasPrefix("GHOSTTY_") {
            env[k] = v
        }
        conn.send(.message(ClientMessage.attach(AttachRequest(block: block, cols: cols, rows: rows, env: env))))

        let stdin = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        stdin.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(0, &buf, buf.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            guard n > 0 else { exit(0) }
            if acceptInput { conn.send(Frame(.data, Data(buf[0..<n]))) }
        }
        stdin.resume()

        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winch.setEventHandler {
            let (cols, rows) = terminalSize()
            conn.send(.resize(cols: cols, rows: rows))
        }
        winch.resume()

        for sig in [SIGHUP, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { exit(0) }
            source.resume()
            keep.append(source)
        }
        keep.append(contentsOf: [stdin, winch])
        dispatchMain()
    }

    private static var keep: [DispatchSourceProtocol] = []

    /// Connects, giving a server that's just starting a moment to listen.
    private static func connect() -> Int32? {
        for _ in 0..<50 {
            if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
            usleep(100_000)
        }
        return nil
    }

    private static func terminalSize() -> (UInt16, UInt16) {
        var cols: UInt16 = 0, rows: UInt16 = 0
        guard mf_terminal_size(0, &cols, &rows) == 0, cols > 0, rows > 0 else { return (80, 24) }
        return (cols, rows)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 {
                    off += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    exit(0)
                }
            }
        }
    }
}
