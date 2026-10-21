import Foundation
import ManifoldCore

/// A card of a block's neighborhood: the block, how it's connected, and
/// what made the connection.
struct FootCard {
    var block: BlockID
    var title: String
    var symbol: String
    /// The context the edge was made with, or how often for the trail.
    var detail: String
    var at: Stamp?
}

/// One bunch of a block's neighborhood (§3.5): an edge kind and
/// direction, how many, and its cards, newest first. The Links
/// organization in the sidebar shows them.
struct FootBunch {
    enum Role { case openedFrom, openedHere, placedIn, before, after, linked }
    var role: Role
    var title: String
    var symbol: String
    var cards: [FootCard]
    var count: Int { cards.count }
}

enum Age {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// How long ago, in a word: now, 4m, 2h, 3d.
    static func short(_ stamp: Stamp) -> String {
        let s = Date().timeIntervalSince(stamp.date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// How long ago, in a few words.
    static func ago(_ stamp: Stamp) -> String {
        let d = stamp.date
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return relative.localizedString(for: d, relativeTo: Date())
    }
}
