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
        /// Made for a block (a smartlog's), not asked for: not listed.
        var hidden = false
    }

    private weak var client: HostClient?
    private(set) var forwards: [Int: Forward] = [:]
    /// Each connection made here, by its stream.
    private var streams: [Int: (connection: NWConnection, stream: MuxStream)] = [:]
    private var nextKey = 0
    /// The forwards changed (made, ready, stopped).
    var onChange: (() -> Void)?

    init(client: HostClient) { self.client = client }

    /// The host's `port` forwarded here; `done` with the port here once
    /// it's listening (nil if it couldn't be).
    func forward(_ port: Int, hidden: Bool = false, done: @escaping (Int?) -> Void) {
        if let f = forwards[port], let local = f.local { return done(local) }
        listen(port, preferring: port) { [weak self] local in
            if hidden { self?.forwards[port]?.hidden = true }
            done(local)
        }
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

    /// A connection made here: a stream to the host's port, then the
    /// bytes piped both ways.
    private func accepted(_ c: NWConnection, for remote: Int) {
        guard let mux = client?.mux else { return c.cancel() }
        // Its handlers on the main thread, where the connections here and
        // this bookkeeping are (the link's own queue would race them).
        let stream = mux.open(bulk: true, callbackQueue: .main)
        let key = nextKey
        nextKey += 1
        streams[key] = (c, stream)
        stream.manualCredit = true
        stream.send(.message(ClientMessage.tunnel(port: remote)))
        // The host's bytes on to the connection here, credited once taken;
        // none, its side is done.
        stream.onFrame = { [weak stream] frame in
            guard frame.kind == .data else { return }
            let n = frame.payload.count + 5
            c.send(content: frame.payload, completion: .contentProcessed { [weak stream] error in
                if error == nil { stream?.consumed(n) }
            })
        }
        // Closed there (its server closed, or nothing listening): closed here,
        // after what came.
        stream.onClose = { [weak self] in
            self?.streams.removeValue(forKey: key)
            self?.finished.remove(key)
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        }
        stream.onDrain = { [weak self] in self?.pump(key) }
        c.start(queue: .main)
        pump(key)
    }

    /// What's sent here, up the stream while it wants more; `finished`,
    /// once this side is done sending (not read again).
    private var reading: Set<Int> = []
    private var finished: Set<Int> = []

    private func pump(_ key: Int) {
        guard let (c, stream) = streams[key], stream.wantsMore, !finished.contains(key), reading.insert(key).inserted else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: stream.piece) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.reading.remove(key)
            // Gone meanwhile (closed from the host's side): nothing more.
            guard self.streams[key] != nil else { return }
            if let data, !data.isEmpty { stream.send(Frame(.data, data)) }
            if error != nil {
                self.streams.removeValue(forKey: key)
                self.finished.remove(key)
                stream.close()
                c.cancel()
                return
            }
            // Done sending, here: said so, and the host's answer still
            // comes back until it closes its side.
            if complete {
                self.finished.insert(key)
                return stream.send(Frame(.data, Data()))
            }
            self.pump(key)
        }
    }

    /// The link to the host went: its connections with it (the ports stay
    /// listening, for when it's back).
    func linkClosed() {
        for (c, _) in streams.values { c.cancel() }
        streams = [:]
        reading = []
        finished = []
    }
}
