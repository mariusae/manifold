import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: EditorViewDelegate {
    func editor(_ view: EditorView, append events: [Event]) {
        hosts.append(events, to: .block(view.block))
    }

    func editor(_ view: EditorView, propose proposal: Proposal) {
        hosts.propose(proposal)
    }

    func editorText(_ view: EditorView) -> TextState? {
        hosts.block(view.block)?.text
    }

    /// An outline's entry clicked: the block's tile goes there — its
    /// terminal to the command's row, its editor or preview to the
    /// heading; with no tile of it shown, one is opened beside the outline.
    /// ⌘P: the focused tile on paper (or a PDF), as it best prints: a
    /// text as text, a page as rendered, a PDF's pages, an image.
    @objc func printTile(_ sender: Any?) {
        guard let f = arrangement?.focused, let p = views[f] as? Printable, let op = p.printOperation(), let window else { return NSSound.beep() }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    var debugPrintOperation: NSPrintOperation? { (arrangement?.focused.flatMap { views[$0] } as? Printable)?.printOperation() }

    /// ⌘/: the focused tile's own sidebar, shown or put away — a
    /// Markdown text's headings, a PDF's contents and pages (§7.5).
    @objc func toggleTileSidebar(_ sender: Any?) {
        guard let f = arrangement?.focused, let v = views[f], v.hasSidebar else { return NSSound.beep() }
        v.toggleSidebar()
        content.sidebarChanged(f)
    }

    func editorEditedChanged(_ view: EditorView) {
        render()
    }

    func editorDiagnostics(_ view: EditorView) -> [Diagnostic] {
        hosts.diagnostics(view.block)
    }

    func editorGutter(_ view: EditorView) -> [GutterMark] {
        hosts.gutter(view.block)
    }

    /// The places in an editor's text something is said about (§2.5): each
    /// anchor with links to it or from it, at its line as last known; a
    /// note linked to it as describing, annotating or explaining it, its
    /// words (its title line left out).
    func editorPlaces(_ view: EditorView) -> [TextView.Place] { places(of: view.block) }

    /// A text's places something is said about (§2.5), as an editor or a
    /// preview shows them.
    func places(of id: BlockID) -> [TextView.Place] {
        guard let b = hosts.block(id), let anchors = b.anchors, !anchors.isEmpty, let rope = b.text?.text else { return [] }
        let n = hosts.neighborhood(of: b.id)
        let inbound = n.inbound.values.flatMap { $0 }.filter { $0.toAnchor != nil }
        let outbound = n.outbound.values.flatMap { $0 }.filter { $0.fromAnchor != nil }
        guard !inbound.isEmpty || !outbound.isEmpty else { return [] }
        var out: [TextView.Place] = []
        for a in anchors.values {
            guard let r = a.range, r.start <= rope.count else { continue }
            var to = inbound.filter { $0.toAnchor == a.id }
            let from = outbound.filter { $0.fromAnchor == a.id }
            guard !to.isEmpty || !from.isEmpty else { continue }
            // Threads about it (§3.12): marked as threads, not among its links.
            let threads = to.filter { $0.relation == ThreadText.annotates }.compactMap { hosts.block($0.from) }.filter { $0.kind == .thread }
            to.removeAll { e in threads.contains { $0.id == e.from } }
            var links: [TextView.Place.Link] = []
            var seen = Set<String>()
            for e in to {
                let target = Self.address(e.from, anchor: e.fromAnchor)
                guard seen.insert(target + (e.relation ?? "")).inserted else { continue }
                links.append(.init(title: hosts.block(e.from)?.displayTitle ?? "?", relation: e.relation, target: target, inbound: true))
            }
            for e in from {
                let target = Self.address(e.to, anchor: e.toAnchor)
                guard seen.insert(target + (e.relation ?? "")).inserted else { continue }
                links.append(.init(title: hosts.block(e.to)?.displayTitle ?? "?", relation: e.relation, target: target, inbound: false))
            }
            // The note that describes it (else annotates, explains), shown under it.
            var note: TextView.Place.Note?
            for relation in ["describes", "annotates", "explains"] {
                guard let e = to.first(where: { $0.relation == relation }), let nb = hosts.block(e.from), nb.isNote, let t = nb.text?.text.string else { continue }
                var body = t
                if let first = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first, first.hasPrefix("# ") {
                    body = String(body.dropFirst(first.count)).trimmingCharacters(in: .newlines)
                }
                note = .init(title: nb.displayTitle, text: body, relation: relation, target: Self.address(e.from))
                break
            }
            var place = TextView.Place(line: rope.line(at: r.start), links: links, note: note)
            place.threads = threads.count
            place.openThreads = threads.filter { $0.thread?.resolved != true }.count
            place.unseen = threads.contains { !hosts.unseen($0).isEmpty }
            place.lines = rope.line(at: r.start)...rope.line(at: max(r.start, r.end))
            out.append(place)
        }
        // Two places on a line: one, their links and threads together.
        var byLine: [Int: TextView.Place] = [:]
        for p in out {
            guard var q = byLine[p.line] else { byLine[p.line] = p; continue }
            q.links += p.links
            q.note = q.note ?? p.note
            q.threads += p.threads
            q.openThreads += p.openThreads
            q.unseen = q.unseen || p.unseen
            byLine[p.line] = q
        }
        return byLine.values.sorted { $0.line < $1.line }
    }

    func editor(_ view: EditorView, lsp request: LSPRequest, done: @escaping (LSPResult) -> Void) {
        hosts.lsp(request, done: done)
    }

    func editor(_ view: EditorView, scip request: SCIPRequest, done: @escaping (SCIPResult) -> Void) {
        hosts.scip(request, on: view.block.host, done: done)
    }

    func editor(_ view: EditorView, open url: URL, over: Bool) {
        open(url.absoluteString, from: view.placement, over: over)
    }

    func terminal(_ view: TerminalView, setCopyOnSelect on: Bool) {
        var s = desk.settings
        s.copyOnSelect = on
        TerminalView.copyOnSelect = on
        host.setSettings(s)
    }

    /// A block dropped into the editor: linked to the note (the host's
    /// mention scan sees the link in the text too, as a mention).
    func editor(_ view: EditorView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// A block's image for a page: this Mac's file as it is; another
    /// host's fetched once (20 MB at most) and kept as data, the pages that
    /// show it drawn again when it's in.
    func imageSource(_ id: BlockID) -> String? {
        guard let b = hosts.block(id), b.kind == .image, let path = b.path else { return nil }
        if id.host == host.host { return URL(fileURLWithPath: path).absoluteString }
        if let data = remoteImages[id] { return data }
        guard !fetchingImages.contains(id), let c = hosts.client(id.host) else { return nil }
        fetchingImages.insert(id)
        c.readBytes(path: path, limit: 20 << 20) { [weak self] data in
            guard let self else { return }
            self.fetchingImages.remove(id)
            guard let data else { return }
            let type = UTType(filenameExtension: path.pathExtension)?.preferredMIMEType ?? "image/png"
            self.remoteImages[id] = "data:\(type);base64," + data.base64EncodedString()
            for case let m as MarkdownView in self.views.values { m.imagesArrived() }
        }
        return nil
    }

    /// A picture a note's outline shows, when it's here: an image block
    /// (`manifold:…`), a file beside the note's own (or a path), a picture
    /// on the web. This Mac's small files read at once; the rest — another
    /// host's, the web's, a large file — sent for, the outlines told when
    /// it comes.
    func picture(_ source: String, in note: BlockID) -> NSImage? {
        if source.hasPrefix("manifold:") {
            guard let (id, _) = BlockID.link(source), let b = hosts.block(id), b.kind == .image, let path = b.path else { return nil }
            return picture(file: path, on: id.host)
        }
        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return picture(web: url) }
            if scheme == "file" { return picture(file: url.path, on: host.host) }
            if scheme == "data" { return picture(key: source) { done in done(try? Data(contentsOf: url)) } }
            if scheme.count > 1 { return nil }
        }
        let path = (source.removingPercentEncoding ?? source).expandingTildeInPath
        if path.hasPrefix("/") { return picture(file: path, on: note.host) }
        guard let folder = hosts.block(note)?.path?.deletingLastPathComponent, !folder.isEmpty else { return nil }
        return picture(file: folder.appendingPathComponent(path), on: note.host)
    }

    private func picture(file path: String, on host: HostID) -> NSImage? {
        let key = "\(host)|\(path)"
        if let image = pictures.object(forKey: key as NSString) { return image }
        if notPictures.contains(key) { return nil }
        if host == self.host.host {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
            guard let size, size <= 40 << 20 else { notPictures.insert(key); return nil }
            if size <= 2 << 20 {
                guard let image = NSImage(contentsOfFile: path), image.isValid else { notPictures.insert(key); return nil }
                pictures.setObject(image, forKey: key as NSString)
                return image
            }
            return picture(key: key) { done in
                Task.detached(priority: .userInitiated) {
                    let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                    await MainActor.run { done(data) }
                }
            }
        }
        guard let c = hosts.client(host) else { return nil }
        return picture(key: key) { done in c.readBytes(path: path, limit: 40 << 20) { data in Task { @MainActor in done(data) } } }
    }

    private func picture(web url: URL) -> NSImage? {
        picture(key: url.absoluteString) { done in
            Task.detached(priority: .utility) {
                var bytes: Data?
                if let (data, response) = try? await URLSession.shared.data(from: url),
                   (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200) { bytes = data }
                let got = bytes
                await MainActor.run { done(got) }
            }
        }
    }

    /// A picture sent for once: kept when it comes (remembered as none when
    /// it's not one), the outlines styled again.
    private func picture(key: String, fetch: (@escaping (Data?) -> Void) -> Void) -> NSImage? {
        if let image = pictures.object(forKey: key as NSString) { return image }
        guard !notPictures.contains(key), fetchingPictures.insert(key).inserted else { return nil }
        fetch { [weak self] data in
            guard let self else { return }
            self.fetchingPictures.remove(key)
            guard let data, let image = NSImage(data: data), image.isValid else { self.notPictures.insert(key); return }
            self.pictures.setObject(image, forKey: key as NSString)
            for case let o as OutlineNoteView in self.views.values { o.picturesArrived() }
        }
        return nil
    }

    /// An image put in a note or a Markdown file: written on the text's
    /// host — beside the file, named so other Markdown readers find it, or
    /// in Manifold's own folder for a note — as an image block, and shown
    /// in the text where the caret was: `![](name)` beside a file,
    /// `![](manifold:…)` in a note. The text then embeds it (§3.6), a
    /// strong edge: the image is kept while a text shows it.
    func editor(_ view: EditorView, image data: Data, kind: String) {
        keepImage(data, kind: kind, for: view.block) { [weak view] markdown in view?.textView.insert(markdown, typing: false) }
    }

    /// An image dropped on a Markdown preview: kept as an editor keeps one,
    /// and shown at the end of the text.
    func markdownView(_ view: MarkdownView, image data: Data, kind: String) {
        let block = view.block
        keepImage(data, kind: kind, for: block) { [weak self] markdown in self?.append(markdown, to: block) }
    }

    /// Markdown dropped on a preview (a link, words), at the end of the
    /// text, the blocks it names linked from it.
    func markdownView(_ view: MarkdownView, append markdown: String, naming blocks: [BlockID]) {
        append(markdown, to: view.block)
        for b in blocks { link(b, to: view.block) }
    }

    /// Markdown put at the end of a text, a paragraph of its own.
    private func append(_ markdown: String, to block: BlockID) {
        guard let t = hosts.block(block)?.text else { return }
        let end = t.text.count
        let lead = t.text.string.hasSuffix("\n") || t.text.string.isEmpty ? "" : "\n"
        hosts.append(.edit([TextEdit(TextRange(end, end), lead + "\n" + markdown + "\n")]), to: .block(block))
    }

    /// An image kept for a text, on its host: written as an image block,
    /// then `insert` given the Markdown that shows it.
    /// A picture's name, kept: when, and a count when several come within
    /// the same second (pasted or dropped together).
    func newImageName(kind: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        imageCount += 1
        return "image-\(f.string(from: Date()))\(imageCount > 1 ? "-\(imageCount)" : "").\(kind == "jpeg" ? "jpg" : kind)"
    }

    func keepImage(_ data: Data, kind: String, for text: BlockID, insert: @escaping (String) -> Void) {
        guard let b = hosts.block(text), let c = hosts.client(text.host) else { return NSSound.beep() }
        let name = newImageName(kind: kind)
        let folder = b.path.map { $0.deletingLastPathComponent }
        let id = BlockID(host: text.host)
        var saved: String?
        Transfers.shared.run(name, detail: "into \(b.displayTitle)", symbol: "photo") { _, done in
            c.saveImage(data, block: id, name: name, folder: folder) { error, path in
                saved = path
                done(error)
            }
            return nil
        } then: { [weak self] error in
            let path = saved
            guard let self else { return }
            if let error { return self.toast.say("Couldn't keep the image: \(error)", .long) }
            let target = folder != nil
                ? (path?.lastPathComponent ?? name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                : "manifold:\(id.description)"
            insert("![](\(target))")
        }
    }

    /// A block dropped on a terminal: linked.
    func terminal(_ view: TerminalView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// What a block holds, as text (a drop's Contents, an agent's), or a
    /// place in it: a block still being made waited for (a few seconds at
    /// most); nil if it doesn't come or can't be read.
    func fetchContents(_ block: BlockID, at: Locator? = nil, _ done: @escaping (String?) -> Void) {
        Task { @MainActor [weak self] in
            for _ in 0..<40 where self?.hosts.block(block) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let self, let b = self.hosts.block(block) else { return done(nil) }
            self.give(b, at: at, done)
        }
    }

    /// A block's contents as text (a place's in it), for an agent.
    private func give(_ b: Block, at: Locator?, _ done: @escaping (String?) -> Void) {
        let shown = views.first { $0.value.block == b.id }?.value
        Task { @MainActor in
            do {
                done(try await maniDesk.contents(of: b, at: at, view: shown))
            } catch let e as ManiDesk.Failure {
                toast.say("Couldn't give “\(b.displayTitle)”: \(e.message)")
                done(nil)
            } catch { done(nil) }
        }
    }

    /// The host's last process listing, those under this terminal's shell;
    /// and a fresh listing asked for, so the next menu is current.
    func terminalProcesses(_ view: TerminalView, refresh: Bool) -> [ProcessEntry] {
        guard let client = hosts.client(view.block.host) else { return [] }
        let pb = client.node.blocks.first { $0.kind == .process }
        if refresh { hosts.propose(.processes(block: pb?.id ?? BlockID(host: client.host))) }
        return pb?.processes?.entries.filter { $0.block == view.block } ?? []
    }

    func terminal(_ view: TerminalView, signal pid: Int32, _ signal: Int32) {
        hosts.client(view.block.host)?.propose(.signal(pid: pid, signal: signal)) { [weak self] error in
            if let error { self?.window?.title = error }
        }
    }

    /// A link in the text clicked: a block's gone to; an address opened.
    func editor(_ view: EditorView, follow target: String, over: Bool) { open(target, from: view.placement, over: over) }

    /// A definition found (⌘-click): its file at its line, beside the
    /// editor — or, ⌘⌥-clicked, stacked over it.
    func editor(_ view: EditorView, open path: String, line: Int, column: Int, over: Bool) {
        let on = view.block.host
        pendingJump = (path, line, column)
        let block = hosts.textBlock(for: path, on: on)
        hosts.link(from: view.block, to: block, kind: .opened, context: view.lineAtCaret)
        show(block, lens: Lens.default(for: .text, path: path), opener(view.placement, over: over), context: view.lineAtCaret)
    }

    /// References as a search block: each place's line read from its file
    /// (this editor's own from its text, edits and all), the word marked.
    func editor(_ view: EditorView, references places: [LSPLocation], of word: String) {
        guard let client = hosts.client(view.block.host) else { return }
        let sorted = places.sorted { ($0.path == view.path ? 0 : 1, $0.path, $0.line) < ($1.path == view.path ? 0 : 1, $1.path, $1.line) }
        var paths: [String] = []
        for p in sorted where p.path != view.path && !paths.contains(p.path) { paths.append(p.path) }
        var lines: [String: [Substring]] = [:]
        let read = DispatchGroup()
        for path in paths.prefix(200) {
            read.enter()
            client.readBytes(path: path, limit: 4 << 20) { data in
                lines[path] = data.map { String(decoding: $0, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) }
                read.leave()
            }
        }
        read.notify(queue: .main) { [weak self, weak view] in
            guard let self, let view else { return }
            let text = view.textView.text
            let hits = sorted.map { p -> SearchHit in
                var line = ""
                if p.path == view.path, p.line < text.lineCount { line = text.lineText(p.line) }
                else if let file = lines[p.path], p.line < file.count { line = String(file[p.line]) }
                line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                return SearchHit(path: p.path, line: p.line + 1, column: p.character + 1, text: line.count > 400 ? String(line.prefix(400)) + "…" : line)
            }
            let root = self.projectRoot(from: view.path.deletingLastPathComponent, on: view.block.host)
            let id = BlockID(host: view.block.host)
            var q = SearchQuery(text: word, caseSensitive: true, root: root)
            q.relation = "references"
            q.symbolPath = view.path
            client.append([.create(kind: .search, title: "References to “\(word)”", path: nil),
                           .search(q, at: client.clock.now()),
                           .hits(hits, done: true, truncated: false, error: nil)], to: .block(id))
            self.show(id, lens: .search, .besideOpener(view.placement), context: "references to “\(word)”")
            // The index's name for it, when it has one: the browser can be
            // asked another way (its callers, its name as text).
            if let b = self.hosts.block(view.block) {
                let at = view.textView.primarySelection.head
                Task { @MainActor [weak self] in
                    guard let self, let s = try? await self.maniDesk.symbolAt(b, offset: at),
                          var now = self.hosts.block(id)?.search?.query, now == q else { return }
                    now.symbol = s.symbol
                    client.append([.search(now, at: client.clock.now()), .hits(hits, done: true, truncated: false, error: nil)], to: .block(id))
                }
            }
        }
    }

    /// A server's edits to other files on the block's host: files that are
    /// blocks through their logs (the server saw the block's text), the
    /// rest written on the host.
    func editor(_ view: EditorView, apply edits: [LSPFileEdit]) {
        let on = view.block.host
        guard let client = hosts.client(on) else { return }
        for f in edits {
            let ordered = f.edits.sorted { $0.start > $1.start }
            if let b = client.node.blocks.first(where: { $0.kind == .text && $0.path == f.path }), b.text != nil {
                client.append(.edit(ordered), to: .block(b.id))
            } else {
                client.propose(.editFile(path: f.path, edits: ordered))
            }
        }
    }
}

extension MainWindowController: MarkdownViewDelegate {
    /// A link followed in a preview: another Markdown file opens as a
    /// preview on top of the same stack (the one it was followed from
    /// stays beneath, to go back to); a web address as a web block beside;
    /// any other file as what it is, beside; other schemes with the system.
    func markdownView(_ view: MarkdownView, follow url: URL, modifiers: NSEvent.ModifierFlags) {
        guard let a = arrangement, let p = a.placement(view.placement) else { return }
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            let over = modifiers.contains(.option)
            // ⇧⌘: a file of this Mac to the system's app, as any link.
            if modifiers.isSuperset(of: [.command, .shift]), p.block.host == host.host {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return
            }
            if Lens.isMarkdown(path), !modifiers.contains(.command) {
                let block = hosts.textBlock(for: path, on: p.block.host)
                // Not "[[…]]": that's the mention scan's, which would take it for its own.
                hosts.link(from: p.block, to: block, kind: .opened, context: "followed in the preview")
                // Page to page in the same tile, as a browser goes — or,
                // with ⌥, the page over this one.
                if over { showOver(block, lens: .preview, over: view.placement) } else { goOn(view.placement, from: p.block, to: block, lens: .preview) }
            } else {
                open(path, from: view.placement, as: Disposition(modifiers))
            }
        } else {
            open(url.absoluteString, from: view.placement, as: Disposition(modifiers))
        }
    }
}

extension MainWindowController {
    func markdownView(_ view: MarkdownView, history direction: Int) -> Bool {
        walkTrail(view.placement, of: view.block, lens: .preview, direction)
    }
}
