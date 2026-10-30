import AppKit
import WebKit
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
    var title: String { caption ?? block?.displayTitle ?? kind.defaultTitle }
    /// Said on the bar instead of the block's name (the agents' view: what
    /// each is doing).
    var caption: String?
    var path: String? { block?.path }
    var symbol: String {
        // A coding agent at work in it: the agent's mark.
        if let a = block?.agent, AgentIcons.has(a.command) { return AgentIcons.prefix + a.command }
        return block?.isNote == true ? Theme.noteSymbol : Theme.symbolName(for: lens, path: block?.kind == .text ? path : nil)
    }
    /// Where it is, for subtitles: a folder, or a working directory.
    var place: String? { block?.place }
    var isDirty: Bool { block?.text?.isDirty == true }
    var isDormant: Bool { block?.terminal?.dormantSince != nil && block?.terminal?.pid == nil }

    private func kindOf(_ lens: Lens) -> BlockKind {
        switch lens {
        case .editor, .preview, .outliner: .text
        case .terminal: .terminal
        case .directory: .directory
        case .web: .web
        case .image: .image
        case .pdf: .pdf
        case .search: .search
        case .diff: .diff
        case .git: .git
        case .smartlog: .smartlog
        case .process: .process
        case .agent: .agent
        case .card: .arrangement
        case .output: .output
        case .notebook: .notebook
        case .outline: .terminal
        case .ui: .ui
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
    /// The view's own buttons on its bar (a page's back, forward, reload).
    var barButtons: [BarButton] { get }
    /// What the pill edits in place when clicked (§3.1): a page's
    /// address. The pill widens to show it; ⏎ commits, ⎋ leaves it.
    var pillEdit: PillEdit? { get }
    /// Whether the view has a sidebar of its own (§7.5: an outline, a
    /// PDF's pages), its button in the tile's bar; and whether it shows.
    var hasSidebar: Bool { get }
    var sidebarShown: Bool { get }
    func toggleSidebar()
    /// The sidebar, where it isn't among the view's own subviews (a
    /// terminal's sits beside it); else found among them.
    var sidebarView: TileSidebar? { get }
    /// Its outline, if it has one (§7.5): the tile shows it as ticks at its
    /// upper right, the whole of it over them while the pointer is there.
    var outline: Outline? { get }
    /// How far down from its top its content begins, under a header of its
    /// own (a PDF's page and zoom): the ticks go below that.
    var outlineInset: CGFloat { get }
    /// Where in its block the view is now, for the block navigation stack
    /// (§3.5): an editor's line, a terminal's command gone to, a page's
    /// scroll, a PDF's page. Nil: only the tile.
    var navLocation: NavLocation? { get }
    /// Back there.
    func go(to location: NavLocation)
    /// What's selected in it, for `mani`'s @selection; nil if nothing.
    func maniSelection() async -> ManiSelected?
    /// What it shows, as text, for `mani read`, where only the view has it
    /// (a terminal's screen, a page's text); nil where the block's state
    /// says it.
    func maniText(_ options: ManiReadOptions) async -> String?
}

/// Text selected in a view (`mani`'s @selection): where, as it can say.
struct ManiSelected {
    var text: String
    /// The lines it spans, from 1 (an editor's).
    var lines: ClosedRange<Int>? = nil
    /// The page it's on, from 1 (a PDF's).
    var page: Int? = nil
}

/// What `mani read` asks of a view.
struct ManiReadOptions {
    /// A terminal's whole transcript, not its screen.
    var all = false
    /// A terminal's command, by its id.
    var command: Int?
    /// A PDF's pages, from 1.
    var pages: ClosedRange<Int>?
}

/// A view held weakly, for what's wired before the view is made.
final class WeakView {
    weak var view: NSView?
}

/// A place within a block (§3.5).
enum NavLocation: Equatable {
    case line(Int)
    case command(Int)
    case offset(Double)
    case page(Int)

    /// Near enough to be one place: lines a few apart are.
    func near(_ other: NavLocation) -> Bool {
        switch (self, other) {
        case let (.line(a), .line(b)): abs(a - b) <= 3
        case let (.offset(a), .offset(b)): abs(a - b) < 40
        default: self == other
        }
    }
}

/// A view about to jump within its block (a definition, a found line, a
/// heading, a command): the block navigation stack notes where it was.
enum NavJumps {
    static var willJump: ((PaneContent) -> Void)?
}

/// A button a view puts on its tile's bar: its symbol, what it says when
/// pointed at, whether it can be pressed now, and what it does.
struct BarButton: Equatable {
    let symbol: String
    let tooltip: String
    let enabled: Bool
    let action: () -> Void

    static func == (a: BarButton, b: BarButton) -> Bool {
        a.symbol == b.symbol && a.tooltip == b.tooltip && a.enabled == b.enabled
    }
}

extension PaneContent {
    func maniSelection() async -> ManiSelected? { nil }
    func maniText(_ options: ManiReadOptions) async -> String? { nil }
    var barButtons: [BarButton] { [] }
    var caretRectInWindow: NSRect? { nil }
    var pillItems: [NSMenuItem] { [] }
    var pillEdit: PillEdit? { nil }
    var hasSidebar: Bool { false }
    var sidebarShown: Bool { false }
    func toggleSidebar() {}
    var sidebarView: TileSidebar? { nil }
    var outline: Outline? { nil }
    var outlineInset: CGFloat { 0 }
    var navLocation: NavLocation? { nil }
    func go(to location: NavLocation) {}
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
    /// What's typed so far, completed (a page's address, as a browser's
    /// address bar does): the rows under the field, the first the default.
    var suggest: ((String) -> [PillSuggestion])? = nil
}

/// A completion for a pill being edited: what it puts in the field, how it
/// reads in the list, and what choosing it does.
struct PillSuggestion {
    /// In the field, chosen (and completed inline, if `inline`).
    var fill: String
    var title: String
    var detail = ""
    var symbol = "globe"
    /// Its `fill` begins with what's typed: completed in the field as you
    /// type, the rest selected to type over.
    var inline = false
    /// Chosen, it goes in the field to type on from (a host's `name:`).
    var fillsOnly = false
    /// What's committed for it, if not its `fill` (a page's whole address).
    var commitText: String?
    /// Chosen: done, instead of the field's commit (a search).
    var run: (() -> Void)?
    /// ⇧⌫ on it: forgotten (a page in the history).
    var remove: (() -> Void)?
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

/// What a row or a pill writes when dragged (§3.4, §3.11), the same
/// everywhere: a thing (`DragThing`) — a file or folder on a host, found,
/// changed or listed, as a folder's entry is; a block, or a place in it.
/// A block's own pill, row or card, dragged plain, is the block moved or
/// brought (a tile); ⇧-dragged, the thing it is. Given by the window,
/// which knows the blocks.
enum Drags {
    static var block: ((_ block: BlockID, _ modifiers: NSEvent.ModifierFlags) -> NSPasteboardItem?)?

    /// A file or folder on a host, dragged (a place in it: a hit's line).
    static func file(_ path: String, isDirectory: Bool, on host: HostID, fragment: String? = nil) -> NSPasteboardItem {
        item(DragThing(fragment: fragment, title: path.lastPathComponent, file: .init(host: host, path: path, isDirectory: isDirectory), text: path))
    }
    /// What a block holds, as text (a drop's Contents), or a place in it
    /// (a command's output, a heading's section, a page): fetched, a block
    /// still being made waited for; nil if it can't be.
    static var contents: ((_ block: BlockID, _ fragment: String?, _ done: @escaping (String?) -> Void) -> Void)?
    /// A place in a block dragged (an outline's item): the block as a
    /// thing, its place in it ("line=12"; nil, the block), the item's words.
    static var place: ((_ block: BlockID, _ fragment: String?, _ title: String) -> NSPasteboardItem?)?
    /// The block a file dragged names: opened as one (not placed), for a
    /// link or a reference to it; nil for one Manifold doesn't open.
    static var resolve: ((DragThing.File) -> BlockID?)?
    /// A picture kept for a note (`note`), as an image block: `insert`
    /// given the Markdown that shows it.
    static var keepImage: ((_ data: Data, _ kind: String, _ note: BlockID, _ insert: @escaping (String) -> Void) -> Void)?
    /// This Mac's host: whose files have URLs here.
    static var localHost = HostID("local")

    /// What dragging a thing writes, from wherever it's dragged: the thing,
    /// and for another app its words, its file here, its page.
    static func item(_ t: DragThing) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(t) { item.setData(data, forType: .manifoldThing) }
        let reference = t.block.map { "manifold:" + $0.description + (t.fragment.map { "#" + $0 } ?? "") }
        if let s = t.text ?? t.place?.path ?? t.url ?? reference { item.setString(s, forType: .string) }
        if let f = t.file, f.host == localHost { item.setString(URL(fileURLWithPath: f.path).absoluteString, forType: .fileURL) }
        if let u = t.url { item.setString(u, forType: .URL) }
        return item
    }

    static var modifiers: NSEvent.ModifierFlags { NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags }

    /// A block's address on the clipboard, a place in it if given
    /// ("line=12", "page=3", "command=7"). Given by the window.
    static var copyLink: ((_ block: BlockID, _ fragment: String?) -> Void)?

    /// A menu of one item: Copy Link to the place.
    static func linkMenu(_ title: String, _ block: BlockID, _ fragment: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title, symbol: "link") { copyLink?(block, fragment) })
        return menu
    }
}

