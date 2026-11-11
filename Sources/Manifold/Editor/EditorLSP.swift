import AppKit
import ManifoldCore

/// What the editor gets from the block's language server (DESIGN.md §7.1):
/// diagnostics under the text and in the gutter, with the one at the caret
/// spelled out along the bottom; definitions by ⌘-click or ⌃⌘J; references,
/// documentation, renames and formatting; and completion on ⌃Space.
extension EditorView {
    private var caret: Int { textView.primarySelection.head }

    // MARK: Status line

    func updateStatus() {
        let c = caret
        let at = textView.diagnostics.first { $0.range.start <= c && c <= max($0.range.end, $0.range.start) }
        statusMessage = at.map { d in
            let what = switch d.level { case .error: "Error"; case .warning: "Warning"; default: "Note" }
            return "\(what): \(d.message.replacingOccurrences(of: "\n", with: " "))"
        }
    }

    /// The status's ground: its tint, half into the panel's.
    func paintStatus() {
        statusBox.layer?.backgroundColor = (statusTint.blended(withFraction: 0.5, of: Theme.panel) ?? Theme.panel).cgColor
    }

    func layoutStatus() {
        let message = loadingMessage ?? busyMessage ?? statusMessage
        guard let message else {
            if !statusBox.isHidden {
                statusBox.isHidden = true
                needsLayout = true
            }
            return
        }
        status.stringValue = message
        // Busy: the panel's own; else the diagnostic's, a note's for words of ours.
        let level: Diagnostic.Severity? = loadingMessage != nil || busyMessage != nil ? nil
            : textView.diagnostics.first { $0.range.start <= caret && caret <= max($0.range.end, $0.range.start) }?.level ?? .information
        let tint: NSColor = level.map { TextView.diagnosticColor($0).withAlphaComponent(0.12) } ?? Theme.panel
        // Themed once (each `themed` adds a hook for good), the tint kept.
        statusTint = tint
        if statusThemed {
            statusBox.effectiveAppearance.performAsCurrentDrawingAppearance { self.paintStatus() }
        } else {
            statusThemed = true
            statusBox.themed { [weak self] _ in self?.paintStatus() }
        }
        if statusBox.isHidden {
            statusBox.isHidden = false
            needsLayout = true
        }
    }

    // MARK: Asking

    private func ask(_ request: LSPRequest, busy: String, _ handle: @escaping (LSPResult) -> Void) {
        busyMessage = busy
        delegate?.editor(self, lsp: request) { [weak self] result in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["MANIFOLD_DEBUG"] != nil { NSLog("lsp %@ -> %@", "\(request)", String("\(result)".prefix(300))) }
            self.busyMessage = nil
            if case .error(let message) = result {
                self.flash(message)
                return
            }
            handle(result)
        }
    }

