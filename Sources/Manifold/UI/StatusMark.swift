import AppKit
import ManifoldCore

/// How a block's status shows by its name (§3.7), wherever its name is —
/// a sidebar row, a tile's bar, an overview's card: one glyph at the
/// trailing edge, the same everywhere: three dots while it's at work, a
/// filled dot when there's something for you — amber, needed; the done
/// colour, done and not seen; red, failed — gone once seen; asleep or
/// inactive, a moon, the name dimmed. A host's states (connecting, offline, quiet, watching)
/// are glyphs too, and a notebook's cells their own.
struct StatusMark: Equatable {
    /// The glyph at the trailing edge, if any.
    var glyph: StatusGlyph.Look?
    /// The name dimmed: asleep, an inactive terminal.
    var dim = false

    init(_ look: StatusGlyph.Look?) {
        switch look {
        case nil, .done(read: true)?, .failed(read: true)?: break
        case .inactive?:
            glyph = .inactive
            dim = true
        default: glyph = look
        }
    }

    init(of block: Block?) {
        self.init(StatusGlyph.look(of: block))
    }
}

/// A status in a word, in a capsule (`StatusMark`): amber for what
/// needs you, red for failed, grey for done; a percent alone, no capsule.
enum StatusPill {
    enum Kind: Equatable {
        case needs(String)
        case done
        case failed
        case progress(Int)
        /// A word in grey, not a state that wants anything (Editing).
        case note(String)

        var text: String {
            switch self {
            case .note(let w): w
            case .needs(let w): w
            case .done: "Done"
            case .failed: "Failed"
            case .progress(let p): "\(p)%"
            }
        }
    }

    /// What a blocked program needs, in a word.
    static func words(_ kind: BlockedKind?) -> String {
        switch kind {
        case .permission?: "Permission"
        case .question?: "Question"
        case .auth?: "Sign in"
        case nil: "Needs you"
        }
    }

    static let height: CGFloat = 16
    static let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let figures = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private static func ink(_ kind: Kind) -> NSColor {
        switch kind {
        case .needs: Status.attention
        case .failed: Status.failed
        case .done, .progress, .note: Theme.secondaryText
        }
    }

    private static func ground(_ kind: Kind) -> NSColor? {
        switch kind {
        case .needs: Status.attention.withAlphaComponent(0.16)
        case .failed: Status.failed.withAlphaComponent(0.14)
        case .done, .note: Pill.ground
        case .progress: nil
        }
    }

    private static func attributed(_ kind: Kind) -> NSAttributedString {
        let f = if case .progress = kind { figures } else { font }
        return NSAttributedString(string: kind.text, attributes: [.font: f, .foregroundColor: ink(kind)])
    }

    /// Short of room: a dot in its color for the word (a percent stays).
    static func compactSize(_ kind: Kind) -> NSSize {
        if case .progress = kind { return size(kind) }
        return NSSize(width: 8, height: height)
    }

    static func drawCompact(_ kind: Kind, in r: NSRect) {
        if case .progress = kind { return draw(kind, in: r) }
        ink(kind).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.midX - 3.5, y: r.midY - 3.5, width: 7, height: 7)).fill()
    }

    static func size(_ kind: Kind) -> NSSize {
        let w = ceil(attributed(kind).size().width)
        if case .progress = kind { return NSSize(width: w + 2, height: height) }
        return NSSize(width: w + 12, height: height)
    }

    static func draw(_ kind: Kind, in r: NSRect) {
        if let g = ground(kind) {
            g.setFill()
            NSBezierPath(roundedRect: r, xRadius: Radius.capsule(r.height), yRadius: Radius.capsule(r.height)).fill()
        }
        let s = attributed(kind)
        let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font
        let w = s.size().width
        // By the letters' cap height, so they sit in the middle.
        let baseline = r.minY + (r.height - f.capHeight) / 2
        let x = if case .progress = kind { r.maxX - w - 1 } else { (r.midX - w / 2).rounded() }
        s.draw(at: NSPoint(x: x, y: baseline + f.descender))
    }
}

/// A `StatusPill` as a view, for a row laid out by views.
final class StatusPillView: NSView {
    var kind: StatusPill.Kind? { didSet { if kind != oldValue { needsDisplay = true; isHidden = kind == nil } } }
    /// Short of room: a dot for the word.
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    var wanted: NSSize { kind.map { compact ? StatusPill.compactSize($0) : StatusPill.size($0) } ?? .zero }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let kind else { return }
        if compact { StatusPill.drawCompact(kind, in: bounds) } else { StatusPill.draw(kind, in: bounds) }
    }
}
