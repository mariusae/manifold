import Foundation

/// The outline commands, as operations on a run of rows.
///
/// These are Bike's: a row always takes its children along — when indented,
/// outdented, moved or deleted — and every operation leaves the rows as
/// Markdown can say them. Each takes the rows the command applies to, and
/// gives back where those rows ended up, or nil when the command cannot be
/// done there.
public enum NoteOutlineEditing {

    /// Where each row sits in the outline. A list nests by indentation; a
    /// heading at the top of the note also holds what follows it, up to the
    /// next heading of its rank or higher — its section — so that a `##`
    /// holds the rows under it and a `#` holds its `##`s.
    public static func levels(_ rows: [NoteRow]) -> [Int] {
        var sections: [Int] = []  // the rank of each open heading
        return rows.map { row in
            if case .heading(let rank) = row.kind, row.depth == 0 {
                while let open = sections.last, open >= rank { sections.removeLast() }
                defer { sections.append(rank) }
                return sections.count
            }
            return sections.count + row.depth
        }
    }

    /// The index after the last descendant of the row at `index`.
    public static func subtreeEnd(_ rows: [NoteRow], _ index: Int) -> Int {
        subtreeEnd(levels(rows), index)
    }

    static func subtreeEnd(_ levels: [Int], _ index: Int) -> Int {
        var end = index + 1
        while end < levels.count, levels[end] > levels[index] { end += 1 }
        return end
    }

    /// The rows a selection of rows acts on: the selection, and the children
    /// of every row in it.
    public static func block(_ rows: [NoteRow], _ selection: Range<Int>) -> Range<Int> {
        let levels = levels(rows)
        var end = selection.upperBound
        for index in selection { end = max(end, subtreeEnd(levels, index)) }
        return selection.lowerBound..<end
    }

    /// The rows a selection takes along when indented or outdented: its
    /// list children only, since a section is not something to indent.
    static func listBlock(_ rows: [NoteRow], _ selection: Range<Int>) -> Range<Int> {
        var end = selection.upperBound
        for index in selection {
            var last = index + 1
            while last < rows.count, rows[last].depth > rows[index].depth { last += 1 }
            end = max(end, last)
        }
        return selection.lowerBound..<end
    }

    /// Whether the row at `index` has children, shown or folded.
    public static func hasChildren(_ rows: [NoteRow], _ index: Int) -> Bool {
        rows[index].isFolded || subtreeEnd(rows, index) > index + 1
    }

    /// The nearest row before `index` at `depth` in its list, before any
    /// row shallower.
    public static func previousSibling(_ rows: [NoteRow], before index: Int, depth: Int) -> Int? {
        var candidate = index - 1
        while candidate >= 0 {
            if rows[candidate].depth == depth { return candidate }
            if rows[candidate].depth < depth { return nil }
            candidate -= 1
        }
        return nil
    }

    /// The nearest row before `index` at `level` in the outline, before any
    /// row that holds it.
    static func previousSibling(_ levels: [Int], before index: Int, level: Int) -> Int? {
        var candidate = index - 1
        while candidate >= 0 {
            if levels[candidate] == level { return candidate }
            if levels[candidate] < level { return nil }
            candidate -= 1
        }
        return nil
    }

    // MARK: Indent and outdent

    /// Makes the rows children of the row before them.
    public static func indent(_ rows: inout [NoteRow], _ selection: Range<Int>) -> Range<Int>? {
        let block = listBlock(rows, selection)
        guard let depth = rows[block].map(\.depth).min(),
              let parent = previousSibling(rows, before: block.lowerBound, depth: depth),
              rows[parent].canHaveChildren
        else { return nil }
        var shift = 0
        if rows[parent].isFolded {
            // Bike opens the row that takes the new children, so they are
            // not hidden as they arrive.
            shift = unfold(&rows, at: parent)
        }
        let moved = (block.lowerBound + shift)..<(block.upperBound + shift)
        for index in moved { rows[index].depth += 1 }
        normalize(&rows)
        return (selection.lowerBound + shift)..<(selection.upperBound + shift)
    }

    /// Makes the rows siblings of their parent. The rows after them that
    /// were their siblings become their children, as the text reads.
    public static func outdent(_ rows: inout [NoteRow], _ selection: Range<Int>) -> Range<Int>? {
        let block = listBlock(rows, selection)
        guard let depth = rows[block].map(\.depth).min(), depth > 0 else { return nil }
        for index in block { rows[index].depth -= 1 }
        normalize(&rows)
        return selection
    }

    // MARK: Moving

    /// Swaps the rows with the sibling before them.
    public static func moveUp(_ rows: inout [NoteRow], _ selection: Range<Int>) -> Range<Int>? {
        let block = block(rows, selection)
        let levels = levels(rows)
        guard let level = levels[block].min(),
              let sibling = previousSibling(levels, before: block.lowerBound, level: level)
        else { return nil }
        let above = Array(rows[sibling..<block.lowerBound])
        let moving = Array(rows[block])
        rows.replaceSubrange(sibling..<block.upperBound, with: swappingGaps(moving, above))
        normalize(&rows)
        let offset = block.lowerBound - sibling
        return (selection.lowerBound - offset)..<(selection.upperBound - offset)
    }

