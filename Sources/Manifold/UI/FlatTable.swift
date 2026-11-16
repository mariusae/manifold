import AppKit

/// A tile's list: a drag from it dressed as the app's drags are (its pill,
/// the cursor's word) without its delegate saying so, and its keys offered
/// to `onKey` first — what every list wrote out for itself.
class FlatTable: NSTableView {
    /// A key pressed in the list, before the table's own handling: true
    /// when it was taken.
    var onKey: ((NSEvent) -> Bool)?
    let linger = Linger()

    override func mouseDown(with event: NSEvent) {
        linger.click(self, event) { super.mouseDown(with: event) }
    }

    /// A list of one column as wide as it, no header, rows `rowHeight`
    /// tall with nothing between them and nothing drawn behind.
    convenience init(column id: String, rowHeight: CGFloat? = nil) {
        self.init(frame: .zero)
        FlatTable.dress(self, column: id, rowHeight: rowHeight)
    }

    /// One column filling the list, no header, no gaps, nothing behind.
    fileprivate static func dress(_ table: NSTableView, column id: String, rowHeight: CGFloat?) {
        let column = NSTableColumn(identifier: .init(id))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if let rowHeight { table.rowHeight = rowHeight }
    }

    override func keyDown(with event: NSEvent) {
        linger.cancel()
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        linger.dragBegan()
        DragPill.dress(session, from: self, at: screenPoint)
        DragCursor.began()
        super.draggingSession(session, willBeginAt: screenPoint)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }

    /// What dragging its chosen rows writes (debugging).
    var debugDragItems: [NSPasteboardWriting] {
        selectedRowIndexes.compactMap { dataSource?.tableView?(self, pasteboardWriterForRow: $0) }
    }
}

/// A chosen row clicked again — the one chosen, the list's keys already
/// its, no modifier — and nothing more (no drag, no second click): told a
/// moment later, as the Finder starts renaming a name lingered on.
final class Linger {
    /// Told, the row and where it was clicked (in the list's coordinates).
    var fire: ((Int, NSPoint) -> Void)?
    /// The click under way is such a one (for the list's action, at its mouse-up).
    private(set) var candidate = false
    private var dragged = false
    private var timer: Timer?

    func cancel() { timer?.invalidate(); timer = nil }

    func dragBegan() { dragged = true; cancel() }

    /// Round the list's own handling of a mouse-down (which returns at its
    /// mouse-up).
    func click(_ table: NSTableView, _ event: NSEvent, track: () -> Void) {
        cancel()
        let p = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: p)
        candidate = fire != nil && event.clickCount == 1 && row >= 0
            && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            && table.selectedRowIndexes == IndexSet(integer: row) && table.window?.firstResponder === table
        dragged = false
        track()
        defer { candidate = false }
        guard candidate, !dragged else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(NSEvent.doubleClickInterval, 0.35) + 0.15, repeats: false) { [weak self, weak table] _ in
            guard let self, let table, table.selectedRowIndexes == IndexSet(integer: row) else { return }
            self.fire?(row, p)
        }
    }
}

/// A tile's tree, as `FlatTable` is its list.
class FlatOutline: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    let linger = Linger()

    override func mouseDown(with event: NSEvent) {
        linger.click(self, event) { super.mouseDown(with: event) }
    }

    /// One column, the tree's, as wide as it; no header, rows `rowHeight`
    /// tall with nothing between them and nothing drawn behind.
    convenience init(column id: String, rowHeight: CGFloat? = nil) {
        self.init(frame: .zero)
        FlatTable.dress(self, column: id, rowHeight: rowHeight)
        outlineTableColumn = tableColumns.first
    }

    override func keyDown(with event: NSEvent) {
        linger.cancel()
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        linger.dragBegan()
        DragPill.dress(session, from: self, at: screenPoint)
        DragCursor.began()
        super.draggingSession(session, willBeginAt: screenPoint)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }
}

extension NSScrollView {
    /// Holds a list: scrolled up and down, its scroller only while it
    /// moves, nothing drawn behind it.
    func hold(_ list: NSView) {
        documentView = list
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
    }
}
