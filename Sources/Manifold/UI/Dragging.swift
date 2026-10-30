import AppKit
import ManifoldCore

extension NSPasteboard.PasteboardType {
    /// A thing dragged, as Manifold knows it (`DragThing`, as JSON).
    static let manifoldThing = NSPasteboard.PasteboardType("com.manifold.thing")
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let heic = NSPasteboard.PasteboardType("public.heic")
}

/// One thing dragged (§3.11), whatever it's dragged from: a block, or a
/// place in it (an outline's item: a command, a heading, a page); a file
/// or folder on a host (a folder's entry, a hit, a changed file, one from
/// the Finder); a page's address; words. Each says what it has, and where
/// it lands takes it as one of the forms (`DropForm`) it can be: its
/// link, its reference, its path, its words, what it holds, inline, a
/// tile of its own, a link to a tile, a copy. Tiles themselves are moved
/// by a plain drag (not things); ⇧ makes a tile the thing it is.
struct DragThing: Codable, Equatable {
    struct File: Codable, Equatable {
        var host: HostID
        var path: String
        var isDirectory: Bool
    }

    /// The block it is, or the block a place is in.
    var block: BlockID?
    /// A place in the block, as a reference names it (`command=7`, `line=12`, `page=3`).
    var fragment: String?
    var title: String
    /// The file (or folder) it is: what's copied or moved, opened as a tile.
    var file: File?
    /// What its path says when it isn't a file: a terminal's folder.
    var folder: File?
    /// A page's address.
    var url: String?
    /// Its words: what was selected, a command's line, a heading, rows as
    /// Markdown, a page's address.
    var text: String?
    /// From another app (the Finder's files): copied where files go, never moved.
    var outside = false

    private enum CodingKeys: String, CodingKey { case block, fragment, title, file, folder, url, text }

    init(block: BlockID? = nil, fragment: String? = nil, title: String, file: File? = nil, folder: File? = nil,
         url: String? = nil, text: String? = nil, outside: Bool = false) {
        self.block = block
        self.fragment = fragment
        self.title = title
        self.file = file
        self.folder = folder
        self.url = url
        self.text = text
        self.outside = outside
    }

    /// What its path form says, and on which host.
    var place: File? { file ?? folder }
    var isImage: Bool { file.map { !$0.isDirectory && BlockKind.forFile($0.path) == .image } ?? false }
    /// It can be named by a block: one already, or a file opened as one.
    var nameable: Bool { block != nil || file != nil }

    /// The block it names: its own, or its file's (opened as a block, not placed).
    @MainActor func named() -> BlockID? { block ?? file.flatMap { Drags.resolve?($0) } }

    private var escapedTitle: String {
        (title.isEmpty ? (file?.path.lastPathComponent ?? "link") : title).replacingOccurrences(of: "]", with: "\\]")
    }

    /// The text a form puts in for it, and the block it names (to be
    /// linked from where it lands); nil if it can't be.
    @MainActor func text(_ form: DropForm) async -> (String, BlockID?)? {
        let place = fragment.map { "#" + $0 } ?? ""
        switch form {
        case .link:
            if let id = named() { return ("[\(escapedTitle)](manifold:\(id.description)\(place))", id) }
            guard let url else { return nil }
            return (title.isEmpty || title == url ? "<\(url)>" : "[\(escapedTitle)](\(url))", nil)
        case .reference:
            guard let id = named() else { return nil }
            return ("manifold:\(id.description)\(place)", id)
        case .path:
            return self.place.map { ($0.path, block) }
        case .text:
            return text.map { ($0, block) }
        case .contents:
            guard let id = named(), let fetch = Drags.contents else { return nil }
            let s: String? = await withCheckedContinuation { c in fetch(id, fragment) { c.resume(returning: $0) } }
            return s.map { ($0, id) }
        case .inline:
            guard let id = named() else { return nil }
            return ("![\(escapedTitle)](manifold:\(id.description)\(place))", id)
        case .open, .linkTile, .copy, .move:
            return nil
        }
    }
}

