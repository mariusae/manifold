import AppKit
import ManifoldCore

/// A thread laid out as a conversation on a line (§3.12) — an issue's
/// connectedness, in Manifold's own materials: down its left a thin line,
/// and on it each comment's author's mark (the comment's handle, as a
/// command's dot is in a terminal) and each thing that happened as a
/// small halo (asked, resolved, edited), the way a terminal marks its
/// commands; beside each mark its comment, a quiet tile — a hairline, a
/// slim band with who and when, the words below in the editing face.
enum IssueLayout {
    /// An author's mark on the line.
    static func mark(inTile: Bool) -> CGFloat { inTile ? 22 : 18 }
    /// Between the line's marks and the cards.
    static let gap: CGFloat = 10
    static func cardX(inTile: Bool) -> CGFloat { mark(inTile: inTile) + gap }
    /// The line, down the middle of the marks.
    static func lineX(inTile: Bool) -> CGFloat { mark(inTile: inTile) / 2 }
    static let lineWidth: CGFloat = 1.5
    /// Clear of the line round a mark or a halo.
    static let lineClearance: CGFloat = 3
    /// A comment's band: who, and when.
    static func band(inTile: Bool) -> CGFloat { inTile ? 28 : 24 }
}

/// What a row of the conversation puts on the line: where (its terms) the
/// line breaks round its mark or halo; and an accent stretch over it (New).
protocol OnTheLine: NSView {
    var lineGaps: [NSRect] { get }
}

