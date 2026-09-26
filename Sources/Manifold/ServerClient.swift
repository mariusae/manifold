import AppKit
import CPTY
import ManifoldCore

/// The app's connection to manifoldd. It starts the server when there isn't
/// one, and starts it again if it goes away.
final class ServerClient {
    private var conn: Connection?
    private(set) var workspace = Workspace()
    private(set) var hasState = false

    /// Called on the main queue with each new workspace.
    var onState: ((Workspace) -> Void)?
    var onDisconnect: (() -> Void)?

    /// The server executable: next to ours in the app bundle.
    static var serverExecutable: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("manifoldd").path
    }

    /// The command a terminal runs to attach to a pane. Ghostty splits
    /// commands on spaces, so a path with spaces goes through a symlink.
    static func attachCommand(pane: UUID) -> String {
        var exe = serverExecutable
        if exe.contains(" ") {
            let link = NSTemporaryDirectory() + "manifoldd-\(getuid())"
            unlink(link)
            symlink(exe, link)
            exe = link
        }
        return "direct:\(exe) attach \(pane.uuidString)"
    }

    func connect() {
        Paths.ensureDirectory()
        if let fd = try? UnixSocket.connect(path: Paths.socket) {
            attach(fd)
            return
        }
        launchServer()
        var attempts = 0
        func retry() {
            attempts += 1
            if let fd = try? UnixSocket.connect(path: Paths.socket) {
                attach(fd)
            } else if attempts < 100 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
            } else {
                let alert = NSAlert()
                alert.messageText = "Manifold couldn't start its server."
                alert.informativeText = "See \(Paths.log.path)."
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
    }

    func send(_ command: Command) {
        // Apply locally right away so the UI responds without a round trip;
        // the server's copy replaces ours when it arrives.
        workspace.apply(command)
        onState?(workspace)
        conn?.send(.json(ClientMessage.command(command)))
    }

    /// Ends the server and every session in it.
    static func stopServer() {
        guard let fd = try? UnixSocket.connect(path: Paths.socket) else { return }
        let frame = Frame.json(ClientMessage.shutdown).encoded
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var b: UInt8 = 0
        _ = read(fd, &b, 1)
        close(fd)
    }

    private func launchServer() {
        let exe = Self.serverExecutable
        let pid = withCStrings([exe, "serve"]) { argv in
            mf_spawn_detached(exe, argv, Paths.log.path)
        }
        if pid < 0 { NSLog("could not start %@: %s", exe, strerror(errno)) }
    }

    private func attach(_ fd: Int32) {
        let conn = Connection(fd: fd, queue: .main)
        conn.onFrame = { [weak self] frame in
            switch frame.decode(ServerMessage.self) {
            case .welcome(let version, _)?:
                if version != protocolVersion {
                    NSLog("manifoldd speaks protocol %d, we speak %d", version, protocolVersion)
                }
            case .state(let ws)?:
                self?.workspace = ws
                self?.hasState = true
                self?.onState?(ws)
            default:
                break
            }
        }
        conn.onClose = { [weak self] in
            guard let self else { return }
            self.conn = nil
            self.onDisconnect?()
            // Bring the server back; terminals re-attach once it's up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect() }
        }
        conn.start()
        conn.send(.json(ClientMessage.hello(version: protocolVersion)))
        self.conn = conn
    }
}

func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { for p in ptrs { free(p) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}