/// What a dropped thing is put in as. Each target takes some, the one it
/// suits first (what a plain drop does, the hint says); ⌃ held as it's
/// dropped, a menu offers the rest.
enum DropForm: String, CaseIterable {
    case link, reference, path, text, contents, inline, open, linkTile, copy, move
}

/// What a pasteboard carries as things dragged — nil for a tile (or a
/// workspace, a host) being moved, which isn't one.
struct Dragged {
    var things: [DragThing]
    /// Files another app promises (Photos, Mail), not yet written.
    var promised: [NSFilePromiseReceiver]
    /// A picture carried as data (a page's image, a screenshot's).
    var hasPictureData: Bool
    let pasteboard: NSPasteboard

    static let moves: [NSPasteboard.PasteboardType] = [.manifoldPlacement, .manifoldBlock, .manifoldArrangement, .manifoldHost]
    static let pictureTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .jpeg, .heic]
    /// What a view taking things registers for.
    static let types: [NSPasteboard.PasteboardType] = [.manifoldThing, .fileURL, .URL, .string] + pictureTypes + Promises.types

    init?(_ pb: NSPasteboard) {
        let types = pb.types ?? []
        guard !types.contains(where: Self.moves.contains) else { return nil }
        pasteboard = pb
        var things: [DragThing] = []
        for item in pb.pasteboardItems ?? [] {
            if let data = item.data(forType: .manifoldThing), let t = try? JSONDecoder().decode(DragThing.self, from: data) {
                things.append(t)
            } else if let s = item.string(forType: .fileURL), let u = URL(string: s), u.isFileURL {
                var dir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: u.path, isDirectory: &dir)
                things.append(DragThing(title: u.lastPathComponent, file: .init(host: Drags.localHost, path: u.path, isDirectory: dir.boolValue),
                                        text: u.path, outside: true))
            } else if let s = item.string(forType: .URL), let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
                let name = item.string(forType: NSPasteboard.PasteboardType("public.url-name"))
                things.append(DragThing(title: name ?? s, url: s, text: s))
            } else if let s = item.string(forType: .string), !s.isEmpty {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.contains(" "), !t.contains("\n"), let u = URL(string: t), u.scheme == "http" || u.scheme == "https" {
                    things.append(DragThing(title: t, url: t, text: t))
                } else if let (id, fragment) = BlockID.reference(t), !t.contains("\n") {
                    // A reference (or a block's link) as text: the block it names.
                    things.append(DragThing(block: id, fragment: fragment, title: t.hasPrefix("[") ? String(t.dropFirst().prefix { $0 != "]" }) : "", text: s))
                } else {
                    things.append(DragThing(title: "", text: s))
                }
            }
        }
        self.things = things
        promised = Promises.receivers(pb)
        hasPictureData = types.contains(where: Self.pictureTypes.contains)
        guard !things.isEmpty || !promised.isEmpty || hasPictureData else { return nil }
    }

    /// It's pictures: image files (not yet blocks), a picture's data, files promised.
    var pictures: Bool {
        if !things.isEmpty, things.allSatisfy({ $0.isImage && $0.block == nil }) { return true }
        if things.contains(where: \.nameable) { return false }
        return hasPictureData || !promised.isEmpty
    }

    private func all(_ test: (DragThing) -> Bool) -> Bool { !things.isEmpty && things.allSatisfy(test) }

    /// Whether every thing dragged can be put in as `form`.
    func offers(_ form: DropForm) -> Bool {
        switch form {
        case .link: all { $0.nameable || $0.url != nil }
        case .reference, .linkTile: all(\.nameable)
        case .path: all { $0.place != nil }
        case .text: all { $0.text != nil }
        case .contents: all { $0.block != nil || $0.file.map { !$0.isDirectory } == true }
        case .inline: pictures || all(\.nameable)
        case .open: true
        case .copy, .move: all { $0.file != nil } || (things.isEmpty && (hasPictureData || !promised.isEmpty)) || pictures
        }
    }

    /// Of `order`, the forms it can be, in that order.
    func forms(_ order: [DropForm]) -> [DropForm] { order.filter(offers) }

    /// The text a form puts in, each thing's (quoted, as a shell would
    /// need) joined by `separator`; and the blocks they name. Nil if any can't be.
    @MainActor func text(_ form: DropForm, separator: String = "\n", quote: ((String) -> String)? = nil,
                         _ done: @escaping (String?, [BlockID]) -> Void) {
        let things = things
        Task { @MainActor in
            var parts: [String] = [], blocks: [BlockID] = []
            for t in things {
                guard let (s, id) = await t.text(form) else { return done(nil, []) }
                parts.append(form == .path || form == .reference ? quote?(s) ?? s : s)
                if let id { blocks.append(id) }
            }
            done(parts.joined(separator: separator), blocks)
        }
    }

    /// The pictures' bytes and kinds — image files read, a picture's data
    /// — once dropped; promised files once written.
    func pictureData(_ done: @escaping ([(Data, String)]) -> Void) {
        let files = things.compactMap { t -> URL? in
            guard t.isImage, let f = t.file, f.host == Drags.localHost else { return nil }
            return URL(fileURLWithPath: f.path)
        }
        if !files.isEmpty {
            return done(files.compactMap { u in (try? Data(contentsOf: u)).map { ($0, u.pathExtension.lowercased()) } })
        }
        if !promised.isEmpty {
            return Promises.receive(promised) { urls in
                done(urls.filter { BlockKind.forFile($0.path) == .image }.compactMap { u in (try? Data(contentsOf: u)).map { ($0, u.pathExtension.lowercased()) } })
            }
        }
        let pb = pasteboard
        if let png = pb.data(forType: .png) { return done([(png, "png")]) }
        if let jpeg = pb.data(forType: .jpeg) { return done([(jpeg, "jpeg")]) }
        if let heic = pb.data(forType: .heic) { return done([(heic, "heic")]) }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return done([(png, "png")])
        }
        done([])
    }

    /// The first thing's words for a menu's detail.
    func detail(_ form: DropForm) -> String {
        let t = things.first
        func short(_ s: String) -> String {
            let a = s.abbreviatingHome.replacingOccurrences(of: "\n", with: " ")
            return a.count > 48 ? String(a.prefix(20)) + "…" + String(a.suffix(26)) : a
        }
        let more = things.count > 1 ? " and \(things.count - 1) more" : ""
        switch form {
        case .link: return "as a note shows it"
        case .reference: return t?.block.map { short("manifold:" + $0.description + (t?.fragment.map { "#" + $0 } ?? "")) + more } ?? "manifold:…"
        case .path: return short(t?.place?.path ?? "") + more
        case .text: return short(t?.text ?? "") + more
        case .contents: return "what it holds, as text"
        case .inline: return pictures ? "the picture, kept with the note" : "its card, as the note shows it"
        case .open: return "a tile of its own"
        case .linkTile: return "an edge from the tile to it"
        case .copy: return "a copy in this folder"
        case .move: return "moved into this folder"
        }
    }
}

