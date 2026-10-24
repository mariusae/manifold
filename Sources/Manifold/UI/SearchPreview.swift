import AppKit
import ManifoldCore

extension SearchQuery {
    /// Where it matches in a string, as the host's search would (text or a
    /// regular expression, with or without case); `limit` at most.
    func ranges(in s: String, limit: Int = 5000) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let ns = s as NSString
        var out: [NSRange] = []
        if regex {
            guard let r = try? NSRegularExpression(pattern: text, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
            r.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                guard let m, m.range.length > 0 else { return }
                out.append(m.range)
                if out.count >= limit { stop.pointee = true }
            }
        } else {
            var from = 0
            while from < ns.length, out.count < limit {
                let r = ns.range(of: text, options: caseSensitive ? [] : [.caseInsensitive], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                out.append(r)
                from = r.location + max(1, r.length)
            }
        }
        return out
    }
}

/// A hit as the column browser previews a file (§7.5): the file, read-only
/// in the code face with its line numbers, scrolled to the hit's line —
/// lit, its match marked strongest — and every other match marked too.
/// Its name and the line along the top; a double-click opens it there.
final class SearchPreviewView: NSView {
    /// A file's text from the search's host; nil if it can't be read.
    var read: (String, @escaping (String?) -> Void) -> Void = { _, done in done(nil) }
    /// A line (1-based) double-clicked: the file opened there.
    var open: (String, Int) -> Void = { _, _ in }
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { if font != oldValue { shownKey = nil; show(hit, query: query, root: root) } } }

    private let title = NSTextField(labelWithString: "")
    private let scroll = ClippingScrollView()
    /// The file's text: a view made afresh for each file, on the text
    /// system laid out for it off the main thread.
    private var text = PreviewTextView()
    /// What owns the shown file's text system (its layout manager, its
    /// container): kept while it's shown.
    private var storage: NSTextStorage?
    private let empty = NSTextField(labelWithString: "")
    /// "Reading…" while a match's file comes from its host.
    private let note = BusyNote()
    private let divider = FlatDivider()
    private let gutter = LineGutter()
    /// Files read, the latest last: kept for going back and forth among
    /// a search's hits, a few dozen at most.
    private var cache: [String: String?] = [:]
    private var cached: [String] = []
    /// What's being made ready off the main thread, by its key.
    private var preparing: String?
    private static let preparation = DispatchQueue(label: "manifold.search-preview", qos: .userInitiated)
    private(set) var hit: SearchHit?
    private var query: SearchQuery?
    private var root = ""
    private var token = 0
    private var laidOutSize = NSSize.zero
    /// What's laid out: the file and query (matches marked once per file).
    private var shownKey: String?
    private var lineStarts: [Int] = [0]
    private var matches: [NSRange] = []
    static let titleHeight: CGFloat = 26
    /// The chosen hit's match: stronger than the others', and than its lit line.
    static let currentMatch = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.62, blue: 0.15, alpha: 0.55),
                                              NSColor(srgbRed: 0.85, green: 0.5, blue: 0.1, alpha: 0.6))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        themed { $0.layer?.backgroundColor = Theme.codePage.cgColor }
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = Theme.secondaryText
        title.lineBreakMode = .byTruncatingHead
        addSubview(title)
        addSubview(divider)
        configure(text)
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        gutter.text = text
        addSubview(gutter)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineGutter.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = Theme.secondaryText
        empty.alignment = .center
        addSubview(empty)
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ text: PreviewTextView) {
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.height]
        text.doubleClicked = { [weak self] offset in self?.doubleClicked(at: offset) }
    }

    override func layout() {
        super.layout()
        let h = Self.titleHeight
        title.frame = NSRect(x: 10, y: bounds.height - h + 5, width: max(0, bounds.width - 20), height: 15)
        divider.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: 1)
        let g = gutter.thickness
        gutter.frame = NSRect(x: 0, y: 0, width: g, height: max(0, bounds.height - h))
        scroll.frame = NSRect(x: g, y: 0, width: max(0, bounds.width - g), height: max(0, bounds.height - h))
        text.minSize = scroll.contentSize
        // Resized: the hit's line in the middle again.
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            if let hit, let query, let cached = cache[hit.path] { DispatchQueue.main.async { [weak self] in self?.present(cached, hit: hit, query: query) } }
        }
        empty.frame = NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
        note.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shownKey = nil
        show(hit, query: query, root: root)
    }

    /// Files read again on the next look (the search ran again).
    func forget() { cache.removeAll(); cached.removeAll(); shownKey = nil }

    private func remember(_ path: String, _ contents: String?) {
        if cache.updateValue(contents, forKey: path) != nil { cached.removeAll { $0 == path } }
        cached.append(path)
        while cached.count > 24 { cache.removeValue(forKey: cached.removeFirst()) }
    }

    func show(_ hit: SearchHit?, query: SearchQuery?, root: String) {
        self.hit = hit
        self.query = query
        self.root = root
        token += 1
        guard let hit, let query else {
            note.set(.idle)
            title.stringValue = ""
            scroll.isHidden = true
            gutter.isHidden = true
            empty.isHidden = false
            empty.stringValue = "Choose a match to see it in its file"
            return
        }
        var shown = hit.path
        if shown.hasPrefix(root + "/") { shown = String(shown.dropFirst(root.count + 1)) }
        title.stringValue = "\(shown)  ·  line \(hit.line)"
        if let cached = cache[hit.path] { return present(cached, hit: hit, query: query) }
        // Not the last file's text under this one's name, if it takes a
        // while to come (as the note shows, a moment on).
        note.set(.busy("Reading…"))
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + BusyNote.delay) { [weak self] in
            guard let self, self.token == t, case .busy = self.note.state else { return }
            self.scroll.isHidden = true
            self.gutter.isHidden = true
            self.empty.isHidden = true
        }
        read(hit.path) { [weak self] contents in
            guard let self else { return }
            self.remember(hit.path, contents)
            guard self.token == t else { return }
            self.present(contents, hit: hit, query: query)
        }
    }

    private func present(_ contents: String?, hit: SearchHit, query: SearchQuery) {
        note.set(.idle)
        guard let contents else {
            scroll.isHidden = true
            gutter.isHidden = true
            empty.isHidden = false
            empty.stringValue = "Can't be read here"
            return
        }
        scroll.isHidden = false
        gutter.isHidden = false
        empty.isHidden = true
        let key = "\(hit.path)|\(query.text)|\(query.regex)|\(query.caseSensitive)|\(contents.utf16.count)|\(font.fontName)\(font.pointSize)"
        if key != shownKey {
            // Its lines, its matches and its text in the face made ready off
            // the main thread (a 4 MB file's took it 0.1 s), then shown.
            note.set(.busy("Reading…"))
            guard preparing != key else { return }
            preparing = key
            let font = self.font, ink = Theme.codeText, mark = TextView.matchColor
            let padding = text.textContainer?.lineFragmentPadding ?? 5
            let current: () -> Bool = { [weak self] in DispatchQueue.main.sync { self?.preparing == key } }
            Self.preparation.async { [weak self] in
                guard let ready = Self.prepare(contents, query: query, font: font, ink: ink, mark: mark, padding: padding, current: current) else { return }
                DispatchQueue.main.async {
                    guard let self, self.preparing == key else { return }
                    self.preparing = nil
                    self.shownKey = key
                    self.lineStarts = ready.lineStarts
                    self.matches = ready.matches
                    let fresh = PreviewTextView(frame: NSRect(origin: .zero, size: self.scroll.contentSize), textContainer: ready.container)
                    self.configure(fresh)
                    fresh.minSize = self.scroll.contentSize
                    self.text = fresh
                    self.storage = ready.storage
                    self.scroll.documentView = fresh
                    self.gutter.text = fresh
                    self.text.sizeToFit()
                    self.gutter.lineStarts = ready.lineStarts
                    self.gutter.font = font
                    self.needsLayout = true
                    // The hit shown now, if it's still this file's.
                    if let now = self.hit, now.path == hit.path, let q = self.query { self.present(contents, hit: now, query: q) }
                }
            }
            return
        }
        // The hit's line lit, its match marked strongest; centred.
        let line = max(0, min(hit.line - 1, lineStarts.count - 1))
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : (text.string as NSString).length
        let lineRange = NSRange(location: start, length: max(0, end - start))
        text.litLine = lineRange
        let current = matches.first { NSIntersectionRange($0, lineRange).length > 0 && NSMaxRange($0) <= end }
        // Marked over the text's own marks, without touching the text: an
        // attribute changed lays out again all that's after it.
        if let old = text.current, NSMaxRange(old) <= (text.string as NSString).length {
            text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        if let current { text.layoutManager?.addTemporaryAttribute(.backgroundColor, value: Self.currentMatch, forCharacterRange: current) }
        text.current = current
        text.needsDisplay = true
        gutter.litLine = line
        gutter.needsDisplay = true
        scrollToCenter(lineRange, match: current)
    }

    /// A file made ready to show: where its lines start (as NSString
    /// counts them), its matches, and its text in the face, matches marked,
    /// laid out whole in a text system of its own (a 4 MB file's layout
    /// held the main thread 1.5 s; laid out only as far as looked at,
    /// AppKit drew one line's text over another's). A piece at a time,
    /// nil once given up on (`current` turned false).
    private static func prepare(_ contents: String, query: SearchQuery, font: NSFont, ink: NSColor, mark: NSColor, padding: CGFloat,
                                current: () -> Bool) -> (lineStarts: [Int], matches: [NSRange], storage: NSTextStorage, container: NSTextContainer)? {
        var starts = [0]
        var i = 0
        var previousCR = false
        for u in contents.utf16 {
            i += 1
            switch u {
            case 0x0A: if !previousCR { starts.append(i) } else { starts[starts.count - 1] = i }
            case 0x0D, 0x2028, 0x2029, 0x85: starts.append(i)
            default: break
            }
            previousCR = u == 0x0D
        }
        // A last line break begins no line.
        if starts.count > 1, starts.last == i { starts.removeLast() }
        let s = NSMutableAttributedString(string: contents, attributes: [.font: font, .foregroundColor: ink])
        let matches = query.ranges(in: contents)
        for r in matches { s.addAttribute(.backgroundColor, value: mark, range: r) }
        let storage = NSTextStorage(attributedString: s)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = padding
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var at = 0
        while at < storage.length {
            guard current() else { return nil }
            let end = min(storage.length, at + 256 << 10)
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: end))
            at = end
        }
        return (starts, matches, storage, container)
    }

    private func scrollToCenter(_ range: NSRange, match: NSRange?) {
        guard let lm = text.layoutManager, let tc = text.textContainer else { return }
        lm.ensureLayout(forCharacterRange: range)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.y += text.textContainerInset.height
        let visible = scroll.contentView.bounds
        var x: CGFloat = 0
        // A match off to the right of a long line: in view.
        if let match {
            let mg = lm.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
            let mr = lm.boundingRect(forGlyphRange: mg, in: tc)
            if mr.maxX > visible.width - 20 { x = max(0, mr.midX - visible.width / 2) }
        }
        let y = max(0, min(rect.midY - visible.height / 2, text.frame.height - visible.height))
        scroll.contentView.scroll(to: NSPoint(x: x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func doubleClicked(at offset: Int) {
        guard let hit else { return }
        let line = (lineStarts.lastIndex { $0 <= offset } ?? 0) + 1
        open(hit.path, line)
    }

    /// Debugging: what it shows.
    var debugState: String {
        guard let hit else { return "preview: nothing" }
        let lit = text.litLine.map { (text.string as NSString).substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "?"
        let mark = text.current.map { (text.string as NSString).substring(with: $0) } ?? "none"
        let visible = text.layoutManager.map { lm -> String in
            let g = lm.glyphRange(forBoundingRect: scroll.contentView.bounds, in: text.textContainer!)
            let c = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
            let first = (lineStarts.lastIndex { $0 <= c.location } ?? 0) + 1
            let last = (lineStarts.lastIndex { $0 <= NSMaxRange(c) } ?? 0) + 1
            return "\(first)–\(last)"
        } ?? "?"
        var geometry = "scroll x \(Int(scroll.frame.minX)) gutter \(Int(gutter.frame.width)) origin \(Int(scroll.contentView.bounds.minX))"
        if let c = text.current, let lm = text.layoutManager, let tc = text.textContainer {
            let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: c, actualCharacterRange: nil), in: tc)
            geometry += " box \(Int(r.minX))+\(Int(r.width)) font \(font.fontName) \(font.pointSize)"
        }
        return geometry + "\npreview: \(title.stringValue) | lit \"\(lit)\" | match \"\(mark)\" | \(matches.count) marked | lines \(visible) shown"
    }
}

/// The preview's text: the hit's line lit behind the text, its match boxed.
final class PreviewTextView: NSTextView {
    var litLine: NSRange?
    var current: NSRange?
    var doubleClicked: (Int) -> Void = { _ in }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        if let line = litLine, line.length > 0 || line.location < (string as NSString).length {
            let g = lm.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: g, in: tc)
            r.origin.x = 0
            r.size.width = max(bounds.width, r.maxX)
            r.origin.y += textContainerInset.height
            TextView.lineHighlight.setFill()
            r.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let current, let lm = layoutManager, let tc = textContainer else { return }
        let g = lm.glyphRange(forCharacterRange: current, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: g, in: tc)
        r.origin.x += textContainerInset.width
        r.origin.y += textContainerInset.height
        let path = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -0.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        NSColor.systemOrange.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            doubleClicked(characterIndexForInsertion(at: p))
            return
        }
        super.mouseDown(with: event)
    }
}

