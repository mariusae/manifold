import Foundation
import GhosttyKit
import ManifoldCore

/// A terminal's stream to its block's shell, on its host's one connection
/// (§8) — what `manifoldd attach` was, in a process of its own: Ghostty
/// runs no command and has no pty here (the shell's is on the host); what
/// the shell prints goes into the surface on the terminal's own queue, off
/// the main thread, and what's typed and the size go up the stream.
///
/// Attaching, or caught up after falling behind, it's sent the screen as it
/// is, at once; the history it hasn't got above that screen comes after on
/// a stream of its own, behind the terminal's (`Gap`), newest first, each
/// piece put into the scrollback above the rows it already has, the view
/// staying where it is.
final class TerminalLink {
    let block: BlockID
    private weak var client: HostClient?
    /// Where output goes into the surface.
    private let queue: DispatchQueue
    /// On `queue`: the surface output goes into (nil once it's freed).
    private var surface: ghostty_surface_t?

    /// Read from Ghostty's thread (typing, sizes) and the main thread.
    private let lock = NSLock()
    private var stream: MuxStream?
    /// The size: the last sent, or, before attaching, the one to attach at.
    private var size: (cols: UInt16, rows: UInt16) = (80, 24)
    private var attaching = false
    private var attached = false
    /// Attached once: what it shows is its own, kept when it resumes.
    private var everAttached = false
    /// Typing waits until the shell's recent output has been replayed (its
    /// queries answered by the terminal as it was, not typed now).
    private var acceptInput = false

    /// The stream closed: on the main thread, whether because the link
    /// went (true) or the shell ended (false).
    var onClosed: ((Bool) -> Void)?
    /// The first of the shell's output arrived (on the main thread): the
    /// terminal is reached.
    var onFirstOutput: (() -> Void)?
    /// On `queue`.
    private var sawOutput = false

    /// When a keystroke went up that no output has answered yet (under the
    /// lock: typed on Ghostty's thread, answered on `queue`).
    private var keySent: Date?
    /// How long keystrokes took to be answered, the last few (on `queue`).
    private var echoTimes: [TimeInterval] = []

    // On `queue`: the history.
    /// Where the host said its history had got to, as this terminal has it
    /// — all the rows before `end` (but the gaps' rows), at the width it
    /// had then.
    private var mark: HistoryMark?
    private var markCols: UInt16 = 0
    /// History rows not yet here, each to go in above its anchor.
    private var gaps: [Gap] = []

    /// History rows the host has that this terminal hasn't, and where in
    /// its scrollback they go: above `anchor` (a row Ghostty keeps track of
    /// as the scrollback grows below it and is trimmed above), rows `from`
    /// to `to`, at most `limit` more of them. Asked for on `stream`; what's
    /// still missing when that closes early is asked for again on the next
    /// attach, if the host's numbering is the same.
    private final class Gap {
        let epoch: UInt64
        var from: UInt64
        var to: UInt64
        var limit: UInt64
        let anchor: UnsafeMutableRawPointer
        var stream: MuxStream?

        init(epoch: UInt64, from: UInt64, to: UInt64, limit: UInt64, anchor: UnsafeMutableRawPointer) {
            self.epoch = epoch
            self.from = from
            self.to = to
            self.limit = limit
            self.anchor = anchor
        }
    }

    /// How much history a terminal attaching anew is sent; and, after a
    /// break, the most of what it missed.
    static let freshHistory: UInt64 = 5_000
    static let missedHistory: UInt64 = 10_000

    init(block: BlockID, client: HostClient?) {
        self.block = block
        self.client = client
        queue = DispatchQueue(label: "manifold.terminal.\(block.description)", qos: .userInteractive)
    }

    /// The surface made: output may go into it.
    func start(_ surface: ghostty_surface_t) {
        queue.async { self.surface = surface }
    }

    /// Before the surface is freed: nothing more goes into it, and the
    /// stream is closed (the session lives on in the host's server).
    func stop() {
        let s: MuxStream? = lock.withLock {
            defer { stream = nil }
            return stream
        }
        s?.close()
        queue.sync {
            dropGaps()
            surface = nil
        }
    }

    /// Whether the host's link is up, so a stream can be opened: its
    /// server has answered (and said what it can do: compressed streams).
    var linkUp: Bool { client?.mux != nil && client?.link == .connected }

    // MARK: From Ghostty (its own threads)

    /// The terminal's size, cells then pixels: the first attaches (a moment
    /// later, as the tile settles to its size), later ones go up.
    func resized(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        let send: MuxStream? = lock.withLock {
            let changed = size != (cols, rows)
            size = (cols, rows)
            if !attached, !attaching {
                attaching = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { self.attach() }
            }
            return attached && changed ? stream : nil
        }
        send?.send(.resize(cols: cols, rows: rows))
    }

    /// Typed (or the terminal's answer to a query): up to the shell.
    func typed(_ data: Data) {
        let s: MuxStream? = lock.withLock {
            guard acceptInput else { return nil }
            if keySent == nil { keySent = Date() }
            return stream
        }
        s?.send(Frame(.data, data))
    }