/// A view things are dropped on (§3.11): what it takes each as, here, and
/// putting it in. What it takes none of goes on to the grid behind it
/// (a tile of its own, a link to the tile), never refused.
@MainActor protocol DropTaking: NSView {
    /// The forms it takes `d` as at `p` (its terms), the one a plain drop
    /// does first; none, to hand it on.
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm]
    /// What the hint beside the pointer says a form does here.
    func dropHint(_ form: DropForm, _ d: Dragged) -> String
    /// What the menu calls a form here (nil: as everywhere).
    func dropLabel(_ form: DropForm, _ d: Dragged) -> String?
    /// The drag over it at `p`: where it would land shown (a caret following).
    func dropTrack(_ d: Dragged, at p: NSPoint)
    /// `d` put in as `form`, at `p` (nil: where the caret is).
    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?)
}

extension DropTaking {
    func dropHint(_ form: DropForm, _ d: Dragged) -> String { Dropping.hint(form, d) }
    func dropLabel(_ form: DropForm, _ d: Dragged) -> String? { nil }
    func dropTrack(_ d: Dragged, at p: NSPoint) {}
}

/// Dropping things, the same everywhere: the hint, ⌃'s menu, and what a
/// view doesn't take handed on to the grid.
@MainActor enum Dropping {
    /// ⌃ held: what's put in chosen from a menu.
    static var choosing: Bool { debugChoice != nil || NSEvent.modifierFlags.contains(.control) }

