import Foundation
import GhosttyKit
import ManifoldCore

/// Keystrokes' echo shown before the host's comes (mosh's local echo): on
/// a link slow enough to feel (an echo of 30 ms or more), what's typed on
/// the cursor's row is drawn at once over the screen — never put in the
/// terminal, which only the host's output changes — and taken away as the
/// host's echo comes and shows the same. Characters overwrite (a shell's
/// suggestion after the cursor then reads as it will), a backspace blanks
/// the cell before the cursor, ← moves it; backspace and ← only over what
/// was typed since predicting began on that row. Anything else typed (a
/// return, a tab, an escape, a paste) ends it until the screen has
/// answered.
///
/// Guesses are shown only once the host has echoed one as guessed since
/// the last miss (a password prompt, a program that takes keys for
/// commands, never shows any); a miss — the screen showing none of them
/// in time — takes them all away. A password the kernel reads (lines, no
/// echo: `TTYMode`) isn't guessed at all. On `TerminalLink`'s queue.
final class EchoPrediction {
    private let surface: ghostty_surface_t
    private let queue: DispatchQueue

    /// The row as guessed after each keystroke since the last the host
    /// showed (`guesses[0]`: as it showed), and the cursor's column then.
    private struct Guess {
        var line: [UInt32]
        var cursor: Int
        var at: Date
    }
    private var guesses: [Guess] = []
    /// The row guessed on, and the leftmost column typed at since.
    private var row = 0, start = 0
    /// One has been seen as guessed since the last miss: guesses show.
    private var confirmed = false
    /// Something unguessable was typed: none until the screen answers.
    private var paused = false
    /// What's shown now (cells, the cursor), so it's withdrawn once.
    private var shown = false
    private var deadlineCheck = false

    /// The overlay as last shown: its cells (columns of `row`) and whether
    /// they glow, for the view to draw their glow (on the main thread).
    var onShown: ((_ cells: [(x: Int, y: Int)], _ glow: Bool, _ info: ghostty_manifold_info_s) -> Void)?

    private var others: [String] = []
    // Tallies, for debugging.
    private(set) var shownCount = 0, confirmedCount = 0, missedCount = 0

    /// Shown from this echo time up, until it's below `off`; glowing from
    /// `glowFrom` (below it, they're the host's soon enough not to need it).
    static let on: TimeInterval = 0.030, off: TimeInterval = 0.020, glowFrom: TimeInterval = 0.080
    private var active = false

    /// The link is away: no guess is a miss for not being shown (nothing
    /// can be), and when it's back, their time starts again.
    var linkAway = false {
        didSet {
            guard !linkAway, oldValue else { return }
            for i in guesses.indices { guesses[i].at = Date() }
        }
    }

    init(surface: ghostty_surface_t, queue: DispatchQueue) {
        self.surface = surface
        self.queue = queue
    }

    // MARK: Keystrokes

    private enum Key {
        case char(UInt32)
        case backspace
        case left
        case other
        /// The terminal's answer to a query in the output (written as typing
        /// is): nothing typed at all.
        case answer
    }

    private static func key(_ data: Data) -> Key {
        if data == Data([0x7f]) || data == Data([0x08]) { return .backspace }
        guard let s = String(data: data, encoding: .utf8) else { return .other }
        if isAnswer(s) { return .answer }
        if s == "\u{1b}[D" || s == "\u{1b}OD" || s == "\u{1b}[1;1D" { return .left }
        // The kitty keyboard protocol's (fish asks for it): a key as its
        // code, unmodified — CSI 127 u is a backspace.
        if s.hasPrefix("\u{1b}["), s.hasSuffix("u") {
            let body = s.dropFirst(2).dropLast()
            let parts = body.split(separator: ";", omittingEmptySubsequences: false)
            guard let code = parts.first.flatMap({ UInt32($0) }), parts.count == 1 || parts.count == 2 && parts[1] == "1" else { return .other }
            if code == 127 || code == 8 { return .backspace }
            return char(code)
        }
        guard s.unicodeScalars.count == 1, let c = s.unicodeScalars.first else { return .other }
        return char(c.value)
    }

