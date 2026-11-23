import Foundation
import ManifoldCore

/// How long ago something was, said shortly (a card's, a row's): within
/// the hour, how long ("now", "4m"; "just now", "4m ago"); past it,
/// when — its time (3:04PM), past a day its weekday too (Mon3:04PM), past
/// a week its date (2Jan06). `BlockSummary.ago` is the rule.
enum Age {
    /// In a word: now, 4m; 3:04PM, Mon3:04PM, 2Jan06.
    static func short(_ stamp: Stamp) -> String { BlockSummary.ago(stamp.date, now: Date()) }

    /// In a few words, as every "ago" is said: just now, 4m ago; 3:04PM, Mon3:04PM, 2Jan06.
    static func ago(_ stamp: Stamp) -> String { ago(stamp.date) }

    static func ago(_ d: Date) -> String { BlockSummary.since(d, now: Date()) }

    /// As `short`, in a phrase: just now, 4m ago; 3:04PM.
    static func since(_ stamp: Stamp) -> String { BlockSummary.since(stamp.date, now: Date()) }
}
