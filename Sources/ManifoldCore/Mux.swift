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
/// A stream opened `compress` (a terminal's, a file's — not a forwarded
/// port's, whose bytes are mostly compressed already, or encrypted, and
/// would tell by their size what they hold) goes compressed both ways when
/// the other end can take it (`compression`) and the link is slow enough
/// to gain: each frame of any size against those before it on the stream
/// (`Zstd.Encoder`), as a `zstdFrame`; its window counts the frames as
/// they were, its pacing the bytes that go.
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
    /// The least a piece is, however slow the link (`MuxStream.piece`).
    public static let leastPiece = 2 << 10

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
    public private(set) var budget = 16 << 10
    /// Round trips measured lately, for the queue they show (`acked`).
    private var recentRTTs: [(at: Date, rtt: TimeInterval)] = []
    /// The last pump stopped at the budget with frames waiting: the
    /// budget, not the senders, held them (it may grow only then).
    private var budgetLimited = false
    /// How long paced bytes wait in the link's queues now (last measured).
    private var queueDelay: TimeInterval = 0
    /// The queue aimed for: enough that the link is kept busy, little
    /// enough that a keystroke behind it is hardly slowed.
    static let queueTarget: TimeInterval = 0.015
    /// How much of itself the budget may grow, or shrink, in a round trip
    /// at most (the queue far under the target, or over it): gently, so a
    /// round trip that's long by chance (a hiccup on the way) doesn't empty
    /// the link.
    static let growGain = 0.5, shrinkGain = 0.25
    /// Debugging: the pacing logged once a second while it's acknowledged
    /// (MANIFOLD_DEBUG_PACING set).
    static let logPacing = ProcessInfo.processInfo.environment["MANIFOLD_DEBUG_PACING"] != nil
    /// Where that goes (the server's log, there).
    public static var log: (String) -> Void = { NSLog("%@", $0) }
    private var lastPacingLog = Date.distantPast

    /// Whether the other end takes streams compressed (its server said so,
    /// and it isn't this machine): set by the client once it's heard.
    public var compression: Bool {
        get { lock.withLock { _compression } }
        set { lock.withLock { _compression = newValue } }
    }
    private var _compression = false

    /// Frames compressed as they went, in all, and what they came to (on
    /// the queue).
    fileprivate var compressedFrom = 0, compressedTo = 0
    /// Compressed frames received, and what they came to.
    private var inflatedFrom = 0, inflatedTo = 0

    /// What the link is given to hold (the budget, steered by the queue it
    /// shows): read from anywhere.
    public var linkHolds: Int { lock.withLock { _linkHolds } }
    private var _linkHolds = 16 << 10

    /// A frame of a terminal's this small (a keystroke, its echo) goes as
    /// soon as it's its turn, ahead of the pacing.
    static let smallFrame = 1 << 10

    /// Faster than this, a link isn't worth compressing for.
    static var compressBelow = Double(32 << 20)

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
    /// (a terminal's) paced too but ahead of the others; `compress` ones
    /// compressed, if the other end takes it; handlers run on
    /// `callbackQueue` (nil: the mux's queue).
    public func open(bulk: Bool, urgent: Bool = false, compress: Bool = false, callbackQueue: DispatchQueue? = nil) -> MuxStream {
        lock.lock()
        let id = nextID
        nextID &+= 1
        let compress = compress && _compression
        lock.unlock()
        let s = MuxStream(id: id, bulk: bulk || urgent, urgent: urgent, compresses: compress, mux: self)
        s.callbackQueue = callbackQueue
        onQueue { [self] in
            if connection.isClosed { return s.peerClosed() }
            streams[id] = s
            // Its kind, then (to a server that knows) its flags.
            var open = Data([urgent ? 2 : bulk ? 1 : 0])
            if compress { open.append(1) }
            sendOp(id, .open, open)
        }
        return s
    }

    /// Whether the link is slow enough that compressing gains (on the queue).
    var worthCompressing: Bool { (rates.map(\.rate).max() ?? 0) < Self.compressBelow }

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
    enum Op: UInt8 { case open = 0, frame = 1, close = 2, credit = 3, pacedFrame = 4, zstdFrame = 5, zstdPacedFrame = 6 }

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
            let flags = rest.count > 1 ? rest[rest.startIndex + 1] : 0
            let s = MuxStream(id: id, bulk: rest.first == 1 || rest.first == 2, urgent: rest.first == 2, compresses: flags & 1 != 0, mux: self)
            streams[id] = s
            onStream?(s)
        case .frame, .pacedFrame, .zstdFrame, .zstdPacedFrame:
            // Received, whether or not it's taken yet (or its stream is
            // still here to take it): the link has it.
            if op == .pacedFrame || op == .zstdPacedFrame {
                bulkReceived &+= UInt64(wire)
                var d = Data(capacity: 8)
                withUnsafeBytes(of: bulkReceived.bigEndian) { d.append(contentsOf: $0) }
                connection.send(Frame(.linkAck, d))
            }
            guard let s = streams[id] else { return }
            var bytes = rest
            if op == .zstdFrame || op == .zstdPacedFrame {
                // Out of turn, or not what its encoder made: the
                // connection can't be trusted to go on.
                guard let d = s.inflate(rest) else { return connection.close() }
                inflatedFrom += rest.count
                inflatedTo += d.count
                // The end of its compressed frames, holding none.
                if d.isEmpty { return }
                bytes = d
            }
            var decoder = FrameDecoder()
            decoder.append(bytes)
            guard let inner = try? decoder.next() else { return connection.close() }
            s.delivered(inner, size: bytes.count)
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
            while let f = s.next() { sendOp(s.id, f.zstd ? .zstdFrame : .frame, f.bytes) }
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
        // A terminal's small frames (a keystroke, its echo), in their turn on
        // their stream, go now: not held for a probe or the budget, which
        // they'd hardly add to — a key isn't left waiting a round trip.
        for s in ready where s.urgent {
            while let size = s.nextSize, size <= Self.smallFrame, let f = s.next() { sendPaced(s, f) }
            s.drainedIfEmpty()
        }
        ready.removeAll { $0.urgent && !$0.hasNext }
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
            sendPaced(s, f)
            if probing { probe = bulkSent }
            // Its producer may send more now (onto its queue, not out).
            s.drainedIfEmpty()
            if s.hasNext, !ready.contains(where: { $0 === s }) { ready.append(s) }
        }
        budgetLimited = !ready.isEmpty && bulkSent - bulkAcked >= UInt64(budget)
        pumping = false
    }

    /// A paced frame out, counted for the pacing.
    private func sendPaced(_ s: MuxStream, _ f: (bytes: Data, zstd: Bool)) {
        let frame = Self.opFrame(s.id, f.zstd ? .zstdPacedFrame : .pacedFrame, f.bytes)
        bulkSent &+= UInt64(frame.payload.count + 5)
        marks.append((bulkSent, frame.payload.count + 5, Date(), bulkAcked, lastAckAt))
        connection.send(frame)
    }

    /// The other end has received this much of the bulk streams' bytes:
    /// a round trip and a rate measured, the budget set from them.
    private func acked(_ total: UInt64) {
        guard total > bulkAcked else { return }
        let now = Date()
        let newly = total - bulkAcked
        bulkAcked = total
        if probing { probingSince = now }
        while let m = marks.first, m.sent <= total {
            marks.removeFirst()
            // As it was: pieces are small enough (a part of what the link
            // holds) that the time one takes to go out hardly counts — and
            // taken off with a rate measured low, it would make the round
            // trip look shorter than it is, and every queue too long.
            let rtt = max(0.0005, now.timeIntervalSince(m.at))
            if m.sent == probe {
                // Sent into an empty queue: the link's round trip, now.
                minRTT = (rtt, now)
                probe = nil
                probing = false
            } else if minRTT == nil || rtt <= minRTT!.rtt {
                minRTT = (rtt, now)
            }
            recentRTTs.append((now, rtt))
            let span = now.timeIntervalSince(m.ackedAt)
            if span > 0.001 { rates.append((now, Double(total - m.acked) / span)) }
        }
        lastAckAt = now
        // The best rate of the last five seconds and the shortest round
        // trip: what the link is, apart from its queues.
        rates.removeAll { now.timeIntervalSince($0.at) > 5 }
        // The budget steered by the queue the round trips show (the least
        // of the last one's, less the shortest there's been): grown while
        // it's under the target and the budget is what holds frames back,
        // shrunk while it's over, in proportion — as LEDBAT does. It follows
        // a link that slows (Wi-Fi, other traffic) within round trips, where
        // a rate measured over seconds would leave a queue for seconds.
        if let base = minRTT?.rtt {
            recentRTTs.removeAll { now.timeIntervalSince($0.at) > max(0.05, base) }
            if let current = recentRTTs.map(\.rtt).min() {
                queueDelay = max(0, current - base)
                let target = max(Self.queueTarget, 0.2 * base)
                let off = max(-1, min(1, (target - queueDelay) / target))
                // Of what's acknowledged now: a round trip's acknowledgments
                // come to the budget, so this is that much of it a round trip.
                let gain = off > 0 ? Self.growGain : Self.shrinkGain
                if off < 0 || budgetLimited { budget += Int(gain * off * Double(newly)) }
            }
            // Never less than two of the least pieces, so one always goes. Not
            // capped by the rate measured: while the budget is what holds
            // frames back, that's only the budget over the round trip, and
            // would keep it where it is.
            budget = max(2 * Self.leastPiece, min(budget, 32 << 20))
            let given = budget
            lock.withLock { _linkHolds = given }
        }
        if Self.logPacing, now.timeIntervalSince(lastPacingLog) >= 1 {
            lastPacingLog = now
            Self.log("pacing: " + pacing)
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
    /// Paced bytes sent, in all (from anywhere).
    var pacedSent: UInt64 { onQueueNow { bulkSent } }

    /// How the link stands, as the pacing sees it (from anywhere).
    public struct LinkStats: Sendable {
        /// Its shortest round trip, and its best rate lately (bytes a second).
        public var roundTrip: TimeInterval?
        public var rate: Double?
        /// How long what's sent waits in queues on the way now.
        public var queueDelay: TimeInterval
        /// How much may be on its way at once, and how much is.
        public var budget: Int
        public var inFlight: Int
        /// Compressed streams' bytes: sent (as they were, as they went) and
        /// received (as they came, as they were).
        public var sent: (raw: Int, wire: Int)
        public var received: (wire: Int, raw: Int)
        public var streams: Int
    }

    public var stats: LinkStats {
        onQueueNow {
            LinkStats(roundTrip: minRTT?.rtt, rate: rates.map(\.rate).max(), queueDelay: queueDelay, budget: budget,
                      inFlight: Int(bulkSent - bulkAcked), sent: (compressedFrom, compressedTo), received: (inflatedFrom, inflatedTo),
                      streams: streams.count)
        }
    }

    /// Debugging: the pacing's state (from anywhere).
    public var debugPacing: String { onQueueNow { pacing } }

    private var pacing: String {
        let rtt = minRTT.map { String(format: "%.1f ms", $0.rtt * 1000) } ?? "?"
        let rate = rates.map(\.rate).max().map { String(format: "%.0f KB/s", $0 / 1024) } ?? "?"
        let zstd = (compressedFrom == 0 ? "" : ", sent compressed \(compressedFrom >> 10) → \(compressedTo >> 10) KB")
            + (inflatedFrom == 0 ? "" : ", received compressed \(inflatedFrom >> 10) → \(inflatedTo >> 10) KB")
        let queue = String(format: "%.0f ms", queueDelay * 1000)
        return "budget \(budget >> 10) KB, in flight \((bulkSent - bulkAcked) >> 10) KB, rtt \(rtt), queue \(queue), rate \(rate), streams \(streams.count)\(zstd)"
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
    /// When the frame being handled now came off the link (set before its
    /// handler runs): a pong's round trip without the wait for the handler's
    /// queue, which may be busy.
    public private(set) var arrived = Date()
    public var isClosed: Bool { mux?.onQueueNow { mux?.connection.isClosed ?? true } ?? true }
    public func send(_ frame: Frame) { mux?.onQueue { [weak mux] in mux?.connection.send(frame) } }
    public func close() { mux?.close() }

    fileprivate func deliver(_ frame: Frame) {
        let at = Date()
        if let q = callbackQueue {
            q.async { [self] in
                arrived = at
                onFrame?(frame)
            }
        } else {
            arrived = at
            onFrame?(frame)
        }
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
    /// Its frames go compressed (both ends agreed when it opened).
    public let compresses: Bool
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
    /// Frames to go: their bytes (compressed, or as they are) and their
    /// size as they are, which the window counts.
    private var outbox: [(bytes: Data, zstd: Bool, size: Int)] = []
    private var uncredited = 0
    /// Compressing what it sends, and what it was sent (made when a frame
    /// is, let go after a while with none).
    private var deflater: Zstd.Encoder?
    private var inflater: Zstd.Decoder?
    private var lastDeflated = Date.distantPast
    /// `close` taken on the queue, after what was sent before it.
    private var closeTaken = false
    private var idleCheck = false
    /// What it sends doesn't get smaller (it was compressed already): sent
    /// as it is from then on.
    private var incompressible = false

    /// A frame smaller than this goes as it is (a keystroke, its echo).
    static let compressFrom = 64
    /// A stream's compressing let go of after this long without a frame.
    static var compressIdle: TimeInterval = 10

    init(id: UInt32, bulk: Bool, urgent: Bool = false, compresses: Bool = false, mux: Mux) {
        self.id = id
        self.bulk = bulk
        self.urgent = urgent
        self.compresses = compresses
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
            // Compressed here, on the queue, so in the order frames go out.
            let out = deflate(data)
            if out.bytes.count != data.count { lock.withLock { _queued += out.bytes.count - data.count } }
            outbox.append((out.bytes, out.zstd, data.count))
            // Given up on (it doesn't get smaller): its frames ended, after this one.
            if incompressible { endDeflating() }
            self.mux?.pump(self)
        }
    }

    /// A frame to go, compressed if this stream is and it gains (on the
    /// queue).
    private func deflate(_ data: Data) -> (bytes: Data, zstd: Bool) {
        guard compresses, !incompressible, data.count >= Self.compressFrom, mux?.worthCompressing == true else { return (data, false) }
        guard let enc = deflater ?? Zstd.Encoder() else { return (data, false) }
        guard let packed = enc.compress(data) else {
            // zstd failed: its frames can't go on; the rest as they are.
            incompressible = true
            deflater = nil
            return (data, false)
        }
        deflater = enc
        lastDeflated = Date()
        mux?.compressedFrom += data.count
        mux?.compressedTo += packed.count
        // A good deal of it, and no smaller (an image, an archive): ended,
        // and not tried again.
        if enc.taken >= 256 << 10, enc.made * 10 > enc.taken * 9 {
            incompressible = true
        } else if !idleCheck {
            idleCheck = true
            checkIdle(after: Self.compressIdle)
        }
        return (packed, true)
    }

    /// Its compressing let go of when it's been idle: ended (the other end
    /// lets go of its own), made again for the next frame.
    private func checkIdle(after delay: TimeInterval) {
        mux?.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, deflater != nil, !isClosed else {
                self?.idleCheck = false
                return
            }
            let idle = Date().timeIntervalSince(lastDeflated)
            if idle < Self.compressIdle { return checkIdle(after: Self.compressIdle - idle) }
            idleCheck = false
            endDeflating()
            mux?.pump(self)
        }
    }

    /// The encoder's frames ended, the end sent after what's waiting; it's
    /// let go of (on the queue).
    private func endDeflating() {
        guard let enc = deflater else { return }
        deflater = nil
        guard let end = enc.end() else { return }
        lock.withLock { _queued += end.count }
        outbox.append((end, true, 0))
    }

    /// Whether it holds an encoder, a decoder now (debugging, tests).
    var compressing: (deflater: Bool, inflater: Bool) { mux?.onQueueNow { (deflater != nil, inflater != nil) } ?? (false, false) }

    /// A compressed frame received made again (on the queue); nil if it
    /// can't be. Its decoder let go of once its encoder's frames end.
    func inflate(_ data: Data) -> Data? {
        guard let dec = inflater ?? Zstd.Decoder() else { return nil }
        guard let d = dec.decompress(data) else { return nil }
        inflater = dec.finished ? nil : dec
        return d
    }

    /// Closed once what was sent before has gone.
    public func close() {
        let first: Bool = lock.withLock {
            guard !_closed, !_closing else { return false }
            _closing = true
            return true
        }
        guard first else { return }
        mux?.onQueue { [self] in
            closeTaken = true
            finishClose()
        }
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
    /// The size of the frame that goes next, if one can.
    var nextSize: Int? { hasNext ? outbox[0].bytes.count : nil }

    /// What its link holds (its rate times its round trip): how much of a
    /// terminal's output may wait to go before it's behind.
    public var linkHolds: Int { mux?.linkHolds ?? Mux.bulkPiece }

    /// How much a frame of bulk data should carry on this link: half what
    /// it's given to hold, between the least and a full piece — a file's
    /// 64 KB pieces on a slow link would sit in front of everything else (a
    /// keystroke's echo) for half a second.
    public var piece: Int { min(Mux.bulkPiece, max(Mux.leastPiece, linkHolds / 2)) }

    /// `data` sent as frames of `kind`, each no more than a piece.
    public func sendPieces(_ data: Data, kind: FrameKind = .data) {
        let piece = self.piece
        guard data.count > piece else { return send(Frame(kind, data)) }
        var at = data.startIndex
        while at < data.endIndex {
            let end = min(data.endIndex, at + piece)
            send(Frame(kind, data.subdata(in: at..<end)))
            at = end
        }
    }

    /// The next frame, if the window lets it go.
    func next() -> (bytes: Data, zstd: Bool)? {
        guard hasNext else { return nil }
        let d = outbox.removeFirst()
        lock.withLock { _queued -= d.bytes.count }
        window -= d.size
        return (d.bytes, d.zstd)
    }

    private func onCallbacks(_ work: @escaping () -> Void) {
        if let q = callbackQueue { q.async(execute: work) } else { work() }
    }

    func drainedIfEmpty() {
        // Closing once the close has been taken in turn: not as soon as it's
        // asked for (from another thread), when frames sent before it may
        // still be on their way to the queue — they'd be dropped.
        if closeTaken { return finishClose() }
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