    /// How long a keystroke takes to be answered here now (the median of
    /// the last few), if any have been (on `queue`).
    var echoTime: TimeInterval? {
        guard !echoTimes.isEmpty else { return nil }
        return echoTimes.sorted()[echoTimes.count / 2]
    }

    /// Debugging: keystrokes' round trips, and the link's.
    var debugLatency: String {
        queue.sync {
            let ms = { (t: TimeInterval) in String(format: "%.0f", t * 1000) }
            let echo = echoTime.map { "echo \(ms($0)) ms (median of \(echoTimes.count); \(echoTimes.map(ms).joined(separator: " ")))" } ?? "echo: no keystrokes yet"
            return echo + " · " + (client?.mux?.debugPacing ?? "no link")
        }
    }

    // MARK: The stream

    /// The host's link is back: attached again, the terminal as it is —
    /// what it showed kept, caught up with the screen now.
    func resume() {
        let go: (Bool, resume: Bool) = lock.withLock {
            guard !attached, !attaching else { return (false, false) }
            attaching = true
            return (true, everAttached)
        }
        if go.0 { attach(resume: go.resume) }
    }

    private func attach(resume: Bool = false) {
        guard let mux = client?.mux, linkUp else {
            // No link yet (or its server hasn't answered): closed now, made
            // again once there is one.
            lock.withLock { attaching = false }
            onClosed?(true)
            return
        }
        // Paced, ahead of files: a flood of output doesn't fill the link.
        // Compressed (where the link and the host's server take it).
        let stream = mux.open(bulk: true, urgent: true, compress: true, callbackQueue: queue)
        stream.onFrame = { [weak self] frame in self?.received(frame) }
        stream.onClose = { [weak self, weak mux] in
            // Its connection closed with it: the link went, not the shell
            // (asked now: the client may not have let go of the link yet).
            let linkWent = mux?.connection.isClosed ?? true
            self?.lock.withLock {
                self?.stream = nil
                self?.attached = false
                self?.acceptInput = false
            }
            DispatchQueue.main.async { self?.onClosed?(linkWent) }
        }
        let size: (cols: UInt16, rows: UInt16) = lock.withLock {
            self.stream = stream
            attaching = false
            attached = true
            everAttached = true
            return self.size
        }
        stream.send(.message(ClientMessage.attach(AttachRequest(block: block, cols: size.cols, rows: size.rows, env: Self.environment, resume: resume))))
    }

