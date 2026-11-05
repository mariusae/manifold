import Foundation
import ManifoldCore
import Network

/// A connection made on this Mac and a stream of a host's connection,
/// joined (§8): what's sent here goes up the stream while it wants more,
/// and what comes down is written here, credited once it's taken — so a
/// fast side and a slow one fill nothing but themselves. A side done
/// sending says so (an empty frame up the stream; the connection's
/// sending side ended here), and the other's answer still comes until it
/// closes. On the main thread, where the stream's and the connection's
/// handlers are.
final class StreamPipe {
    private let connection: NWConnection
    private let stream: MuxStream
    /// Closed, from either side or by `cancel`.
    var onEnd: (() -> Void)?
    private var reading = false
    /// This side is done sending: not read again.
    private var finished = false
    private var ended = false

    /// `stream` is taken with `manualCredit` and its handlers on the main
    /// queue; `connection` is started.
    init(_ connection: NWConnection, _ stream: MuxStream) {
        self.connection = connection
        self.stream = stream
    }

    func start() {
        // The host's bytes on to the connection here, credited once taken.
        let c = connection
        stream.onFrame = { [weak stream] frame in
            guard frame.kind == .data else { return }
            let n = frame.payload.count + 5
            c.send(content: frame.payload, completion: .contentProcessed { [weak stream] error in
                if error == nil { stream?.consumed(n) }
            })
        }
        // Closed there (its server closed, nothing listening, the link
        // gone): closed here, after what came.
        stream.onClose = { [weak self] in
            guard let self, !self.ended else { return }
            self.ended = true
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            self.onEnd?()
        }
        stream.onDrain = { [weak self] in self?.pump() }
        pump()
    }

    /// Both sides closed now (the link went).
    func cancel() {
        guard !ended else { return }
        ended = true
        connection.cancel()
        stream.close()
        onEnd?()
    }

    /// What's sent here, up the stream while it wants more.
    private func pump() {
        guard !ended, !finished, !reading, stream.wantsMore else { return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: stream.piece) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.reading = false
            guard !self.ended else { return }
            if let data, !data.isEmpty { self.stream.send(Frame(.data, data)) }
            if error != nil { return self.cancel() }
            // Done sending, here: said so, and the host's answer still
            // comes back until it closes its side.
            if complete {
                self.finished = true
                return self.stream.send(Frame(.data, Data()))
            }
            self.pump()
        }
    }
}
