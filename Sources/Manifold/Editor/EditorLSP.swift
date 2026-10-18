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
            let what = d.severity == 1 ? "Error" : d.severity == 2 ? "Warning" : "Note"
            return "\(what): \(d.message.replacingOccurrences(of: "\n", with: " "))"
        }
    }

    func layoutStatus() {
        let message = busyMessage ?? statusMessage
        guard let message else {
            if !statusBox.isHidden {
                statusBox.isHidden = true
                needsLayout = true
            }
            return
        }
        status.stringValue = message
        let severity = busyMessage != nil ? 0 : (textView.diagnostics.first { $0.range.start <= caret && caret <= max($0.range.end, $0.range.start) }?.severity ?? 3)
        let tint: NSColor = severity == 0 ? Theme.panel : TextView.diagnosticColor(severity).withAlphaComponent(0.12)
        statusBox.themed { v in
            v.layer?.backgroundColor = (tint.blended(withFraction: 0.5, of: Theme.panel) ?? Theme.panel).cgColor
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

    func definition(at offset: Int) {
        ask(.definition(block, offset: offset), busy: "Looking for the definition…") { [weak self] result in
            guard let self, case .locations(let places) = result else { return }
            guard let place = places.first else { return self.flash("No definition found") }
            self.go(to: place)
        }
    }

    private func go(to place: LSPLocation) {
        if place.path == path {
            select(line: place.line + 1, column: place.character + 1)
        } else {
            delegate?.editor(self, open: place.path, line: place.line + 1, column: place.character + 1)
        }
    }

    @objc func findReferences(_ sender: Any?) {
        let at = caret
        ask(.references(block, offset: at), busy: "Looking for references…") { [weak self] result in
            guard let self, case .locations(let places) = result else { return }
            guard !places.isEmpty else { return self.flash("No references found") }
            self.showPlaces(places, at: at)
        }
    }

    /// Places, in a menu at the caret: one is chosen to go there.
    private func showPlaces(_ places: [LSPLocation], at offset: Int) {
        let menu = NSMenu()
        let home = NSHomeDirectory()
        for place in places.prefix(60) {
            var shown = place.path
            if shown.hasPrefix(path.deletingLastPathComponent + "/") { shown = String(shown.dropFirst(path.deletingLastPathComponent.count + 1)) }
            else if shown.hasPrefix(home) { shown = "~" + shown.dropFirst(home.count) }
            let item = NSMenuItem(title: "\(shown):\(place.line + 1)", action: #selector(placeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = place
            if place.path == path {
                let lineText = textView.text.lineText(min(place.line, textView.text.lineCount - 1)).trimmingCharacters(in: .whitespaces)
                if !lineText.isEmpty {
                    let a = NSMutableAttributedString(string: item.title + "   ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                    a.append(NSAttributedString(string: String(lineText.prefix(60)), attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
                    item.attributedTitle = a
                }
            }
            menu.addItem(item)
        }
        if places.count > 60 { menu.addItem(NSMenuItem(title: "\(places.count - 60) more…", action: nil, keyEquivalent: "")) }
        let r = textView.caretRectInWindow(offset)
        let p = textView.convert(NSPoint(x: r.minX, y: r.maxY), from: nil)
        menu.popUp(positioning: nil, at: p, in: textView)
    }

    @objc private func placeChosen(_ sender: NSMenuItem) {
        guard let place = sender.representedObject as? LSPLocation else { return }
        go(to: place)
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
    func textView(_ view: TextView, handle event: NSEvent) -> Bool { handleCompletionKey(event) }
    func textView(_ view: TextView, commandClickAt offset: Int) { definition(at: offset) }
    func textViewRequestsCompletion(_ view: TextView) { completeSymbol(nil) }
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
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.masksToBounds = true
        box.autoresizingMask = [.width, .height]
        box.themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        let scroll = NSScrollView(frame: box.bounds)
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
        let r = view.caretRectInWindow(offset)
        var origin = parent.convertToScreen(NSRect(origin: NSPoint(x: r.minX - 8, y: r.minY), size: .zero)).origin
        origin.y -= window.frame.height
        if let screen = parent.screen, origin.y < screen.visibleFrame.minY {
            origin.y = parent.convertToScreen(NSRect(origin: NSPoint(x: r.minX, y: r.maxY), size: .zero)).origin.y
        }
        window.setFrameOrigin(origin)
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
        let height = min(CGFloat(shown.count) * table.rowHeight + 8, 200)
        let top = window.frame.maxY
        window.setFrame(NSRect(x: window.frame.minX, y: top - height, width: window.frame.width, height: height), display: true)
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

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

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