    /// A message along the bottom for a few seconds.
    func flash(_ message: String) {
        busyMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.busyMessage == message { self?.busyMessage = nil }
        }
    }

    @objc func goToDefinition(_ sender: Any?) { definition(at: caret) }

    /// `over`: what's found goes over this tile (⌘⌥-click) — said with
    /// the click, as the answer comes after it.
    func definition(at offset: Int, over: Bool = false) {
        ask(.definition(block, offset: offset), busy: "Looking for the definition…") { [weak self] result in
            guard let self, case .locations(let places) = result else { return }
            guard let place = places.first else { return self.flash("No definition found") }
            self.go(to: place, over: over)
        }
    }

    private func go(to place: LSPLocation, over: Bool) {
        if place.path == path {
            select(line: place.line + 1, column: place.character + 1)
        } else {
            delegate?.editor(self, open: place.path, line: place.line + 1, column: place.character + 1, over: over)
        }
    }

    /// Find References: a block of every place that uses the word at the
    /// caret, as a search's hits, beside this one — the language server's, else (none running, or it
    /// found none) the project's SCIP index's (§2.5), across its files.
    @objc func findReferences(_ sender: Any?) {
        let at = caret
        let word = textView.text[textView.wordRange(at: at)]
        busyMessage = "Looking for references…"
        delegate?.editor(self, lsp: .references(block, offset: at)) { [weak self] result in
            guard let self else { return }
            if case .locations(let places) = result, !places.isEmpty {
                self.busyMessage = nil
                return self.delegate?.editor(self, references: places, of: word) ?? ()
            }
            let why: String = if case .error(let m) = result { m } else { "No references found" }
            self.indexReferences(at: at, word: word, else: why)
        }
    }

    /// Code ▸ Index Project: the project the file is in indexed (SCIP,
    /// §2.5), on its host; said along the bottom as it goes and when done.
    @objc func indexProject(_ sender: Any?) {
        guard !path.isEmpty else { return NSSound.beep() }
        delegate?.editor(self, scip: .index(path: path)) { [weak self] result in
            guard let self else { return }
            guard case .status(let s) = result else {
                if case .error(let m) = result { self.flash(m) }
                return
            }
            self.busyMessage = "Indexing \(s.root?.lastPathComponent ?? "the project") with \(s.indexer ?? "its indexer")…"
            self.watchIndex()
        }
    }

    private func watchIndex(_ tries: Int = 1200) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.delegate?.editor(self, scip: .status(path: self.path)) { [weak self] result in
                guard let self, case .status(let s) = result else { return }
                switch s.state {
                case .indexing: if tries > 0 { self.watchIndex(tries - 1) }
                case .current: self.busyMessage = nil; self.flash("Indexed \(s.root?.lastPathComponent ?? "the project")")
                case .failed: self.busyMessage = nil; self.flash("Indexing failed: " + (s.reason ?? ""))
                case .none: self.busyMessage = nil
                }
            }
        }
    }

    /// References from the project's index; `why` said if it has none.
    private func indexReferences(at offset: Int, word: String, else why: String) {
        let rope = textView.text
        guard !path.isEmpty else { busyMessage = nil; return flash(why) }
        let line = rope.line(at: offset)
        delegate?.editor(self, scip: .symbol(path: path, line: line, byte: offset - rope.offset(ofLine: line))) { [weak self] result in
            guard let self else { return }
            guard case .symbol(let s?) = result else { self.busyMessage = nil; return self.flash(why) }
            self.delegate?.editor(self, scip: .references(symbol: s.symbol, path: self.path)) { [weak self] result in
                guard let self else { return }
                self.busyMessage = nil
                guard case .locations(let found) = result, !found.isEmpty else { return self.flash(why) }
                let places = found.map { LSPLocation(path: $0.path, line: $0.line, character: $0.character, endLine: $0.endLine, endCharacter: $0.endCharacter) }
                self.delegate?.editor(self, references: places, of: word)
            }
        }
    }

    @objc func showDocumentation(_ sender: Any?) {
        let at = caret
        ask(.hover(block, offset: at), busy: "Asking…") { [weak self] result in
            guard let self, case .hover(let text) = result else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return self.flash("Nothing known about this") }
            self.showHover(trimmed, at: at)
        }
    }

    private func showHover(_ text: String, at offset: Int) {
        hover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let label = NSTextField(wrappingLabelWithString: Self.plainMarkdown(text))
        label.font = theme.font(.monospaced, size: 12)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 520
        let size = label.sizeThatFits(NSSize(width: 520, height: 400))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: min(size.width, 520) + 24, height: min(size.height, 400) + 20))
        label.frame = NSRect(x: 12, y: 10, width: view.frame.width - 24, height: view.frame.height - 20)
        view.addSubview(label)
        vc.view = view
        popover.contentViewController = vc
        let r = textView.convert(textView.caretRectInWindow(offset), from: nil)
        popover.show(relativeTo: r, of: textView, preferredEdge: .maxY)
        hover = popover
    }

    /// Markdown as servers send it, read plainly: code fences and the
    /// commonest marks dropped.
    static func plainMarkdown(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasPrefix("```") { continue }
            if line.hasPrefix("---") && line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" }) { line = "" }
            line = line.replacingOccurrences(of: "**", with: "")
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    @objc func renameSymbol(_ sender: Any?) {
        guard let window else { return }
        let at = caret
        let word = textView.text[textView.wordRange(at: at)]
        guard !word.isEmpty else { return flash("Nothing to rename here") }
        let alert = NSAlert()
        alert.messageText = "Rename “\(word)”"
        alert.informativeText = "Everywhere the language server knows it, in every file."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = word
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != word else { return }
            self.rename(at: at, to: name)
        }
    }

    func rename(at offset: Int, to name: String) {
        ask(.rename(block, offset: offset, newName: name), busy: "Renaming…") { [weak self] result in
            guard let self, case .edits(let files) = result else { return }
            self.apply(files)
        }
    }

    @objc func formatDocument(_ sender: Any?) {
        ask(.format(block, tabSize: textView.tabWidth), busy: "Formatting…") { [weak self] result in
            guard let self, case .edits(let files) = result else { return }
            self.apply(files)
        }
    }

    /// Edits from the server: this file's through the view (so they undo),
    /// the rest through the delegate.
    private func apply(_ files: [LSPFileEdit]) {
        var others: [LSPFileEdit] = []
        for f in files {
            if f.path == path {
                let count = textView.text.count
                let edits = f.edits.filter { $0.start <= count }.map { (TextRange($0.start, min($0.end, count)), $0.text) }
                let keep = textView.selections
                textView.replace(edits, selectAfter: keep)
            } else {
                others.append(f)
            }
        }
        if !others.isEmpty { delegate?.editor(self, apply: others) }
        let n = files.reduce(0) { $0 + $1.edits.count }
        flash(n == 0 ? "Nothing to change" : "\(n) change\(n == 1 ? "" : "s") in \(files.count) file\(files.count == 1 ? "" : "s")")
    }

    // MARK: Completion

    @objc func completeSymbol(_ sender: Any?) {
        let at = caret
        let word = textView.wordRange(at: at)
        let prefixRange = TextRange(word.start, at)
        ask(.completion(block, offset: at), busy: "Completing…") { [weak self] result in
            guard let self, case .completions(let items) = result else { return }
            guard !items.isEmpty else { return self.flash("No completions") }
            self.showCompletions(items, replacing: prefixRange)
        }
    }

    private func showCompletions(_ items: [Completion], replacing range: TextRange) {
        completion?.close()
        let popup = CompletionPopup(items: items, start: range.start, font: theme.font(.monospaced, size: 12.5))
        popup.onChoose = { [weak self] item in
            guard let self else { return }
            let end = self.caret
            let r = TextRange(range.start, max(range.start, end))
            self.textView.replace([(r, item.insert)])
            self.completion?.close()
            self.completion = nil
        }
        popup.onClose = { [weak self] in self?.completion = nil }
        completion = popup
        completionTextChanged()
        popup.show(for: textView, at: range.start)
    }

    /// The text changed under the popup: it narrows to what's typed, and
    /// goes when the caret leaves the word.
    func completionTextChanged() {
        guard let completion else { return }
        let end = caret
        guard end >= completion.start, textView.text.line(at: end) == textView.text.line(at: completion.start) else {
            completion.close()
            return
        }
        let typed = textView.text[TextRange(completion.start, end)]
        completion.filter(typed)
        if completion.isEmpty { completion.close() }
    }

    func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard let completion else { return false }
        return completion.handle(event)
    }
}

