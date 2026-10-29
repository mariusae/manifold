import Foundation
import ManifoldCore

// manifoldd serve           run the server (the app starts it as needed)
// manifoldd attach <block>  connect this terminal to a terminal block's shell
// manifoldd bridge [--name NAME]
//                           stdio to the server's socket, starting it if need
//                           be (what a client runs on a remote host over ssh)
// manifoldd mani ...       the `mani` command, on a host Manifold installed
//                           this server on (a script there named so runs it)
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

case "mani":
    // `mani` on a host Manifold installed this server on: a script beside
    // it runs us so.
    Mani.main(Array(args.dropFirst()), platform: Mani.Platform(
        request: { _, body in
            guard let fd = try? UnixSocket.connect(path: Paths.socket) else { Mani.fail("the server isn't running here") }
            return body(fd)
        },
        bringForward: nil))

case "serve":
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    ToolPath.extend()
    AgentSkill.refresh()
    var server: Server?
    do {
        Mux.log = { log($0) }
        server = try Server()
        try server?.run()
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
            if case let .welcome(_, _, host, _, _, _, snapshots, _, _)? = frame.decode(ServerMessage.self) {
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
                        if let a = b.arrangement { line += " columns=\(a.columns.map(\.count)) focused=\(a.focused ?? "-")" }
                        if let t = b.text { line += " v\(t.version) clean\(t.cleanVersion)\(t.isDirty ? " dirty" : "")\(t.stale ? " stale" : "")" }
                        if let t = b.terminal { line += " cwd=\(t.cwd ?? "-")\(t.busy ? " busy" : "")\(t.dormantSince != nil ? " dormant" : "")" }
                        print(line)
                    }
                }
                exit(0)
            }
        }
    }

default:
    FileHandle.standardError.write(Data("usage: manifoldd [serve | attach <block> | bridge | mani ... | stop | state]\n".utf8))
    exit(2)
}
