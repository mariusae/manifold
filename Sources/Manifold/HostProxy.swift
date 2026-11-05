import Foundation
import ManifoldCore
import Network

/// A SOCKS5 proxy on this Mac's loopback for one host (§7.6), for the
/// web blocks loaded through it: each connection a page makes is a
/// stream of the host's connection, made by the host (`connect`) — a name
/// looked up by its resolver, an address reached by its routes — so the
/// page loads as it would there, a site on a network only the host is on
/// too. Only those pages can use it: it asks for a name and a password
/// made when it starts, which their data store is given (`WebStores`).
/// The host's own localhost isn't reached through it (WebKit never asks
/// a proxy for a loopback address): those are forwarded ports.
final class HostProxy {
    private weak var client: HostClient?
    let user = "manifold"
    let password: String
    private var listener: NWListener?
    /// Where it listens, once it does.
    private(set) var port: Int?
    private var waiters: [(Int?) -> Void] = []
    /// Each connection made here, from its greeting until it closes.
    private var connections: [Int: ProxyConnection] = [:]
    private var nextKey = 0
    /// Asked for while the host is being reached (at launch, a link made
    /// again): connected once it's there, failed after this long.
    static let linkWait: TimeInterval = 30

    /// Why a page's connection went nowhere: the host's reason, or no
    /// link to the host.
    enum Refusal: Equatable {
        case host(ConnectFailure)
        case unreached
    }
    /// The last refusal for each address ("name:port"), and when: WebKit
    /// says only "bad URL" of a connection its proxy refused, so the page
    /// asks here what happened.
    private var refusals: [String: (Refusal, Date)] = [:]

    init(client: HostClient) {
        self.client = client
        var g = SystemRandomNumberGenerator()
        password = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// The port it listens on, once it does (nil: it couldn't).
    func whenListening(_ done: @escaping (Int?) -> Void) {
        if let port { return done(port) }
        waiters.append(done)
        if listener == nil { listen() }
    }

    private func listen() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: .any) else { return answer(nil) }
        l.newConnectionHandler = { [weak self] c in self?.accepted(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, l === self.listener else { return }
            switch state {
            case .ready:
                self.port = l.port.map { Int($0.rawValue) }
                self.answer(self.port)
            case .failed:
                // Listened again when next asked for.
                l.cancel()
                self.listener = nil
                self.port = nil
                self.answer(nil)
            default:
                break
            }
        }
        listener = l
        l.start(queue: .main)
    }

    private func answer(_ port: Int?) {
        let w = waiters
        waiters = []
        for done in w { done(port) }
    }

    private func accepted(_ c: NWConnection) {
        let key = nextKey
        nextKey += 1
        let p = ProxyConnection(c, user: user, password: password)
        p.onRequest = { [weak self, weak p] request in
            guard let self, let p else { return }
            self.requested(p, request)
        }
        p.onRefused = { [weak self] request, why in self?.refused(request, why) }
        p.onEnd = { [weak self] in self?.connections.removeValue(forKey: key) }
        connections[key] = p
        c.start(queue: .main)
        p.start()
    }

    /// Where a page asked to go: there through the host, when it's
    /// reached — at once if it is, as soon as it's back if it's being
    /// reached again, and not at all if it can't be now.
    private func requested(_ p: ProxyConnection, _ request: Socks5.Request) {
        refusals.removeValue(forKey: Self.key(request.host, request.port))
        guard let client else { return p.fail(.unreached) }
        if client.link == .connected, let mux = client.mux { return p.connect(through: mux) }
        guard client.link == .connecting else { return p.fail(.unreached) }
        p.waitingForLink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkWait) { [weak p] in
            guard let p, p.waitingForLink else { return }
            p.waitingForLink = false
            p.fail(.unreached)
        }
    }

    /// How long a refusal is kept for the page to ask about.
    static let refusalKept: TimeInterval = 30

    private func refused(_ request: Socks5.Request, _ why: Refusal) {
        refusals = refusals.filter { $0.value.1.timeIntervalSinceNow > -Self.refusalKept }
        refusals[Self.key(request.host, request.port)] = (why, Date())
    }

    /// Why the last connection to an address, made lately, went nowhere,
    /// if it did.
    func refusal(host: String, port: Int) -> Refusal? {
        guard let (why, at) = refusals[Self.key(host, port)], at.timeIntervalSinceNow > -Self.refusalKept else { return nil }
        return why
    }

    private static func key(_ host: String, _ port: Int) -> String {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return "\(h):\(port)"
    }

    /// The host answered (a link made, or made again): what waited for it
    /// goes. (A link that goes takes its streams with it, and each page's
    /// connection with its stream.)
    func linkOpened() {
        guard let mux = client?.mux else { return }
        for p in connections.values where p.waitingForLink {
            p.waitingForLink = false
            p.connect(through: mux)
        }
    }
}

/// One connection a page made to the proxy: its greeting and name
/// checked, where it asks to go read, then — the host connected there —
/// joined to its stream (`StreamPipe`).
private final class ProxyConnection {
    private let connection: NWConnection
    private let user: Data
    private let password: Data
    /// What's come and not yet read.
    private var buffer = Data()
    private enum Step { case greeting, credentials, request, asked, piped, ended }
    private var step = Step.greeting
    private var request: Socks5.Request?
    /// The stream the host is asked to connect on, once it is.
    private var stream: MuxStream?
    private var pipe: StreamPipe?
    private var finished = false
    var onRequest: ((Socks5.Request) -> Void)?
    /// The request went nowhere, and why.
    var onRefused: ((Socks5.Request, HostProxy.Refusal) -> Void)?
    var onEnd: (() -> Void)?
    /// Asked for while the host's link was down: connected when it's up.
    var waitingForLink = false