    /// Swaps the rows with the sibling after them.
    public static func moveDown(_ rows: inout [NoteRow], _ selection: Range<Int>) -> Range<Int>? {
        let block = block(rows, selection)
        let levels = levels(rows)
        guard let level = levels[block].min(),
              block.upperBound < rows.count, levels[block.upperBound] == level
        else { return nil }
        let below = Array(rows[block.upperBound..<subtreeEnd(levels, block.upperBound)])
        let moving = Array(rows[block])
        rows.replaceSubrange(block.lowerBound..<(block.upperBound + below.count), with: swappingGaps(below, moving))
        normalize(&rows)
        return (selection.lowerBound + below.count)..<(selection.upperBound + below.count)
    }

    /// Two runs of rows, the second now first. The blank lines between
    /// them are where the text had them, not with the rows that moved.
    private static func swappingGaps(_ first: [NoteRow], _ second: [NoteRow]) -> [NoteRow] {
        var first = first, second = second
        swap(&first[0].gap, &second[0].gap)
        return first + second
    }

    // MARK: Folding

    /// Folds away the children of the row at `index`. Returns how many rows
    /// left the screen.
    @discardableResult
    public static func fold(_ rows: inout [NoteRow], at index: Int) -> Int {
        let end = subtreeEnd(rows, index)
        guard end > index + 1 else { return 0 }
        let depth = rows[index].depth
        let children = rows[(index + 1)..<end].map { child in
            var child = child
            child.depth -= depth
            return child
        }
        rows[index].folded = children + rows[index].folded
        rows.removeSubrange((index + 1)..<end)
        return children.count
    }

    /// Shows the folded children of the row at `index`; with `completely`,
    /// theirs too, all the way down. Returns how many rows came onto the
    /// screen.
    @discardableResult
    public static func unfold(_ rows: inout [NoteRow], at index: Int, completely: Bool = false) -> Int {
        let before = rows.count
        if completely {
            let end = subtreeEnd(rows, index)
            rows.replaceSubrange(index..<end, with: NoteRow.unfold(Array(rows[index..<end])))
        } else {
            let depth = rows[index].depth
            let children = rows[index].folded.map { child in
                var child = child
                child.depth += depth
                return child
            }
            rows[index].folded = []
            rows.insert(contentsOf: children, at: index + 1)
        }
        return rows.count - before
    }

    /// Folds the row and every row inside it, so that each opens later on
    /// its own children folded.
    @discardableResult
    public static func foldCompletely(_ rows: inout [NoteRow], at index: Int) -> Int {
        let end = subtreeEnd(rows, index)
        var removed = 0
        // Innermost first, so each fold takes its own children with it.
        for child in stride(from: end - 1, through: index, by: -1) {
            removed += fold(&rows, at: child)
        }
        return removed
    }

    // MARK: Rows

    /// Deletes the rows and their children. A note keeps one row.
    public static func delete(_ rows: inout [NoteRow], _ selection: Range<Int>) -> Int {
        let block = block(rows, selection)
        rows.removeSubrange(block)
        if rows.isEmpty { rows = [.blank] }
        normalize(&rows)
        return min(block.lowerBound, rows.count - 1)
    }

    /// Copies the rows and their children, and puts the copy after them.
    public static func duplicate(_ rows: inout [NoteRow], _ selection: Range<Int>) -> Range<Int> {
        let block = block(rows, selection)
        rows.insert(contentsOf: rows[block], at: block.upperBound)
        return (selection.lowerBound + block.count)..<(selection.upperBound + block.count)
    }

    /// Checks the rows off, or, when all are done, unchecks them. Rows
    /// without a checkbox are left alone, unless none has one.
    /// The two checkbox items, as Prism has them: a task, `+ [ ]`, drawn
    /// round; and a checklist item, `- [ ]`, drawn square.
    public enum Checkbox {
        case task, checklist

        /// Whether a row is one.
        func holds(_ row: NoteRow) -> Bool {
            guard row.task != nil, row.kind == .bullet else { return false }
            return (row.marker == "+") == (self == .task)
        }
    }

    /// Cycles rows as ⌘Return (checklist) and ⇧⌘Return (task) do:
    /// anything else becomes an open one, an open one is checked, a
    /// checked one becomes a plain bullet — the first row deciding for all.
    public static func cycle(_ checkbox: Checkbox, _ rows: inout [NoteRow], _ selection: Range<Int>) {
        guard let first = selection.first else { return }
        let lead = rows[first]
        let next: NoteRow.Task?
        if checkbox.holds(lead) {
            next = lead.task?.isDone == true ? nil : .done("x")
        } else {
            next = .open
        }
        for index in selection {
            var row = rows[index]
            guard row.kind != .code, row.kind != .rule else { continue }
            if case .heading = row.kind { continue }
            row.kind = .bullet
            row.spacing = 1
            row.task = next
            switch (next, checkbox) {
            case (nil, _): row.marker = "-"
            case (_, .task): row.marker = "+"
            case (_, .checklist): row.marker = row.marker == "*" ? "*" : "-"
            }
            rows[index] = row
        }
    }

