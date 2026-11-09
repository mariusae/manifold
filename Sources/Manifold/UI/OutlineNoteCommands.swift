import AppKit
import ManifoldCore

// The outliner's commands beyond typing (§7.9), as Prism's outline has
// them: rows duplicated, typed anew, turned into another kind; checkboxes
// and their done ones sunk; folds all the way; the selection grown a step
// at a time; inline Markdown put round words; a row focused on, the rest of
// the note set aside; and each of them on a row's menu.

/// A row focused on (Focus In), as Bike has it: it and what's under it
/// shown as if they were the whole note, the rest set aside as it was until
/// the focus is left. Edits in focus are the note's: written, it is whole,
/// the rows set aside round those shown.
struct NoteOutlineFocus {
    /// The note's rows before those shown, and after, as they were.
    var before: [NoteRow]
    var after: [NoteRow]
    /// How far in the focused row is: those shown are that much less deep.
    var shift: Int
    /// The rows it is in, outermost first: their words, and where each is
    /// among the note's rows.
    var ancestors: [(text: String, index: Int)]
}

/// A selection, as Expand Selection steps through them.
struct OutlineSelection: Equatable {
    var range: NSRange
    var rows: Range<Int>?
}

/// What was folded, kept across the note being read again (an edit from
/// elsewhere): each fold by its place among all the rows and its words,
/// found again at the nearest row with those words.
enum NoteOutlineFolds {
    static func marks(_ rows: [NoteRow]) -> [(index: Int, text: String)] {
        var marks: [(Int, String)] = []
        var at = 0
        func walk(_ rows: [NoteRow]) {
            for row in rows {
                if row.isFolded { marks.append((at, row.text)) }
                at += 1
                walk(row.folded)
            }
        }
        walk(rows)
        return marks
    }

    /// The marks folded again in rows read anew (none folded).
    static func apply(_ marks: [(index: Int, text: String)], to rows: inout [NoteRow]) {
        let found = Set(marks.compactMap { nearest($0.text, to: $0.index, in: rows) })
        // From the last, so each fold takes those inside it folded already.
        for index in found.sorted(by: >) where index < rows.count { NoteOutlineEditing.fold(&rows, at: index) }
    }

    /// The row with those words nearest a place, if any is within reach.
    static func nearest(_ text: String, to index: Int, in rows: [NoteRow]) -> Int? {
        guard !rows.isEmpty else { return nil }
        for distance in 0..<max(rows.count, 1) {
            for i in [index - distance, index + distance] where rows.indices.contains(i) && rows[i].text == text { return i }
            if index - distance < 0, index + distance >= rows.count { break }
        }
        return nil
    }
}

/// The path from the note to the row focused on, over its rows — each step
/// a way back — or, for a note the outline only shows, why.
final class NoteOutlinePath: NSView {
    static let height: CGFloat = 24
    /// A step clicked: nil for the whole note, else a row among the note's.
    var onStep: ((Int?) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    private var font: NSFont = UIType.caption

    func show(note: String, ancestors: [(text: String, index: Int)], fontSize: CGFloat) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        font = NSFont.systemFont(ofSize: round(fontSize * 0.82), weight: .medium)
        let name = Self.plain(note)
        stack.addArrangedSubview(step(name, symbol: "chevron.left", index: nil))
        // The note's own title heading is the note, already first.
        for (i, ancestor) in ancestors.enumerated() {
            let text = Self.plain(ancestor.text)
            guard !text.isEmpty, !(i == 0 && text.caseInsensitiveCompare(name) == .orderedSame) else { continue }
            let separator = NSTextField.label("›", font: font, color: Theme.tertiaryText)
            stack.addArrangedSubview(separator)
            stack.addArrangedSubview(step(text, symbol: nil, index: ancestor.index))
        }
        needsLayout = true
    }

