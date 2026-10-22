import Foundation

/// What a frame goes over: a connection, or one stream of a connection
/// (`MuxStream`). The server takes either the same way — what it is is
/// said by its first frame (a hello, an attach, a tunnel, a file).
public protocol Channel: AnyObject {
    func send(_ frame: Frame)
    func close()
    var isClosed: Bool { get }
    var onFrame: ((Frame) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
}

extension Connection: Channel {}

/// One connection to a host, many streams in it (§8): the frames said on
/// the connection itself are its control stream, as a connection's
/// always were; a stream is opened (by the client) for anything that
/// can go on alongside — a terminal, a forwarded port, a file on its
/// way — and carries frames of its own, framed inside `stream` frames.
///
/// Each stream has a window: no more than `window` bytes of it on the
/// way and not yet taken by the other end, which gives credit back as it
/// takes them. Interactive streams' frames go out as they're sent, in
/// order with the control stream's. Paced streams' (files, forwarded
/// ports, terminals — these first) go out only as the link takes them — no more of them in flight
/// at once than the link holds (its rate times its shortest round trip,
/// measured from the other end's `linkAck`s, twice over) — so what's
/// queued below us (ssh's window, the sockets' buffers) stays small and
/// a keystroke isn't left behind megabytes of a file.
///
/// It runs on its connection's queue. `open`, and a stream's or the
/// control channel's `send`, `close` and `consumed`, may be called from
/// any thread: they go to the queue, in the order made. A stream's (or
/// the control channel's) handlers run on its `callbackQueue` if it has
/// one, else on the queue; set them before its first `send`.
public final class Mux {
    public static let window = 1 << 20
    /// The most a bulk stream's frame carries, so frames interleave.
    public static let bulkPiece = 64 << 10

    public let connection: Connection
    public var queue: DispatchQueue { connection.queue }
    /// The queue's own mark, to know when we're on it.
    private let token: QueueToken
    private static let queueKey = DispatchSpecificKey<QueueToken>()
    private let lock = NSLock()
    /// The control stream: frames on the connection itself.
    public let control: ControlChannel
    /// A stream the other end opened (the server's side).
    public var onStream: ((MuxStream) -> Void)?

    private var streams: [UInt32: MuxStream] = [:]
    private var nextID: UInt32 = 1
    /// Bulk streams with frames waiting, in turn.
    private var ready: [MuxStream] = []

    /// Pacing (bulk): bytes sent, and acknowledged as received.
    private var bulkSent: UInt64 = 0
    private var bulkAcked: UInt64 = 0
    private var bulkReceived: UInt64 = 0
    /// Sends remembered until acknowledged: how far, when, and how much
    /// was acknowledged by then — a round trip, and a delivery rate.
    private var marks: [(sent: UInt64, size: Int, at: Date, acked: UInt64, ackedAt: Date)] = []
    private var lastAckAt = Date()
    /// The shortest round trip, and when it was seen. Measured while our
    /// own bytes are queued, a round trip is longer than the link's; so when
    /// the shortest is ten seconds old the paced streams stop until what's
    /// in flight has arrived (`probing`), and one piece sent into the empty
    /// queue measures it again (`probe`).
    private var minRTT: (rtt: TimeInterval, at: Date)?
    private var probing = false
    /// When probing began, or last saw an acknowledgment: one that waits
    /// longer than `probeWait` for the rest is given up, so the paced
    /// streams can't be stopped for good by anything that never comes.
    private var probingSince = Date()
    static let probeWait: TimeInterval = 5
    private var probe: UInt64?
    private var rates: [(at: Date, rate: Double)] = []
    public private(set) var budget = 256 << 10

    public init(_ connection: Connection) {
        self.connection = connection
        if let t = connection.queue.getSpecific(key: Self.queueKey) {
            token = t
        } else {
            token = QueueToken()
            connection.queue.setSpecific(key: Self.queueKey, value: token)
        }
        control = ControlChannel()
        control.mux = self
        connection.onFrame = { [weak self] frame in self?.received(frame) }
        connection.onClose = { [weak self] in self?.closed() }
        connection.onDrain = { [weak self] in self?.pumpBulk() }
    }

