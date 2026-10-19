import Foundation
import ManifoldCore

// manifoldd serve           run the server (the app starts it as needed)
// manifoldd attach <block>  connect this terminal to a terminal block's shell
// manifoldd bridge [--name NAME]
//                           stdio to the server's socket, starting it if need
//                           be (what a client runs on a remote host over ssh)
// manifoldd open [--wait] FILE...
//                           have the app open files (a remote shell's $EDITOR)
// manifoldd stop            end the server and every session
// manifoldd state           print what the host has

let args = CommandLine.arguments.dropFirst()

switch args.first ?? "serve" {
case "bridge":
    var name: String?
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--name" { name = it.next() }
    }
    Bridge.run(name: name)

case "open":
    var wait = false
    var files: [String] = []
    for a in args.dropFirst() {
        if a == "--wait" || a == "-w" { wait = true } else { files.append(a) }
    }
    let paths: [String]
    switch OpenCommand.resolve(files) {
    case .success(let p): paths = p
    case .failure(let error):
        FileHandle.standardError.write(Data("manifold: \(error.message)\n".utf8))
        exit(1)
    }
    guard let fd = try? UnixSocket.connect(path: Paths.socket) else {
        FileHandle.standardError.write(Data("manifold: the server isn't running here\n".utf8))
        exit(1)
    }
    let beside = ProcessInfo.processInfo.environment["MANIFOLD_BLOCK"].flatMap(BlockID.init(string:))
    exit(OpenCommand.run(fd: fd, paths: paths, beside: beside, wait: wait, name: "manifoldd open"))

case "serve":
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    let server = Server()
    do {
        try server.run()
    } catch ServerError.alreadyRunning {
        exit(0)
    } catch {
        log("manifoldd: \(error)")
        exit(1)
    }
    dispatchMain()

case "attach":
    guard args.count == 2, let block = BlockID(string: args[args.startIndex + 1]) else {
        FileHandle.standardError.write(Data("usage: manifoldd attach <host/block>\n".utf8))
        exit(2)
    }
    Attach.run(block: block)

case "stop":
    guard let fd = try? UnixSocket.connect(path: Paths.socket) else { exit(0) }
    let frame = Frame.message(ClientMessage.shutdown).encoded
    _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var b: UInt8 = 0
    _ = read(fd, &b, 1)

case "state":
    guard let fd = try? UnixSocket.connect(path: Paths.socket) else {
        FileHandle.standardError.write(Data("manifoldd is not running\n".utf8))
        exit(1)
    }
    let hello = Frame.message(ClientMessage.hello(version: protocolVersion, name: "state")).encoded
    _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var decoder = FrameDecoder()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { exit(1) }
        decoder.append(Data(buf[0..<n]))
        while let frame = try decoder.next() {
            if case let .welcome(_, _, host, _, snapshots)? = frame.decode(ServerMessage.self) {
                let node = Node()
                for s in snapshots { node.load(s) }
                if args.count > 1, args[args.startIndex + 1] == "--json" {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try enc.encode(snapshots), as: UTF8.self))
                } else {
                    print("host \(host)")
                    let desk = node.desk(host)
                    print("desk: \(desk.order.count) on it, selected \(desk.selected.map(\.description) ?? "none")")
                    for b in node.blocks.sorted(by: { $0.created < $1.created }) {
                        var line = "\(b.id) \(b.kind) \"\(b.displayTitle)\""
                        if let p = b.path { line += " \(p)" }
                        if let a = b.arrangement { line += " columns=\(a.columns.map(\.count)) shown=\(a.shown) focused=\(a.focused ?? "-")" }
                        if let t = b.text { line += " v\(t.version) clean\(t.cleanVersion)\(t.isDirty ? " dirty" : "")\(t.stale ? " stale" : "")" }
                        if let t = b.terminal { line += " cwd=\(t.cwd ?? "-")\(t.busy ? " busy" : "")\(t.dormantSince != nil ? " dormant" : "")" }
                        if let r = node.registry(host).blocks[b.id] { line += " [\(r.life)\(r.held ? " held" : "")]" }
                        print(line)
                    }
                }
                exit(0)
            }
        }
    }

default:
    FileHandle.standardError.write(Data("usage: manifoldd [serve | attach <block> | stop | state]\n".utf8))
    exit(2)
}
