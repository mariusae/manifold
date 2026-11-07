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
}

extension NSAttributedString.Key {
    /// A pill in the composer: the Markdown it's sent as.
    static let mentionLink = NSAttributedString.Key("ManifoldMentionLink")
    /// And what was typed for it (put back by ⌫).
    static let mentionTyped = NSAttributedString.Key("ManifoldMentionTyped")
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

/// The rows: a symbol, a title, a detail in grey; the selected on the
/// accent's band.
private final class MentionList: NSView {
    var choices: [MentionChoice] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onChoose: ((MentionChoice) -> Void)?
    static let rowHeight: CGFloat = 26
    static let width: CGFloat = 300
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        themed { v in
            v.layer?.backgroundColor = Theme.panel.cgColor
            v.layer?.borderColor = Theme.panelBorder.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var wantedSize: NSSize { NSSize(width: Self.width, height: CGFloat(choices.count) * Self.rowHeight + 8) }

    private func rowRect(_ i: Int) -> NSRect { NSRect(x: 4, y: 4 + CGFloat(i) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in choices.enumerated() {
            let r = rowRect(i)
            if i == selected {
                Theme.accent.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: r, xRadius: Radius.control, yRadius: Radius.control).fill()
            }
            let iconRect = NSRect(x: r.minX + 7, y: r.midY - 7, width: 14, height: 14)
            if let icon = c.icon {
                icon.draw(in: iconRect)
            } else if let image = Theme.symbol(c.symbol, size: 11, weight: .medium) {
                let tinted = NSImage(size: iconRect.size, flipped: false) { rect in
                    let s = image.size
                    image.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
                    (c.link == nil || c.icon != nil ? Theme.accent : Theme.secondaryText).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: iconRect)
            }
            let title = NSAttributedString(string: c.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Theme.text])
            let detail = NSAttributedString(string: c.detail, attributes: [.font: UIType.footnote, .foregroundColor: Theme.secondaryText])
            let x = iconRect.maxX + 8
            let tw = min(title.size().width, r.width - (x - r.minX) - 8)
            title.draw(with: NSRect(x: x, y: r.midY - 8, width: tw, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let dx = x + tw + 8
            if dx < r.maxX - 20 {
                detail.draw(with: NSRect(x: dx, y: r.midY - 7, width: r.maxX - dx - 6, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = choices.indices.first(where: { rowRect($0).contains(p) }) else { return }
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

    /// The plain look of what's typed (none of a pill's).
    var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? UIType.body, .foregroundColor: Theme.text]
    }

    /// A choice put in for the `@word` typed: a pill, or the word; a space after.
    func insertMention(_ c: MentionChoice, for token: (range: NSRange, query: String)) {
        let typed = (string as NSString).substring(with: token.range)
        let piece = NSMutableAttributedString()
        if let link = c.link {
            piece.append(NSAttributedString(string: c.title, attributes: plainAttributes.merging([
                .foregroundColor: Theme.accent, .backgroundColor: Theme.accent.withAlphaComponent(0.12),
                .mentionLink: link, .mentionTyped: typed,
            ]) { $1 }))
        } else {
            piece.append(NSAttributedString(string: "@" + c.title, attributes: plainAttributes))
        }
        piece.append(NSAttributedString(string: " ", attributes: plainAttributes))
        guard shouldChangeText(in: token.range, replacementString: piece.string) else { return }
        textStorage?.replaceCharacters(in: token.range, with: piece)
        didChangeText()
        setSelectedRange(NSRange(location: token.range.location + piece.length, length: 0))
        typingAttributes = plainAttributes
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
                                         icon: AgentIcons.image(a.command, size: 14)))
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
                                         link: nil, icon: AgentIcons.image(a.command, size: 14)))
            }
            // Then what ⌘O finds.
            let room = max(0, 9 - out.count)
            if room > 0, let ranked = FinderRanking.rank(query, corpus, limit: room + listed.count + 8) {
                for c in ranked.rows {
                    guard let id = c.block, !listed.contains(id), out.count < 9, self.hosts.block(id)?.kind != .thread else { continue }
                    out.append(MentionChoice(symbol: c.symbol, title: c.title, detail: c.detail.isEmpty ? c.note : c.detail,
                                             link: "[\(c.title.replacingOccurrences(of: "]", with: "\\]"))](\(Self.address(id)))"))
                }
            }
            return out
        }
    }
}