    func showReadOnly() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField.label("Read only: this note's Markdown has shapes an outline can't write back as they are — Edit as Text (⌥⌘↩) to change it", font: UIType.caption, color: Theme.secondaryText)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)
        needsLayout = true
    }

    private func step(_ title: String, symbol: String?, index: Int?) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(stepped(_:)))
        button.isBordered = false
        button.font = font
        button.contentTintColor = Theme.secondaryText
        button.tag = index ?? -1
        button.lineBreakMode = .byTruncatingTail
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .semibold))
            button.imagePosition = .imageLeading
        }
        button.toolTip = index == nil ? "Unfocus: the whole note" : "Focus on “\(title)”"
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// Words as they read: a link by its text, not its brackets.
    static func plain(_ text: String) -> String {
        InlineMarkup.plainText(text).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
    }

    @objc private func stepped(_ sender: NSButton) { onStep?(sender.tag < 0 ? nil : sender.tag) }

    var debugState: String {
        stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title ?? ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
    }
}

extension NoteOutlineTextView {
    // MARK: Focus

    /// The note's rows: those shown, and, in focus, those set aside round
    /// them. What is written.
    var fullRows: [NoteRow] {
        guard let focus else { return rows }
        return focus.before + rows.map { var row = $0; row.depth += focus.shift; return row } + focus.after
    }

    /// Where a row shown is among the note's rows.
    func fullIndex(of index: Int) -> Int { (focus?.before.count ?? 0) + index }

    /// ⌃⌥⌘→, or ⌥-click a bullet: the row and what's under it, alone.
    @objc func focusIn(_ sender: Any?) {
        let index = selectedRows?.lowerBound ?? rowIndex(at: selectedRange().location)
        // Already the focused row, alone: nothing further in.
        guard focus == nil || index > 0 || paragraphRanges.count > 1 else { return NSSound.beep() }
        focusOn(fullRow: fullIndex(of: index))
    }

    /// ⌃⌥⌘←: the row it's in focused on — at the top, the whole note.
    @objc func focusOut(_ sender: Any?) {
        guard let focus else { return NSSound.beep() }
        if let parent = focus.ancestors.last { focusOn(fullRow: parent.index, caretOnFullRow: focus.before.count) } else { unfocus(sender) }
    }

    @objc func unfocus(_ sender: Any?) {
        guard let focus else { return }
        let caret = caretPosition
        let all = fullRows
        self.focus = nil
        load(all, keepingCaret: false)
        restoreCaret(CaretPosition(row: focus.before.count + caret.row, offset: caret.offset))
        scrollRangeToVisible(selectedRange())
        onFocusChange?()
    }

    /// A row of the note focused on (by its place among all the rows), the
    /// caret on another of them if it's shown, else at the row's end.
    func focusOn(fullRow index: Int, caretOnFullRow caretRow: Int? = nil) {
        if selectedRows != nil { leaveRowSelection() }
        var all = fullRows
        guard all.indices.contains(index) else { return }
        // A folded row opened: what's in it is what's focused on.
        if all[index].isFolded { NoteOutlineEditing.unfold(&all, at: index) }
        let block = NoteOutlineEditing.block(all, index..<(index + 1))
        let shift = all[index].depth
        // The rows whose blocks hold it — list parents, the headings whose
        // sections it's in — nearest last.
        let levels = NoteOutlineEditing.levels(all)
        var ancestors: [(text: String, index: Int)] = []
        var level = levels[index]
        for i in stride(from: index - 1, through: 0, by: -1) where levels[i] < level {
            ancestors.insert((all[i].text, i), at: 0)
            level = levels[i]
        }
        let shown = all[block].map { var row = $0; row.depth -= shift; return row }
        focus = NoteOutlineFocus(before: Array(all[..<block.lowerBound]), after: Array(all[block.upperBound...]), shift: shift, ancestors: ancestors)
        load(shown, keepingCaret: false)
        if let caretRow, block.contains(caretRow) {
            restoreCaret(CaretPosition(row: caretRow - block.lowerBound, offset: 0))
        } else {
            restoreCaret(CaretPosition(row: 0, offset: (shown[0].text as NSString).length))
        }
        scrollRangeToVisible(NSRange(location: 0, length: 0))
        onFocusChange?()
    }

    // MARK: Rows

    /// Outline ▸ New Row: one after the rows, to write in.
    @objc func newRow(_ sender: Any?) {
        let index = targetRows.upperBound - 1
        editText(inRow: index)
        splitRow()
    }

