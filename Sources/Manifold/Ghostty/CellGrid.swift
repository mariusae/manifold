import AppKit
import GhosttyKit

/// What ghostty says of a surface's grid now: its cells' size, padding,
/// columns and rows, the cursor, the screen's state.
func cellInfo(of surface: ghostty_surface_t) -> ghostty_manifold_info_s {
    var info = ghostty_manifold_info_s()
    ghostty_surface_manifold_info(surface, &info)
    return info
}

/// A terminal's cells in a view of it, which isn't flipped: rows counted
/// from the top, the view's y from the bottom.
struct CellGrid {
    let info: ghostty_manifold_info_s
    /// The view's height.
    let height: CGFloat

    init(_ info: ghostty_manifold_info_s, height: CGFloat) {
        self.info = info
        self.height = height
    }

    var cellWidth: CGFloat { CGFloat(info.cell_width) }
    var cellHeight: CGFloat { CGFloat(info.cell_height) }

    /// A cell's rectangle (`width` cells' across, from it).
    func rect(col: Int, row: Int, width: Int = 1) -> CGRect {
        CGRect(x: CGFloat(info.pad_left) + CGFloat(col) * cellWidth, y: height - CGFloat(info.pad_top) - CGFloat(row + 1) * cellHeight,
               width: CGFloat(width) * cellWidth, height: cellHeight)
    }

    /// A point some way into the cells: (col 2.5, row 0.5) the middle of
    /// the top row's third.
    func point(col: Double, row: Double) -> NSPoint {
        NSPoint(x: info.pad_left + col * info.cell_width, y: Double(height) - info.pad_top - row * info.cell_height)
    }

    /// The cell a point is in, if it's in one.
    func cell(at p: NSPoint) -> (col: Int, row: Int)? {
        guard info.cell_width > 0, info.cell_height > 0 else { return nil }
        let x = Double(p.x) - info.pad_left, y = Double(height - p.y) - info.pad_top
        guard x >= 0, y >= 0 else { return nil }
        let col = Int(x / info.cell_width), row = Int(y / info.cell_height)
        guard col < Int(info.cols), row < Int(info.rows) else { return nil }
        return (col, row)
    }
}
