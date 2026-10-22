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
/// order with the control stream's. Bulk streams' (files, forwarded
/// ports) go out only as the link takes them — no more of them in flight
/// at once than the link holds (its rate times its shortest round trip,
/// measured from the other end's `linkAck`s, twice over) — so what's
/// queued below us (ssh's window, the sockets' buffers) stays small and
/// a keystroke isn't left behind megabytes of a file.
///
/// All of it on the connection's queue.
public final class Mux {
    public static let window = 1 << 20
    /// The most a bulk stream's frame carries, so frames interleave.
    public static let bulkPiece = 64 << 10

    public let connection: Connection
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
    private var probe: UInt64?
    private var rates: [(at: Date, rate: Double)] = []
    public private(set) var budget = 256 << 10

    public init(_ connection: Connection) {
        self.connection = connection
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

    /// A new stream (the client's side): `bulk` ones paced.
    public func open(bulk: Bool) -> MuxStream {
        let id = nextID
        nextID &+= 1
        let s = MuxStream(id: id, bulk: bulk, mux: self)
        if connection.isClosed {
            s.peerClosed()
            return s
        }
        streams[id] = s
        sendOp(id, .open, Data([bulk ? 1 : 0]))
        return s
    }

    /// Bytes waiting to be written, every stream's.
    public var pending: Int { connection.pending + ready.reduce(0) { $0 + $1.queued } }

    // MARK: The wire

    enum Op: UInt8 { case open = 0, frame = 1, close = 2, credit = 3 }

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
            control.onFrame?(frame)
        }
    }

    private func streamOp(_ id: UInt32, _ op: Op, _ rest: Data, wire: Int) {
        switch op {
        case .open:
            guard streams[id] == nil else { return }
            let s = MuxStream(id: id, bulk: rest.first == 1, mux: self)
            streams[id] = s
            onStream?(s)
        case .frame:
            guard let s = streams[id] else { return }
            // Received, whether or not it's taken yet: the link has it.
            if s.bulk {
                bulkReceived &+= UInt64(wire)
                var d = Data(capacity: 8)
                withUnsafeBytes(of: bulkReceived.bigEndian) { d.append(contentsOf: $0) }
                connection.send(Frame(.linkAck, d))
            }
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
        if let m = minRTT, !probing, Date().timeIntervalSince(m.at) > 10 { probing = true }
        while !ready.isEmpty, connection.pending < Self.bulkPiece, bulkSent - bulkAcked < UInt64(budget) {
            // Probing: nothing more until all that's out has arrived, then
            // one piece alone.
            if probing, probe != nil || bulkSent != bulkAcked { break }
            let s = ready.removeFirst()
            guard let f = s.next() else {
                s.drainedIfEmpty()
                continue
            }
            let frame = Self.opFrame(s.id, .frame, f)
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

    /// Debugging: the pacing's state.
    public var debugPacing: String {
        let rtt = minRTT.map { String(format: "%.1f ms", $0.rtt * 1000) } ?? "?"
        let rate = rates.map(\.rate).max().map { String(format: "%.0f KB/s", $0 / 1024) } ?? "?"
        return "budget \(budget >> 10) KB, in flight \((bulkSent - bulkAcked) >> 10) KB, rtt \(rtt), rate \(rate), streams \(streams.count)"
    }
}

/// The control stream: the connection's own frames.
public final class ControlChannel: Channel {
    fileprivate weak var mux: Mux?
    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?
    public var isClosed: Bool { mux?.connection.isClosed ?? true }
    public func send(_ frame: Frame) { mux?.connection.send(frame) }
    public func close() { mux?.connection.close() }

    fileprivate func closed() {
        let f = onClose
        onClose = nil
        onFrame = nil
        f?()
    }
}

/// One stream of a `Mux`: frames, in order, both ways, as a connection's.
public final class MuxStream: Channel {
    public let id: UInt32
    /// Paced, as the link takes it (a file, a forwarded port).
    public let bulk: Bool
    private weak var mux: Mux?
    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?
    /// Told when what was sent has gone and the window is open again: a
    /// producer that waited (`wantsMore` false) goes on.
    public var onDrain: (() -> Void)?
    public private(set) var isClosed = false

    /// What may be sent before the other end gives credit.
    private var window = Mux.window
    private var outbox: [Data] = []
    private(set) var queued = 0
    private var closing = false
    /// Taken by the consumer as it chooses (`consumed`), not on delivery.
    public var manualCredit = false
    private var uncredited = 0

    init(id: UInt32, bulk: Bool, mux: Mux) {
        self.id = id
        self.bulk = bulk
        self.mux = mux
    }

    /// Whether a producer should send more now: little waiting.
    public var wantsMore: Bool { !isClosed && queued < Mux.window / 2 }

    public func send(_ frame: Frame) {
        guard !isClosed, !closing else { return }
        let data = frame.encoded
        outbox.append(data)
        queued += data.count
        mux?.pump(self)
    }

    /// Closed once what was sent before has gone.
    public func close() {
        guard !isClosed, !closing else { return }
        closing = true
        finishClose()
    }

    /// The consumer took `n` bytes (with `manualCredit`): the other end may
    /// send as much again.
    public func consumed(_ n: Int) {
        guard !isClosed else { return }
        uncredited += n
        // In batches, not a credit per frame.
        if uncredited >= Mux.window / 8 {
            mux?.sendCredit(self, uncredited)
            uncredited = 0
        }
    }

    /// A frame goes while there's any window left (one bigger than the
    /// window still goes, alone).
    var hasNext: Bool { !outbox.isEmpty && window > 0 }

    /// The next frame, if the window lets it go.
    func next() -> Data? {
        guard hasNext else { return nil }
        let d = outbox.removeFirst()
        queued -= d.count
        window -= d.count
        return d
    }

    func drainedIfEmpty() {
        if closing { return finishClose() }
        if wantsMore { onDrain?() }
    }

    private func finishClose() {
        guard outbox.isEmpty, !isClosed else { return }
        isClosed = true
        mux?.sendClose(self)
        let f = onClose
        onClose = nil
        onFrame = nil
        onDrain = nil
        f?()
    }

    func delivered(_ frame: Frame, size: Int) {
        onFrame?(frame)
        if !manualCredit { consumed(size) }
    }

    func credited(_ n: Int) {
        window += n
        mux?.pump(self)
    }

    func peerClosed() {
        guard !isClosed else { return }
        isClosed = true
        outbox = []
        queued = 0
        let f = onClose
        onClose = nil
        onFrame = nil
        onDrain = nil
        f?()
    }
}