/// The conversation's list: the line down it, from its first mark to its
/// last, drawn behind its rows and broken round their marks.
final class IssueList: NSStackView {
    override var isFlipped: Bool { true }
    /// Where the line runs (nil: none — a chat with nothing in it).
    var lineX: CGFloat? { didSet { if lineX != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard let x = lineX else { return }
        var gaps: [NSRect] = []
        for v in arrangedSubviews {
            guard let row = v as? OnTheLine else { continue }
            gaps += row.lineGaps.map { convert($0, from: row) }
        }
        guard gaps.count > 1, let top = gaps.map(\.midY).min(), let bottom = gaps.map(\.midY).max() else { return }
        Theme.divider.setFill()
        // From mark to mark, round each.
        var y = top
        for g in gaps.sorted(by: { $0.minY < $1.minY }) {
            if g.minY > y { NSRect(x: x - IssueLayout.lineWidth / 2, y: y, width: IssueLayout.lineWidth, height: g.minY - y).fill() }
            y = max(y, g.maxY)
        }
        if bottom > y { NSRect(x: x - IssueLayout.lineWidth / 2, y: y, width: IssueLayout.lineWidth, height: bottom - y).fill() }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// A comment: its author's mark on the line — its handle: dragged, the
/// comment goes with it, as a reference — and a quiet tile beside it: a
/// band with who and when (⋯ under the pointer), the words below. One more
/// of the same author's just after shares the mark above (`continued`).
final class IssueCommentView: NSView, OnTheLine, NSDraggingSource {
    /// Its words, as written.
    let markdown: String
    /// Its entry's id: what a reference to it names.
    let entryID: String
    /// Who wrote it, as its band says.
    let authorName: String
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
    /// What dragging its mark carries: a reference to it (the window's).
    var dragged: (() -> NSPasteboardWriting?)?
    /// Copy Link: its reference, as text.
    var link: (() -> String?)?
    /// Ringed, as the focused tile is: the comment gone to from a link.
    var ringed = false { didSet { if ringed != oldValue { card.ringed = ringed } } }

    private let inTile: Bool
    private let continued: Bool
    private let avatar: Avatar
    private let card = CardView()
    private let name: NSTextField
    private let when: NSTextField
    private let more = IconButton("ellipsis", size: 11, tip: "More")
    private let pad: CGFloat
    private let band: CGFloat
    /// Between its pieces.
    private static let partGap: CGFloat = 8

    init(_ e: ThreadEntry, text: String, icon: NSImage?, inTile: Bool, continued: Bool, size: CGFloat, font: NSFont?, lineHeight: CGFloat = 0) {
        markdown = text
        entryID = e.id
        authorName = e.author.isYou ? "You" : e.author.name
        self.inTile = inTile
        self.continued = continued
        let code = font == nil ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : FontTheme.current.font(.monospaced, size: size - 1)
        parts = CommentPieces.split(text).map { piece -> NSView in
            switch piece {
            case let .words(md): return CommentText(markdown: md, size: size, font: font, boxes: true, lineHeight: lineHeight)
            case let .code(lines): return CodeBlockView(lines, font: code)
            }
        }
        avatar = Avatar(e.author, icon: icon)
        pad = inTile ? 14 : 11
        band = IssueLayout.band(inTile: inTile)
        let headSize: CGFloat = inTile ? 12.5 : 11.5
        // As a tile's bar says its name: the interface's font, quiet ink.
        name = NSTextField.label(e.author.isYou ? "You" : e.author.name, font: .systemFont(ofSize: headSize, weight: .semibold))
        let ago = BlockSummary.ago(e.at, now: Date()) ?? ""
        let said = (ago == "now" ? "now" : ago) + (e.edited == nil ? "" : " · edited")
        when = NSTextField.label(continued ? said : "· " + said, font: .systemFont(ofSize: headSize), color: Theme.tertiaryText)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        when.toolTip = DateFormatter.localizedString(from: e.at.date, dateStyle: .medium, timeStyle: .short)
            + (e.edited.map { "\nEdited " + DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .short) } ?? "")
        if case let .you(machine) = e.author { name.toolTip = machine.map { "From \($0)" } }
        name.isHidden = continued
        avatar.isHidden = continued
        avatar.onClick = { [weak self] in self?.onAuthor?() }
        avatar.onDrag = { [weak self] event in self?.dragOut(event) }
        avatar.toolTip = (e.author.isYou ? "You" : e.author.name) + " — drag to refer to this comment"
        more.target = self
        more.action = #selector(showMore)
        more.isHidden = true
        // Laid out here, by hand, not by constraints.
        for p in parts { p.translatesAutoresizingMaskIntoConstraints = true }
        for v in [card, avatar, name, when, more] + parts as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var cardX: CGFloat { IssueLayout.cardX(inTile: inTile) }
    private func bodyWidth(_ width: CGFloat) -> CGFloat { max(60, width - cardX - 2 * pad) }

    /// Its mark, where the line breaks round it.
    var lineGaps: [NSRect] {
        guard !continued else { return [] }
        return [avatar.frame.insetBy(dx: -IssueLayout.lineClearance, dy: -IssueLayout.lineClearance)]
    }

    /// A piece's height at the card's width.
    private func height(_ p: NSView, _ w: CGFloat) -> CGFloat {
        (p as? CommentText)?.height(forWidth: w) ?? (p as? CodeBlockView)?.height ?? 0
    }

    private func partsHeight(_ w: CGFloat) -> CGFloat {
        parts.reduce(0) { $0 + height($1, w) } + CGFloat(max(0, parts.count - 1)) * Self.partGap
    }

    override var intrinsicContentSize: NSSize {
        let w = bounds.width > 0 ? bounds.width : 400
        return NSSize(width: NSView.noIntrinsicMetric, height: band + partsHeight(bodyWidth(w)) + pad)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let m = IssueLayout.mark(inTile: inTile)
        // On the band's middle.
        avatar.frame = NSRect(x: 0, y: ((band - m) / 2).rounded(), width: m, height: m)
        card.frame = NSRect(x: cardX, y: 0, width: bounds.width - cardX, height: bounds.height)
        more.frame = NSRect(x: bounds.maxX - pad + 2 - 18, y: (band - 18) / 2, width: 18, height: 18)
        let x = cardX + pad
        name.sizeToFit()
        when.sizeToFit()
        let nameW = continued ? 0 : min(name.frame.width, bounds.width / 2)
        name.frame = NSRect(x: x, y: ((band - name.frame.height) / 2).rounded() + 1, width: nameW, height: name.frame.height)
        let whenX = continued ? x : name.frame.maxX + 4
        when.frame = NSRect(x: whenX, y: ((band - when.frame.height) / 2).rounded() + 1, width: max(0, more.frame.minX - 6 - whenX), height: when.frame.height)
        var y = band
        let w = bodyWidth(bounds.width)
        for p in parts {
            let h = height(p, w)
            p.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h + Self.partGap
        }
    }

    // ⋯ under the pointer only, as a tile's bar shows its buttons.
    override func updateTrackingAreas() {
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { more.isHidden = false }
    override func mouseExited(with event: NSEvent) { more.isHidden = true }

    /// ⋯: Quote Reply, Copy Text, Copy Link; yours, Edit Comment.
    @objc private func showMore() {
        let menu = NSMenu()
        if let onEdit { menu.addItem(ClosureMenuItem("Edit Comment", symbol: "pencil") { onEdit() }) }
        let words = markdown
        if let onQuote { menu.addItem(ClosureMenuItem("Quote Reply", symbol: "text.quote") { onQuote(words) }) }
        menu.addItem(ClosureMenuItem("Copy Text", symbol: "doc.on.doc") { NSPasteboard.copy(words) })
        if let address = link?() { menu.addItem(ClosureMenuItem("Copy Link to Comment", symbol: "link") { NSPasteboard.copy(address) }) }
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY + 2), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onEdit else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Edit Comment", symbol: "pencil") { onEdit() })
        return menu
    }

    // MARK: Its mark, dragged: the comment, as a reference

    private func dragOut(_ event: NSEvent) {
        guard let writer = dragged?() else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let at = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 6, y: at.y - 6, width: 12, height: 12), contents: nil)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        DragPill.dress(session, from: self, at: NSEvent.mouseLocation)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .link, .generic] }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { DragCursor.began() }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { DragCursor.moved() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { DragCursor.ended() }

    /// The card: a quiet tile — the panel's ground, a hairline round it,
    /// rounded as a tile is but no shadow, no band of its own; ringed in
    /// the accent when it's the one gone to.
    final class CardView: NSView {
        var ringed = false { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 1.5, dy: 1.5)
            let shape = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            Theme.panel.setFill()
            shape.fill()
            (ringed ? EdgeColor.accentStrong : EdgeColor.hairline).setStroke()
            shape.lineWidth = ringed ? 2 : 1
            shape.stroke()
        }
    }
}