    /// ⇧⌘D (Duplicate Line): the rows and what's under them, again, after them.
    @objc func duplicateLine(_ sender: Any?) { perform("Duplicate") { NoteOutlineEditing.duplicate(&$0, $1) } }
    /// ⇧⌘K (Delete Line): the rows and what's under them.
    @objc func deleteLine(_ sender: Any?) { deleteRows(sender) }
    /// ⌃⌘↑ ⌃⌘↓ (Move Line Up, Down): among their siblings.
    @objc func moveLineUp(_ sender: Any?) { moveRowsUp(sender) }
    @objc func moveLineDown(_ sender: Any?) { moveRowsDown(sender) }

    /// A task: round, `+ [ ]` — open, checked, then a bullet again.
    @objc func cycleTask(_ sender: Any?) {
        perform("Task") { rows, selection in
            NoteOutlineEditing.cycle(.task, &rows, selection)
            return selection
        }
    }

    /// ⌃⇧⌘D: a list's done items below the rest (or, with none there, the
    /// row's own children's).
    @objc func moveDoneToBottom(_ sender: Any?) {
        perform("Move Done to Bottom") { rows, selection in
            NoteOutlineEditing.moveDoneToBottom(&rows, at: selection.lowerBound).map { $0..<($0 + selection.count) }
        }
    }

    @objc func collapseCompletely(_ sender: Any?) { fold(name: "Collapse Completely") { rows, i in -NoteOutlineEditing.foldCompletely(&rows, at: i) } }
    @objc func expandCompletely(_ sender: Any?) { fold(name: "Expand Completely") { rows, i in NoteOutlineEditing.unfold(&rows, at: i, completely: true) } }

    /// What a row can be turned into.
    enum RowType: CaseIterable {
        case bullet, checklist, task, ordered, heading1, heading2, heading3, quote, paragraph

        var title: String {
            switch self {
            case .bullet: "Bullet"
            case .checklist: "Checkbox"
            case .task: "Task"
            case .ordered: "Numbered"
            case .heading1: "Heading 1"
            case .heading2: "Heading 2"
            case .heading3: "Heading 3"
            case .quote: "Quote"
            case .paragraph: "Paragraph"
            }
        }

        func holds(_ row: NoteRow) -> Bool {
            switch self {
            case .bullet: row.kind == .bullet && row.task == nil
            case .checklist: row.kind == .bullet && row.task != nil && row.marker != "+"
            case .task: row.kind == .bullet && row.task != nil && row.marker == "+"
            case .ordered: row.kind == .ordered
            case .heading1: row.kind == .heading(1)
            case .heading2: row.kind == .heading(2)
            case .heading3: row.kind == .heading(3)
            case .quote: row.kind == .quote
            case .paragraph: row.kind == .paragraph
            }
        }
    }

    /// The rows turned into a kind (code and rules left as they are).
    func setRowType(_ type: RowType) {
        perform("Change Row Type") { rows, selection in
            var number = 0
            for index in selection {
                var row = rows[index]
                guard row.kind != .code, row.kind != .rule else { continue }
                row.spacing = 1
                switch type {
                case .bullet: row.kind = .bullet; row.marker = "-"; row.task = nil
                case .checklist: row.kind = .bullet; row.marker = row.marker == "*" ? "*" : "-"; row.task = row.task ?? .open
                case .task: row.kind = .bullet; row.marker = "+"; row.task = row.task ?? .open
                case .ordered:
                    // Counted on from the first, down the rows turned.
                    if row.kind != .ordered { number += 1; row.number = number } else { number = row.number }
                    row.kind = .ordered; row.marker = "."; row.task = nil
                case .heading1: row.kind = .heading(1); row.task = nil
                case .heading2: row.kind = .heading(2); row.task = nil
                case .heading3: row.kind = .heading(3); row.task = nil
                case .quote: row.kind = .quote; row.task = nil
                case .paragraph: row.kind = .paragraph; row.task = nil
                }
                rows[index] = row
            }
            NoteOutlineEditing.normalize(&rows)
            return selection
        }
    }

    @objc func turnInto(_ sender: NSMenuItem) {
        guard RowType.allCases.indices.contains(sender.tag) else { return }
        setRowType(RowType.allCases[sender.tag])
    }

