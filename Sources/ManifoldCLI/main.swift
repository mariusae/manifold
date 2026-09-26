import AppKit
import ManifoldCore

// manifold [file ...]
//
// Opens files in Manifold (Markdown, for now, in a live preview). Run in one
// of Manifold's terminals, the first file opens beside it; anywhere else, in
// a tab of its own, with Manifold brought forward (and started if need be).
// With no files, just brings Manifold forward.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("manifold: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
    print("""
        usage: manifold [file ...]

        Opens Markdown files in Manifold, in a live preview: beside this
        terminal when run in one of Manifold's, else in a new tab.
        """)
    exit(0)
}

let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let files: [String] = args.map { arg in
    let path = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        fail("no such file: \(arg)")
    }
    guard markdownExtensions.contains((path as NSString).pathExtension.lowercased()) else {
        fail("\(arg): only Markdown files can be opened, for now")
    }
    return path
}

let env = ProcessInfo.processInfo.environment
let besidePane = env["MANIFOLD_PANE"].flatMap(UUID.init(uuidString:))

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

func connect() -> Int32 {
    if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
    launchApp(activate: besidePane == nil)
    for _ in 0..<100 {
        if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
        usleep(100_000)
    }
    fail("Manifold didn't start (see \(Paths.log.path))")
}

func send(_ fd: Int32, _ message: ClientMessage) {
    let data = Frame.json(message).encoded
    let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
    if !ok { fail("lost the connection to Manifold") }
}

/// Waits for the server's welcome, and checks it speaks our protocol.
func awaitWelcome(_ fd: Int32) {
    var decoder = FrameDecoder()
    var buf = [UInt8](repeating: 0, count: 65536)
    let deadline = Date().addingTimeInterval(5)
    while true {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
        guard left > 0, poll(&pfd, 1, left) > 0 else { fail("Manifold didn't answer") }
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { fail("lost the connection to Manifold") }
        decoder.append(Data(buf[0..<n]))
        while let frame = try? decoder.next() {
            if case .welcome(let version, _)? = frame.decode(ServerMessage.self) {
                if version != protocolVersion {
                    fail("Manifold's server is from another version; restart it (Manifold ▸ Restart Server)")
                }
                return
            }
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let fd = connect()
send(fd, .hello(version: protocolVersion))
awaitWelcome(fd)
for (i, path) in files.enumerated() {
    let beside = i == 0 ? besidePane : nil
    send(fd, .command(.openFile(path: path, kind: .markdown, pane: UUID(), tab: UUID(), beside: beside)))
}
// The server handles what we sent before it notices we've gone.
close(fd)
if besidePane == nil {
    launchApp(activate: true)
}
