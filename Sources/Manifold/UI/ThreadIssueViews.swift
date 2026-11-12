import AppKit
import ManifoldCore

/// A thread laid out as an issue's conversation is (GitHub's), in
/// Manifold's own materials: each comment a card — a header band with its
/// author and when, a caret toward its author's round picture at the left,
/// its words below — and between the cards, on a line running down the
/// conversation, what happened: an agent asked, resolved, reopened, edited.
enum IssueLayout {
    /// The author's picture, at the left of each card.
    static func avatar(inTile: Bool) -> CGFloat { inTile ? 32 : 24 }
    /// Between the picture and its card.
    static let gap: CGFloat = 12
    /// The line down the conversation: under the cards, this far into them.
    static let lineInset: CGFloat = 18
    static func lineX(inTile: Bool) -> CGFloat { avatar(inTile: inTile) + gap + lineInset }
    static let lineWidth: CGFloat = 2
    /// The header band's ground: yours a touch of the accent, as an issue
    /// sets its author's apart; the rest the text's faintest tint.
    static let headerGround = NSColor(name: nil) { a in
        (a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white : NSColor.black).withAlphaComponent(0.035)
    }
    static var yourHeaderGround: NSColor { Theme.accent.withAlphaComponent(0.09) }
}

/// The conversation's list: the line down it drawn behind its rows.
final class IssueList: NSStackView {
    override var isFlipped: Bool { true }
    /// Where the line runs (nil: none — a chat with nothing in it).
    var lineX: CGFloat? { didSet { if lineX != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let x = lineX, arrangedSubviews.count > 1 else { return }
        let top = arrangedSubviews.first?.frame.midY ?? 0, bottom = arrangedSubviews.last?.frame.midY ?? bounds.maxY
        Theme.divider.setFill()
        NSRect(x: x - IssueLayout.lineWidth / 2, y: top, width: IssueLayout.lineWidth, height: max(0, bottom - top)).fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// A comment as an issue's: its author's picture at the left; a card —
/// a header band (who, "commented", when, edited; its ⋯ menu), the words
/// below, a caret from the band to the picture.
final class IssueCommentView: NSView {
    /// Its words, as written.
    let markdown: String
    /// Its pieces, top to bottom: its words between code blocks, and each
    /// code block — its own view, scrolled sideways rather than wrapped.
    private let parts: [NSView]
    private var proses: [CommentText] { parts.compactMap { $0 as? CommentText } }
    /// Every text in it (words and code): what ⌘ marks and ⌘F searches.
    var texts: [PillTextView] { parts.compactMap { ($0 as? CommentText)?.text ?? ($0 as? CodeBlockView)?.text } }
    var onAuthor: (() -> Void)?
    var onLink: ((URL) -> Void)? { didSet { proses.forEach { $0.onLink = onLink } } }
    /// Yours: Edit Comment, in its ⋯ menu and its words' own.
    var onEdit: (() -> Void)? { didSet { proses.forEach { $0.onEdit = onEdit } } }
    /// ⌘-clicked on a path or address in it.
    var onCommandLink: ((String, Bool) -> Void)? { didSet { texts.forEach { $0.onCommandLink = onCommandLink } } }
    /// Quote Reply: its words, quoted, into the composer.
    var onQuote: ((String) -> Void)?

    private let entry: ThreadEntry
    private let inTile: Bool
    private let avatar: Avatar
    private let card = CardView()
    private let name: NSTextField
    private let when: NSTextField
    private let more = IconButton("ellipsis", size: 11, tip: "More")
    private let pad: CGFloat
    private let headerHeight: CGFloat
    /// When it was said, in full and short (a narrow card's).
    private let said: (full: String, short: String)
    /// Between its pieces.
    private static let partGap: CGFloat = 8

    init(_ e: ThreadEntry, text: String, icon: NSImage?, inTile: Bool, size: CGFloat, font: NSFont?, lineHeight: CGFloat = 0) {
        entry = e
        markdown = text
        self.inTile = inTile
        let code = font == nil ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : FontTheme.current.font(.monospaced, size: size - 1)
        parts = CommentPieces.split(text).map { piece -> NSView in
            switch piece {
            case let .words(md): return CommentText(markdown: md, size: size, font: font, boxes: true, lineHeight: lineHeight)
            case let .code(lines): return CodeBlockView(lines, font: code)
            }
        }
        avatar = Avatar(e.author, icon: icon)
        pad = inTile ? 16 : 12
        headerHeight = inTile ? 38 : 32
        let headSize = inTile ? 13 : 12
        name = NSTextField.label(e.author.isYou ? "You" : e.author.name, font: .systemFont(ofSize: CGFloat(headSize), weight: .semibold))
        let ago = BlockSummary.ago(e.at, now: Date()) ?? ""
        let full = (ago == "now" ? "commented just now" : "commented \(ago) ago") + (e.edited == nil ? "" : " · edited")
        said = (full, ago + (e.edited == nil ? "" : " · edited"))
        when = NSTextField.label(full, font: .systemFont(ofSize: CGFloat(headSize)), color: Theme.secondaryText)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        when.toolTip = DateFormatter.localizedString(from: e.at.date, dateStyle: .medium, timeStyle: .short)
            + (e.edited.map { "\nEdited " + DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .short) } ?? "")
        if case let .you(machine) = e.author { name.toolTip = machine.map { "From \($0)" } }
        card.yours = e.author.isYou
        card.headerHeight = headerHeight
        card.caretY = headerHeight / 2
        avatar.onClick = { [weak self] in self?.onAuthor?() }
        // Laid out here, by hand, not by constraints.
        for p in parts { p.translatesAutoresizingMaskIntoConstraints = true }
        more.target = self
        more.action = #selector(showMore)
        for v in [card, avatar, name, when, more] + parts as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var cardX: CGFloat { IssueLayout.avatar(inTile: inTile) + IssueLayout.gap }
    private func bodyWidth(_ width: CGFloat) -> CGFloat { max(60, width - cardX - 2 * pad) }

    /// A piece's height at the card's width.
    private func height(_ p: NSView, _ w: CGFloat) -> CGFloat {
        (p as? CommentText)?.height(forWidth: w) ?? (p as? CodeBlockView)?.height ?? 0
    }

    private func partsHeight(_ w: CGFloat) -> CGFloat {
        parts.reduce(0) { $0 + height($1, w) } + CGFloat(max(0, parts.count - 1)) * Self.partGap
    }

    override var intrinsicContentSize: NSSize {
        let w = bounds.width > 0 ? bounds.width : 400
        let h = headerHeight + pad + partsHeight(bodyWidth(w)) + pad
        return NSSize(width: NSView.noIntrinsicMetric, height: max(h, IssueLayout.avatar(inTile: inTile)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let a = IssueLayout.avatar(inTile: inTile)
        // On the band's middle, as the caret pointing to it is.
        avatar.frame = NSRect(x: 0, y: ((headerHeight - a) / 2).rounded(), width: a, height: a)
        card.frame = NSRect(x: cardX - 7, y: 0, width: bounds.width - cardX + 7, height: bounds.height)
        card.inset = 7
        more.frame = NSRect(x: bounds.maxX - pad - 18, y: (headerHeight - 18) / 2, width: 18, height: 18)
        name.sizeToFit()
        // When, in full where it fits; else short ("28m"), as an issue's does.
        when.stringValue = said.full
        when.sizeToFit()
        let room = more.frame.minX - 8 - (cardX + pad + name.frame.width + 5)
        if when.frame.width > room {
            when.stringValue = said.short
            when.sizeToFit()
        }
        let x = cardX + pad
        name.frame = NSRect(x: x, y: ((headerHeight - name.frame.height) / 2).rounded(), width: min(name.frame.width, bounds.width / 2), height: name.frame.height)
        when.frame = NSRect(x: name.frame.maxX + 5, y: ((headerHeight - when.frame.height) / 2).rounded(),
                            width: max(0, more.frame.minX - 8 - name.frame.maxX - 5), height: when.frame.height)
        var y = headerHeight + pad
        let w = bodyWidth(bounds.width)
        for p in parts {
            let h = height(p, w)
            p.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h + Self.partGap
        }
    }

    /// ⋯: Quote Reply, Copy Text; yours, Edit Comment.
    @objc private func showMore() {
        let menu = NSMenu()
        if let onEdit { menu.addItem(ClosureMenuItem("Edit Comment", symbol: "pencil") { onEdit() }) }
        let words = markdown
        if let onQuote { menu.addItem(ClosureMenuItem("Quote Reply", symbol: "text.quote") { onQuote(words) }) }
        menu.addItem(ClosureMenuItem("Copy Text", symbol: "doc.on.doc") { NSPasteboard.copy(words) })
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY + 2), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onEdit else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Edit Comment", symbol: "pencil") { onEdit() })
        return menu
    }

    /// The card: a hairline round it on the panel's ground, its header band
    /// tinted, a hairline under the band, and a caret at its left edge
    /// pointing to the picture. Drawn `inset` in from its left, where the
    /// caret goes.
    final class CardView: NSView {
        var yours = false
        var headerHeight: CGFloat = 34
        var caretY: CGFloat = 12
        var inset: CGFloat = 7
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let r = NSRect(x: inset, y: 0, width: bounds.width - inset, height: bounds.height).insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: r, xRadius: Radius.control, yRadius: Radius.control)
            Theme.panel.setFill()
            shape.fill()
            // The band.
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            (yours ? IssueLayout.yourHeaderGround : IssueLayout.headerGround).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: headerHeight).fill()
            EdgeColor.hairline.setFill()
            NSRect(x: r.minX, y: r.minY + headerHeight - 0.5, width: r.width, height: 0.5).fill()
            NSGraphicsContext.restoreGraphicsState()
            EdgeColor.hairline.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            // The caret, on the band's middle: its two edges the card's, alike
            // above and below, its inside the band's — over the card's edge
            // there, so the band runs out into it unbroken.
            let y = (caretY).rounded() + 0.5, h: CGFloat = 7, tip = r.minX - inset + 1
            let inside = NSBezierPath()
            inside.move(to: NSPoint(x: r.minX + 1, y: y - h))
            inside.line(to: NSPoint(x: tip, y: y))
            inside.line(to: NSPoint(x: r.minX + 1, y: y + h))
            inside.close()
            Theme.panel.setFill()
            inside.fill()
            (yours ? IssueLayout.yourHeaderGround : IssueLayout.headerGround).setFill()
            inside.fill()
            EdgeColor.hairline.setStroke()
            let edge = NSBezierPath()
            edge.move(to: NSPoint(x: r.minX, y: y - h))
            edge.line(to: NSPoint(x: tip, y: y))
            edge.line(to: NSPoint(x: r.minX, y: y + h))
            edge.lineWidth = 1
            edge.lineJoinStyle = .miter
            edge.stroke()
        }
    }
}

/// Something that happened, on the conversation's line: a round badge on
/// the line (its symbol, or an agent's mark), and what happened beside it,
/// its author's name in bold.
final class IssueEventView: NSView {
    private let badge = Badge()
    private let label: NSTextField
    private let inTile: Bool

