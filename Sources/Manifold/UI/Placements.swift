import AppKit
import ManifoldCore

/// What a placement shows, as the views need to know it: the placement, and
/// what's known of its block.
struct Shown: Equatable {
    var placement: Placement
    var block: Block?

    var id: PlacementID { placement.id }
    var lens: Lens { placement.lens }
    var kind: BlockKind { block?.kind ?? kindOf(lens) }
    var title: String { block?.displayTitle ?? kind.defaultTitle }
    var path: String? { block?.path }
    var symbol: String { Theme.symbolName(for: lens) }
    /// Where it is, for subtitles: a folder, or a working directory.
    var place: String? { block?.place }
    var isDirty: Bool { block?.text?.isDirty == true }
    var isDormant: Bool { block?.terminal?.dormantSince != nil && block?.terminal?.pid == nil }

    private func kindOf(_ lens: Lens) -> BlockKind {
        switch lens {
        case .editor, .preview: .text
        case .terminal: .terminal
        case .directory: .directory
        case .web: .web
        case .image: .image
        case .pdf: .pdf
        case .search: .search
        case .diff: .diff
        case .git: .git
        case .process: .process
        case .agent: .agent
        case .card: .arrangement
        }
    }
}

/// A placement's view: a terminal, an editor, a preview, and so on.
protocol PaneContent: NSView {
    var placement: PlacementID { get }
    var block: BlockID { get }
    /// The view that takes the keyboard when the placement is focused.
    var focusView: NSView { get }
    /// Whether the view failed and should be made again.
    var isDead: Bool { get }
    func destroy()
}

extension String {
    /// A path with the home folder as `~`.
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}