    /// ⇧⌘8: list items plain rows again; plain rows bullets.
    @objc func toggleBullet(_ sender: Any?) {
        perform("Bullet") { rows, selection in
            if selection.allSatisfy({ rows[$0].kind.isListItem }) {
                for i in selection { rows[i].kind = .paragraph; rows[i].task = nil }
            } else {
                for i in selection where rows[i].kind == .paragraph { rows[i].kind = .bullet; rows[i].marker = "-"; rows[i].spacing = 1 }
            }
            NoteOutlineEditing.normalize(&rows)
            return selection
        }
    }

    /// ⌥⌘-: a line across after the row (an empty row, or one of only a
    /// line's marks, becomes it), a row after that to write in.
    @objc func insertHorizontalLine(_ sender: Any?) {
        let index = targetRows.lowerBound
        let row = rows[index]
        if row.text.trimmingCharacters(in: .whitespaces).isEmpty || ["---", "***", "___"].contains(row.text.trimmingCharacters(in: .whitespaces)) {
            if selectedRows != nil { leaveRowSelection() }
            return makeRule(at: index)
        }
        var all = rows
        let before = all
        let end = NoteOutlineEditing.block(all, targetRows).upperBound
        all.insert(contentsOf: [NoteRow(kind: .rule, depth: row.depth, text: "---", gap: [""]), NoteRow(kind: .bullet, depth: row.depth, gap: [""])], at: end)
        NoteOutlineEditing.normalize(&all)
        if selectedRows != nil { leaveRowSelection() }
        replace(before, with: all, actionName: "Horizontal Line")
        restoreCaret(CaretPosition(row: end + 1, offset: 0))
    }

    /// ⇧⌥⌘C: the rows one code block, their depths as indents; a code
    /// block, rows again.
    @objc func toggleCodeBlock(_ sender: Any?) {
        let target = targetRows
        var all = rows
        let before = all
        if all[target.lowerBound].kind == .code {
            let block = all[target.lowerBound]
            var lines = block.text.components(separatedBy: "\n")
            if Self.closes(block.text) { lines.removeLast() }
            if let first = lines.first, NoteOutlineMarkdown.fenceMarker(first.trimmingCharacters(in: .whitespaces)) != nil { lines.removeFirst() }
            let made = (lines.isEmpty ? [""] : lines).map { NoteRow(kind: .bullet, depth: block.depth, text: $0.trimmingCharacters(in: .whitespaces)) }
            var placed = made
            placed[0].gap = block.gap
            all.replaceSubrange(target.lowerBound..<(target.lowerBound + 1), with: placed)
        } else {
            let block = NoteOutlineEditing.block(all, target)
            let base = all[block.lowerBound].depth
            let body = all[block].map { String(repeating: "  ", count: max(0, $0.depth - base)) + $0.text }
            all.replaceSubrange(block, with: [NoteRow(kind: .code, depth: base, text: (["```"] + body + ["```"]).joined(separator: "\n"), gap: all[block.lowerBound].gap)])
        }
        NoteOutlineEditing.normalize(&all)
        if selectedRows != nil { leaveRowSelection() }
        replace(before, with: all, actionName: "Code Block")
        restoreCaret(CaretPosition(row: target.lowerBound, offset: 0))
    }

    // MARK: Selection

    /// ⇧⌘L: the row's text.
    @objc func selectRowText(_ sender: Any?) {
        let index = selectedRows?.lowerBound ?? rowIndex(at: selectedRange().location)
        leaveRowSelection()
        let paragraph = paragraphRanges[index]
        setSelectedRange(NSRange(location: paragraph.location, length: max(0, paragraph.length - 1)))
    }

    /// ⇧⌘B: the row and all under it, as rows.
    @objc func selectBranch(_ sender: Any?) {
        let block = NoteOutlineEditing.block(rows, targetRows)
        selectRows(anchor: block.lowerBound, head: block.upperBound - 1)
    }

    private var currentSelection: OutlineSelection { OutlineSelection(range: selectedRange(), rows: selectedRows) }

