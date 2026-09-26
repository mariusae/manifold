import Foundation
import ManifoldCore

/// `manifoldd attach <pane>`: the program each terminal in the app runs. It
/// connects the terminal it runs in to the pane's session in the server,
/// passing bytes both ways, like dtach or tmux attach.
enum Attach {
    private static var original = termios()
    private static var acceptInput = false

    static func run(pane: UUID) -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let fd = connect() else {
            FileHandle.standardError.write(Data("manifold: can't reach the server\r\n".utf8))
            exit(1)
        }

        tcgetattr(0, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        atexit { tcsetattr(0, TCSANOW, &Attach.original) }

        let conn = Connection(fd: fd, queue: .main)
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
        conn.send(.json(ClientMessage.attach(AttachRequest(pane: pane, cols: cols, rows: rows, env: env))))

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
        var ws = winsize()
        guard ioctl(0, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return (80, 24) }
        return (ws.ws_col, ws.ws_row)
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