/// Something that happened, on the conversation's line: a small halo on
/// the line (its symbol, or an agent's mark, in it), and what happened
/// beside it — at the cards' edge — its author's name in bold.
final class IssueEventView: NSView, OnTheLine {
    private let badge = Badge()
    private let label: NSTextField
    private let inTile: Bool

    init(who: String?, words: String, at: Stamp?, symbol: String, icon: NSImage?, tone: NSColor?, inTile: Bool) {
        self.inTile = inTile
        let size: CGFloat = inTile ? 12 : 11.5
        let s = NSMutableAttributedString()
        if let who { s.append(NSAttributedString(string: who + " ", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: tone ?? Theme.secondaryText])) }
        s.append(NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: tone ?? Theme.secondaryText]))
        if let at, let ago = BlockSummary.ago(at, now: Date()) {
            s.append(NSAttributedString(string: " · " + ago, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.tertiaryText]))
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
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: inTile ? 22 : 20) }

    var lineGaps: [NSRect] { [badge.frame.insetBy(dx: -IssueLayout.lineClearance, dy: -IssueLayout.lineClearance)] }

    override func layout() {
        super.layout()
        let d: CGFloat = inTile ? 14 : 12
        let x = IssueLayout.lineX(inTile: inTile)
        badge.frame = NSRect(x: x - d / 2, y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
        label.sizeToFit()
        let lx = IssueLayout.cardX(inTile: inTile) + 2
        label.frame = NSRect(x: lx, y: ((bounds.height - label.frame.height) / 2).rounded(), width: max(0, bounds.width - lx), height: label.frame.height)
    }

    /// The halo: a ring in the line's colour (an outcome's, its tone), its
    /// symbol, or the agent's mark, small inside — the terminal's last
    /// command's mark's kin.
    final class Badge: NSView {
        var symbol = "circle"
        var icon: NSImage?
        var tone: NSColor?
        override func draw(_ dirtyRect: NSRect) {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            (tone ?? Theme.divider).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            let side = bounds.height * 0.6
            let r = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            let ink = tone ?? Theme.secondaryText
            if let icon {
                // A one-color mark (a template): in the halo's ink.
                guard icon.isTemplate else { return icon.draw(in: r) }
                NSImage(size: r.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }.draw(in: r)
                return
            }
            Theme.symbol(symbol, size: side * 0.85, weight: .semibold, color: ink)?.draw(centeredAt: NSPoint(x: r.midX, y: r.midY))
        }
    }
}

