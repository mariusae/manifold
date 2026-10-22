import AppKit
import ManifoldCore

/// What a placement shows, as the views need to know it: the placement, and
/// what's known of its block.
struct Shown: Equatable {
    var placement: Placement
    var block: Block?
    /// The block's host can't be reached now (§8): the view is what was
    /// last seen, and takes no edits.
    var offline = false
    /// The block lives on another host than the workspace it's in: that
    /// host's name, said on its bar.
    var foreignHost: String?

    var id: PlacementID { placement.id }
    var lens: Lens { placement.lens }
    var kind: BlockKind { block?.kind ?? kindOf(lens) }
    var title: String { block?.displayTitle ?? kind.defaultTitle }
    var path: String? { block?.path }
    var symbol: String { block?.isNote == true ? Theme.noteSymbol : Theme.symbolName(for: lens, path: block?.kind == .text ? path : nil) }
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
        case .output: .output
        case .notebook: .notebook
        case .outline: .terminal
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
    /// What's in use under the tile's top edge, in the window, if
    /// anything: the text cursor's line, an address or filter field with
    /// the keyboard. The tile's pill gets out of its way (§3.1).
    var caretRectInWindow: NSRect? { get }
    /// The view's own verbs for its pill's menu (a page's back, forward
    /// and address), before the tile's.
    var pillItems: [NSMenuItem] { get }
    /// What the pill edits in place when clicked (§3.1): a page's
    /// address. The pill widens to show it; ⏎ commits, ⎋ leaves it.
    var pillEdit: PillEdit? { get }
    /// Whether the view has a sidebar of its own (§7.5: an outline, a
    /// PDF's pages), its button in the tile's bar; and whether it shows.
    var hasSidebar: Bool { get }
    var sidebarShown: Bool { get }
    func toggleSidebar()
}

extension PaneContent {
    var caretRectInWindow: NSRect? { nil }
    var pillItems: [NSMenuItem] { [] }
    var pillEdit: PillEdit? { nil }
    var hasSidebar: Bool { false }
    var sidebarShown: Bool { false }
    func toggleSidebar() {}
}

/// Something a tile's pill can become a field for: the text to start
/// from, what to say when there is none, and what to do with it entered.
struct PillEdit {
    var text: String
    var placeholder: String
    /// Over the name, in its type (a note's name), rather than over the
    /// place after it (a page's address).
    var overName = false
    var commit: (String) -> Void
}

/// A lens's keeper of its state (DESIGN.md §3.5): what it notes is written
/// to the block's log a moment later, by placement, and read back when the
/// lens is made again — after a restart, a move between lenses, a reload.
final class ViewStateKeeper {
    var save: (([String: String]) -> Void)?
    var load: () -> [String: String] = { [:] }
    private var pending: [String: String] = [:]
    private var work: DispatchWorkItem?
    /// Whether the lens has read its state back yet: nothing is saved
    /// before, so what was kept isn't written over by a fresh view's zeros.
    var restored = false

    /// Notes values to keep; written after a pause in the noting.
    func note(_ values: [String: String], after delay: Double = 0.5) {
        guard restored else { return }
        let known = load()
        var changed = false
        for (k, v) in values where known[k] != v && pending[k] != v {
            pending[k] = v
            changed = true
        }
        guard changed else { return }
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func flush() {
        work?.cancel()
        work = nil
        guard !pending.isEmpty else { return }
        let values = pending
        pending = [:]
        save?(values)
    }

    func value(_ key: String) -> String? { pending[key] ?? load()[key] }
    func double(_ key: String) -> Double? { value(key).flatMap(Double.init) }
    func int(_ key: String) -> Int? { value(key).flatMap(Int.init) }
}

/// A lens that keeps its state through a keeper.
protocol KeepsViewState: AnyObject {
    var keeper: ViewStateKeeper { get }
}

extension NSScrollView {
    /// Tells when the content scrolls.
    func watchScrolling(_ handler: @escaping (CGFloat, CGFloat) -> Void) {
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            handler(self.contentView.bounds.origin.x, self.contentView.bounds.origin.y)
        }
    }

    func scrollTo(x: CGFloat, y: CGFloat) {
        contentView.scroll(to: NSPoint(x: x, y: y))
        reflectScrolledClipView(contentView)
    }
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

/// AppKit has a `TextRange` of its own; ours is the core's.
typealias TextRange = ManifoldCore.TextRange
