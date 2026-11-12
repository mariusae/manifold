import AppKit
import ManifoldCore

/// `@` in a thread's composer (§3.12): a list at the caret of who and what
/// to name — the agents running near first, then the words that ask (or
/// start) one, then what ⌘O finds, ranked as it ranks. Chosen, a block
/// (a running agent's terminal too) is a pill — its link when sent, so a
/// running agent's asks it, as a dropped one does — and a word is the
/// word. ↩ or ⇥ takes it, ↑↓ move, ⎋ keeps what's typed; ⌫ just after a
/// pill puts back what was typed for it.
struct MentionChoice {
    var symbol: String
    var title: String
    var detail: String
    /// What it is when sent: a link (a pill shows it); nil, the plain word
    /// `@title`.
    var link: String?
    var icon: NSImage? = nil
    /// Its part of the list, a small header over each (Agents, Here, Files…).
    var category = ""
    /// The block it stands for: a card of it over the composer while it's in.
    var block: BlockID? = nil
}

extension NSAttributedString.Key {
    /// A pill in the composer: the Markdown it's sent as.
    static let mentionLink = NSAttributedString.Key("ManifoldMentionLink")
    /// And what was typed for it (put back by ⌫).
    static let mentionTyped = NSAttributedString.Key("ManifoldMentionTyped")
    /// The block it stands for (its id), for its card.
    static let mentionBlock = NSAttributedString.Key("ManifoldMentionBlock")
}