/// Line numbers down the preview's left, beside its scroll view and kept
/// in step with it; the lit line's number in the text's colour.
final class LineGutter: NSView {
    weak var text: NSTextView?
    var lineStarts: [Int] = [0] { didSet { needsDisplay = true } }
    var litLine: Int?
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var thickness: CGFloat { max(30, CGFloat(String(lineStarts.count).count) * 7.5 + 16) }

    override var isFlipped: Bool { true }

    @objc func scrolled() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.codePage.setFill()
        bounds.fill()
        guard let tv = text, let lm = tv.layoutManager, let tc = tv.textContainer, let clip = tv.enclosingScrollView?.contentView else { return }
        let visible = clip.bounds
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        var line = lineStarts.lastIndex { $0 <= chars.location } ?? 0
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(chars), lm.numberOfGlyphs > 0 {
            let g = min(lm.glyphIndexForCharacter(at: lineStarts[line]), lm.numberOfGlyphs - 1)
            let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let y = r.minY + tv.textContainerInset.height - visible.minY
            let s = NSAttributedString(string: "\(line + 1)", attributes: [
                .font: numberFont, .foregroundColor: line == litLine ? Theme.codeText : Theme.codeLineNumber,
            ])
            let size = s.size()
            s.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y + (r.height - size.height) / 2))
            line += 1
        }
    }
}

