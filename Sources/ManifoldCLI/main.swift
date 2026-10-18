import AppKit
import ManifoldCore

// manifold [--wait] [file ...]
//
// Opens files in Manifold: Markdown in a live preview, folders in a listing,
// anything else in an editor. Run in one of Manifold's terminals, they open
// beside it; anywhere else, in the selected arrangement, with Manifold
// brought forward (and started if need be). With --wait (what Manifold's
// shells have as $EDITOR), returns when they've been put away again. With
// no files, just brings Manifold forward.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("manifold: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
    print("""
        usage: manifold [--wait] [file ...]

        Opens files in Manifold: Markdown in a live preview, folders in a
        listing, text in an editor; beside this terminal when run in one of
        Manifold's. With --wait, returns once they've been put away.
        """)
    exit(0)
}
let wait = args.contains("--wait") || args.contains("-w")
args.removeAll { $0 == "--wait" || $0 == "-w" }

let paths: [String]
switch OpenCommand.resolve(args) {
case .success(let p): paths = p
case .failure(let error): fail(error.message)
}

let env = ProcessInfo.processInfo.environment
let besideBlock = env["MANIFOLD_BLOCK"].flatMap(BlockID.init(string:))

/// The app this command belongs to: it lives in Manifold.app/Contents/Helpers.
func appURL() -> URL? {
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" { return app }
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.manifold.app")
}

/// Starts or brings forward the app, and waits for it to answer.
func launchApp(activate: Bool) {
    guard let url = appURL() else { fail("can't find Manifold.app") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = activate
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        if let error { fail("can't open \(url.path): \(error.localizedDescription)") }
        done.signal()
    }
    done.wait()
}

/// Connects to the host, starting the app (and so the server) if need be.
func connect() -> Int32 {
    if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
    launchApp(activate: besideBlock == nil)
    for _ in 0..<100 {
        if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
        usleep(100_000)
    }
    fail("Manifold didn't start (see \(Paths.log.path))")
}

signal(SIGPIPE, SIG_IGN)
if paths.isEmpty {
    launchApp(activate: true)
    exit(0)
}
// The app must be attached for the host to pass the request on.
var fd = connect()
if besideBlock == nil { launchApp(activate: true) }
var status = OpenCommand.run(fd: fd, paths: paths, beside: besideBlock, wait: wait)
if status != 0, besideBlock == nil {
    // The app was starting: give it a moment and ask again.
    close(fd)
    sleep(2)
    fd = connect()
    status = OpenCommand.run(fd: fd, paths: paths, beside: besideBlock, wait: wait)
}
exit(status)
