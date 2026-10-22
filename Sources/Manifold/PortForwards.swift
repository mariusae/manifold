import Foundation
import ManifoldCore
import Network

/// Ports of another host's brought here (§8): a server on the host's
/// loopback (a dev server's localhost:3000) reached on this Mac's, at the
/// same port when it's free here, else another. Each connection made here
/// is a tunnel through the host's own link: the host connects to the port
/// on its side, and the bytes go both ways in `tunnel` frames — no more
/// than a window of a tunnel's at once, each end saying (`tunnelAck`)
/// when it has passed bytes on, so a slow side fills nothing but itself.
final class PortForwards {
    struct Forward {
        let remote: Int
        var local: Int?
        let listener: NWListener
    }

    private weak var client: HostClient?
    private(set) var forwards: [Int: Forward] = [:]
    private var streams: [UInt32: NWConnection] = [:]
    /// Bytes of each tunnel's sent to the host and not yet taken there;
    /// a tunnel at its window waits (`stalled`) to be read again.
    private var unacked: [UInt32: Int] = [:]
    private var stalled: Set<UInt32> = []
    private var nextID: UInt32 = 1
    /// The forwards changed (made, ready, stopped).
    var onChange: (() -> Void)?

    init(client: HostClient) { self.client = client }

    /// The host's `port` forwarded here; `done` with the port here once
    /// it's listening (nil if it couldn't be).
    func forward(_ port: Int, done: @escaping (Int?) -> Void) {
        if let f = forwards[port], let local = f.local { return done(local) }
        listen(port, preferring: port, done: done)
    }

    private func listen(_ remote: Int, preferring wanted: Int?, done: @escaping (Int?) -> Void) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let port = wanted.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) } ?? .any
        guard let listener = try? NWListener(using: params, on: port) else {
            return wanted != nil ? listen(remote, preferring: nil, done: done) : done(nil)
        }
        listener.newConnectionHandler = { [weak self] c in self?.accepted(c, for: remote) }
        var answered = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let local = Int(listener.port?.rawValue ?? 0)
                self.forwards[remote]?.local = local
                self.onChange?()
                if !answered { answered = true; done(local) }
            case .failed:
                listener.cancel()
                self.forwards.removeValue(forKey: remote)
                // Taken here: another port, any.
                if !answered { answered = true; wanted != nil ? self.listen(remote, preferring: nil, done: done) : done(nil) }
            default:
                break
            }
        }
        forwards[remote] = Forward(remote: remote, local: nil, listener: listener)
        listener.start(queue: .main)
    }

    func stop(_ remote: Int) {
        forwards.removeValue(forKey: remote)?.listener.cancel()
        onChange?()
    }

    func stopAll() {
        for f in forwards.values { f.listener.cancel() }
        forwards = [:]
        onChange?()
    }

    /// A connection made here: a tunnel asked for, then the bytes piped.
    private func accepted(_ c: NWConnection, for remote: Int) {
        guard let client else { return c.cancel() }
        let id = nextID
        nextID &+= 1
        streams[id] = c
        c.start(queue: .main)
        client.propose(.openTunnel(id: Int(id), port: remote)) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.streams.removeValue(forKey: id)
                c.cancel()
                return
            }
            self.pump(c, id)
        }
    }

    private func pump(_ c: NWConnection, _ id: UInt32) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.client?.sendTunnel(id, data)
                self.unacked[id, default: 0] += data.count
            }
            if error != nil {
                if self.streams.removeValue(forKey: id) != nil { self.client?.sendTunnel(id, Data()) }
                self.forget(id)
                c.cancel()
                return
            }
            if complete {
                // Done sending, here: said so, and the host's answer
                // still comes back until it closes its side.
                self.client?.sendTunnel(id, Data())
                return
            }
            if self.unacked[id, default: 0] >= Frame.tunnelWindow { self.stalled.insert(id) } else { self.pump(c, id) }
        }
    }

    /// The host passed on `count` of a tunnel's bytes: read on, if it waited.
    func acked(_ id: UInt32, _ count: Int) {
        guard let c = streams[id] else { return }
        unacked[id] = max(0, unacked[id, default: 0] - count)
        if unacked[id, default: 0] < Frame.tunnelWindow, stalled.remove(id) != nil { pump(c, id) }
    }

    private func forget(_ id: UInt32) {
        unacked.removeValue(forKey: id)
        stalled.remove(id)
    }

    /// The host's side of a tunnel: its bytes on to the connection here;
    /// none, it closed (after this side's EOF, if it came first).
    func received(_ id: UInt32, _ data: Data) {
        guard let c = streams[id] else { return }
        if data.isEmpty {
            streams.removeValue(forKey: id)
            forget(id)
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        } else {
            // Taken here: the host may send as much again.
            c.send(content: data, completion: .contentProcessed { [weak self] error in
                if error == nil { self?.client?.sendTunnelAck(id, data.count) }
            })
        }
    }

    /// The link to the host went: its tunnels with it (the ports stay
    /// listening, for when it's back).
    func linkClosed() {
        for c in streams.values { c.cancel() }
        streams = [:]
        unacked = [:]
        stalled = []
    }
}