extension Notification.Name {
    /// Text was selected in a view (the object, a `PaneContent`): what
    /// `mani`'s @selection goes by.
    static let manifoldSelectionMade = Notification.Name("ManifoldSelectionMade")
}

/// A page's selection, told of as it's made (`selectionchange`), in the
/// content world of Manifold's own scripts, so a page's own can't stop it.
enum PageSelection {
    static let handlerName = "maniSelection"
    static let script = WKUserScript(source: """
        (function () { var t; document.addEventListener('selectionchange', function () {
          clearTimeout(t); t = setTimeout(function () {
            var s = String(window.getSelection() || '');
            if (s.length) { try { window.webkit.messageHandlers.maniSelection.postMessage(1); } catch (e) {} }
          }, 250);
        }); })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)

    /// The page's selected text, if any.
    @MainActor static func text(in web: WKWebView) async -> String? {
        let s = try? await web.callAsyncJavaScript("return String(window.getSelection() || '')", contentWorld: .defaultClient) as? String
        return s?.isEmpty == false ? s : nil
    }

    /// The page's text, as it reads.
    @MainActor static func pageText(in web: WKWebView) async -> String? {
        try? await web.callAsyncJavaScript("return document.body ? document.body.innerText : ''", contentWorld: .defaultClient) as? String
    }

    /// Wires a configuration so `view` is said to have a selection as one's made.
    static func watch(_ config: WKWebViewConfiguration, for view: @escaping () -> NSView?) {
        config.userContentController.addUserScript(script)
        config.userContentController.add(Handler(view), contentWorld: .defaultClient, name: handlerName)
    }

    private final class Handler: NSObject, WKScriptMessageHandler {
        let view: () -> NSView?
        init(_ view: @escaping () -> NSView?) { self.view = view }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            NotificationCenter.default.post(name: .manifoldSelectionMade, object: view())
        }
    }
}
