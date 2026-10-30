import AppKit
import ManifoldCore

/// A block ⇧-dragged, as where it lands can put it in (§3.5): its **link**
/// (`[title](manifold:…)`, which a note shows as its name), its
/// **reference** (`manifold:host/id`, a place in it after `#` — what `mani`
/// and an agent take as its name, to read it, write it, show it), its
/// **path** (a file's, a folder's, a terminal's directory), or what it
/// **holds**, as text. A plain ⇧-drop puts in what suits the target (a
/// note a link, a shell a path, an agent what a note or a command's output
/// holds); with ⌃ held as it's dropped, a menu there offers each the target
/// takes. The hint beside the pointer says which, and that ⌃ offers more.
struct BlockDrop {
    enum Form: CaseIterable {
        case link, reference, path, contents
    }

    let block: BlockID
    let title: String
    /// As a note shows it.
    let link: String
    /// As mani takes it.
    let reference: String
    /// What a ⇧-drag carries as text: a file's path, a page's address, a
    /// terminal's directory — nil for a block with none.
    let path: String?

    /// The block a pasteboard carries ⇧-dragged (not a tile moved, not the
    /// link alone ⌥⇧ gives).
    init?(_ pb: NSPasteboard) {
        guard pb.string(forType: .manifoldPlacement) == nil, pb.string(forType: .manifoldLinkOnly) == nil,
              let link = pb.string(forType: .manifoldBlockLink), let (id, fragment) = BlockID.reference(link) else { return nil }
        block = id
        self.link = link
        reference = "manifold:" + id.description + (fragment.map { "#" + $0 } ?? "")
        let name = link.hasPrefix("[") ? link.dropFirst().prefix { $0 != "]" } : ""
        title = String(name)
        let text = pb.string(forType: .string) ?? ""
        path = text.isEmpty ? nil : text
    }

    /// ⌃ held: what's put in chosen from a menu.
    static var choosing: Bool { debugChoice != nil || NSEvent.modifierFlags.contains(.control) }

    /// Debugging: the form chosen, as if from the menu (it isn't shown),
    /// and the forms the last menu offered.
    static var debugChoice: Form?
    private(set) static var lastOffered: [Form] = []

    /// Of those a target takes, the ones this block can be (a path only if
    /// it has one).
    func forms(_ taken: [Form]) -> [Form] { taken.filter { $0 != .path || path != nil } }

    /// What the hint says beside the pointer: what a plain drop does, and
    /// that ⌃ offers the rest — or, ⌃ held, that a menu will.
    static func hint(_ plain: String, choices: Int) -> String {
        if choosing, choices > 1 { return "Choose what to put in…" }
        return choices > 1 ? plain + " · ⌃ for more" : plain
    }

    /// The text a form puts in (what it holds fetched, on the main queue).
    func text(_ form: Form, _ done: @escaping (String?) -> Void) {
        switch form {
        case .link: done(link)
        case .reference: done(reference)
        case .path: done(path)
        case .contents:
            guard let fetch = Drags.contents else { return done(nil) }
            fetch(block, done)
        }
    }

    /// A menu of the forms, at a point in a view, the default first; the
    /// one chosen done (after the drop has finished: the menu runs once the
    /// drag is over).
    func choose(_ forms: [Form], at point: NSPoint, in view: NSView, _ done: @escaping (Form) -> Void) {
        Self.lastOffered = forms
        if let chosen = Self.debugChoice { return forms.contains(chosen) ? done(chosen) : NSSound.beep() }
        let name = title.isEmpty ? "it" : "“\(title)”"
        let menu = NSMenu()
        let header = NSMenuItem(title: "Put in \(name) as", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for form in forms {
            let (label, symbol, detail): (String, String, String) = switch form {
            case .link: ("Link", "link", "as a note shows it")
            case .reference: ("Reference", "number", short(reference))
            case .path: ("Path", "folder", short(path ?? ""))
            case .contents: ("Contents", "doc.plaintext", "what it holds, as text")
            }
            let item = ClosureMenuItem(label, symbol: symbol) { done(form) }
            item.toolTip = detail
            let text = NSMutableAttributedString(string: label, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
            menu.addItem(item)
        }
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    private func short(_ s: String) -> String {
        let a = s.abbreviatingHome
        return a.count > 48 ? String(a.prefix(20)) + "…" + String(a.suffix(26)) : a
    }
}
