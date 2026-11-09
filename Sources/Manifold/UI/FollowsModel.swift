import AppKit
import ManifoldCore

/// What each render tells the views shown: the model may have changed,
/// with the theme and the code font as they are now.
struct RenderContext {
    let theme: FontTheme
    let codeFont: NSFont
    /// A block's threads' places (§3.12), for views that mark them.
    let places: (BlockID) -> [TextView.Place]
}

/// A view that follows the model as each render tells it.
protocol FollowsModel {
    func modelChanged(_ c: RenderContext)
}

extension TerminalView: FollowsModel {
    func modelChanged(_ c: RenderContext) { syncFocus(); processesChanged() }
}

extension MarkdownView: FollowsModel {
    func modelChanged(_ c: RenderContext) { textChanged(); refreshCards(); refreshPlaces() }
}

extension EditorView: FollowsModel {
    func modelChanged(_ c: RenderContext) { documentChanged(); refreshPills() }
}

extension OutlineNoteView: FollowsModel {
    func modelChanged(_ c: RenderContext) { theme = c.theme; documentChanged(); threadPlaces = c.places(block) }
}

extension OutputView: FollowsModel {
    func modelChanged(_ c: RenderContext) { font = c.codeFont; refresh() }
}

extension NotebookView: FollowsModel {
    func modelChanged(_ c: RenderContext) { codeFont = c.codeFont; documentChanged() }
}

extension SearchView: FollowsModel {
    func modelChanged(_ c: RenderContext) { codeFont = c.codeFont; documentChanged() }
}

extension DirectoryView: FollowsModel { func modelChanged(_ c: RenderContext) { documentChanged() } }
extension WebView: FollowsModel { func modelChanged(_ c: RenderContext) { documentChanged() } }
extension GitView: FollowsModel { func modelChanged(_ c: RenderContext) { documentChanged() } }
extension ProcessView: FollowsModel { func modelChanged(_ c: RenderContext) { documentChanged() } }
extension DiffView: FollowsModel { func modelChanged(_ c: RenderContext) { documentChanged() } }
extension PanelView: FollowsModel { func modelChanged(_ c: RenderContext) { documentChanged() } }