    /// What only a terminal says, answering: a string (OSC, DCS, APC — a
    /// color, a capability), or a CSI that's a report — private (? >), or
    /// device attributes (c), a status (n), the cursor's place (R), the
    /// window's (t), a mode's (y).
    private static func isAnswer(_ s: String) -> Bool {
        if s.hasPrefix("\u{1b}]") || s.hasPrefix("\u{1b}P") || s.hasPrefix("\u{1b}_") { return true }
        guard s.hasPrefix("\u{1b}["), let last = s.last else { return false }
        let body = s.dropFirst(2)
        if body.first == "?" || body.first == ">" { return true }
        return "cnRty".contains(last)
    }

    /// One cell wide, nothing joined to it: Latin, Greek, Cyrillic.
    private static func char(_ c: UInt32) -> Key {
        switch c {
        case 0x20...0x7e, 0xa0...0x2ff, 0x370...0x52f: return .char(c)
        default: return .other
        }
    }

    /// A keystroke (its bytes as sent), with the echo time and the pty's mode now.
    func typed(_ data: Data, echoTime: TimeInterval?, mode: TTYMode?) {
        if let e = echoTime { active = active ? e >= Self.off : e >= Self.on }
        // A password the kernel reads: never.
        if let mode, mode.contains(.canonical), !mode.contains(.echo) { return stop() }
        guard active else { return stop() }
        let key = Self.key(data)
        if case .answer = key { return }
        if case .other = key {
            others.append(data.map { $0 < 0x20 || $0 >= 0x7f ? String(format: "\\x%02x", $0) : String(UnicodeScalar($0)) }.joined())
            if others.count > 6 { others.removeFirst() }
            return stop(pause: true)
        }
        guard !paused else { return }
        var info = ghostty_manifold_info_s()
        ghostty_surface_manifold_info(surface, &info)
        // Scrolled up, or about to wrap: where it goes can't be told.
        guard info.flags & 2 != 0, info.flags & 8 == 0 else { return stop(pause: true) }
        let cols = Int(info.cols)
        if guesses.isEmpty || Int(info.cursor_y) != row {
            row = Int(info.cursor_y)
            start = Int(info.cursor_x)
            guesses = [Guess(line: line(row, cols), cursor: start, at: Date())]
        }
        var next = guesses[guesses.count - 1]
        switch key {
        case .char(let c):
            guard next.cursor < cols - 1 else { return stop(pause: true) }
            next.line[next.cursor] = c
            next.cursor += 1
        case .backspace:
            // The kernel's own lines echo a backspace as erasing only so set.
            if let mode, mode.contains(.canonical), !mode.contains(.echoErase) { return stop(pause: true) }
            guard next.cursor > start else { return stop(pause: true) }
            next.cursor -= 1
            next.line[next.cursor] = 0
        case .left:
            guard next.cursor > start else { return stop(pause: true) }
            next.cursor -= 1
        case .other, .answer:
            return
        }
        next.at = Date()
        guesses.append(next)
        show(echoTime: echoTime)
        scheduleDeadline(echoTime: echoTime)
    }

    // MARK: The host's output

    /// Output has gone into the terminal: guesses it shows confirmed, a
    /// miss once it's shown none of them in time.
    func output(echoTime: TimeInterval?) {
        paused = false
        judge(echoTime: echoTime)
    }

    private func judge(echoTime: TimeInterval?) {
        guard guesses.count > 1 else { return }
        var info = ghostty_manifold_info_s()
        ghostty_surface_manifold_info(surface, &info)
        guard Int(info.cursor_y) == row, info.flags & 2 != 0 else {
            // The row moved (output scrolled it, a return was echoed).
            return stop(missed: true)
        }
        let real = line(row, Int(info.cols))
        let cursor = Int(info.cursor_x)
        // The newest guess the screen shows: before the cursor (not what
        // follows it — a shell's suggestion, which it draws as it likes).
        if let j = guesses.indices.reversed().first(where: { matches(real, cursor, guesses[$0]) }) {
            if j > 0 {
                confirmedCount += j
                confirmed = true
                guesses.removeFirst(j)
            }
        } else if !linkAway, let first = guesses.dropFirst().first, Date().timeIntervalSince(first.at) > Self.deadline(echoTime) {
            return stop(missed: true)
        }
        if guesses.count == 1 { return withdraw() }
        show(echoTime: echoTime)
    }