    /// Debugging: the form chosen, as if from the menu (it isn't shown),
    /// and the forms the last drop offered.
    static var debugChoice: DropForm?
    private(set) static var lastOffered: [DropForm] = []

    /// What a form does, said in general.
    static func hint(_ form: DropForm, _ d: Dragged) -> String {
        let many = d.things.count > 1
        switch form {
        case .link: return many ? "Put links to them here" : "Put a link to it here"
        case .reference: return many ? "Put their references here" : "Put its reference here"
        case .path: return many ? "Put their paths here" : "Put its path here"
        case .text: return "Put it in here"
        case .contents: return "Put in what it holds"
        case .inline: return d.pictures ? (many ? "Put the pictures here" : "Put the picture here") : "Show its card here"
        case .open: return "Open it here"
        case .linkTile: return "Link the tile to it"
        case .copy: return "Copy here"
        case .move: return "Move here"
        }
    }

    static func label(_ form: DropForm) -> (String, String) {
        switch form {
        case .link: ("Link", "link")
        case .reference: ("Reference", "number")
        case .path: ("Path", "folder")
        case .text: ("Text", "text.alignleft")
        case .contents: ("Contents", "doc.plaintext")
        case .inline: ("Inline", "photo")
        case .open: ("Open as a Tile", "rectangle.badge.plus")
        case .linkTile: ("Link to Tile", "point.topleft.down.to.point.bottomright.curvepath")
        case .copy: ("Copy Here", "doc.on.doc")
        case .move: ("Move Here", "arrow.right.doc.on.clipboard")
        }
    }

    static func grid(of view: NSView) -> GridView? {
        var v = view.superview
        while let s = v, !(s is GridView) { v = s.superview }
        return v as? GridView
    }

    static func updated(_ view: DropTaking, _ sender: NSDraggingInfo) -> NSDragOperation {
        guard let d = Dragged(sender.draggingPasteboard) else { return grid(of: view)?.draggingUpdated(sender) ?? [] }
        let p = view.convert(sender.draggingLocation, from: nil)
        let forms = view.dropForms(d, at: p)
        guard let first = forms.first else { return grid(of: view)?.draggingUpdated(sender) ?? [] }
        grid(of: view)?.draggingExited(sender)
        view.dropTrack(d, at: p)
        let plain = view.dropHint(first, d)
        DropHint.say(choosing && forms.count > 1 ? "Choose what to put in…" : forms.count > 1 ? plain + " · ⌃ for more" : plain,
                     at: sender.draggingLocation, in: view.window)
        return first == .move ? .move : first == .linkTile ? .link : .copy
    }

    static func exited(_ view: DropTaking, _ sender: NSDraggingInfo?) {
        DropHint.hush()
        grid(of: view)?.draggingExited(sender)
    }

    static func perform(_ view: DropTaking, _ sender: NSDraggingInfo) -> Bool {
        DropHint.hush()
        guard let d = Dragged(sender.draggingPasteboard) else { return grid(of: view)?.performDragOperation(sender) ?? false }
        let p = view.convert(sender.draggingLocation, from: nil)
        let forms = view.dropForms(d, at: p)
        guard !forms.isEmpty else { return grid(of: view)?.performDragOperation(sender) ?? false }
        take(d, forms, by: view, at: p)
        return true
    }