    /// Kept while its connection is open.
    private var keptAlive: Mux?

    public func start() {
        keptAlive = self
        connection.start()
    }

    /// On the queue: now if we're there, else as soon as it gets to it.
    func onQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) === token { work() } else { queue.async(execute: work) }
    }

    /// Now, on the queue (waiting for it if we're elsewhere).
    func onQueueNow<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) === token ? work() : queue.sync(execute: work)
    }

    /// A new stream (the client's side): `bulk` ones paced, `urgent` ones
    /// (a terminal's) paced too but ahead of the others; handlers run on
    /// `callbackQueue` (nil: the mux's queue).
    public func open(bulk: Bool, urgent: Bool = false, callbackQueue: DispatchQueue? = nil) -> MuxStream {
        lock.lock()
        let id = nextID
        nextID &+= 1
        lock.unlock()
        let s = MuxStream(id: id, bulk: bulk || urgent, urgent: urgent, mux: self)
        s.callbackQueue = callbackQueue
        onQueue { [self] in
            if connection.isClosed { return s.peerClosed() }
            streams[id] = s
            sendOp(id, .open, Data([urgent ? 2 : bulk ? 1 : 0]))
        }
        return s
    }

    /// Closes the connection (from anywhere).
    public func close() { onQueue { [connection] in connection.close() } }

    /// How the link stands (from anywhere): when bytes last came in and
    /// went out, and how many wait to go.
    public func linkState() -> (lastRead: Date, lastWrite: Date, pending: Int) {
        onQueueNow { (connection.lastRead, connection.lastWrite, connection.pending + ready.reduce(0) { $0 + $1.queued }) }
    }

    // MARK: The wire

    /// A paced stream's frames are `pacedFrame`s, acknowledged (`linkAck`)
    /// as they arrive whether or not their stream is still open here: one
    /// closed at this end while the other was sending on it still has
    /// what was on its way counted, or the sender's pacing would wait for
    /// it forever.
    enum Op: UInt8 { case open = 0, frame = 1, close = 2, credit = 3, pacedFrame = 4 }

    private func sendOp(_ id: UInt32, _ op: Op, _ rest: Data) {
        connection.send(Self.opFrame(id, op, rest))
    }

    static func opFrame(_ id: UInt32, _ op: Op, _ rest: Data) -> Frame {
        var p = Data(capacity: 5 + rest.count)
        withUnsafeBytes(of: id.bigEndian) { p.append(contentsOf: $0) }
        p.append(op.rawValue)
        p.append(rest)
        return Frame(.stream, p)
    }

    private func received(_ frame: Frame) {
        switch frame.kind {
        case .stream:
            let p = frame.payload
            guard p.count >= 5, let op = Op(rawValue: p[p.startIndex + 4]) else { return connection.close() }
            let id = p[p.startIndex..<p.startIndex + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let rest = p[(p.startIndex + 5)...]
            streamOp(id, op, Data(rest), wire: p.count + 5)
        case .linkAck:
            guard frame.payload.count == 8 else { return }
            acked(frame.payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        default:
            control.deliver(frame)
        }
    }

    private func streamOp(_ id: UInt32, _ op: Op, _ rest: Data, wire: Int) {
        switch op {
        case .open:
            guard streams[id] == nil else { return }
            let s = MuxStream(id: id, bulk: rest.first == 1 || rest.first == 2, urgent: rest.first == 2, mux: self)
            streams[id] = s
            onStream?(s)
        case .frame, .pacedFrame:
            // Received, whether or not it's taken yet (or its stream is
            // still here to take it): the link has it.
            if op == .pacedFrame {
                bulkReceived &+= UInt64(wire)
                var d = Data(capacity: 8)
                withUnsafeBytes(of: bulkReceived.bigEndian) { d.append(contentsOf: $0) }
                connection.send(Frame(.linkAck, d))
            }
            guard let s = streams[id] else { return }
            var decoder = FrameDecoder()
            decoder.append(rest)
            guard let inner = try? decoder.next() else { return connection.close() }
            s.delivered(inner, size: rest.count)
        case .credit:
            guard let s = streams[id], rest.count == 4 else { return }
            s.credited(Int(rest.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
        case .close:
            guard let s = streams.removeValue(forKey: id) else { return }
            s.peerClosed()
        }
    }

    private func closed() {
        defer { keptAlive = nil }
        let all = streams.values
        streams = [:]
        ready = []
        for s in all { s.peerClosed() }
        control.closed()
    }

    // MARK: Streams' sending

    /// An interactive stream's frames out now, as its window lets them;
    /// a bulk stream in line for the link.
    func pump(_ s: MuxStream) {
        if s.bulk {
            if !ready.contains(where: { $0 === s }) { ready.append(s) }
            if !pumping { pumpBulk() }
        } else {
            while let f = s.next() { sendOp(s.id, .frame, f) }
            s.drainedIfEmpty()
        }
    }

    /// Bulk frames out while the link takes them: the connection's own
    /// bytes nearly all written, and less in flight than the budget.
    private var pumping = false

    private func pumpBulk() {
        guard !pumping else { return }
        pumping = true
        let now = Date()
        if let m = minRTT, !probing, now.timeIntervalSince(m.at) > 10 {
            probing = true
            probingSince = now
        } else if probing, now.timeIntervalSince(probingSince) > Self.probeWait, let m = minRTT {
            // No measurement this time: the last one kept, for another ten seconds.
            probing = false
            probe = nil
            minRTT = (m.rtt, now)
        }
        while !ready.isEmpty, connection.pending < Self.bulkPiece, bulkSent - bulkAcked < UInt64(budget) {
            // Probing: nothing more until all that's out has arrived, then
            // one piece alone.
            if probing, probe != nil || bulkSent != bulkAcked { break }
            // An urgent stream (a terminal's) first, then the others in turn.
            let s = ready.remove(at: ready.firstIndex { $0.urgent } ?? 0)
            guard let f = s.next() else {
                s.drainedIfEmpty()
                continue
            }
            let frame = Self.opFrame(s.id, .pacedFrame, f)
            bulkSent &+= UInt64(frame.payload.count + 5)
            marks.append((bulkSent, frame.payload.count + 5, Date(), bulkAcked, lastAckAt))
            if probing { probe = bulkSent }
            connection.send(frame)
            // Its producer may send more now (onto its queue, not out).
            s.drainedIfEmpty()
            if s.hasNext, !ready.contains(where: { $0 === s }) { ready.append(s) }
        }
        pumping = false
    }

    /// The other end has received this much of the bulk streams' bytes:
    /// a round trip and a rate measured, the budget set from them.
    private func acked(_ total: UInt64) {
        guard total > bulkAcked else { return }
        let now = Date()
        bulkAcked = total
        let rate = rates.map(\.rate).max()
        if probing { probingSince = now }
        while let m = marks.first, m.sent <= total {
            marks.removeFirst()
            // Less the time the piece itself took to go out: on a slow link
            // that's most of it, and it isn't the link's round trip.
            let rtt = max(0.0005, now.timeIntervalSince(m.at) - (rate.map { Double(m.size) / $0 } ?? 0))
            if m.sent == probe {
                // Sent into an empty queue: the link's round trip, now.
                minRTT = (rtt, now)
                probe = nil
                probing = false
            } else if minRTT == nil || rtt <= minRTT!.rtt {
                minRTT = (rtt, now)
            }
            let span = now.timeIntervalSince(m.ackedAt)
            if span > 0.001 { rates.append((now, Double(total - m.acked) / span)) }
        }
        lastAckAt = now
        // The best rate of the last five seconds and the shortest round
        // trip: what the link is, apart from its queues.
        rates.removeAll { now.timeIntervalSince($0.at) > 5 }
        // What the link holds, and a half again; never less than a piece.
        if let rtt = minRTT?.rtt, let rate = rates.map(\.rate).max() {
            budget = min(32 << 20, max(Self.bulkPiece, Int(1.5 * rate * rtt)))
        }
        pumpBulk()
    }

    fileprivate func sendCredit(_ s: MuxStream, _ n: Int) {
        var d = Data(capacity: 4)
        withUnsafeBytes(of: UInt32(clamping: n).bigEndian) { d.append(contentsOf: $0) }
        sendOp(s.id, .credit, d)
    }

    fileprivate func sendClose(_ s: MuxStream) {
        streams.removeValue(forKey: s.id)
        ready.removeAll { $0 === s }
        sendOp(s.id, .close, Data())
    }

    /// Paced bytes sent and not yet acknowledged (from anywhere).
    var inFlight: UInt64 { onQueueNow { bulkSent - bulkAcked } }

    /// Debugging: the pacing's state (from anywhere).
    public var debugPacing: String { onQueueNow { pacing } }

    private var pacing: String {
        let rtt = minRTT.map { String(format: "%.1f ms", $0.rtt * 1000) } ?? "?"
        let rate = rates.map(\.rate).max().map { String(format: "%.0f KB/s", $0 / 1024) } ?? "?"
        return "budget \(budget >> 10) KB, in flight \((bulkSent - bulkAcked) >> 10) KB, rtt \(rtt), rate \(rate), streams \(streams.count)"
    }
}

final class QueueToken {}

/// The control stream: the connection's own frames.
public final class ControlChannel: Channel {
    fileprivate weak var mux: Mux?
    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?
    /// Where its handlers run (nil: the mux's queue).
    public var callbackQueue: DispatchQueue?
    public var isClosed: Bool { mux?.onQueueNow { mux?.connection.isClosed ?? true } ?? true }
    public func send(_ frame: Frame) { mux?.onQueue { [weak mux] in mux?.connection.send(frame) } }
    public func close() { mux?.close() }

    fileprivate func deliver(_ frame: Frame) {
        if let q = callbackQueue { q.async { [self] in onFrame?(frame) } } else { onFrame?(frame) }
    }

    fileprivate func closed() {
        let go = { [self] in
            let f = onClose
            onClose = nil
            onFrame = nil
            f?()
        }
        if let q = callbackQueue { q.async(execute: go) } else { go() }
    }
}

/// One stream of a `Mux`: frames, in order, both ways, as a connection's.
public final class MuxStream: Channel {
    public let id: UInt32
    /// Paced, as the link takes it (a file, a forwarded port, a terminal).
    public let bulk: Bool
    /// Paced, but ahead of the others (a terminal's).
    public let urgent: Bool
    /// How much may wait to go before a producer is told to hold off
    /// (`wantsMore`): a terminal's is small, so one that falls behind is
    /// caught up with its screen, not left to drain what it missed.
    public var highWater = Mux.window / 2
    private weak var mux: Mux?
    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?
    /// Told when what was sent has gone and the window is open again: a
    /// producer that waited (`wantsMore` false) goes on.
    public var onDrain: (() -> Void)?
    /// Where its handlers run (nil: the mux's queue).
    public var callbackQueue: DispatchQueue?
    /// Taken by the consumer as it chooses (`consumed`), not on delivery.
    public var manualCredit = false

    /// Read from anywhere, under the lock: how much waits to go, and
    /// whether it's done (closed, or closing).
    private let lock = NSLock()
    private var _queued = 0
    private var _closed = false
    private var _closing = false

    // On the mux's queue:
    /// What may be sent before the other end gives credit.
    private var window = Mux.window
    private var outbox: [Data] = []
    private var uncredited = 0

    init(id: UInt32, bulk: Bool, urgent: Bool = false, mux: Mux) {
        self.id = id
        self.bulk = bulk
        self.urgent = urgent
        self.mux = mux
    }

    public var isClosed: Bool { lock.withLock { _closed } }
    var queued: Int { lock.withLock { _queued } }

    /// Whether a producer should send more now: little waiting.
    public var wantsMore: Bool { lock.withLock { !_closed && !_closing && _queued < highWater } }

    public func send(_ frame: Frame) {
        let data = frame.encoded
        let ok: Bool = lock.withLock {
            guard !_closed, !_closing else { return false }
            _queued += data.count
            return true
        }
        guard ok, let mux else { return }
        mux.onQueue { [self] in
            outbox.append(data)
            self.mux?.pump(self)
        }
    }

    /// Closed once what was sent before has gone.
    public func close() {
        let first: Bool = lock.withLock {
            guard !_closed, !_closing else { return false }
            _closing = true
            return true
        }
        guard first else { return }
        mux?.onQueue { [self] in finishClose() }
    }

    /// Closed now, what's waiting dropped (a copy stopped): the other end
    /// told at once, not after the rest has gone.
    public func abort() {
        let first: Bool = lock.withLock {
            guard !_closed else { return false }
            _closed = true
            _queued = 0
            return true
        }
        guard first, let mux else { return }
        mux.onQueue { [self] in
            outbox = []
            self.mux?.sendClose(self)
            onCallbacks { [self] in
                let f = onClose
                onClose = nil
                onFrame = nil
                onDrain = nil
                f?()
            }
        }
    }

    /// The consumer took `n` bytes (with `manualCredit`): the other end may
    /// send as much again.
    public func consumed(_ n: Int) {
        mux?.onQueue { [self] in
            guard !isClosed else { return }
            uncredited += n
            // In batches, not a credit per frame.
            if uncredited >= Mux.window / 8 {
                mux?.sendCredit(self, uncredited)
                uncredited = 0
            }
        }
    }

    /// A frame goes while there's any window left (one bigger than the
    /// window still goes, alone).
    var hasNext: Bool { !outbox.isEmpty && window > 0 }

    /// The next frame, if the window lets it go.
    func next() -> Data? {
        guard hasNext else { return nil }
        let d = outbox.removeFirst()
        lock.withLock { _queued -= d.count }
        window -= d.count
        return d
    }

    private func onCallbacks(_ work: @escaping () -> Void) {
        if let q = callbackQueue { q.async(execute: work) } else { work() }
    }

    func drainedIfEmpty() {
        if lock.withLock({ _closing }) { return finishClose() }
        if wantsMore, onDrain != nil { onCallbacks { [self] in onDrain?() } }
    }

    private func finishClose() {
        guard outbox.isEmpty else { return }
        let first: Bool = lock.withLock {
            guard !_closed else { return false }
            _closed = true
            return true
        }
        guard first else { return }
        mux?.sendClose(self)
        onCallbacks { [self] in
            let f = onClose
            onClose = nil
            onFrame = nil
            onDrain = nil
            f?()
        }
    }

    func delivered(_ frame: Frame, size: Int) {
        if callbackQueue == nil {
            onFrame?(frame)
            if !manualCredit { consumed(size) }
        } else {
            onCallbacks { [self] in
                onFrame?(frame)
                // Taken once its handler has had it: a consumer slower than
                // the link holds the sender back, not its own memory.
                if !manualCredit { consumed(size) }
            }
        }
    }

    func credited(_ n: Int) {
        window += n
        mux?.pump(self)
    }

    func peerClosed() {
        let first: Bool = lock.withLock {
            guard !_closed else { return false }
            _closed = true
            _queued = 0
            return true
        }
        guard first else { return }
        outbox = []
        onCallbacks { [self] in
            let f = onClose
            onClose = nil
            onFrame = nil
            onDrain = nil
            f?()
        }
    }
}
