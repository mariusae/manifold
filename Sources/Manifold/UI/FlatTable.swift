import AppKit

/// A tile's list: a drag from it dressed as the app's drags are (its pill,
/// the cursor's word) without its delegate saying so, and its keys offered
/// to `onKey` first — what every list wrote out for itself.
class FlatTable: NSTableView {
    /// A key pressed in the list, before the table's own handling: true
    /// when it was taken.
    var onKey: ((NSEvent) -> Bool)?

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
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
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

/// A tile's tree, as `FlatTable` is its list.
class FlatOutline: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?

    /// One column, the tree's, as wide as it; no header, rows `rowHeight`
    /// tall with nothing between them and nothing drawn behind.
    convenience init(column id: String, rowHeight: CGFloat? = nil) {
        self.init(frame: .zero)
        FlatTable.dress(self, column: id, rowHeight: rowHeight)
        outlineTableColumn = tableColumns.first
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
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