    /// `d` put in by `view` as its plain form, or (⌃) as chosen from a menu at `p`.
    static func take(_ d: Dragged, _ forms: [DropForm], by view: DropTaking, at p: NSPoint?) {
        lastOffered = forms
        guard choosing, forms.count > 1 else { return view.dropPut(d, as: forms[0], at: p) }
        if let chosen = debugChoice { return forms.contains(chosen) ? view.dropPut(d, as: chosen, at: p) : NSSound.beep() }
        let menu = NSMenu()
        let name = d.things.count == 1 ? d.things[0].title : ""
        let header = NSMenuItem(title: name.isEmpty || name.count > 40 ? "Put it in as" : "Put “\(name)” in as", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for form in forms {
            let (general, symbol) = label(form)
            let title = view.dropLabel(form, d) ?? general
            let detail = d.detail(form)
            let item = ClosureMenuItem(title, symbol: symbol) { view.dropPut(d, as: form, at: p) }
            item.toolTip = detail
            let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
            menu.addItem(item)
        }
        let at = p ?? view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        // After the drop has finished: the menu runs once the drag is over.
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: at, in: view) }
    }

    /// Debugging: what dropping `pb` on `view` does (at `p`; nil, its
    /// caret or middle): the form taken, those offered, the hint.
    static func debugDrop(_ pb: NSPasteboard, on view: DropTaking, at p: NSPoint?) -> String {
        guard let d = Dragged(pb) else { return "not a thing" }
        let forms = view.dropForms(d, at: p ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        guard let first = forms.first else { return "handed on to the grid" }
        let taken = debugChoice.flatMap { forms.contains($0) ? $0 : nil } ?? first
        take(d, forms, by: view, at: p)
        return "dropped as \(taken.rawValue) · offered \(forms.map(\.rawValue).joined(separator: ", ")) · “\(view.dropHint(first, d))”"
    }

    /// A link, a reference, a path put in among words: a space before
    /// and after it where it would touch them.
    static func spaced(_ s: String, after prev: Character?, before next: Character?) -> String {
        var s = s
        if let p = prev, !p.isWhitespace, !"([{\"'".contains(p) { s = " " + s }
        if let n = next, !n.isWhitespace, !".,;:!?)]}\"'".contains(n) { s += " " }
        return s
    }

    /// The forms a note takes (an editor's, an outline's, a preview's):
    /// pictures inline; a block, a file, a place a link; a page a link;
    /// words as they are.
    static func noteForms(_ d: Dragged) -> [DropForm] {
        d.forms(d.pictures ? [.inline, .link, .reference, .path] : [.link, .inline, .reference, .path, .contents, .text])
    }

    /// The forms a shell, a cell (a command line) takes: a path, typed; a
    /// place by its words (a command again); else its reference.
    static func shellForms(_ d: Dragged) -> [DropForm] {
        let place = d.things.contains { $0.fragment != nil }
        return d.forms(place ? [.text, .path, .reference, .contents, .link] : [.path, .text, .reference, .contents, .link])
    }

    /// `d` put in a note as `form`: its pictures kept (as image blocks,
    /// by `keep`), else `insert` given the Markdown; `linked` the blocks named.
    static func noteText(_ d: Dragged, as form: DropForm, keep: ((Data, String) -> Void)?, insert: @escaping (String) -> Void,
                         linked: @escaping (BlockID) -> Void) {
        if form == .inline, d.pictures {
            d.pictureData { pictures in
                guard !pictures.isEmpty, let keep else { return NSSound.beep() }
                for (data, kind) in pictures { keep(data, kind) }
            }
            return
        }
        d.text(form, separator: form == .inline ? "\n\n" : "\n") { text, blocks in
            guard let text, !text.isEmpty else { return NSSound.beep() }
            insert(text)
            if form != .text, form != .path { blocks.forEach(linked) }
        }
    }
}
