import AppKit
import ManifoldCore

// manifold [file ...]
//
// Opens files in Manifold: Markdown in a live preview, folders in a listing,
// anything else in an editor. Run in one of Manifold's terminals, the first
// file opens beside it; anywhere else, in an arrangement of its own, with
// Manifold brought forward (and started if need be). With no files, just
// brings Manifold forward.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("manifold: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
    print("""
        usage: manifold [file ...]

        Opens files in Manifold: Markdown in a live preview, folders in a
        listing, text in an editor; beside this terminal when run in one of
        Manifold's, else in a new arrangement.
        """)
    exit(0)
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let files: [(path: String, isDir: Bool)] = args.map { arg in
    let path = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        fail("no such file: \(arg)")
    }
    return (path, isDir.boolValue)
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

func connect() -> Int32 {
    if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
    launchApp(activate: besideBlock == nil)
    for _ in 0..<100 {
        if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
        usleep(100_000)
    }
    fail("Manifold didn't start (see \(Paths.log.path))")
}

func send(_ fd: Int32, _ message: ClientMessage) {
    let data = Frame.message(message).encoded
    let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
    if !ok { fail("lost the connection to Manifold") }
}

/// Waits for the server's welcome, checks it speaks our protocol, and
/// returns the host's state.
func awaitWelcome(_ fd: Int32) -> (HostID, Node) {
    var decoder = FrameDecoder()
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    let deadline = Date().addingTimeInterval(5)
    while true {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
        guard left > 0, poll(&pfd, 1, left) > 0 else { fail("Manifold didn't answer") }
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { fail("lost the connection to Manifold") }
        decoder.append(Data(buf[0..<n]))
        while let frame = try? decoder.next() {
            if case let .welcome(version, _, host, _, snapshots)? = frame.decode(ServerMessage.self) {
                if version != protocolVersion {
                    fail("Manifold's server is from another version; restart it (Manifold ▸ Restart Server)")
                }
                let node = Node()
                for s in snapshots { node.load(s) }
                return (host, node)
            }
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let fd = connect()
send(fd, .hello(version: protocolVersion, name: "manifold"))
let (host, node) = awaitWelcome(fd)
let clock = Clock(host: host)

/// Appends to a shard the app leads, continuing its log as we saw it; the
/// app sees the entries as the host passes them on.
func append(_ events: [Event], to shard: ShardID) {
    var entries: [Entry] = []
    for e in events {
        if let entry = node.append(e, to: shard, at: clock.now()) { entries.append(entry) }
    }
    if !entries.isEmpty { send(fd, .append(shard: shard, entries: entries)) }
}

var proposalID = 1
func propose(_ p: Proposal) {
    send(fd, .propose(id: proposalID, p))
    proposalID += 1
}

let desk = node.desk(host)
// Where things go: the arrangement with the terminal we're in, else the
// selected one, else a new one.
var arrangementID: BlockID? = besideBlock.flatMap { b in
    desk.order.first { node.block($0)?.arrangement?.placements.contains { $0.block == b } == true }
} ?? desk.selected
if arrangementID.flatMap({ node.block($0)?.arrangement }) == nil, !files.isEmpty {
    let id = BlockID(host: host)
    append([.create(kind: .arrangement, title: nil, path: nil)], to: .block(id))
    append([.order(desk.order + [id]), .select(id)], to: .desk(host))
    arrangementID = id
}

for (i, file) in files.enumerated() {
    guard let aid = arrangementID, let a = node.block(aid)?.arrangement else { break }
    let block: BlockID
    let lens: Lens
    if file.isDir {
        block = node.blocks.first { $0.kind == .directory && $0.path == file.path }?.id ?? BlockID(host: host)
        lens = .directory
        if node.block(block) == nil { propose(.directory(block: block, path: file.path)) }
    } else {
        if let existing = node.blocks.first(where: { $0.kind == .text && $0.path == file.path }) {
            block = existing.id
        } else {
            block = BlockID(host: host)
            append([.create(kind: .text, title: nil, path: file.path)], to: .block(block))
            if let contents = TextFile.read(file.path) {
                append([.content(contents.text, encoding: contents.encoding, lineEnding: contents.lineEnding, fingerprint: contents.fingerprint)], to: .block(block))
            }
        }
        lens = Lens.default(for: .text, path: file.path)
    }
    let beside = i == 0 ? a.placements.first { $0.block == besideBlock }?.id : nil
    append(a.placing(block, lens: lens, beside: beside, newPlacement: { ULID.make() }), to: .block(aid))
    if let besideBlock { propose(.link(Link(from: besideBlock, to: block, kind: .opened, at: clock.now()))) }
}
if besideBlock != nil, let aid = arrangementID, desk.selected != aid {
    append([.select(aid)], to: .desk(host))
}
// The server handles what we sent before it notices we've gone.
usleep(50_000)
close(fd)
if besideBlock == nil {
    launchApp(activate: true)
}
