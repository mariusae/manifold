import AppKit
import ManifoldCore

extension MainWindowController {
    /// What can be done with a link ⌘-right-clicked in a tile (an address,
    /// a path, `path:line`): each way a ⌘-click opens it, its click said
    /// beside it — beside the tile, over it, in the system's app — then
    /// copied, and, a file's, its folder.
    func linkMenu(_ target: String, from placement: PlacementID?) -> NSMenu {
        let menu = NSMenu()
        let address = Self.isAddress(target)
        let on = placement.flatMap { shown($0)?.placement.block.host } ?? host.host
        let local = on == host.host
        // The file it names, its line and column left off (an address: none).
        let location = address ? nil : FileLocation.split(target)
        let path = address ? nil : (location?.path ?? target)
        func item(_ title: String, _ symbol: String, click: String? = nil, _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title, symbol: symbol, run)
            if let click, #available(macOS 14.4, *) { i.subtitle = click }
            menu.addItem(i)
        }

        item("Open", "arrow.up.forward.square", click: "⌘-click") { [weak self] in self?.open(target, from: placement, as: .beside) }
        item("Open Over", "square.on.square", click: "⌥⌘-click") { [weak self] in self?.open(target, from: placement, as: .over) }
        item("Open in \(Self.systemApp(for: target, path: local ? path : nil) ?? "Default App")", "arrow.up.right.square",
             click: "⇧⌘-click") { [weak self] in self?.open(target, from: placement, as: .system) }
        menu.addItem(.separator())
        if address {
            item("Copy Address", "doc.on.doc") { NSPasteboard.copy(target) }
        } else if let path {
            item("Copy Path", "doc.on.doc") { NSPasteboard.copy(path) }
            if location?.line != nil { item("Copy Path and Line", "text.line.first.and.arrowtriangle.forward") { NSPasteboard.copy(target) } }
            item("Copy Name", "textformat") { NSPasteboard.copy((path as NSString).lastPathComponent) }
            menu.addItem(.separator())
            // Its folder, here; and, this Mac's, in the Finder.
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                item("Open Enclosing Folder", "folder") { [weak self] in self?.open(folder, from: placement, as: .beside) }
            }
            if local {
                item("Reveal in Finder", "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
                }
            }
        }
        return menu
    }

    /// Whether a link's an address (a scheme and what follows), not a file.
    static func isAddress(_ target: String) -> Bool { TerminalLinks.Link(range: 0..<0, target: target).path == nil }

    /// The app the system opens a link in (⇧⌘-click): an address's
    /// browser, a file of this Mac's app (a folder's, the Finder); nil if
    /// it can't be said (another host's file).
    static func systemApp(for target: String, path: String?) -> String? {
        let url: URL?
        if isAddress(target) {
            url = URL(string: target)
        } else if let path {
            let p = (path as NSString).expandingTildeInPath
            url = FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        } else {
            url = nil
        }
        guard let url, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}