    /// ⌃⌥⌘↑: a word, its sentence, the row's text, the row, its branch,
    /// the branch it's in, and on out, to every row.
    @objc func expandSelection(_ sender: Any?) {
        let now = currentSelection
        if expanded != now { expansions = [] }
        guard let next = nextSelection(after: now) else { return NSSound.beep() }
        expansions.append(now)
        apply(next)
        expanded = currentSelection
    }

    /// ⌃⌥⌘↓: back along those steps.
    @objc func contractSelection(_ sender: Any?) {
        guard expanded == currentSelection, let previous = expansions.popLast() else { return NSSound.beep() }
        apply(previous)
        expanded = expansions.isEmpty ? nil : currentSelection
    }

    private func apply(_ selection: OutlineSelection) {
        if let rows = selection.rows {
            selectRows(anchor: rows.lowerBound, head: rows.upperBound - 1)
        } else {
            leaveRowSelection()
            setSelectedRange(selection.range)
        }
        scrollRangeToVisible(selectedRange())
    }

    private func nextSelection(after now: OutlineSelection) -> OutlineSelection? {
        let all = rows
        if let picked = now.rows {
            let branch = NoteOutlineEditing.block(all, picked)
            if branch != picked { return OutlineSelection(range: now.range, rows: branch) }
            // The row it's in, with its branch.
            let levels = NoteOutlineEditing.levels(all)
            if let parent = stride(from: picked.lowerBound - 1, through: 0, by: -1).first(where: { levels[$0] < levels[picked.lowerBound] }) {
                return OutlineSelection(range: now.range, rows: NoteOutlineEditing.block(all, parent..<(parent + 1)))
            }
            let every = 0..<all.count
            return picked == every ? nil : OutlineSelection(range: now.range, rows: every)
        }
        let range = now.range
        let row = textRange(ofRowAt: range.location)
        let text = textStorage!.string as NSString
        var candidates: [NSRange] = []
        let word = selectionRange(forProposedRange: NSRange(location: range.location, length: range.length), granularity: .selectByWord)
        candidates.append(NSIntersectionRange(word, row))
        text.enumerateSubstrings(in: row, options: .bySentences) { _, sentence, _, stop in
            if NSLocationInRange(range.location, sentence) || sentence.location == range.location {
                candidates.append(NSRange(location: sentence.location, length: (text.substring(with: sentence) as NSString).trimmingCharacters(in: .whitespaces).utf16.count))
                stop.pointee = true
            }
        }
        candidates.append(row)
        for c in candidates where c.location <= range.location && NSMaxRange(c) >= NSMaxRange(range) && c.length > range.length { return OutlineSelection(range: c, rows: nil) }
        let index = rowIndex(at: range.location)
        return OutlineSelection(range: range, rows: index..<(index + 1))
    }

    // MARK: Inline Markdown

    @objc func formatBold(_ sender: Any?) { toggleWrap("**", name: "Bold") }
    @objc func formatItalic(_ sender: Any?) { toggleWrap("_", name: "Italic") }
    @objc func formatStrikethrough(_ sender: Any?) { toggleWrap("~~", name: "Strikethrough") }
    @objc func formatCode(_ sender: Any?) { toggleWrap("`", name: "Code") }
    @objc func formatHighlight(_ sender: Any?) { toggleWrap("==", name: "Highlight") }

    /// The words selected wrapped in the marks, or unwrapped
    /// (`InlineEditing.toggleWrap`), within their row.
    private func toggleWrap(_ marks: String, name: String) {
        guard isEditable, selectedRows == nil else { return NSSound.beep() }
        let range = selectedRange()
        let row = textRange(ofRowAt: range.location)
        guard NSMaxRange(range) <= NSMaxRange(row) else { return NSSound.beep() }
        let edit = InlineEditing.toggleWrap(text: textStorage!.string as NSString, selection: range, marks: marks, within: row)
        replaceCharacters(edit.range, with: edit.replacement, selecting: edit.selection, name: name)
    }

