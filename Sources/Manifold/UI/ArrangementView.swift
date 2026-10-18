import AppKit
import ManifoldCore

/// An arrangement on screen, through one of its lenses: stacks, tiling, or
/// the list. The three lens views are kept, and the one for the
/// arrangement's layout fills this view; the placements' views move
/// between them.
final class ArrangementView: NSView {
    let stacks = TabContentView()
    let tiling = TilingView()
    let list = ListLensView()
    private(set) var shownLayout: ArrangementLayout = .stacks
    private(set) var columns: [[Shown]] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(stacks)
    }

    required init?(coder: NSCoder) { fatalError() }

    var current: NSView {
        switch shownLayout {
        case .stacks: stacks
        case .tiling: tiling
        case .list: list
        }
    }

    /// The placements' views on screen.
    var views: [PaneContent] {
        switch shownLayout {
        case .stacks: stacks.panes
        case .tiling: tiling.views
        case .list: list.views
        }
    }

    func show(_ a: ArrangementState?, columns: [[Shown]], view: (Shown) -> PaneContent) {
        let a = a ?? ArrangementState()
        self.columns = columns
        if a.layout != shownLayout {
            // Views leave the old lens before the new one takes them.
            for v in views { v.removeFromSuperview() }
            current.removeFromSuperview()
            shownLayout = a.layout
            addSubview(current)
            current.frame = bounds
        }
        switch shownLayout {
        case .stacks:
            let shown: [TabContentView.ColumnContent] = columns.compactMap { column in
                guard let top = column.last, let first = column.first else { return nil }
                return .init(id: first.id, view: view(top), beneath: column.dropLast().reversed())
            }
            stacks.show(shown, fractions: a.fractions, focused: a.focused)
        case .tiling:
            let tiles = columns.map { $0.map { TilingView.Tile(shown: $0, view: view($0)) } }
            tiling.show(tiles, fractions: a.fractions, heights: a.heights, focused: a.focused)
        case .list:
            let focused = columns.flatMap { $0 }.first { $0.id == a.focused } ?? columns.first?.first
            list.show(columns, focused: a.focused, view: focused.map(view))
        }
    }

    func clear() {
        for v in views { v.removeFromSuperview() }
        stacks.show([], fractions: [], focused: nil)
        tiling.show([], fractions: [], heights: [:], focused: nil)
        list.show([], focused: nil, view: nil)
        columns = []
    }

    override func layout() {
        super.layout()
        current.frame = bounds
    }

    /// Where a column is, in this view's coordinates (stacks and tiling).
    func frame(ofColumn i: Int) -> NSRect? {
        switch shownLayout {
        case .stacks: stacks.frame(ofColumn: i)
        case .tiling, .list: nil
        }
    }

    /// A placement's view, if on screen.
    func view(of placement: PlacementID) -> PaneContent? {
        views.first { $0.placement == placement }
    }
}