    public static func toggleDone(_ rows: inout [NoteRow], _ selection: Range<Int>) {
        let tasks = selection.filter { rows[$0].task != nil }
        if tasks.isEmpty {
            for index in selection where rows[index].kind.isListItem { rows[index].task = .done("x") }
            return
        }
        let allDone = tasks.allSatisfy { rows[$0].task?.isDone == true }
        for index in tasks { rows[index].task = allDone ? .open : .done("x") }
    }

    // MARK: Done to the bottom

    /// Moves the done items of a list below the rest: those not done — and
    /// rows with no checkbox — keep their order at the top, the done ones
    /// theirs under them, each taking its children along. The list is the
    /// one the row at `index` is in; or, when that has nothing done to
    /// move, the row's own children. Blank lines stay where they were, and
    /// an ordered list keeps counting from the top. A heading or paragraph
    /// among the items is fixed, and the items on each side of it sorted
    /// apart. Gives back where the row at `index` went, or nil when nothing
    /// moved.
    public static func moveDoneToBottom(_ rows: inout [NoteRow], at index: Int) -> Int? {
        guard rows.indices.contains(index) else { return nil }
        if let moved = sinkDone(&rows, around: index, following: index) { return moved }
        let levels = levels(rows)
        guard subtreeEnd(levels, index) > index + 1 else { return nil }
        return sinkDone(&rows, around: index + 1, following: index)
    }

    /// The done items among a row's children moved below the rest, as
    /// `moveDoneToBottom` moves them. Says whether any moved.
    @discardableResult
    public static func moveDoneToBottom(_ rows: inout [NoteRow], under parent: Int) -> Bool {
        guard rows.indices.contains(parent), subtreeEnd(levels(rows), parent) > parent + 1 else { return false }
        return sinkDone(&rows, around: parent + 1, following: parent) != nil
    }

    /// Every list in the note with its done items below the rest. Says
    /// whether any moved.
    @discardableResult
    public static func moveAllDoneToBottom(_ rows: inout [NoteRow]) -> Bool {
        var moved = false
        // A list is sorted from its first item, before any list in it: the
        // rows only move within the list, so those after are still to come.
        for index in rows.indices where sinkDone(&rows, around: index, following: index) != nil { moved = true }
        return moved
    }

    /// The done items of the list `member` is in, moved below the rest;
    /// where the row at `following` then is.
    private static func sinkDone(_ rows: inout [NoteRow], around member: Int, following: Int) -> Int? {
        let levels = levels(rows)
        let level = levels[member]
        // The list: back and on over the siblings and what they hold.
        var start = member
        while start > 0, levels[start - 1] >= level { start -= 1 }
        var end = member
        while end < rows.count, levels[end] >= level { end += 1 }
        // Each sibling, with its children.
        var items: [Range<Int>] = []
        var at = start
        while at < end {
            let next = subtreeEnd(levels, at)
            items.append(at..<next)
            at = next
        }
        // Sorted in runs of list items, apart from anything else among them.
        var order: [Range<Int>] = []
        var run: [Range<Int>] = []
        var changed = false
        func finish() {
            let open = run.filter { rows[$0.lowerBound].task?.isDone != true }
            let done = run.filter { rows[$0.lowerBound].task?.isDone == true }
            if open + done != run { changed = true }
            order += open + done
            run.removeAll()
        }
        for item in items {
            if rows[item.lowerBound].kind.isListItem {
                run.append(item)
            } else {
                finish()
                order.append(item)
            }
        }
        finish()
        guard changed else { return nil }
        // Blank lines, and numbers, where they were; the rows in their new order.
        let heads = items.map { rows[$0.lowerBound] }
        var sorted: [NoteRow] = []
        var landed = following
        for (position, item) in order.enumerated() {
            if item.contains(following) { landed = start + sorted.count + (following - item.lowerBound) }
            var moved = Array(rows[item])
            moved[0].gap = heads[position].gap
            if moved[0].kind == .ordered, heads[position].kind == .ordered { moved[0].number = heads[position].number }
            sorted += moved
        }
        rows.replaceSubrange(start..<end, with: sorted)
        return landed
    }

    /// Brings every row to a depth Markdown can write: no deeper than one
    /// below the row before, and only below a list item.
    public static func normalize(_ rows: inout [NoteRow]) {
        guard !rows.isEmpty else { return }
        rows[0].depth = 0
        for index in rows.indices.dropFirst() {
            let previous = rows[index - 1]
            let deepest = previous.depth + (previous.canHaveChildren ? 1 : 0)
            if rows[index].depth > deepest { rows[index].depth = deepest }
            if rows[index].depth < 0 { rows[index].depth = 0 }
        }
    }
}
