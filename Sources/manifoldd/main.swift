import Foundation
import ManifoldCore

// manifoldd serve          run the server (the app starts it as needed)
// manifoldd attach <pane>  connect this terminal to a pane's session
// manifoldd stop           end the server and every session
// manifoldd state          print the workspace

let args = CommandLine.arguments.dropFirst()

switch args.first ?? "serve" {
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
    guard args.count == 2, let pane = UUID(uuidString: args[args.startIndex + 1]) else {
        FileHandle.standardError.write(Data("usage: manifoldd attach <pane>\n".utf8))
        exit(2)
    }
    Attach.run(pane: pane)

case "stop":
    guard let fd = try? UnixSocket.connect(path: Paths.socket) else { exit(0) }
    let frame = Frame.json(ClientMessage.shutdown).encoded
    _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var b: UInt8 = 0
    _ = read(fd, &b, 1)

case "state":
    guard let fd = try? UnixSocket.connect(path: Paths.socket) else {
        FileHandle.standardError.write(Data("manifoldd is not running\n".utf8))
        exit(1)
    }
    let hello = Frame.json(ClientMessage.hello(version: protocolVersion)).encoded
    _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var decoder = FrameDecoder()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { exit(1) }
        decoder.append(Data(buf[0..<n]))
        while let frame = try decoder.next() {
            if case .state(let ws)? = frame.decode(ServerMessage.self) {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try enc.encode(ws), as: UTF8.self))
                exit(0)
            }
        }
    }

default:
    FileHandle.standardError.write(Data("usage: manifoldd [serve | attach <pane> | stop | state]\n".utf8))
    exit(2)
}
