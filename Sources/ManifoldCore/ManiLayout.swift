import Foundation

/// A workspace's tiles as `mani` names and lists them: where each is, as a
/// share of the window (x, y from the top left, width, height), which share
/// an edge, and the positions (`@left`, `@rightmost`, `@2`, …) each answers
/// to, from a reference tile (the one `mani` was run in, else the focused).
public struct ManiLayout {
    public struct Frame: Equatable, Sendable {
        public var x, y, width, height: Double
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var array: [Double] { [x, y, width, height].map { ($0 * 1000).rounded() / 1000 } }
    }

    public enum Direction: String, CaseIterable, Sendable {
        case left, right, above, below
    }

    public let arrangement: ArrangementState
    /// Shown tiles' frames; a stashed tile has none (it's behind another).
    public private(set) var frames: [PlacementID: Frame] = [:]
    /// Shown tiles in reading order: columns left to right, each top down.
    public private(set) var order: [PlacementID] = []

    public init(_ arrangement: ArrangementState) {
        self.arrangement = arrangement
        var x = 0.0
        for (c, column) in arrangement.columns.enumerated() {
            let w = c < arrangement.fractions.count ? arrangement.fractions[c] : 1 / Double(arrangement.columns.count)
            var y = 0.0
            for p in column where !arrangement.isStashed(p.id) {
                let h = arrangement.height(of: p.id)
                frames[p.id] = Frame(x: x, y: y, width: w, height: h)
                order.append(p.id)
                y += h
            }
            x += w
        }
    }

    private static let eps = 0.002

    /// The tiles stacked behind a shown one, nearest first.
    public func stack(behind id: PlacementID) -> [PlacementID] {
        guard let (c, _) = arrangement.locate(id) else { return [] }
        return arrangement.stashedTiles(inColumn: c).filter { arrangement.tile(behind: $0.id)?.id == id }.map(\.id)
    }

    /// The shown tiles wholly to one side of `id`, nearest first: by the
    /// gap to them, then by how far their middle is from its, across.
    public func toward(_ d: Direction, of id: PlacementID) -> [PlacementID] {
        guard let r = frames[id] else { return [] }
        func score(_ f: Frame) -> (Double, Double)? {
            switch d {
            case .right: f.x >= r.maxX - Self.eps ? (f.x - r.maxX, abs((f.y + f.maxY) - (r.y + r.maxY)) / 2) : nil
            case .left: f.maxX <= r.x + Self.eps ? (r.x - f.maxX, abs((f.y + f.maxY) - (r.y + r.maxY)) / 2) : nil
            case .below: f.y >= r.maxY - Self.eps && overlap(f.x, f.maxX, r.x, r.maxX) > Self.eps ? (f.y - r.maxY, abs((f.x + f.maxX) - (r.x + r.maxX)) / 2) : nil
            case .above: f.maxY <= r.y + Self.eps && overlap(f.x, f.maxX, r.x, r.maxX) > Self.eps ? (r.y - f.maxY, abs((f.x + f.maxX) - (r.x + r.maxX)) / 2) : nil
            }
        }
        return order.compactMap { p -> (PlacementID, (Double, Double))? in
            guard p != id, let f = frames[p], let s = score(f) else { return nil }
            return (p, s)
        }.sorted { a, b in
            abs(a.1.0 - b.1.0) > Self.eps ? a.1.0 < b.1.0 : a.1.1 < b.1.1
        }.map(\.0)
    }

