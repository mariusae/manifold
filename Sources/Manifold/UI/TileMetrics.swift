import AppKit

/// The heights inside a tile, one set for every kind (§3.1): its header,
/// a strip along its top, its lists' rows and their sections' headings.
enum TileMetrics {
    /// A header holding controls, or two lines: a folder's path and modes,
    /// the state's, a search's query, a command and how it went.
    static let controlHeader: CGFloat = 44
    /// A strip of one line along a tile's top: a notebook's, a PDF's
    /// controls, a branch, a diff's count, a search preview's file.
    static let strip: CGFloat = 28
    /// A row in a list of names: files, changes, results.
    static let nameRow: CGFloat = 24
    /// A row of dense data: search hits, processes.
    static let denseRow: CGFloat = 20
    /// A section's heading in a list, its words in the middle of it…
    static let sectionRow: CGFloat = 28
    /// …and the air above every heading but the first, parting it from
    /// the section before.
    static let sectionAir: CGFloat = 14

    /// A heading's row: its band, with the air above it unless it's first.
    static func sectionHeight(first: Bool) -> CGFloat { first ? sectionRow : sectionRow + sectionAir }
}
