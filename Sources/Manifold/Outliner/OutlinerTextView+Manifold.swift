import AppKit
import ManifoldCore

/// What a row can be turned into, in Edit ▸ Outline ▸ Turn Into (by its tag).
enum OutlinerRowType: CaseIterable {
    case paragraph, bullet, checkbox, task, numbered, heading1, heading2, heading3, quote

    var title: String {
        switch self {
        case .paragraph: "Paragraph"
        case .bullet: "Bullet"
        case .checkbox: "Checkbox"
        case .task: "Task"
        case .numbered: "Numbered"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .quote: "Quote"
        }
    }

    var command: EditCommand {
        switch self {
        case .paragraph: .turnParagraph
        case .bullet: .turnBullet
        case .checkbox: .turnCheckbox
        case .task: .turnTask
        case .numbered: .turnNumbered
        case .heading1: .turnHeading1
        case .heading2: .turnHeading2
        case .heading3: .turnHeading3
        case .quote: .turnQuote
        }
    }
}

/// The outliner in Manifold's menus: Edit ▸ Outline and Format, and the
/// line commands, each the engine's command its key does (Bike 2's keys,
/// which the view takes before the menus while it has the keyboard).
extension OutlinerTextView {
    private func run(_ command: EditCommand) {
        guard isEditable || [.fold, .unfold, .foldAll, .unfoldAll, .foldCompletely, .unfoldCompletely,
                             .foldByLevel, .unfoldByLevel, .foldAllByLevel, .unfoldAllByLevel].contains(command) else { return NSSound.beep() }
        if owner?.run(command) != true { NSSound.beep() }
    }

    @objc func insertRowBelow(_ sender: Any?) { run(.insertBelow) }
    @objc func insertRowAbove(_ sender: Any?) { run(.insertAbove) }
    @objc func insertChildRow(_ sender: Any?) { run(.insertChild) }
    @objc func indentRows(_ sender: Any?) { run(.indent) }
    @objc func outdentRows(_ sender: Any?) { run(.outdent) }
    @objc func moveRowsUp(_ sender: Any?) { run(.moveUp) }
    @objc func moveRowsDown(_ sender: Any?) { run(.moveDown) }
    @objc func moveUpKeepingLevel(_ sender: Any?) { run(.moveUpKeepingLevel) }
    @objc func moveDownKeepingLevel(_ sender: Any?) { run(.moveDownKeepingLevel) }
    @objc func groupRows(_ sender: Any?) { run(.group) }
    @objc func joinRows(_ sender: Any?) { run(.joinRows) }
    @objc func promoteChildren(_ sender: Any?) { run(.promoteChildren) }
    @objc func demoteSiblings(_ sender: Any?) { run(.demoteSiblings) }
    @objc func deleteRowOnly(_ sender: Any?) { run(.deleteRowOnly) }
    @objc func cycleChecklist(_ sender: Any?) { run(.cycleChecklist) }
    @objc func cycleTask(_ sender: Any?) { run(.toggleTask) }
    @objc func toggleDone(_ sender: Any?) { run(.toggleCheckbox) }
    @objc func markDone(_ sender: Any?) { run(.markDone) }
    @objc func moveDoneToBottom(_ sender: Any?) { run(.moveDoneToBottom) }
    @objc func toggleBullet(_ sender: Any?) { run(.bullet) }

    @objc func turnInto(_ sender: NSMenuItem) {
        guard OutlinerRowType.allCases.indices.contains(sender.tag) else { return }
        run(OutlinerRowType.allCases[sender.tag].command)
    }

    // The editor's line commands (Edit ▸ Lines), as rows.
    @objc func duplicateLine(_ sender: Any?) { run(.duplicateRows) }
    @objc func deleteLine(_ sender: Any?) { run(.deleteRows) }
    @objc func moveLineUp(_ sender: Any?) { run(.moveUp) }
    @objc func moveLineDown(_ sender: Any?) { run(.moveDown) }

    // Format.
    @objc func formatBold(_ sender: Any?) { run(.bold) }
    @objc func formatItalic(_ sender: Any?) { run(.italic) }
    @objc func formatStrikethrough(_ sender: Any?) { run(.strikethrough) }
    @objc func formatCode(_ sender: Any?) { run(.code) }
    @objc func formatHighlight(_ sender: Any?) { run(.highlight) }
    @objc func editLink(_ sender: Any?) { isEditable ? askLink() : NSSound.beep() }
    /// ⌘K: a terminal's Clear Screen, a note's Link…
    @objc func clearOrLink(_ sender: Any?) { editLink(sender) }

    // The selection, a step at a time.
    @objc func expandSelection(_ sender: Any?) { expandSelection() }
    @objc func contractSelection(_ sender: Any?) { contractSelection() }

    // A row focused on.
    @objc func focusIn(_ sender: Any?) { if owner?.focusIn() != true { NSSound.beep() } }
    @objc func focusOut(_ sender: Any?) { if owner?.focusOut() != true { NSSound.beep() } }
    @objc func unfocus(_ sender: Any?) { owner?.unfocus() }

