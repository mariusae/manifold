import Foundation
import ManifoldCore
import Network

/// Ports of another host's brought here (§8): a server on the host's
/// loopback (a dev server's localhost:3000) reached on this Mac's, at the
/// same port when it's free here, else another. Each connection made here
/// is a stream of the host's connection (§8): the host connects to the
/// port on its side, and the bytes go both ways — paced, and no more
/// than the stream's window on the way, credited as each side passes
/// them on, so a slow side fills nothing but itself.
final class PortForwards {
    struct Forward {
        let remote: Int
        var local: Int?
        let listener: NWListener
        /// Made for a block (a smartlog's, a page's loaded through the
        /// host), not asked for: not listed.
        var hidden = false
    }

    private weak var client: HostClient?
    private(set) var forwards: [Int: Forward] = [:]
    /// Each connection made here, joined to its stream.
    private var pipes: [Int: StreamPipe] = [:]
    private var nextKey = 0
    /// The forwards changed (made, ready, stopped).
    var onChange: (() -> Void)?

    init(client: HostClient) { self.client = client }

    /// The host's `port` forwarded here; `done` with the port here once
    /// it's listening (nil if it couldn't be). Asked for again before it
    /// is, it's told then too: one port, one forward. A forward made for
    /// a block (`hidden`) is listed once it's asked for by hand.
    func forward(_ port: Int, hidden: Bool = false, done: @escaping (Int?) -> Void) {
        if !hidden { forwards[port]?.hidden = false }
        if let f = forwards[port] {
            if let local = f.local { return done(local) }
            waiting[port, default: []].append(done)
            return
        }
        waiting[port] = [done]
        listen(port, preferring: port, hidden: hidden)
    }

    /// Who's waiting for each forward being made.
    private var waiting: [Int: [(Int?) -> Void]] = [:]

    private func answer(_ remote: Int, _ local: Int?) {
        for done in waiting.removeValue(forKey: remote) ?? [] { done(local) }
    }

    private func listen(_ remote: Int, preferring wanted: Int?, hidden: Bool) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let port = wanted.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) } ?? .any
        guard let listener = try? NWListener(using: params, on: port) else {
            return wanted != nil ? listen(remote, preferring: nil, hidden: hidden) : answer(remote, nil)
        }
        listener.newConnectionHandler = { [weak self] c in self?.accepted(c, for: remote) }
        var answered = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.forwards[remote]?.listener === listener else { return }
            switch state {
            case .ready:
                let local = Int(listener.port?.rawValue ?? 0)
                self.forwards[remote]?.local = local
                self.onChange?()
                if !answered { answered = true; self.answer(remote, local) }
            case .failed:
                listener.cancel()
                // (Asked for by hand meanwhile, it's listed.)
                let hidden = self.forwards.removeValue(forKey: remote)?.hidden ?? hidden
                // Taken here: another port, any.
                if !answered { answered = true; wanted != nil ? self.listen(remote, preferring: nil, hidden: hidden) : self.answer(remote, nil) }
            default:
                break
            }
        }
        forwards[remote] = Forward(remote: remote, local: nil, listener: listener, hidden: hidden)
        listener.start(queue: .main)
    }

    func stop(_ remote: Int) {
        forwards.removeValue(forKey: remote)?.listener.cancel()
        answer(remote, nil)
        onChange?()
    }

    func stopAll() {
        for f in forwards.values { f.listener.cancel() }
        forwards = [:]
        for remote in Array(waiting.keys) { answer(remote, nil) }
        onChange?()
    }

    /// The most connections a host's forwards take at once; past that,
    /// one is refused. A host whose localhost is this Mac's (this Mac
    /// attached as another host) would otherwise, its port forwarded onto
    /// the same port here, have the forward connect to itself without end
    /// — a page loaded through it is enough — until the Mac has no ports
    /// left; refused, the loop comes undone.
    static let most = 512

    /// A connection made here: a stream to the host's port, then the
    /// bytes piped both ways.
    private func accepted(_ c: NWConnection, for remote: Int) {
        guard let mux = client?.mux else { return c.cancel() }
        guard pipes.count < Self.most else {
            NSLog("host %@: %d connections forwarded at once; another to port %d refused", client?.host.raw ?? "?", pipes.count, remote)
            return c.cancel()
        }
        // Its handlers on the main thread, where the connections here and
        // this bookkeeping are (the link's own queue would race them).
        let stream = mux.open(bulk: true, callbackQueue: .main)
        stream.manualCredit = true
        stream.send(.message(ClientMessage.tunnel(port: remote)))
        c.start(queue: .main)
        let key = nextKey
        nextKey += 1
        let pipe = StreamPipe(c, stream)
        pipe.onEnd = { [weak self] in self?.pipes.removeValue(forKey: key) }
        pipes[key] = pipe
        pipe.start()
    }

    /// The link to the host went: its connections with it (the ports stay
    /// listening, for when it's back).
    func linkClosed() {
        for p in pipes.values { p.cancel() }
        pipes = [:]
    }
}
