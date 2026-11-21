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

/// A word in grey in a capsule beside a status (`StatusMark`): what a
/// tile is doing that isn't a status — Editing (an $EDITOR's tile). Status
/// itself is the glyph's alone (one status rule): no word for done,
/// failed or what's needed, and no colour.
enum StatusPill {
    enum Kind: Equatable {
        case note(String)

        var text: String {
            switch self {
            case .note(let w): w
            }
        }
    }

    /// What a blocked program needs, in a word (a tooltip, a list's line).
    static func words(_ kind: BlockedKind?) -> String {
        switch kind {
        case .permission?: "Permission"
        case .question?: "Question"
        case .auth?: "Sign in"
        case nil: "Needs you"
        }
    }

    static let height: CGFloat = Pill.height
    static let font = Pill.words

    private static func attributed(_ kind: Kind) -> NSAttributedString {
        NSAttributedString(string: kind.text, attributes: [.font: font, .foregroundColor: Theme.secondaryText])
    }

    static func size(_ kind: Kind) -> NSSize {
        NSSize(width: ceil(attributed(kind).size().width) + 12, height: height)
    }

    static func draw(_ kind: Kind, in r: NSRect) {
        Pill.ground.setFill()
        NSBezierPath(roundedRect: r, xRadius: Radius.capsule(r.height), yRadius: Radius.capsule(r.height)).fill()
        let s = attributed(kind)
        let w = s.size().width
        // By the letters' cap height, so they sit in the middle.
        let baseline = r.minY + (r.height - font.capHeight) / 2
        s.draw(at: NSPoint(x: (r.midX - w / 2).rounded(), y: baseline + font.descender))
    }
}

/// A `StatusPill` as a view, for a row laid out by views.
final class StatusPillView: NSView {
    var kind: StatusPill.Kind? { didSet { if kind != oldValue { needsDisplay = true; isHidden = kind == nil } } }
    /// Short of room: the word gone (not a dot, which would read as a status).
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    var wanted: NSSize { compact ? .zero : kind.map { StatusPill.size($0) } ?? .zero }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let kind, !compact else { return }
        StatusPill.draw(kind, in: bounds)
    }
}
