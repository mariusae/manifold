import CManifoldVT
import Foundation

/// A shell's terminal as the host keeps it (§8): Ghostty's emulator, the
/// one the app draws with, fed everything the shell prints and sized with
/// its pty. A terminal attaching is sent a snapshot of it — escape
/// sequences that make the same screen, scrollback, modes and cursor in a
/// fresh terminal — not the output that made it; so is one that fell
/// behind, in place of all it missed.
final class TerminalScreen {
    private let terminal: OpaquePointer
    /// History kept, as the app's terminals keep theirs (Ghostty's default).
    static let scrollback = 10_000_000

    init?(cols: UInt16, rows: UInt16) {
        guard let t = mvt_new(cols, rows, Self.scrollback) else { return nil }
        terminal = t
    }

    deinit { mvt_free(terminal) }

    func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            mvt_feed(terminal, base, raw.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) { mvt_resize(terminal, cols, rows) }

    /// The terminal as escape sequences that make it again, with `history`
    /// rows of what scrolled off the top (all of it, if nil).
    func snapshot(history: Int?) -> Data {
        var n = 0
        guard let bytes = mvt_snapshot(terminal, history ?? -1, &n) else { return Data() }
        defer { mvt_free_bytes(bytes, n) }
        return Data(bytes: bytes, count: n)
    }

    /// What a terminal attaching is sent: the screen, and as much history
    /// as the app's terminal would show in a good scroll back (not all ten
    /// megabytes, over a slow link).
    var attaching: Data { snapshot(history: 5_000) }

    /// What a terminal that fell behind is sent: its modes reset (DECSTR)
    /// and its screen cleared — its own history kept — then the screen as
    /// it is now. What it skipped stays here.
    var catchUp: Data { Data("\u{1b}[!p\u{1b}[H\u{1b}[2J".utf8) + snapshot(history: 0) }
}
