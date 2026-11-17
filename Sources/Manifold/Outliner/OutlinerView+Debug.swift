import AppKit
import ManifoldCore

/// What the view shows and has chosen, said in words — each row's kind,
/// depth, fold and words, the caret, the selection, the rows chosen, the
/// folds kept, the focus — for Manifold's debug socket; and the keys and
/// clicks it takes, done by name, to drive it as a person would.
extension OutlinerView {
    public var debugState: String {
        let text = shown as NSString
        var out: [String] = []
        for (index, line) in bodyLayout.lines.enumerated() {
            let words = line.content <= line.end && line.end <= text.length ? text.substring(with: NSRange(location: line.content, length: line.end - line.content)) : ""
            var kind: String
            switch line.kind {
            case .blank: kind = "blank"
            case .paragraph: kind = "paragraph"
            case .heading(let level): kind = "heading\(level)"
            case .item(let number, let done, let bullet):
                if let done { kind = (bullet == "+" ? "task" : "checkbox") + (done ? "(done)" : "(open)") }
                else if let number { kind = "ordered(\(number)\(bullet))" }
                else { kind = bullet == "-" ? "body" : "unordered(\(bullet))" }
            case .quote: kind = "quote"
            case .fence: kind = "fence"
            case .code: kind = "code"
            case .table: kind = "table"
            case .rule: kind = "rule"
            }
            var flags: [String] = []
            if line.hasChildren { flags.append(line.isFolded ? "folded" : "open") }
            let shownWords = words.replacingOccurrences(of: "\u{FFFC}", with: "◻︎").replacingOccurrences(of: "\u{2028}", with: "⏎")
            out.append("\(index) d\(line.depth) \(kind)\(flags.isEmpty ? "" : " " + flags.joined(separator: " ")) [\(line.start)-\(line.end) @\(line.content)] \"\(shownWords)\"")
        }
        let selection = textView.selectedRange()
        out.append("caret: \(selection.location)\(selection.length > 0 ? " +\(selection.length)" : "") row \(caretRow.map(String.init) ?? "none")")
        if selection.length > 0, NSMaxRange(selection) <= text.length { out.append("selected: \"\(text.substring(with: selection))\"") }
        out.append("chosen: \(chosenRows.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none")")
        out.append("folds: " + (editor.foldedRows.isEmpty ? "none" : editor.foldedRows.map { "\($0.index) \"\($0.text)\"" }.joined(separator: ", ")))
        out.append("focus: " + (editor.isFocused ? (editor.focusTrail + [editor.focusLabel ?? "?"]).joined(separator: " ▸ ") : "none"))
        out.append("writing: \(isWriting ? "yes" : "no") · prose: \(isProse ? "yes" : "no") · undo: \(editor.canUndo ? "yes" : "no") · redo: \(editor.canRedo ? "yes" : "no")")
        return out.joined(separator: "\n")
    }

    /// A debug command done as a person would: "state"; "caret <n>";
    /// "select <from> <length>"; "type <words>"; "return", "tab",
    /// "backtab", "delete", "forward", "escape", "up", "down", "shiftup",
    /// "shiftdown", "left", "right", "all", "expand", "contract", "undo",
    /// "redo", "copy"; "click <row> [option]" (its handle); "run
    /// <command>" (an `EditCommand` by name: "run duplicateRows");
    /// "focus [row]", "out", "unfocus"; "move <row> <before> <depth>";
    /// "paste <markdown>" (\n for line breaks). Answers with the state after.
    public func debug(_ command: String) -> String {
        let words = command.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = words.count > 1 ? words[1] : ""
        let numbers = rest.split(separator: " ").compactMap { Int($0) }
        let none = NSRange(location: NSNotFound, length: 0)
        switch words.first ?? "state" {
        case "state": break
        case "caret": if let at = numbers.first { setCaret(at) }
        case "select": if numbers.count == 2 { selectedRange = NSRange(location: numbers[0], length: numbers[1]) }
        case "type": for character in rest { textView.insertText(String(character), replacementRange: none) }
        case "return": textView.insertNewline(nil)
        case "tab": textView.insertTab(nil)
        case "backtab": textView.insertBacktab(nil)
        case "delete": textView.deleteBackward(nil)
        case "forward": textView.deleteForward(nil)
        case "escape": textView.cancelOperation(nil)
        case "up": textView.moveUp(nil)
        case "down": textView.moveDown(nil)
        case "shiftup": textView.moveUpAndModifySelection(nil)
        case "shiftdown": textView.moveDownAndModifySelection(nil)
        case "left": textView.moveLeft(nil)
        case "right": textView.moveRight(nil)
        case "all": textView.selectAll(nil)
        case "expand": textView.expandSelection()
        case "contract": textView.contractSelection()
        case "undo": undo()
        case "redo": redo()
        case "copy":
            textView.copy(nil)
            return "copied:\n" + (NSPasteboard.general.string(forType: .string) ?? "")
        case "click":
            guard let row = numbers.first else { return "usage: click <row> [option]" }
            textView.clickHandle(ofRow: row, option: rest.hasSuffix("option"))
        case "run":
            guard let found = EditCommand.allCases.first(where: { String(describing: $0) == rest }) else { return "no command \(rest)" }
            if !textView.perform(keyed: found) { return "nothing to do\n" + debugState }
        case "focus": if !focusIn(row: numbers.first) { return "no row to focus on\n" + debugState }
        case "out": if !focusOut() { return "not focused\n" + debugState }
        case "unfocus": unfocus()
        case "move":
            guard numbers.count == 3 else { return "usage: move <row> <before> <depth>" }
            moveRows([numbers[0]], before: numbers[1], depth: numbers[2])
        case "paste":
            let board = NSPasteboard.general
            let was = board.string(forType: .string)
            board.clearContents()
            board.setString(rest.replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            textView.paste(nil)
            board.clearContents()
            if let was { board.setString(was, forType: .string) }
        default:
            return "unknown: \(words.first ?? "")"
        }
        return debugState
    }
}
