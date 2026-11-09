import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

/// A menu of something on a host — a terminal's, an editor's — ends with
/// the host's own (Forward a Port, Reset Server): the window controller says
/// what that is.
@MainActor
enum HostMenu {
    static var submenu: ((HostID) -> NSMenuItem?)?

    static func append(for host: HostID, to menu: NSMenu) {
        guard let item = submenu?(host) else { return }
        menu.addItem(.separator())
        menu.addItem(item)
    }
}

/// A block's text as Search reads it: its lines as written, and lowercased
/// bytes with where each line begins — looked through with memmem, not a
/// line at a time.
final class SearchText {
    let key: String
    let lines: [Substring]
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(key: String, text: String) {
        self.key = key
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        bytes = Array(text.lowercased().utf8)
        var starts = [0]
        for (i, c) in bytes.enumerated() where c == 0x0A { starts.append(i + 1) }
        lineStarts = starts
    }

    /// The lines (from 1) `q` (lowercased) is in, the first `limit`.
    func lines(matching q: [UInt8], limit: Int) -> [Int] {
        guard !q.isEmpty, bytes.count >= q.count else { return [] }
        var out: [Int] = []
        bytes.withUnsafeBytes { hay in
            q.withUnsafeBytes { needle in
                guard let base = hay.baseAddress, let n = needle.baseAddress else { return }
                var at = 0
                while out.count < limit, at <= bytes.count - q.count,
                      let p = memmem(base + at, bytes.count - at, n, q.count) {
                    let offset = base.distance(to: UnsafeRawPointer(p))
                    // Its line: the last start at or before it.
                    var lo = 0, hi = lineStarts.count - 1
                    while lo < hi {
                        let mid = (lo + hi + 1) / 2
                        if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
                    }
                    if lo < lines.count { out.append(lo + 1) }
                    // On from the next line: a line is a hit once.
                    at = lo + 1 < lineStarts.count ? lineStarts[lo + 1] : bytes.count
                }
            }
        }
        return out
    }
}

/// A block's own menu's Pin in Space (a terminal's, an editor's): for
/// its tile, named Unpin when it's pinned (`validateMenuItem`).
enum PinMenu {
    static func item(for placement: PlacementID) -> NSMenuItem {
        let item = NSMenuItem(title: "Pin in Space", action: #selector(MainWindowController.togglePinInWorkspace(_:)), keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .control]
        item.representedObject = placement
        return item
    }
}

extension Block {
    /// How it's shown when nothing says otherwise.
    var defaultLens: Lens { Lens.default(for: kind, path: path) }
}

extension FindKinds {
    /// What kinds a block is found as (⌘O's chips).
    static func of(_ b: Block) -> [String] { of(b.kind, path: b.path, agent: b.agent != nil) }
}

extension AgentTurn {
    /// The first line of what it was asked, to name it by.
    var headline: String? { prompt.split(whereSeparator: \.isNewline).first.map(String.init) }
}