    /// The tiles sharing an edge with `id`, on each side that has any.
    public func adjacent(_ id: PlacementID) -> [Direction: [PlacementID]] {
        guard let r = frames[id] else { return [:] }
        var out: [Direction: [PlacementID]] = [:]
        for d in Direction.allCases {
            let touching = toward(d, of: id).filter { p in
                guard let f = frames[p] else { return false }
                switch d {
                case .right: return abs(f.x - r.maxX) < Self.eps && overlap(f.y, f.maxY, r.y, r.maxY) > Self.eps
                case .left: return abs(f.maxX - r.x) < Self.eps && overlap(f.y, f.maxY, r.y, r.maxY) > Self.eps
                case .below: return abs(f.y - r.maxY) < Self.eps
                case .above: return abs(f.maxY - r.y) < Self.eps
                }
            }
            // In screen order, top to bottom or left to right.
            if !touching.isEmpty { out[d] = touching.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } }
        }
        return out
    }

    /// The outermost shown tile on a side (`@leftmost`, `@top`, …): of
    /// those there, the one nearest `from` across.
    public func outermost(_ d: Direction, from: PlacementID?, among: [PlacementID]? = nil) -> PlacementID? {
        let pool = (among ?? order).filter { frames[$0] != nil }
        let r = from.flatMap { frames[$0] }
        func edge(_ f: Frame) -> Double {
            switch d { case .left: f.x; case .right: -f.maxX; case .above: f.y; case .below: -f.maxY }
        }
        func across(_ f: Frame) -> Double {
            guard let r else { return d == .left || d == .right ? f.y : f.x }
            return d == .left || d == .right ? abs((f.y + f.maxY) - (r.y + r.maxY)) : abs((f.x + f.maxX) - (r.x + r.maxX))
        }
        return pool.min { a, b in
            let fa = frames[a]!, fb = frames[b]!
            return abs(edge(fa) - edge(fb)) > Self.eps ? edge(fa) < edge(fb) : across(fa) < across(fb)
        }
    }

    public static let outermostNames: [String: Direction] = ["leftmost": .left, "rightmost": .right, "top": .above, "bottom": .below]

    /// The positions `id` answers to from `from`: its number, a side of
    /// `from` it's nearest on, the outermost on a side, beneath `from`.
    public func names(of id: PlacementID, from: PlacementID?) -> [String] {
        var out: [String] = []
        if let from {
            for d in Direction.allCases where toward(d, of: from).first == id { out.append("@" + d.rawValue) }
            if stack(behind: from).first == id { out.append("@under") }
        }
        for (name, d) in Self.outermostNames.sorted(by: { $0.key < $1.key }) where outermost(d, from: from) == id { out.append("@" + name) }
        if let n = order.firstIndex(of: id), n < 9 { out.append("@\(n + 1)") }
        return out
    }

    public enum Resolved: Equatable {
        case tile(PlacementID)
        case none(String)
        case ambiguous([PlacementID])
    }

    /// A position (`left`, `rightmost`, `under`, `3`, or "" for anywhere)
    /// from `from`, among tiles that `matches` (a kind asked for).
    public func resolve(_ position: String, from: PlacementID?, matches: (PlacementID) -> Bool = { _ in true }) -> Resolved {
        if let d = Direction(rawValue: position) {
            guard let from else { return .none("there's no tile to be \(position) of") }
            return toward(d, of: from).first(where: matches).map { .tile($0) } ?? .none("nothing \(position == "above" || position == "below" ? position : "to the \(position) of") it")
        }
        if let d = Self.outermostNames[position] {
            return outermost(d, from: from, among: order.filter(matches)).map { .tile($0) } ?? .none("nothing there")
        }
        if position == "under" {
            guard let from else { return .none("there's no tile to be under") }
            return stack(behind: from).first(where: matches).map { .tile($0) } ?? .none("nothing is stacked under it")
        }
        if let n = Int(position) {
            let pool = order.filter(matches)
            return n >= 1 && n <= pool.count ? .tile(pool[n - 1]) : .none("there's no tile \(n)")
        }
        if position.isEmpty {
            // Anywhere: one shown, else one stacked away.
            let shown = order.filter(matches)
            if shown.count == 1 { return .tile(shown[0]) }
            if shown.count > 1 { return .ambiguous(shown) }
            let stashed = arrangement.placements.map(\.id).filter { frames[$0] == nil && matches($0) }
            if stashed.count == 1 { return .tile(stashed[0]) }
            return stashed.isEmpty ? .none("there's none") : .ambiguous(stashed)
        }
        return .none("no position @\(position)")
    }

    private func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }
}

/// A name `mani` was given: `@position[:kind]` (`@right:diff`, `@:pdf`,
/// `@here`), or anything else (an id, a path, a title).
public enum ManiName: Equatable {
    case at(String, kind: String?)
    case other(String)

    public init(_ s: String) {
        guard s.hasPrefix("@") else { self = .other(s); return }
        let body = s.dropFirst()
        if let colon = body.firstIndex(of: ":") {
            let kind = String(body[body.index(after: colon)...])
            self = .at(String(body[..<colon]), kind: kind.isEmpty ? nil : kind.lowercased())
        } else {
            self = .at(String(body), kind: nil)
        }
    }
}