    init(who: String?, words: String, at: Stamp?, symbol: String, icon: NSImage?, tone: NSColor?, inTile: Bool) {
        self.inTile = inTile
        let size: CGFloat = inTile ? 12.5 : 11.5
        let s = NSMutableAttributedString()
        if let who { s.append(NSAttributedString(string: who + " ", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: tone ?? Theme.text])) }
        s.append(NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: tone ?? Theme.secondaryText]))
        if let at, let ago = BlockSummary.ago(at, now: Date()) {
            s.append(NSAttributedString(string: " · " + (ago == "now" ? "just now" : ago + " ago"), attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.tertiaryText]))
        }
        label = NSTextField(labelWithAttributedString: s)
        label.lineBreakMode = .byTruncatingTail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge.symbol = symbol
        badge.icon = icon
        badge.tone = tone
        for v in [badge, label] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: inTile ? 30 : 26) }

    override func layout() {
        super.layout()
        let d: CGFloat = inTile ? 24 : 20
        let x = IssueLayout.lineX(inTile: inTile)
        badge.frame = NSRect(x: x - d / 2, y: (bounds.height - d) / 2, width: d, height: d)
        label.sizeToFit()
        label.frame = NSRect(x: badge.frame.maxX + 8, y: ((bounds.height - label.frame.height) / 2).rounded(),
                             width: max(0, bounds.width - badge.frame.maxX - 8), height: label.frame.height)
    }

    /// The badge: a disc of the window's ground ringed in the line's colour,
    /// over the line, its symbol (or the agent's mark) in it.
    final class Badge: NSView {
        var symbol = "circle"
        var icon: NSImage?
        var tone: NSColor?
        override func draw(_ dirtyRect: NSRect) {
            let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            Theme.windowBackground.setFill()
            disc.fill()
            Theme.divider.setStroke()
            disc.lineWidth = 1.5
            disc.stroke()
            let side = bounds.height * 0.55
            let r = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            if let icon {
                // A one-color mark (a template): in the badge's ink, as its symbols are.
                guard icon.isTemplate else { return icon.draw(in: r) }
                let ink = tone ?? Theme.secondaryText
                NSImage(size: r.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }.draw(in: r)
                return
            }
            Theme.symbol(symbol, size: side * 0.8, weight: .medium, color: tone ?? Theme.secondaryText)?.draw(centeredAt: NSPoint(x: r.midX, y: r.midY))
        }
    }
}