extension EditorView {
    func textView(_ view: TextView, handle event: NSEvent) -> Bool {
        if handleCompletionKey(event) { return true }
        // Back in time (read-only): [ and ] a commit older or newer, ⎋ the
        // history closed, back to now.
        if scrubbed, event.keyMods.isEmpty {
            switch event.charactersIgnoringModifiers {
            case "[": olderRevision(nil); return true
            case "]": newerRevision(nil); return true
            case "\u{1b}": closeFileHistory(); return true
            default: break
            }
        }
        // ⌃G: Go to Line, as code editors have it (⌘L too) — editing or
        // viewing. Here, not the menu's: a terminal keeps its ⌃G.
        if event.keyMods == .control,
           event.charactersIgnoringModifiers == "g" {
            goToLine(nil)
            return true
        }
        return false
    }
    func textView(_ view: TextView, mentioned block: BlockID) { delegate?.editor(self, linkedFrom: block) }
    func textView(_ view: TextView, follow target: String, over: Bool) { delegate?.editor(self, follow: target, over: over) }

    /// ⌘-right-click: a link there, what can be done with it (each way
    /// ⌘-click opens it, copied, its folder); a name in code, where it
    /// goes — its definition, as ⌘-click and ⌥⌘-click go, its references,
    /// callers, documentation, its uses — and its name copied.
    func textView(_ view: TextView, commandMenuAt offset: Int, link: String?) -> NSMenu? {
        if let target = link ?? linkAt(offset) { return delegate?.editor(self, menuForLink: target) }
        guard textView.syntaxLanguage != nil, !textView.markdown else { return nil }
        let word = textView.wordRange(at: offset)
        guard !word.isEmpty else { return nil }
        let name = String(textView.text[word])
        // As the other code items act at the caret: the caret on the name.
        textView.setSelections([Selection(at: offset)], scroll: false)
        window?.makeFirstResponder(textView)
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, click: String? = nil, _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title, symbol: symbol, run)
            if let click, #available(macOS 14.4, *) { i.subtitle = click }
            menu.addItem(i)
        }
        item("Go to Definition", "arrow.up.forward.square", click: "⌘-click") { [weak self] in self?.definition(at: offset) }
        item("Go to Definition Over", "square.on.square", click: "⌥⌘-click") { [weak self] in self?.definition(at: offset, over: true) }
        item("Peek Definition", "eye") { [weak self] in self?.peekDefinition(at: offset) }
        menu.addItem(.separator())
        for (title, symbol, action) in [("Find References", "magnifyingglass", #selector(EditorView.findReferences(_:))),
                                        ("Show Callers", "arrow.turn.down.left", #selector(MainWindowController.showCallers(_:))),
                                        ("Show Documentation", "doc.text", #selector(EditorView.showDocumentation(_:))),
                                        ("Highlight Uses", "highlighter", #selector(TextView.highlightUses(_:)))] {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.setSymbol(symbol, size: 12)
            menu.addItem(i)
        }
        menu.addItem(.separator())
        item("Copy Name", "doc.on.doc") { NSPasteboard.copy(name) }
        let line = textView.text.line(at: offset) + 1
        let file = path.isEmpty ? (noteName ?? "this note") : (path as NSString).lastPathComponent
        delegate?.editor(self, aboutItems: LinkSubject(place: Place(block: block, at: .range(word), name: name),
                                                       label: name, forAgent: "`\(name)` (\(path.isEmpty ? file : path):\(line))", address: nil,
                                                       cwd: path.isEmpty ? nil : (path as NSString).deletingLastPathComponent), to: menu)
        return menu
    }

    /// ⌘-pressed and dragged: a link there, what it goes to; a name in
    /// code, a reference to it here (as its name selected and dragged).
    func textView(_ view: TextView, dragCommandAt offset: Int, link: String?) -> (writer: NSPasteboardWriting, label: String)? {
        if let target = link ?? linkAt(offset) {
            return LinkMenus.drag?(target, nil, block.host).map { ($0, target) }
        }
        guard textView.syntaxLanguage != nil, !textView.markdown else { return nil }
        let word = textView.wordRange(at: offset)
        guard !word.isEmpty else { return nil }
        let name = String(textView.text[word])
        return Drags.place?(Place(block: block, at: .range(word), name: name), name).map { ($0, name) }
    }

    /// Peek Definition: where the name at `offset` is defined, a few lines
    /// of it, in a card by the name — not gone to.
    func peekDefinition(at offset: Int) {
        ask(.definition(block, offset: offset), busy: "Looking for the definition…") { [weak self] result in
            guard let self, case .locations(let places) = result else { return }
            guard let place = places.first else { return self.flash("No definition found") }
            let show = { [weak self] (text: String?) in
                guard let self, let text else { return self?.flash("Couldn't read the definition") ?? () }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                let from = max(0, place.line - 1), to = min(lines.count, place.line + 15)
                guard from < to else { return self.flash("Couldn't read the definition") }
                let snippet = lines[from..<to].joined(separator: "\n")
                self.showPeek(snippet, title: "\((place.path as NSString).lastPathComponent):\(place.line + 1)", at: offset) { [weak self] in
                    self?.go(to: place, over: false)
                }
            }
            if place.path == self.path { return show(self.textView.text.string) }
            self.delegate?.editor(self, read: place.path, done: show)
        }
    }

    /// A definition peeked at: its lines, in the code's font, under a line
    /// naming where they are, which clicked goes there.
    private func showPeek(_ code: String, title: String, at offset: Int, go: @escaping () -> Void) {
        debugLastPeek = title + "\n" + code
        hover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let head = FlatButton(title, symbol: "arrow.up.forward.square", font: UIType.detail)
        let action = ClosureMenuItem("", { go(); popover.close() })
        head.target = action
        head.action = action.action
        let label = NSTextField(labelWithString: code)
        label.font = theme.font(.monospaced, size: 12)
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        let size = label.sizeThatFits(NSSize(width: 640, height: 420))
        let w = min(max(size.width, head.intrinsicContentSize.width), 640) + 24, h = min(size.height, 420)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h + 46))
        head.frame = NSRect(x: 8, y: h + 16, width: head.intrinsicContentSize.width, height: 22)
        label.frame = NSRect(x: 12, y: 10, width: w - 24, height: h)
        view.addSubview(head)
        view.addSubview(label)
        vc.view = view
        objc_setAssociatedObject(view, "manifold.peek.go", action, .OBJC_ASSOCIATION_RETAIN)
        popover.contentViewController = vc
        let r = textView.convert(textView.caretRectInWindow(offset), from: nil)
        popover.show(relativeTo: r, of: textView, preferredEdge: .maxY)
        hover = popover
    }

    func textView(_ view: TextView, commandClickAt offset: Int, over: Bool) {
        if let target = linkAt(offset) { delegate?.editor(self, follow: target, over: over); return }
        definition(at: offset, over: over)
    }

    /// What's under an offset to go to before a definition: an address (a
    /// web link, a block's reference), or a file named with its line as a
    /// compiler or a log names one (`main.c:12`), as a terminal's is.
    func linkAt(_ offset: Int) -> String? {
        let text = textView.text
        guard text.lineCount > 0 else { return nil }
        let n = text.line(at: offset)
        let start = text.offset(ofLine: n)
        let line = text.lineText(n)
        let before = String(decoding: text.bytes(in: TextRange(start, offset)), as: UTF8.self)
        if let found = TextLinks.address(at: before.utf16.count, in: line) { return found.address }
        if let file = TerminalLinks.link(at: before.unicodeScalars.count, in: line), file.standing != .possible,
           FileLocation.split(file.target)?.line != nil {
            return file.target
        }
        return nil
    }
    func textViewRequestsCompletion(_ view: TextView) { completeSymbol(nil) }

    /// The selection dragged: its words, and a reference to what it names
    /// (§2.5) — the declaration, else the stretch — a symbol into an agent.
    func textView(_ view: TextView, dragSelection range: TextRange, text: String) -> NSPasteboardWriting? {
        Drags.place?(Place(block: block, at: .range(range)), text)
    }

    /// Peek: what the name the pointer rests on is — the language server's
    /// hover (its signature, its documentation), else the project's
    /// index's — under it, while the pointer stays.
    func textView(_ view: TextView, peekAt word: TextRange, in rect: NSRect) {
        let show = { [weak self] (markdown: String) in
            guard let self, let window = self.window, self.textView.stillPeeking(at: word) else { return }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let body = self.theme.technicalFont(size: 12.5)
            let content = MarkdownText.attributed(String(trimmed.prefix(1500)), font: body, code: self.theme.font(.monospaced, size: 12))
            PeekTip.shared.show(content, under: rect, in: window)
        }
        let index = { [weak self] (answer: @escaping (String) -> Void) in
            guard let self, !self.path.isEmpty else { return }
            let rope = self.textView.text, line = rope.line(at: word.start)
            self.delegate?.editor(self, scip: .symbol(path: self.path, line: line, byte: word.start - rope.offset(ofLine: line))) { result in
                guard case .symbol(let s?) = result else { return }
                // Its definition's line (its signature, mostly), then what's said of it.
                var md = ""
                if let d = s.definition { md = "```\n\(d.text)\n```\n" }
                md += s.documentation.isEmpty ? (s.definition.map { $0.path.lastPathComponent + ":\($0.line + 1)" } ?? "") : s.documentation
                answer(md)
            }
        }
        // Both asked at once: the index answers at once, a language server
        // (starting, busy) may take a while — its answer, when it comes, in
        // place of the index's.
        var serverAnswered = false
        delegate?.editor(self, lsp: .hover(block, offset: word.start)) { result in
            guard case .hover(let text) = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            serverAnswered = true
            show(text)
        }
        index { if !serverAnswered { show($0) } }
    }

    /// The symbol at a place's uses in this text, as its language server
    /// highlights them; nil if there's no server or it doesn't say.
    func textView(_ view: TextView, usesAt offset: Int, _ done: @escaping ([TextRange]?) -> Void) {
        guard let delegate else { return done(nil) }
        delegate.editor(self, lsp: .highlights(block, offset: offset)) { result in
            guard case .ranges(let r) = result, !r.isEmpty else { return done(nil) }
            done(r)
        }
    }

    /// A gutter's line dragged: a reference to its place (§2.5) — what an
    /// outline's item carries, its line made an anchor by the window.
    func textView(_ view: TextView, dragLine line: Int) -> NSPasteboardWriting? {
        Drags.place?(Place(block: block, at: .line(line + 1), name: view.text.lineText(line).trimmingCharacters(in: .whitespaces)), nil)
    }
}

