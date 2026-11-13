import Foundation
import ManifoldCore

/// How long ago something was, said shortly (a card's, a row's): within
/// the hour, how long ("now", "4m"; "just now", "4 min. ago"); past it,
/// when — its time (3:04PM), past a day its weekday too (Mon3:04PM), past
/// a week its date (2Jan06). `BlockSummary.ago` is the rule.
enum Age {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// In a word: now, 4m; 3:04PM, Mon3:04PM, 2Jan06.
    static func short(_ stamp: Stamp) -> String { BlockSummary.ago(stamp.date, now: Date()) }

    /// In a few words: just now, 4 min. ago; 3:04PM, Mon3:04PM, 2Jan06.
    static func ago(_ stamp: Stamp) -> String { ago(stamp.date) }

    static func ago(_ d: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(d) < 60 { return "just now" }
        guard BlockSummary.isRelative(d, now: now) else { return BlockSummary.when(d, now: now) }
        return relative.localizedString(for: d, relativeTo: now)
    }

    /// As `short`, in a phrase: just now, 4m ago; 3:04PM.
    static func since(_ stamp: Stamp) -> String { BlockSummary.since(stamp.date, now: Date()) }
}