/// A comment cut into what's laid out as words and what's laid out as
/// code: each fenced code block (```, at a line's start) its own piece.
enum CommentPieces {
    enum Piece: Equatable { case words(String), code(String) }

    static func split(_ markdown: String) -> [Piece] {
        var out: [Piece] = []
        var words: [Substring] = [], code: [Substring] = []
        var fence: String?
        func flushWords() {
            let w = words.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !w.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.words(w)) }
            words = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.drop { $0 == " " }
            let indent = line.count - t.count
            if let f = fence {
                if indent <= 3, t.hasPrefix(f), t.drop(while: { String($0) == String(f.first!) }).trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(.code(code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if indent <= 3, t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushWords()
                fence = String(t.prefix { $0 == t.first })
            } else {
                words.append(line)
            }
        }
        // A fence left open: what came after it, its code.
        if fence != nil { out.append(.code(code.joined(separator: "\n"))) }
        flushWords()
        return out
    }
}

/// A comment's code block: its lines unwrapped on a tint, padded, scrolled
/// sideways when they're wider than the card.
final class CodeBlockView: NSView {
    let text = PillTextView()
    private let scroll = NSScrollView()
    private static let pad: CGFloat = 10
    /// Its height: its lines', and the room round them.
    let height: CGFloat

    init(_ code: String, font: NSFont) {
        let storage = NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: Theme.text])
        _ = text.layoutManager
        text.textStorage?.setAttributedString(storage)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: Self.pad, height: Self.pad)
        text.textContainer?.lineFragmentPadding = 0
        // Unwrapped: as wide as its longest line.
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!) ?? .zero
        height = ceil(used.height) + 2 * Self.pad
        text.frame = NSRect(x: 0, y: 0, width: ceil(used.width) + 2 * Self.pad, height: height)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = text
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        text.frame.size.width = max(text.frame.width, bounds.width)
        text.frame.size.height = bounds.height
    }

    override func draw(_ dirtyRect: NSRect) {
        MarkdownText.codeGround.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Radius.inline, yRadius: Radius.inline).fill()
    }
}
