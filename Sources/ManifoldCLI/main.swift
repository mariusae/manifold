import AppKit
import ManifoldCore

// manifold [--wait] [file ...]
// manifold diff [--title name] < patch
//
// Opens files in Manifold: Markdown in a live preview, folders in a listing,
// anything else in an editor. Run in one of Manifold's terminals, they open
// beside it; anywhere else, in the selected arrangement, with Manifold
// brought forward (and started if need be). With --wait (what Manifold's
// shells have as $EDITOR), returns when they've been put away again. With
// no files, just brings Manifold forward. `diff` reads a patch from its
// input (git diff | manifold diff) and shows it as a diff block.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("manifold: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
// An agent's hook, and installing them: nothing else of the command's.
if args.first == "agent" { AgentHookCommand.run(Array(args.dropFirst())) }
if let flag = args.first, flag == "--install-skill" || flag == "--uninstall-skill" {
    AgentSkill.runInstall(Array(args.dropFirst()), uninstall: flag == "--uninstall-skill")
}
if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
    print("""
        usage: manifold [--wait] [file ...]
               manifold diff [--title name] < patch
               manifold --install-skill [agent ...]   (--uninstall-skill to take it out)
               manifold agent <event> [--agent name]

        Opens files in Manifold: Markdown in a live preview, folders in a
        listing, text in an editor; beside this terminal when run in one of
        Manifold's. With --wait, returns once they've been put away.
        diff shows a patch from its input (git diff | manifold diff) as a
        diff block; double-click a line to open the file there.
        --install-skill puts hooks in the coding agents found here (or those
        named) so a Manifold terminal running one shows its status and each
        of its turns on the scrubber and in the outline; the hooks run
        `manifold agent`.
        """)
    exit(0)
}
let isDiff = args.first == "diff"
var diffTitle: String?
if isDiff {
    args.removeFirst()
    if let i = args.firstIndex(of: "--title"), i + 1 < args.count {
        diffTitle = args[i + 1]
        args.removeSubrange(i...(i + 1))
    } else if let t = args.first, !t.hasPrefix("-") {
        diffTitle = t
        args.removeFirst()
    }
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
if isDiff {
    let patch: String
    switch OpenCommand.readPatch() {
    case .success(let p): patch = p
    case .failure(let error): fail(error.message)
    }
    var fd = connect()
    if besideBlock == nil { launchApp(activate: true) }
    let root = FileManager.default.currentDirectoryPath
    var status = OpenCommand.runPatch(fd: fd, patch: patch, root: root, title: diffTitle, beside: besideBlock)
    if status != 0, besideBlock == nil {
        close(fd)
        sleep(2)
        fd = connect()
        status = OpenCommand.runPatch(fd: fd, patch: patch, root: root, title: diffTitle, beside: besideBlock)
    }
    exit(status)
}
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
