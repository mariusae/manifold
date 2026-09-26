import Foundation

/// The recent output of a terminal session, replayed into a terminal that
/// attaches to it so it shows what it showed before.
public struct ReplayBuffer: Sendable {
    public let limit: Int
    private var bytes = Data()
    /// Whether the session is on the alternate screen (a full-screen program
    /// like vim or less is running).
    public private(set) var altScreen = false
    private var trimmed = false
    private var tail = [UInt8]()

    public init(limit: Int = 4 << 20) {
        self.limit = limit
    }

    /// A buffer that starts with the output of an earlier session of the
    /// same pane, left in a state a new shell can carry on from.
    public init(limit: Int = 4 << 20, restoring history: Data) {
        self.limit = limit
        guard !history.isEmpty else { return }
        append(history)
        var tail = "\u{1b}[0m"
        if altScreen { tail += "\u{1b}[?1049l" }
        append(Data((tail + "\r\n").utf8))
    }

    /// The buffered output, for saving.
    public var contents: Data { bytes }

    public mutating func append(_ data: Data) {
        scanModes(data)
        bytes.append(data)
        if bytes.count > limit {
            // Cut at a line break, so the replay doesn't start in the middle
            // of an escape sequence.
            var cut = bytes.startIndex + bytes.count - limit * 3 / 4
            if let nl = bytes[cut...].firstIndex(of: 0x0A) { cut = nl + 1 }
            bytes.removeSubrange(bytes.startIndex..<cut)
            bytes = Data(bytes)
            trimmed = true
        }
    }

    /// What to send an attaching terminal.
    public var replay: Data {
        var out = Data()
        // Start from a clean terminal: the attaching one may already have
        // shown some of this.
        out.append(contentsOf: Array("\u{1b}[?1049l\u{1b}c".utf8))
        if trimmed && altScreen {
            // The switch to the alternate screen was trimmed away.
            out.append(contentsOf: Array("\u{1b}[?1049h".utf8))
        }
        out.append(bytes)
        return out
    }

    private static let modes: [(String, Bool)] = [
        ("\u{1b}[?1049h", true), ("\u{1b}[?1049l", false),
        ("\u{1b}[?1047h", true), ("\u{1b}[?1047l", false),
        ("\u{1b}[?47h", true), ("\u{1b}[?47l", false),
    ].map { ($0.0, $0.1) }

    private mutating func scanModes(_ data: Data) {
        // Include the end of the last chunk, for sequences split across two.
        let hay = tail + [UInt8](data)
        var last: (Int, Bool)?
        for (seq, on) in Self.modes {
            let needle = Array(seq.utf8)
            if let r = lastRange(of: needle, in: hay), r > (last?.0 ?? -1) {
                last = (r, on)
            }
        }
        if let last { altScreen = last.1 }
        tail = Array(hay.suffix(8))
    }

    private func lastRange(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }
}

/// Picks window titles (OSC 0 and OSC 2) out of a terminal's output.
public struct TitleScanner: Sendable {
    private enum State { case ground, esc, osc, oscEsc }
    private var state = State.ground
    private var osc = [UInt8]()

    public init() {}

    /// Feeds output; returns the last title set in it, if any.
    public mutating func feed(_ data: Data) -> String? {
        var title: String?
        for b in data {
            switch state {
            case .ground:
                if b == 0x1B { state = .esc }
            case .esc:
                if b == 0x5D { // ]
                    state = .osc
                    osc.removeAll(keepingCapacity: true)
                } else {
                    state = b == 0x1B ? .esc : .ground
                }
            case .osc:
                if b == 0x07 {
                    title = finish() ?? title
                    state = .ground
                } else if b == 0x1B {
                    state = .oscEsc
                } else if osc.count < 4096 {
                    osc.append(b)
                }
            case .oscEsc:
                if b == 0x5C { // ESC \ ends it
                    title = finish() ?? title
                    state = .ground
                } else {
                    // Anything else aborts the OSC and starts a new escape.
                    state = b == 0x5D ? .osc : .ground
                    osc.removeAll(keepingCapacity: true)
                }
            }
        }
        return title
    }

    private func finish() -> String? {
        guard let semi = osc.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: osc[..<semi], as: UTF8.self)
        guard code == "0" || code == "2" else { return nil }
        return String(decoding: osc[(semi + 1)...], as: UTF8.self)
    }
}