/// The list, in a panel of its own over the composer's window: it never
/// takes the keyboard — the composer passes it ↑↓↩⇥⎋.
final class MentionPopover {
    private let panel: NSPanel
    private let list = MentionList()
    private(set) var choices: [MentionChoice] = []
    var isShown: Bool { panel.isVisible }
    var onChoose: ((MentionChoice) -> Void)? {
        get { list.onChoose }
        set { list.onChoose = newValue }
    }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = list
    }

    /// Shown over `caret` (a rect on screen), above it — the composer is
    /// at the foot of what it's in — or below, with no room above.
    func show(_ choices: [MentionChoice], at caret: NSRect, in window: NSWindow) {
        self.choices = choices
        guard !choices.isEmpty else { return hide() }
        list.choices = choices
        list.selected = 0
        let size = list.wantedSize
        var origin = NSPoint(x: caret.minX - 10, y: caret.maxY + 4)
        if let screen = window.screen?.visibleFrame {
            if origin.y + size.height > screen.maxY { origin.y = caret.minY - 4 - size.height }
            origin.x = min(max(screen.minX + 4, origin.x), screen.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ by: Int) {
        guard !choices.isEmpty else { return }
        list.selected = (list.selected + by + choices.count) % choices.count
    }

    var selected: MentionChoice? { choices.indices.contains(list.selected) ? choices[list.selected] : nil }

    /// Debugging: the list as drawn, written as a PNG.
    func debugPicture(_ path: String) -> String {
        guard isShown, let rep = list.bitmapImageRepForCachingDisplay(in: list.bounds) else { return "no list" }
        list.cacheDisplay(in: list.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return "wrote \(path)"
    }

    /// Debugging: its rows, the selected marked.
    var debugRows: String {
        guard isShown else { return "no list" }
        return choices.enumerated().map { (list.selected == $0.offset ? "> " : "  ") + $0.element.title + " — " + $0.element.detail + ($0.element.link == nil ? " (word)" : "") }.joined(separator: "\n")
    }
}

/// The rows, as Dia's: in parts under small grey headers (Agents, Here,
/// Files), a line each — its icon and title, a detail in grey — the
/// chosen on the accent, its words white.
private final class MentionList: PopoverView {
    var choices: [MentionChoice] = [] { didSet { lay(); needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onChoose: ((MentionChoice) -> Void)?
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 22
    static let width: CGFloat = 300
    override var isFlipped: Bool { true }
    /// Each row's rect, and each header's (its title, its top).
    private var rows: [NSRect] = []
    private var headers: [(String, CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func lay() {
        rows = []
        headers = []
        var y: CGFloat = 5
        var last: String?
        for c in choices {
            if !c.category.isEmpty, c.category != last {
                headers.append((c.category, y))
                y += Self.headerHeight
                last = c.category
            }
            rows.append(NSRect(x: 5, y: y, width: Self.width - 10, height: Self.rowHeight))
            y += Self.rowHeight
        }
        height = y + 5
    }

    private var height: CGFloat = 10
    var wantedSize: NSSize { NSSize(width: Self.width, height: height) }

    override func drawContent(_ dirtyRect: NSRect) {
        for (title, y) in headers { Flat.menuHeader(title, at: NSPoint(x: 13, y: y + 5)) }
        for (i, c) in choices.enumerated() where rows.indices.contains(i) {
            let r = rows[i]
            let lit = i == selected
            if lit { Flat.menuBand(r) }
            let iconRect = NSRect(x: r.minX + 7, y: r.midY - 7, width: 14, height: 14)
            if let icon = c.icon {
                icon.draw(in: iconRect)
            } else if let image = Theme.symbol(c.symbol, size: 11, weight: .medium, color: lit ? Flat.onBand() : Theme.secondaryText) {
                image.draw(centeredAt: NSPoint(x: iconRect.midX, y: iconRect.midY))
            }
            let title = NSAttributedString(string: c.title, attributes: [.font: UIType.row, .foregroundColor: lit ? Flat.onBand() : Theme.text])
            let detail = NSAttributedString(string: c.detail, attributes: [.font: UIType.footnote, .foregroundColor: lit ? Flat.onBand(dim: true) : Theme.tertiaryText])
            let x = iconRect.maxX + 8
            let tw = min(title.size().width + 2, r.width - (x - r.minX) - 8)
            title.draw(with: NSRect(x: x, y: r.midY - 8, width: tw, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let dx = x + tw + 8
            if dx < r.maxX - 20 {
                detail.draw(with: NSRect(x: dx, y: r.midY - 7, width: r.maxX - dx - 6, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rows.indices.first(where: { rows[$0].contains(p) }) else { return }
        selected = i
        onChoose?(choices[i])
    }
}

extension ComposerTextView {
    /// The `@word` the caret is at the end of: its range (the `@` too) and
    /// what's typed after the `@`. An `@` only at a word's start (not an
    /// address's), nothing of a pill in it.
    var mentionToken: (range: NSRange, query: String)? {
        let sel = selectedRange()
        guard sel.length == 0, let storage = textStorage else { return nil }
        let s = string as NSString
        var i = sel.location
        while i > 0 {
            let c = s.character(at: i - 1)
            if c == 0x40 { break } // @
            guard let u = UnicodeScalar(c), !CharacterSet.whitespacesAndNewlines.contains(u), sel.location - i < 40 else { return nil }
            i -= 1
        }
        guard i > 0, s.character(at: i - 1) == 0x40 else { return nil }
        let at = i - 1
        if at > 0, let u = UnicodeScalar(s.character(at: at - 1)), !CharacterSet.whitespacesAndNewlines.contains(u), u != "(" { return nil }
        let range = NSRange(location: at, length: sel.location - at)
        var inPill = false
        storage.enumerateAttribute(.mentionLink, in: range) { v, _, stop in if v != nil { inPill = true; stop.pointee = true } }
        guard !inPill else { return nil }
        return (range, s.substring(with: NSRange(location: i, length: sel.location - i)))
    }

    /// The words as sent: each pill its link.
    var message: String {
        guard let storage = textStorage else { return string }
        let out = NSMutableString(string: storage.string)
        var pills: [(NSRange, String)] = []
        storage.enumerateAttribute(.mentionLink, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if let link = v as? String { pills.append((r, link)) }
        }
        for (r, link) in pills.reversed() { out.replaceCharacters(in: r, with: link) }
        return out as String
    }

    /// A comment's words put back to change: each reference
    /// (`[name](manifold:…)`) the pill it was written as, sent as the same
    /// link; the rest as typed.
    func fill(markdown: String) {
        let ns = markdown as NSString
        let out = NSMutableAttributedString()
        let pattern = try! NSRegularExpression(pattern: #"\[((?:\\\]|[^\]\n])+)\]\((manifold:[^)\s]+)\)"#)
        var last = 0
        for m in pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)), attributes: plainAttributes))
            let title = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\]", with: "]")
            let marks: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.secondaryText, .mentionLink: ns.substring(with: m.range)]
            out.append(NSAttributedString(string: title, attributes: plainAttributes.merging(marks) { $1 }))
            last = NSMaxRange(m.range)
        }
        out.append(NSAttributedString(string: ns.substring(from: last), attributes: plainAttributes))
        textStorage?.setAttributedString(out)
        typingAttributes = plainAttributes
        setSelectedRange(NSRange(location: out.length, length: 0))
        didChangeText()
    }

    /// The plain look of what's typed (none of a pill's).
    var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? UIType.body, .foregroundColor: Theme.text]
    }

    /// A choice put in for the `@word` typed: a pill, or the word; a space after.
    func insertMention(_ c: MentionChoice, for token: (range: NSRange, query: String)) {
        let typed = (string as NSString).substring(with: token.range)
        let piece = NSMutableAttributedString(attributedString: pillPiece(c, typed: typed))
        piece.append(NSAttributedString(string: " ", attributes: plainAttributes))
        guard shouldChangeText(in: token.range, replacementString: piece.string) else { return }
        textStorage?.replaceCharacters(in: token.range, with: piece)
        didChangeText()
        setSelectedRange(NSRange(location: token.range.location + piece.length, length: 0))
        typingAttributes = plainAttributes
        if c.link != nil { shimmer(NSRange(location: token.range.location, length: piece.length - 1)) }
    }

    /// Markdown put in at `location` with each reference in it a pill, as
    /// `@` makes one — a link to a block (`[name](manifold:…)`) and one
    /// written bare — so it's sent as written and its block's card is over
    /// the composer; the rest plain, in the composer's own look (what a
    /// drop or a paste brought, its fonts left behind).
    func insertReferences(_ markdown: String, at location: Int) {
        let ns = markdown as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, MentionChoice)] = []
        let linkPattern = try! NSRegularExpression(pattern: #"\[((?:\\\]|[^\]\n])+)\]\((manifold:[^)\s]+)\)"#)
        for m in linkPattern.matches(in: markdown, range: all) {
            let address = ns.substring(with: m.range(at: 2))
            guard let (id, _) = BlockID.link(address) else { continue }
            let title = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\]", with: "]")
            let look = CommentText.look?(id)
            found.append((m.range, MentionChoice(symbol: look?.symbol ?? "doc", title: title, detail: "", link: ns.substring(with: m.range), block: id)))
        }
        for m in TextLinks.bareReference.matches(in: markdown, range: all) where !found.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) {
            let address = ns.substring(with: m.range)
            guard let (id, place) = BlockID.link(address), let look = CommentText.look?(id) else { continue }
            let title = look.title + (place.flatMap { Locator(fragment: $0)?.words }.map { " · " + $0 } ?? "")
            found.append((m.range, MentionChoice(symbol: look.symbol, title: title, detail: "", link: address, block: id)))
        }
        found.sort { $0.0.location < $1.0.location }
        let out = NSMutableAttributedString()
        var last = 0
        for (r, c) in found {
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: r.location - last)), attributes: plainAttributes))
            out.append(pillPiece(c, typed: ""))
            last = NSMaxRange(r)
        }
        out.append(NSAttributedString(string: ns.substring(from: last), attributes: plainAttributes))
        // A pill last: a space after it, as `@` leaves one, so what's typed next isn't run into it.
        if let lastPill = found.last, NSMaxRange(lastPill.0) == ns.length { out.append(NSAttributedString(string: " ", attributes: plainAttributes)) }
        let r = NSRange(location: min(location, (string as NSString).length), length: 0)
        guard shouldChangeText(in: r, replacementString: out.string) else { return }
        textStorage?.replaceCharacters(in: r, with: out)
        didChangeText()
        setSelectedRange(NSRange(location: r.location + out.length, length: 0))
        typingAttributes = plainAttributes
    }

    /// A pill: its icon, then its name in grey — one piece, sent as its link.
    func pillPiece(_ c: MentionChoice, typed: String) -> NSAttributedString {
        let piece = NSMutableAttributedString()
        if let link = c.link {
            // As Dia's: its icon, then its name in grey — one piece, sent as its link.
            var marks: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.secondaryText, .mentionLink: link, .mentionTyped: typed]
            if let b = c.block { marks[.mentionBlock] = b.description }
            let attrs = plainAttributes.merging(marks) { $1 }
            let icon = c.icon ?? Theme.symbol(c.symbol, size: 11, weight: .medium, color: Theme.secondaryText)
            if let icon {
                let a = NSTextAttachment()
                a.image = icon
                let size: CGFloat = 13, font = (attrs[.font] as? NSFont) ?? UIType.body
                a.bounds = NSRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
                let m = NSMutableAttributedString(attachment: a)
                m.addAttributes(attrs, range: NSRange(location: 0, length: m.length))
                piece.append(m)
                piece.append(NSAttributedString(string: "\u{2009}", attributes: attrs))
            }
            piece.append(NSAttributedString(string: c.title, attributes: attrs))
        } else {
            piece.append(NSAttributedString(string: "@" + c.title, attributes: plainAttributes))
        }
        return piece
    }

    /// Magic text, as Dia's: a reference just resolved swept by a rainbow,
    /// left to right, each letter settling to its grey as it passes.
    func shimmer(_ range: NSRange) {
        guard let lm = layoutManager, range.length > 0, !Motion.reduced else { return }
        let start = CACurrentMediaTime(), d = 0.9 * Motion.slowdown
        let n = range.length
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak lm] timer in
            MainActor.unchecked {
                guard let self, let lm, let storage = self.textStorage, NSMaxRange(range) <= storage.length else { return timer.invalidate() }
                let t = (CACurrentMediaTime() - start) / d
                if t >= 1 {
                    lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                    return timer.invalidate()
                }
                for k in 0..<n {
                    let u = Double(k) / Double(max(n - 1, 1))
                    // The sweep's front at t·1.4: behind it settled, at it the colours.
                    let behind = t * 1.4 - u
                    let c: NSColor
                    if behind < 0 { c = Theme.secondaryText.withAlphaComponent(0.25) }
                    else if behind > 0.45 { c = Theme.secondaryText }
                    else {
                        let rainbow = NSColor(hue: CGFloat((u * 0.8 + t * 0.6).truncatingRemainder(dividingBy: 1)), saturation: 0.65, brightness: 0.9, alpha: 1)
                        c = rainbow.blended(withFraction: CGFloat(behind / 0.45), of: Theme.secondaryText) ?? rainbow
                    }
                    lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: NSRange(location: range.location + k, length: 1))
                }
            }
        }
    }

    /// The blocks referred to in what's written, in order, each once.
    var mentionedBlocks: [String] {
        guard let storage = textStorage else { return [] }
        var out: [String] = []
        storage.enumerateAttribute(.mentionBlock, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let id = v as? String, !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// A reference taken out of what's written (its card's ×), and the space after it.
    func removeMention(_ id: String) {
        guard let storage = textStorage else { return }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.mentionBlock, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if (v as? String) == id { ranges.append(r) }
        }
        for var r in ranges.reversed() {
            if NSMaxRange(r) < storage.length, (storage.string as NSString).character(at: NSMaxRange(r)) == 0x20 { r.length += 1 }
            guard shouldChangeText(in: r, replacementString: "") else { continue }
            storage.replaceCharacters(in: r, with: "")
            didChangeText()
        }
    }

    /// ⌫ just after a pill: what was typed for it, back.
    func unpillBeforeCaret() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0, let storage = textStorage else { return false }
        var r = NSRange()
        guard storage.attribute(.mentionLink, at: sel.location - 1, effectiveRange: &r) != nil,
              let typed = storage.attribute(.mentionTyped, at: sel.location - 1, effectiveRange: nil) as? String else { return false }
        guard shouldChangeText(in: r, replacementString: typed) else { return true }
        storage.replaceCharacters(in: r, with: NSAttributedString(string: typed, attributes: plainAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: r.location + (typed as NSString).length, length: 0))
        typingAttributes = plainAttributes
        return true
    }
}