    /// On `queue`.
    private func received(_ frame: Frame) {
        switch frame.kind {
        case .data:
            // Output after a keystroke: its round trip (or near enough —
            // output that would have come anyway is the odd short one).
            if let sent = lock.withLock({ () -> Date? in defer { keySent = nil }; return keySent }) {
                echoTimes.append(Date().timeIntervalSince(sent))
                if echoTimes.count > 20 { echoTimes.removeFirst() }
            }
            if !sawOutput {
                sawOutput = true
                DispatchQueue.main.async { [weak self] in self?.onFirstOutput?() }
            }
            guard let surface else { return }
            frame.payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(raw.count))
            }
        case .historyMark:
            if let m = HistoryMark(frame) { marked(m) }
        case .replayDone:
            // A replay no one has seen yet is live output (a shell just
            // started, its queries waiting for answers): typing goes through
            // at once. One seen before holds queries the terminal answers
            // again now; those answers aren't for the shell, so typing
            // waits a moment longer.
            if frame.payload.first == 1 {
                lock.withLock { acceptInput = true }
            } else {
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.lock.withLock { self?.acceptInput = true } }
            }
        default:
            break
        }
    }

    // MARK: The history (on `queue`)

    /// Where the host's history has got to. After output, it's where this
    /// terminal's own has: the same rows, numbered so. After a screen sent
    /// whole (`screen`), the rows between where it had got to and here
    /// are missing, just above that screen: asked for.
    private func marked(_ m: HistoryMark) {
        let cols = lock.withLock { size.cols }
        defer { mark = m; markCols = cols }
        // Numbered anew (the session made again, or reflowed to a new
        // width): what's on its way, and what it was to fill, is no more.
        if let old = mark, old.epoch != m.epoch { dropGaps(of: old.epoch) }
        guard m.screen, let surface else { return }
        let from: UInt64
        if let old = mark, old.epoch == m.epoch {
            from = old.end
        } else {
            // Reflowed while it was away (this terminal's width changed,
            // the host's rows rewrapped): which of them it has can't be
            // told, so its own go and the host's come instead. Otherwise
            // (a terminal new here, or a session started again) what it
            // has stays, the host's newest above the screen.
            if mark != nil, cols != markCols {
                let clear = "\u{1b}[3J"
                clear.withCString { ghostty_surface_process_output(surface, $0, UInt(strlen($0))) }
            }
            from = m.end > Self.freshHistory ? m.end - Self.freshHistory : 0
        }
        let limit = mark?.epoch == m.epoch ? Self.missedHistory : Self.freshHistory
        if m.end > from, let anchor = ghostty_surface_history_anchor(surface) {
            gaps.append(Gap(epoch: m.epoch, from: from, to: m.end, limit: limit, anchor: anchor))
        }
        // No more than `limit` rows on their way altogether (a flood falls
        // behind, and is caught up, again and again): the newest; older gaps
        // get what's left, or only the seam that says rows are missing —
        // asked for again if they were coming.
        var left = limit
        for gap in gaps.reversed() where gap.epoch == m.epoch {
            if gap.limit > left {
                gap.limit = left
                gap.stream?.abort()
                gap.stream = nil
            }
            left -= gap.limit
        }
        // The newest first; and those left from before, if the link went
        // while they came.
        for gap in gaps.reversed() where gap.epoch == m.epoch && gap.stream == nil { fill(gap) }
    }

    private func fill(_ gap: Gap) {
        guard let mux = client?.mux else { return }
        let stream = mux.open(bulk: true, compress: true, callbackQueue: queue)
        gap.stream = stream
        stream.onFrame = { [weak self, weak gap, weak stream] frame in
            // Not what an earlier asking (since given up) sends still.
            guard let self, let gap, let stream, gap.stream === stream else { return }
            switch frame.kind {
            case .data: self.filled(gap, frame.payload)
            case .replayDone: self.drop(gap)
            default: break
            }
        }
        stream.onClose = { [weak gap, weak stream] in
            if let gap, gap.stream === stream { gap.stream = nil }
        }
        stream.send(.message(ClientMessage.backfill(BackfillRequest(block: block, epoch: gap.epoch, from: gap.from, to: gap.to, limit: gap.limit))))
    }

    /// A piece of a gap's rows (the newest of what's missing): into the
    /// scrollback above the anchor, which moves to its first row.
    private func filled(_ gap: Gap, _ p: Data) {
        guard p.count >= 18, let surface, gaps.contains(where: { $0 === gap }) else { return }
        func u64(_ at: Int) -> UInt64 { p[p.startIndex + at..<p.startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        let lo = u64(0), hi = u64(8)
        let cols = UInt16(p[p.startIndex + 16]) << 8 | UInt16(p[p.startIndex + 17])
        let rows = p[(p.startIndex + 18)...]
        // Older gaps' anchors where this one's is (no rows between them)
        // go up with it, so their rows stay above these.
        let older: [UnsafeMutableRawPointer?] = gaps.prefix { $0 !== gap }.filter { $0.epoch == gap.epoch }.map(\.anchor)
        if !rows.isEmpty {
            rows.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                older.withUnsafeBufferPointer { o in
                    _ = ghostty_surface_history_insert(surface, gap.anchor, o.baseAddress, UInt(o.count), base.assumingMemoryBound(to: CChar.self), UInt(raw.count), cols)
                }
            }
        }
        gap.limit -= min(gap.limit, hi > lo ? hi - lo : 0)
        gap.to = min(gap.to, lo)
    }

    private func drop(_ gap: Gap) {
        guard let i = gaps.firstIndex(where: { $0 === gap }) else { return }
        gaps.remove(at: i)
        gap.stream?.abort()
        gap.stream = nil
        if let surface { ghostty_surface_history_release(surface, gap.anchor) }
    }

    /// The gaps (all, or those of another numbering): not filled.
    private func dropGaps(of epoch: UInt64? = nil) {
        for gap in gaps where epoch == nil || gap.epoch == epoch { drop(gap) }
    }

    /// Debugging: where the history stands — the host's mark as it has it,
    /// and what's still on its way.
    var debugHistory: String {
        queue.sync {
            let m = mark.map { "mark \($0.end) epoch \(String($0.epoch, radix: 16).prefix(6))" } ?? "no mark"
            return ([m] + gaps.map { "gap \($0.from)..<\($0.to) limit \($0.limit)\($0.stream == nil ? " waiting" : "")" }).joined(separator: "; ")
        }
    }

    /// What a shell started for a terminal here is told about it, as
    /// Ghostty would tell a shell it started: its type, its terminfo and
    /// shell integration (the server carries them over), the locale.
    static let environment: [String: String] = {
        var env: [String: String] = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_SHELL_FEATURES": "cursor:blink,path,title",
        ]
        if let res = Bundle.main.resourceURL {
            env["TERMINFO"] = res.appendingPathComponent("terminfo").path
            env["GHOSTTY_RESOURCES_DIR"] = res.appendingPathComponent("ghostty").path
        }
        if let bin = Bundle.main.executableURL?.deletingLastPathComponent() { env["GHOSTTY_BIN_DIR"] = bin.path }
        let ours = ProcessInfo.processInfo.environment
        for k in ["LANG", "LC_ALL", "LC_CTYPE"] { if let v = ours[k] { env[k] = v } }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }()
}
