import Foundation
import ManifoldCore

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