/// Completions, in a small window under the caret: typing narrows them,
/// ↑↓ choose, ⏎ or ⇥ takes one, ⎋ dismisses.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let start: Int
    var onChoose: ((Completion) -> Void)?
    var onClose: (() -> Void)?
    private let all: [Completion]
    private var shown: [Completion] = []
    private let window: NSWindow
    private let table = NSTableView()
    private let font: NSFont
    private var closed = false
    /// Over the caret, for want of room under it: it shrinks toward it.
    private var above = false

    var isEmpty: Bool { shown.isEmpty }

    init(items: [Completion], start: Int, font: NSFont) {
        self.all = items
        self.start = start
        self.font = font
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        let box = NSView(frame: window.contentView!.bounds)
        Flat.float(box, shadow: false)
        box.layer?.masksToBounds = true
        box.autoresizingMask = [.width, .height]
        let scroll = ClippingScrollView(frame: box.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = 340
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        scroll.documentView = table
        box.addSubview(scroll)
        window.contentView?.addSubview(box)
    }

    func show(for view: TextView, at offset: Int) {
        guard let parent = view.window, !closed else { return }
        let placed = CaretPopup.frame(width: window.frame.width, height: window.frame.height, by: view.caretRectInWindow(offset), in: parent,
                                      above: false, gap: 0, lead: 8)
        above = placed.above
        window.setFrame(placed.frame, display: false)
        parent.addChildWindow(window, ordered: .above)
    }

    func filter(_ typed: String) {
        let t = typed.lowercased()
        shown = t.isEmpty ? all : all.filter { $0.label.lowercased().contains(t) }
            .sorted { a, b in
                let ap = a.label.lowercased().hasPrefix(t), bp = b.label.lowercased().hasPrefix(t)
                return ap != bp ? ap : a.label.count < b.label.count
            }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        // The edge by the caret kept where it is.
        let height = min(CGFloat(shown.count) * table.rowHeight + 8, 200)
        let y = above ? window.frame.minY : window.frame.maxY - height
        window.setFrame(NSRect(x: window.frame.minX, y: y, width: window.frame.width, height: height), display: true)
    }

    func handle(_ event: NSEvent) -> Bool {
        guard !closed, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let key = chars.unicodeScalars.first!.value
        switch Int(key) {
        case NSUpArrowFunctionKey: move(-1); return true
        case NSDownArrowFunctionKey: move(1); return true
        case 0x0D, 0x09: choose(); return true
        case 0x1B: close(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) { CaretPopup.move(table, by: delta, count: shown.count) }

    private func choose() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return close() }
        onChoose?(shown[row])
    }

    @objc private func doubleClicked() { choose() }

    func close() {
        guard !closed else { return }
        closed = true
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        onClose?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let cell = NSTextField(labelWithString: "")
        let s = NSMutableAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: Theme.text])
        if let d = item.detail, !d.isEmpty {
            s.append(NSAttributedString(string: "  " + d, attributes: [.font: font.withSize(font.pointSize - 1), .foregroundColor: Theme.secondaryText]))
        }
        cell.attributedStringValue = s
        cell.lineBreakMode = .byTruncatingTail
        let wrap = NSView()
        cell.frame = NSRect(x: 10, y: 2, width: 320, height: 18)
        cell.autoresizingMask = [.width]
        wrap.addSubview(cell)
        return wrap
    }
}
