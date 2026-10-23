import CManifoldVT
import Foundation
import ManifoldCore

/// A shell's terminal as the host keeps it (§8): Ghostty's emulator, the
/// one the app draws with, fed everything the shell prints and sized with
/// its pty. A terminal attaching is sent its screen — escape sequences that
/// make the same screen, modes and cursor in a fresh terminal — not the
/// output that made it; so is one that fell behind, in place of all it
/// missed. The history above that screen goes after, at a lower priority
/// (`history(from:to:)`): its rows are numbered from the first ever to
/// scroll off (`historyEnd`), so the app can say how far it has them.
final class TerminalScreen {
    private let terminal: OpaquePointer
    /// This terminal's numbering of its history rows: another terminal's
    /// (the session's made again) or the same one's reflowed to a new
    /// width (its rows joined and split anew) count differently.
    private(set) var epoch = UInt64.random(in: 1...UInt64.max)
    /// Its width: what its history is drawn at.
    private(set) var width: UInt16
    /// History kept, as the app's terminals keep theirs (Ghostty's default).
    static let scrollback = 10_000_000

    init?(cols: UInt16, rows: UInt16) {
        guard let t = mvt_new(cols, rows, Self.scrollback) else { return nil }
        terminal = t
        width = cols
    }

    deinit { mvt_free(terminal) }

    func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            mvt_feed(terminal, base, raw.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        mvt_resize(terminal, cols, rows)
        if cols != width { epoch = UInt64.random(in: 1...UInt64.max) }
        width = cols
    }

    /// How many rows have ever scrolled into the history, and the first
    /// still kept.
    var historyEnd: UInt64 { mvt_history_end(terminal) }
    var historyStart: UInt64 { mvt_history_start(terminal) }

    /// Where the history has got to, as the app is told it.
    func mark(screen: Bool) -> HistoryMark { HistoryMark(epoch: epoch, end: historyEnd, screen: screen) }

    /// History rows `from` to `to` (those still kept), as escape sequences
    /// drawn at the terminal's width; empty if none.
    func history(from: UInt64, to: UInt64) -> Data {
        var n = 0
        guard let bytes = mvt_history_range(terminal, from, to, &n) else { return Data() }
        defer { mvt_free_bytes(bytes, n) }
        return Data(bytes: bytes, count: n)
    }

    /// The first row of the line history row `row` is part of, no higher
    /// than `floor`: where history can be cut without cutting a line.
    func lineStart(_ row: UInt64, floor: UInt64) -> UInt64 { mvt_history_line_start(terminal, row, floor) }

    /// The terminal as escape sequences that make it again, with `history`
    /// rows of what scrolled off the top (all of it, if nil).
    func snapshot(history: Int?) -> Data {
        var n = 0
        guard let bytes = mvt_snapshot(terminal, history ?? -1, &n) else { return Data() }
        defer { mvt_free_bytes(bytes, n) }
        return Data(bytes: bytes, count: n)
    }

    /// What a terminal attaching is sent: the screen alone, at once; its
    /// history follows by backfill.
    var attaching: Data { snapshot(history: 0) }

    /// What a terminal that fell behind (or whose link went and came back)
    /// is sent: its modes reset (DECSTR) and its screen erased — its own
    /// history kept — then the screen as it is now; what it skipped of the
    /// history follows by backfill. Erased from the top-left down (ED 0),
    /// not cleared (ED 2), which at a prompt would scroll the old screen
    /// into the history, before the rows that come after it.
    var catchUp: Data { Data("\u{1b}[!p\u{1b}[H\u{1b}[J".utf8) + snapshot(history: 0) }
}