    /// Characters replaced as one step to undo, a selection after.
    func replaceCharacters(_ range: NSRange, with string: String, selecting: NSRange, name: String) {
        let was = adjusting
        adjusting = true
        breakUndoCoalescing()
        if shouldChangeText(in: range, replacementString: string) {
            textStorage!.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: typingAttributes))
            didChangeText()
        }
        setSelectedRange(selecting)
        adjusting = was
        undoManager?.setActionName(name)
    }

    /// ⌥⌘K: a link — the one at the caret given another address (or
    /// none: its words alone), or the words selected made one.
    /// ⌘K (Edit ▸ Link… here, a terminal's Clear Screen).
    @objc func clearOrLink(_ sender: Any?) { editLink(sender) }

    @objc func editLink(_ sender: Any?) {
        guard isEditable, selectedRows == nil, let window else { return NSSound.beep() }
        let range = selectedRange()
        let text = textStorage!.string as NSString
        let existing = spans(atRowOf: range.location).first { span in
            guard case .link = span.kind else { return false }
            return span.range.location <= range.location && NSMaxRange(range) <= NSMaxRange(span.range)
        }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Link" : "Edit Link"
        alert.informativeText = "An address: a page's, a path, or a block's reference."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if let existing, case let .link(target) = existing.kind { field.stringValue = target }
        alert.accessoryView = field
        alert.addButton(withTitle: existing == nil ? "Link" : "Change")
        alert.addButton(withTitle: "Cancel")
        if existing != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing {
                let words = text.substring(with: existing.content)
                if response == .alertThirdButtonReturn || (response == .alertFirstButtonReturn && address.isEmpty) {
                    self.replaceCharacters(existing.range, with: words, selecting: NSRange(location: existing.range.location, length: (words as NSString).length), name: "Remove Link")
                } else if response == .alertFirstButtonReturn {
                    let made = "[\(words)](\(InlineEditing.linkAddress(address)))"
                    self.replaceCharacters(existing.range, with: made, selecting: NSRange(location: existing.range.location + 1, length: (words as NSString).length), name: "Link")
                }
                return
            }
            guard response == .alertFirstButtonReturn, !address.isEmpty else { return }
            let words = text.substring(with: range)
            let made = words.isEmpty ? "<\(address)>" : InlineEditing.markdownLink(words, address)
            self.replaceCharacters(range, with: made, selecting: NSRange(location: range.location + (made as NSString).length, length: 0), name: "Link")
        }
    }

    /// An address pasted over words in a row: they link to it (a link's
    /// words, their link to it instead). False when it isn't that.
    func pasteLink(_ pasted: String, over range: NSRange) -> Bool {
        let address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TextLinks.isAddress(address), URL(string: address) != nil else { return false }
        let text = textStorage!.string as NSString
        let words = text.substring(with: range)
        guard !words.contains(NoteOutlineText.lineSeparator), !words.contains("\n"), URL(string: words)?.scheme == nil else { return false }
        if let link = spans(atRowOf: range.location).first(where: { if case .link = $0.kind { return $0.content == range } else { return false } }) {
            let made = "[\(words)](\(InlineEditing.linkAddress(address)))"
            replaceCharacters(link.range, with: made, selecting: NSRange(location: link.range.location + (made as NSString).length, length: 0), name: "Link")
            return true
        }
        let made = InlineEditing.markdownLink(words, address)
        replaceCharacters(range, with: made, selecting: NSRange(location: range.location + (made as NSString).length, length: 0), name: "Link")
        return true
    }

    // MARK: A row's menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        guard isEditable, let index = row(under: convert(event.locationInWindow, from: nil)) else { return base }
        // The row clicked, if it isn't among those the menu acts on, is.
        if !targetRows.contains(index) {
            if selectedRows != nil { leaveRowSelection() }
            setSelectedRange(NSRange(location: paragraphRanges[index].location, length: 0))
        }
        let items = rowMenuItems(for: index)
        for (i, item) in items.enumerated() { base.insertItem(item, at: i) }
        if !items.isEmpty { base.insertItem(.separator(), at: items.count) }
        return base
    }

    /// What a row's menu offers, by what the row is.
    func rowMenuItems(for index: Int) -> [NSMenuItem] {
        let all = rows
        guard all.indices.contains(index) else { return [] }
        let row = all[index]
        let many = targetRows.count > 1
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        if row.isFolded { add("Expand", #selector(expand(_:))) } else if NoteOutlineEditing.hasChildren(all, index) { add("Collapse", #selector(collapse(_:))) }
        let block = NoteOutlineEditing.block(all, index..<(index + 1))
        if row.folded.contains(where: \.isFolded) || all[block].dropFirst().contains(where: \.isFolded) { add("Expand Completely", #selector(expandCompletely(_:))) }
        if block.dropFirst().contains(where: { NoteOutlineEditing.hasChildren(all, $0) && !all[$0].isFolded }) || !row.folded.isEmpty {
            add("Collapse Completely", #selector(collapseCompletely(_:)))
        }
        if let task = row.task { add(task.isDone ? "Mark Not Done" : "Mark Done", #selector(toggleDone(_:))) }
        else if NoteRow.unfold([row] + all[block].dropFirst()).contains(where: { $0.task != nil }) { add("Move Done to Bottom", #selector(moveDoneToBottom(_:))) }
        add("Focus In", #selector(focusIn(_:)))
        let turn = NSMenu(title: "Turn Into")
        for (i, type) in RowType.allCases.enumerated() {
            let item = NSMenuItem(title: type.title, action: #selector(turnInto(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = type.holds(row) ? .on : .off
            turn.addItem(item)
        }
        let turnItem = NSMenuItem(title: "Turn Into", action: nil, keyEquivalent: "")
        turnItem.submenu = turn
        items.append(turnItem)
        add(many ? "Duplicate Rows" : "Duplicate Row", #selector(duplicateLine(_:)))
        add(many ? "Delete Rows" : "Delete Row", #selector(deleteRows(_:)))
        return items
    }

    // MARK: Menus

    /// Whether an outline command can be chosen now; nil for one it doesn't know.
    func validateOutline(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action else { return nil }
        let structural: Set<Selector> = [#selector(newRow(_:)), #selector(duplicateLine(_:)), #selector(deleteLine(_:)), #selector(moveLineUp(_:)),
                                         #selector(moveLineDown(_:)), #selector(indentRows(_:)), #selector(outdentRows(_:)), #selector(cycleChecklist(_:)),
                                         #selector(cycleTask(_:)), #selector(toggleDone(_:)), #selector(moveDoneToBottom(_:)), #selector(toggleBullet(_:)),
                                         #selector(insertHorizontalLine(_:)), #selector(toggleCodeBlock(_:)), #selector(turnInto(_:)), #selector(deleteRows(_:))]
        let inline: Set<Selector> = [#selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatStrikethrough(_:)), #selector(formatCode(_:)),
                                     #selector(formatHighlight(_:)), #selector(editLink(_:))]
        if structural.contains(action) { return isEditable }
        if inline.contains(action) { return isEditable && selectedRows == nil }
        if action == #selector(clearOrLink(_:)) {
            (item as? NSMenuItem)?.title = "Link…"
            return isEditable && selectedRows == nil
        }
        if action == #selector(focusOut(_:)) || action == #selector(unfocus(_:)) { return focus != nil }
        return nil
    }

    // MARK: Accessibility

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard isEditable, !paragraphRanges.isEmpty else { return nil }
        let index = rowIndex(at: selectedRange().location)
        let all = rows
        let row = all[index]
        var actions: [NSAccessibilityCustomAction] = []
        func add(_ name: String, _ run: @escaping () -> Void) {
            actions.append(NSAccessibilityCustomAction(name: name) { run(); return true })
        }
        if let task = row.task { add(task.isDone ? "Mark Not Done" : "Mark Done") { [weak self] in self?.toggleDone(nil) } }
        if row.isFolded { add("Expand") { [weak self] in self?.expand(nil) } } else if NoteOutlineEditing.hasChildren(all, index) { add("Collapse") { [weak self] in self?.collapse(nil) } }
        add("Indent") { [weak self] in self?.indentRows(nil) }
        add("Outdent") { [weak self] in self?.outdentRows(nil) }
        add("Move Up") { [weak self] in self?.moveRowsUp(nil) }
        add("Move Down") { [weak self] in self?.moveRowsDown(nil) }
        add("Delete Row") { [weak self] in self?.deleteRows(nil) }
        return actions
    }
}
