import Foundation

/// Moving and deleting through text whose markup is hidden, as Bike does.
///
/// Where a span begins or ends, two places to put the caret sit side by
/// side on screen: outside the span and inside it, with the hidden markup
/// between them. The caret stops at both, never within the markup, and says
/// which it is by the side its tail points to — toward the text it is
/// attached to, away from the markup.
public enum InlineEditing {

    /// A place strictly within hidden markup is not a place for the caret;
    /// it goes to the markup's end when moving forward, its start when back.
    public static func snap(_ location: Int, runs: [NSRange], forward: Bool) -> Int {
        for run in runs where location > run.location && location < NSMaxRange(run) {
            return forward ? NSMaxRange(run) : run.location
        }
        return location
    }

    /// The next place for the caret, one character on. Between two adjacent
    /// runs of markup the caret stops once; a run with nothing shown in it
    /// (a comment) is passed over as if it were not there.
    public static func step(from location: Int, forward: Bool, text: NSString, within bounds: NSRange,
                            spans: [InlineSpan]) -> Int {
        let runs = spans.flatMap(\.markup)
        let wholes = spans.filter { $0.kind == .comment }.map(\.range)
        // An image is one thing to the caret, passed in one step.
        let images = spans.filter(\.isImage).map(\.range)
        var location = location
        if forward {
            while let whole = wholes.first(where: { $0.location == location }) { location = NSMaxRange(whole) }
            if let image = images.first(where: { $0.location == location }) { return NSMaxRange(image) }
            guard location < NSMaxRange(bounds) else { return location }
            let next = NSMaxRange(text.rangeOfComposedCharacterSequence(at: location))
            return snap(next, runs: runs, forward: true)
        } else {
            while let whole = wholes.first(where: { NSMaxRange($0) == location }) { location = whole.location }
            if let image = images.first(where: { NSMaxRange($0) == location }) { return image.location }
            guard location > bounds.location else { return location }
            let previous = text.rangeOfComposedCharacterSequence(at: location - 1).location
            return snap(previous, runs: runs, forward: false)
        }
    }

    public enum Tail: Equatable, Sendable { case left, right }

    /// Which way the caret's tail points at a place: away from the markup
    /// beside it, or nowhere when there is none.
    public static func tail(at location: Int, spans: [InlineSpan]) -> Tail? {
        let runs = spans.filter { $0.kind != .comment && !$0.isImage }.flatMap(\.markup)
        if runs.contains(where: { NSMaxRange($0) == location }) { return .right }
        if runs.contains(where: { $0.location == location }) { return .left }
        return nil
    }

    /// What a single Delete (backward) or Forward Delete takes away: the
    /// nearest shown character, never markup; and the whole span when that
    /// character is all it shows. Nil when there is nothing within the row.
    public static func deletion(at location: Int, forward: Bool, text: NSString, within bounds: NSRange,
                                spans: [InlineSpan]) -> NSRange? {
        // An image beside the caret is what Delete takes, with its size.
        if let image = spans.first(where: { $0.isImage && (forward ? $0.range.location == location : NSMaxRange($0.range) == location) }) {
            return image.range
        }
        let runs = spans.flatMap(\.markup)
        var edge = location
        // Walk over the markup between the caret and the character.
        while true {
            if forward, let run = runs.first(where: { $0.location == edge && $0.length > 0 }) {
                edge = NSMaxRange(run)
            } else if !forward, let run = runs.first(where: { NSMaxRange($0) == edge && $0.length > 0 }) {
                edge = run.location
            } else {
                break
            }
        }
        if forward ? edge >= NSMaxRange(bounds) : edge <= bounds.location { return nil }
        let character = text.rangeOfComposedCharacterSequence(at: forward ? edge : edge - 1)
        // The last character of a span takes the span with it, rather than
        // leave markup around nothing.
        if let span = spans.first(where: { $0.content == character && !$0.markup.isEmpty }) {
            return span.range
        }
        return character
    }

    /// The parts of a range that an edit may take away: all of it, except
    /// markup whose span reaches outside the range, which stays so the
    /// span's text keeps its style.
    public static func deletablePieces(of range: NSRange, spans: [InlineSpan]) -> [NSRange] {
        var kept: [NSRange] = []
        for span in spans where !span.markup.isEmpty {
            let inside = span.range.location >= range.location && NSMaxRange(span.range) <= NSMaxRange(range)
            if inside { continue }
            for run in span.markup {
                let covered = NSIntersectionRange(run, range)
                if covered.length > 0 { kept.append(covered) }
            }
        }
        guard !kept.isEmpty else { return [range] }
        var pieces: [NSRange] = []
        var start = range.location
        for keep in kept.sorted(by: { $0.location < $1.location }) {
            if keep.location > start { pieces.append(NSRange(location: start, length: keep.location - start)) }
            start = max(start, NSMaxRange(keep))
        }
        if start < NSMaxRange(range) { pieces.append(NSRange(location: start, length: NSMaxRange(range) - start)) }
        return pieces
    }
}