extension MainWindowController {
    /// What `@` offers, for what's typed after it: made once as the list
    /// opens (what ⌘O would find), ranked as each letter comes.
    func mentionSource() -> (String) -> [MentionChoice] {
        let (corpus, _) = finderCorpusForMentions()
        let space = selected
        let here = Set(space.flatMap { hosts.arrangement($0) }?.placements.map(\.block) ?? [])
        let running = hosts.blocks.filter { b in
            guard b.agent != nil, b.terminal?.pid != nil, b.terminal?.dormantSince == nil else { return false }
            return true
        }.sorted { a, b in here.contains(a.id) != here.contains(b.id) ? here.contains(a.id) : a.displayTitle < b.displayTitle }
        return { [weak self] query in
            guard let self else { return [] }
            let q = query.lowercased()
            func matches(_ words: [String]) -> Bool { q.isEmpty || words.contains { $0.lowercased().contains(q) } }
            var out: [MentionChoice] = []
            var listed = Set<BlockID>()
            // The agents at work, this space's first.
            for b in running {
                guard let a = b.agent, matches([b.displayTitle, a.command, a.name]) else { continue }
                listed.insert(b.id)
                out.append(MentionChoice(symbol: "sparkle", title: b.displayTitle, detail: a.name + (here.contains(b.id) ? " · here" : " · running"),
                                         link: "[\(b.displayTitle.replacingOccurrences(of: "]", with: "\\]"))](\(Self.address(b.id)))",
                                         icon: AgentIcons.image(a.command, size: 14), category: "Agents", block: b.id))
            }
            // The words that ask one (the nearest at work, or one started):
            // with nothing typed, only those at work and the one Settings
            // names; else those it starts.
            let usual = AgentCatalog.agent(inCommand: self.desk.settings.agentCommand)?.command
            for a in AgentCatalog.known where out.count < 9 {
                let atWork = running.contains { $0.agent?.command == a.command }
                guard q.isEmpty ? atWork || a.command == usual : a.command.hasPrefix(q) || a.name.lowercased().hasPrefix(q) else { continue }
                out.append(MentionChoice(symbol: "sparkle", title: a.command,
                                         detail: atWork ? "asks \(a.name)" : "starts \(a.name)",
                                         link: nil, icon: AgentIcons.image(a.command, size: 14), category: "Ask"))
            }
            // Then what ⌘O finds.
            let room = max(0, 9 - out.count)
            if room > 0, let ranked = FinderRanking.rank(query, corpus, limit: room + listed.count + 8) {
                for c in ranked.rows {
                    guard let id = c.block, !listed.contains(id), out.count < 9, self.hosts.block(id)?.kind != .thread else { continue }
                    let b = self.hosts.block(id)
                    out.append(MentionChoice(symbol: c.symbol, title: c.title, detail: c.detail.isEmpty ? c.note : c.detail,
                                             link: "[\(c.title.replacingOccurrences(of: "]", with: "\\]"))](\(Self.address(id)))",
                                             icon: b?.web.flatMap { Favicons.image(forPage: $0.url) },
                                             category: here.contains(id) ? "In this space" : (b?.path != nil ? "Files" : "Elsewhere"), block: id))
                }
            }
            // Each part together, in this order, as ranked within it.
            let order = ["Agents", "Ask", "In this space", "Files", "Elsewhere"]
            return out.enumerated().sorted { a, b in
                let i = order.firstIndex(of: a.element.category) ?? order.count, j = order.firstIndex(of: b.element.category) ?? order.count
                return i != j ? i < j : a.offset < b.offset
            }.map(\.element)
        }
    }
}