    private func matches(_ real: [UInt32], _ cursor: Int, _ g: Guess) -> Bool {
        guard cursor == g.cursor, real.count == g.line.count else { return false }
        for x in start..<min(cursor, real.count) where !Self.same(real[x], g.line[x]) { return false }
        return true
    }

    private static func same(_ a: UInt32, _ b: UInt32) -> Bool {
        a == b || (a == 0 || a == 0x20) && (b == 0 || b == 0x20)
    }

    /// How long a guess may go unseen: a good deal longer than an echo
    /// takes, so one that's slow (behind a file) isn't taken for a miss.
    static func deadline(_ echoTime: TimeInterval?) -> TimeInterval { max(0.4, 2.5 * (echoTime ?? 0.2)) }

    /// Judged again once the oldest guess's time is up, output or not (a
    /// program that echoes nothing).
    private var echoTimeForDeadline: TimeInterval?
    private func scheduleDeadline(echoTime: TimeInterval?) {
        echoTimeForDeadline = echoTime
        guard !deadlineCheck else { return }
        deadlineCheck = true
        let after = Self.deadline(echoTime) + 0.05
        queue.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self else { return }
            deadlineCheck = false
            guard guesses.count > 1 else { return }
            judge(echoTime: echoTimeForDeadline)
            if guesses.count > 1 { scheduleDeadline(echoTime: echoTimeForDeadline) }
        }
    }

    // MARK: Showing

    private func show(echoTime: TimeInterval?) {
        guard confirmed, let g = guesses.last, guesses.count > 1 else { return withdraw() }
        var info = ghostty_manifold_info_s()
        ghostty_surface_manifold_info(surface, &info)
        let real = line(row, Int(info.cols))
        var cells: [ghostty_manifold_cell_s] = []
        for x in start..<g.line.count where !Self.same(real[x], g.line[x]) {
            cells.append(ghostty_manifold_cell_s(x: UInt16(x), y: UInt16(row), codepoint: g.line[x], source: -1, _pad: 0))
        }
        if cells.isEmpty, g.cursor == Int(info.cursor_x) { return withdraw() }
        cells.withUnsafeBufferPointer { ghostty_surface_manifold_predict(surface, $0.baseAddress, UInt($0.count), Int32(g.cursor), Int32(row)) }
        if !shown { shownCount += 1 }
        shown = true
        let glow = (echoTime ?? 0) >= Self.glowFrom
        let at = cells.map { (x: Int($0.x), y: Int($0.y)) }
        let onShown = onShown
        DispatchQueue.main.async { onShown?(at, glow, info) }
    }

    private func withdraw() {
        guard shown else { return }
        shown = false
        ghostty_surface_manifold_predict(surface, nil, 0, -1, -1)
        var info = ghostty_manifold_info_s()
        ghostty_surface_manifold_info(surface, &info)
        let onShown = onShown
        DispatchQueue.main.async { onShown?([], false, info) }
    }

    /// No guesses (what's shown taken away); a miss, or something
    /// unguessable typed: none shown until one is seen again, or (paused)
    /// until the screen has answered.
    func stop(missed: Bool = false, pause: Bool = false) {
        if missed, guesses.count > 1 { missedCount += 1 }
        if missed || pause { confirmed = false }
        if pause { paused = true }
        guesses = []
        withdraw()
    }

    private func line(_ y: Int, _ cols: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: cols)
        let n = out.withUnsafeMutableBufferPointer { ghostty_surface_manifold_row(surface, UInt16(y), $0.baseAddress, UInt($0.count)) }
        if n < cols { out.replaceSubrange(Int(n)..., with: repeatElement(0, count: cols - Int(n))) }
        return out
    }

    /// Debugging.
    var debugState: String {
        "\(active ? "on" : "off")\(confirmed ? ", confirmed" : "")\(paused ? ", paused" : ""), \(guesses.count - (guesses.isEmpty ? 0 : 1)) waiting; shown \(shownCount), confirmed \(confirmedCount), missed \(missedCount); others: \(others.joined(separator: " "))"
    }
}