    init(_ connection: NWConnection, user: String, password: String) {
        self.connection = connection
        self.user = Data(user.utf8)
        self.password = Data(password.utf8)
    }

    func start() { read() }

    /// What the page says, until it has asked where to go; then, while
    /// the host connects, whether it goes (the host's connecting given up
    /// with it), what it sends meanwhile kept to go up the stream first.
    /// Read once the pipe has begun, that goes up ahead of what the pipe
    /// reads after it.
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            switch self.step {
            case .greeting, .credentials, .request, .asked:
                if let data { self.buffer.append(data) }
                self.advance()
                guard self.step != .ended else { return }
                if error != nil || complete { return self.gone() }
                if self.step != .piped { self.read() }
            case .piped:
                if let data, !data.isEmpty { self.stream?.send(Frame(.data, data)) }
                // Its end, as the pipe would say it, had the pipe read it.
                if error != nil { self.pipe?.cancel() } else if complete { self.stream?.send(Frame(.data, Data())) }
            case .ended:
                break
            }
        }
    }

    /// The page went before the host answered: the host's connecting, or
    /// the wait for its link, given up.
    private func gone() {
        stream?.close()
        end()
    }

    /// As far as what's come says.
    private func advance() {
        while true {
            switch step {
            case .greeting:
                switch Socks5.greeting(buffer) {
                case .more: return
                case .bad: return end()
                case let .done(methods, n):
                    buffer.removeFirst(n)
                    // By a name and a password, or not at all.
                    guard methods.contains(Socks5.usernamePassword) else { return sayLast(Socks5.chose(Socks5.noMethod)) }
                    connection.send(content: Socks5.chose(Socks5.usernamePassword), completion: .contentProcessed { _ in })
                    step = .credentials
                }
            case .credentials:
                switch Socks5.credentials(buffer) {
                case .more: return
                case .bad: return end()
                case let .done(given, n):
                    buffer.removeFirst(n)
                    guard same(Data(given.user.utf8), user), same(Data(given.password.utf8), password) else {
                        return sayLast(Socks5.authenticated(false))
                    }
                    connection.send(content: Socks5.authenticated(true), completion: .contentProcessed { _ in })
                    step = .request
                }
            case .request:
                switch Socks5.request(buffer) {
                case .more: return
                case .bad: return end()
                case let .done(r, n):
                    buffer.removeFirst(n)
                    guard r.command == Socks5.connectCommand else { return sayLast(Socks5.Reply.commandNotSupported.bytes) }
                    step = .asked
                    request = r
                    onRequest?(r)
                    return
                }
            case .asked, .piped, .ended:
                return
            }
        }
    }

    /// Whether two secrets are the same, taking as long whatever they hold.
    private func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The host asked to connect where the page asked to go; its answer
    /// said to the page, and the bytes piped once it's connected.
    func connect(through mux: Mux) {
        guard step == .asked, let request else { return }
        let stream = mux.open(bulk: true, callbackQueue: .main)
        self.stream = stream
        stream.manualCredit = true
        stream.send(.message(ClientMessage.connect(host: request.host, port: request.port)))
        stream.onFrame = { [weak self, weak stream] frame in
            guard let self, let stream else { return }
            stream.consumed(frame.payload.count + 5)
            switch frame.kind == .message ? frame.decode(ConnectReply.self) : nil {
            case .connected?:
                self.piped(stream)
            case let .failed(why)?:
                self.fail(.host(why))
                stream.close()
            case nil:
                self.fail(.host(.failed))
                stream.close()
            }
        }
        // Closed unanswered: the link went, or a server from before
        // `connect` took it for nothing it knew.
        stream.onClose = { [weak self] in self?.fail(.host(.failed)) }
    }

    private func piped(_ stream: MuxStream) {
        guard step == .asked else { return stream.close() }
        step = .piped
        connection.send(content: Socks5.Reply.succeeded.bytes, completion: .contentProcessed { _ in })
        // What the page sent after its request, before the answer: first up.
        if !buffer.isEmpty { stream.send(Frame(.data, buffer)) }
        buffer = Data()
        let p = StreamPipe(connection, stream)
        p.onEnd = { [weak self] in self?.finish() }
        pipe = p
        p.start()
    }

    /// The page's request answered as not done, and the connection closed.
    func fail(_ why: HostProxy.Refusal) {
        guard step == .asked, let request else { return }
        onRefused?(request, why)
        switch why {
        case let .host(f): sayLast(Socks5.Reply(f).bytes)
        case .unreached: sayLast(Socks5.Reply.networkUnreachable.bytes)
        }
    }

    /// The last word to the page, then closed.
    private func sayLast(_ d: Data) {
        step = .ended
        connection.send(content: d, completion: .contentProcessed { [weak self] _ in self?.end() })
    }

    /// Closed now: the pipe, or the connection.
    func end() {
        guard !finished else { return }
        if let pipe { return pipe.cancel() }
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        step = .ended
        pipe = nil
        onEnd?()
        onEnd = nil
    }
}