    // Folds.
    @objc func collapse(_ sender: Any?) { run(.fold) }
    @objc func expand(_ sender: Any?) { run(.unfold) }
    @objc func collapseAll(_ sender: Any?) { run(.foldAll) }
    @objc func expandAll(_ sender: Any?) { run(.unfoldAll) }
    @objc func collapseCompletely(_ sender: Any?) { run(.foldCompletely) }
    @objc func expandCompletely(_ sender: Any?) { run(.unfoldCompletely) }
    @objc func collapseByLevel(_ sender: Any?) { run(.foldByLevel) }
    @objc func expandByLevel(_ sender: Any?) { run(.unfoldByLevel) }

    /// The outline's items, enabled as they can be done here: what changes
    /// the note only while it can be written; a focus to leave only while
    /// one is held.
    func validateOutline(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action else { return nil }
        let reading: Set<Selector> = [#selector(collapse(_:)), #selector(expand(_:)), #selector(collapseAll(_:)), #selector(expandAll(_:)),
                                      #selector(collapseCompletely(_:)), #selector(expandCompletely(_:)), #selector(collapseByLevel(_:)),
                                      #selector(expandByLevel(_:)), #selector(focusIn(_:)), #selector(expandSelection(_:)), #selector(contractSelection(_:))]
        if action == #selector(focusOut(_:)) || action == #selector(unfocus(_:)) { return owner?.editor.isFocused == true }
        if reading.contains(action) { return true }
        let writing: Set<Selector> = [#selector(insertRowBelow(_:)), #selector(insertRowAbove(_:)), #selector(insertChildRow(_:)), #selector(indentRows(_:)),
                                      #selector(outdentRows(_:)), #selector(moveRowsUp(_:)), #selector(moveRowsDown(_:)), #selector(moveUpKeepingLevel(_:)),
                                      #selector(moveDownKeepingLevel(_:)), #selector(groupRows(_:)), #selector(joinRows(_:)), #selector(promoteChildren(_:)),
                                      #selector(demoteSiblings(_:)), #selector(deleteRowOnly(_:)), #selector(cycleChecklist(_:)), #selector(cycleTask(_:)),
                                      #selector(toggleDone(_:)), #selector(markDone(_:)), #selector(moveDoneToBottom(_:)), #selector(toggleBullet(_:)),
                                      #selector(turnInto(_:)), #selector(duplicateLine(_:)), #selector(deleteLine(_:)), #selector(moveLineUp(_:)),
                                      #selector(moveLineDown(_:)), #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatStrikethrough(_:)),
                                      #selector(formatCode(_:)), #selector(formatHighlight(_:)), #selector(editLink(_:)), #selector(clearOrLink(_:))]
        if writing.contains(action) {
            if action == #selector(clearOrLink(_:)), let menuItem = item as? NSMenuItem { menuItem.title = "Link…" }
            return isEditable
        }
        return nil
    }
}

/// Things dropped on the outline (§3.11), as a note takes them: a block's
/// (a file's, a place's) link, a page's, words, put in where the pointer
/// is; pictures, cards, several things at once as rows of their own
/// where the pointer lets go.
extension OutlinerTextView: DropTaking {
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] { isEditable ? Dropping.noteForms(d) : [] }

    func dropTrack(_ d: Dragged, at p: NSPoint) {
        let at = characterIndexForInsertion(at: p)
        if selectedRange() != NSRange(location: at, length: 0) { setSelectedRange(NSRange(location: at, length: 0)) }
    }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        let at = p.map { characterIndexForInsertion(at: $0) } ?? selectedRange().location
        // As rows: before the row under the pointer's, at its depth.
        let rows = p.flatMap { rowsDrop(at: $0, rows: [], own: false) }
        let put = { [weak self, weak owner] (markdown: String, asRows: Bool) in
            guard let self, let owner else { return }
            if asRows {
                let before = rows?.before ?? owner.rowCount
                if owner.insertRows(markdown, before: before, depth: rows?.depth ?? 0) { return }
            }
            let all = self.string as NSString
            let r = NSRange(location: min(at, all.length), length: 0)
            let char = { (i: Int) -> Character? in i >= 0 && i < all.length ? Character(all.substring(with: NSRange(location: i, length: 1))) : nil }
            let text = [.link, .reference, .path].contains(form) ? Dropping.spaced(markdown, after: char(r.location - 1), before: char(r.location)) : markdown
            self.setSelectedRange(r)
            self.insertText(text, replacementRange: r)
        }
        let keep = owner.keepImage.map { keep in { (data: Data, kind: String) in keep(data, kind) { put($0, true) } } }
        Dropping.noteText(d, as: form, keep: keep, insert: { put($0, form == .inline || $0.contains("\n") || d.things.count > 1) },
                          linked: { [weak owner] in owner?.onLinked?($0) })
    }
}