/// New: a stretch of the line in the accent, and the word at the cards'
/// edge — where what hadn't been seen begins.
final class IssueNewView: NSView {
    private let label = NSTextField.label("New", font: UIType.caption, color: Tints.accentText)
    private let inTile: Bool

    init(inTile: Bool) {
        self.inTile = inTile
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: IssueLayout.cardX(inTile: inTile) + 2, y: ((bounds.height - label.frame.height) / 2).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.setFill()
        let x = IssueLayout.lineX(inTile: inTile), w: CGFloat = 2.5
        NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: -4, width: w, height: bounds.height + 8), xRadius: w / 2, yRadius: w / 2).fill()
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

/// A reference's card (the block's, as its row in the sidebar shows it),
/// the pointer resting on a reference to it: a pill in a comment or the
/// composer, a card over the composer. The window says how to show it.
enum ReferenceCards {
    /// The block's card beside `rect` (window terms), after the pointer's lingered.
    static var show: ((BlockID, NSRect, NSWindow) -> Void)?
    static var hide: (() -> Void)?

    /// The block a pill at a point stands for, and the pill's rect (the
    /// view's terms): an attachment carrying a block's link (a comment's)
    /// or a composer's reference.
    static func reference(in tv: NSTextView, at p: NSPoint) -> (BlockID, NSRect)? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage, storage.length > 0 else { return nil }
        let origin = tv.textContainerOrigin
        let q = NSPoint(x: p.x - origin.x, y: p.y - origin.y)
        let g = lm.glyphIndex(for: q, in: tc)
        let i = lm.characterIndexForGlyph(at: g)
        guard i < storage.length else { return nil }
        var range = NSRange()
        let id: BlockID?
        if let mention = storage.attribute(.mentionBlock, at: i, effectiveRange: &range) as? String {
            id = BlockID(string: mention)
        } else if storage.attribute(.attachment, at: i, effectiveRange: nil) != nil, let link = storage.attribute(.link, at: i, effectiveRange: &range) {
            let address = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            id = BlockID.link(address)?.0
        } else {
            id = nil
        }
        guard let id else { return nil }
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
            .offsetBy(dx: origin.x, dy: origin.y)
        return rect.insetBy(dx: -1, dy: -1).contains(p) ? (id, rect) : nil
    }

    /// The pointer moved in a text view: the card of the pill under it
    /// shown (once), or put away as it leaves one. What's under it now.
    static func track(_ tv: NSTextView, at p: NSPoint, was: BlockID?) -> BlockID? {
        let now = reference(in: tv, at: p)
        if now?.0 == was { return was }
        if let (id, r) = now, let window = tv.window {
            show?(id, tv.convert(r, to: nil), window)
            return id
        }
        hide?()
        return nil
    }
}
