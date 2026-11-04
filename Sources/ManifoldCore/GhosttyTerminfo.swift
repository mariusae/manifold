import Foundation

/// Ghostty's terminfo, the description of the terminal Manifold's tiles
/// are, carried in every server: a shell is told it runs in Ghostty
/// (`TERM=xterm-ghostty`), and on a host other than this Mac nothing else
/// says what that is — the app bundle's terminfo is here, and the host's
/// own has no Ghostty in it, as a rule — so the shell couldn't move the
/// cursor, ⌫ seemed to do nothing, `reset` wouldn't run. The entry is
/// Ghostty's own, as tic compiled it (GhosttyTerminfoEntry.swift, made by
/// scripts/embed-terminfo.sh), in ncurses' original format, which every
/// ncurses reads.
public enum GhosttyTerminfo {
    /// The names it's filed under: Ghostty's `TERM`, and its alias.
    public static let names = ["xterm-ghostty", "ghostty"]

    /// The entry, as tic wrote it.
    public static let entry = Data(base64Encoded: compiled, options: .ignoreUnknownCharacters)!

    /// Writes the entry into `dir`, a terminfo folder, under each name,
    /// filed both ways ncurses looks for one: under the name's first
    /// letter (Linux, and most) and under that letter's code in hex
    /// (macOS). A file that's the entry already is left as it is; one
    /// that isn't is replaced whole, so a shell starting meanwhile reads
    /// the old or the new. Whether they're all there.
    public static func install(in dir: URL) -> Bool {
        let fm = FileManager.default
        for name in names {
            guard let first = name.unicodeScalars.first else { continue }
            for folder in [String(first), String(first.value, radix: 16)].map({ dir.appendingPathComponent($0) }) {
                let file = folder.appendingPathComponent(name)
                if (try? Data(contentsOf: file)) == entry { continue }
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try entry.write(to: file, options: .atomic)
                } catch {
                    return false
                }
            }
        }
        return true
    }
}
