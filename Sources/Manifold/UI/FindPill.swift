import AppKit

/// What a view does for the find pill (⌘F): finds and shows every match
/// of a query and goes to the first from where it is, steps between them,
/// and lets go.
protocol Searchable: AnyObject {
    /// Finds every match, showing them, and goes to the first from here;
    /// says how many through `done` (nil when it can't count), on the main
    /// queue.
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void)
    func findNext(forward: Bool)
    func endSearch()
    /// The selected text, or the word at the caret, for ⌘E.
    func textForFind(_ done: @escaping (String?) -> Void)
}

/// A searchable view that replaces too (an editor).
protocol Replaceable: Searchable {
    func replaceCurrent(with text: String)
    func replaceAll(with text: String)
}

/// The find pill, an accessory (§3.1): a compact capsule at the upper
/// right of a tile — the query, how many matches, ↑ ↓ for the previous
/// and next (↩ and ⇧↩ too), Aa for case, and ×. With Find and Replace, a
/// second row for what to put.
final class FindPill: NSView, NSTextFieldDelegate {
    weak var target: Searchable?
    var onClose: (() -> Void)?
    var showsReplace = false {
        didSet { if showsReplace != oldValue { needsLayout = true; superview?.needsLayout = true } }
    }
    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 28
    var height: CGFloat { showsReplace ? 2 * Self.rowHeight + 2 : Self.rowHeight }

    private let field = NSTextField()
    private let replaceField = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = IconButton(symbol: "chevron.up", size: 10, target: nil, action: nil)
    private let next = IconButton(symbol: "chevron.down", size: 10, target: nil, action: nil)
    private let close = IconButton(symbol: "xmark", size: 9, target: nil, action: nil)
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; refresh() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight))
        wantsLayer = true
        layer?.cornerRadius = Self.rowHeight / 2
        layer?.masksToBounds = true
        // Above a terminal's Metal layer, which sits over its subviews.
        layer?.zPosition = 10
        for f in [field, replaceField] {
            f.delegate = self
            f.font = .systemFont(ofSize: 12.5)
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.cell?.sendsActionOnEndEditing = false
            f.lineBreakMode = .byTruncatingTail
            f.cell?.usesSingleLineMode = true
        }
        field.placeholderString = "Find"
        replaceField.placeholderString = "Replace with"
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = Theme.secondaryText
        count.alignment = .right
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.bezelStyle = .inline
        caseButton.controlSize = .mini
        caseButton.font = .systemFont(ofSize: 10, weight: .medium)
        caseButton.toolTip = "Match Case"
        caseButton.target = self
        caseButton.action = #selector(optionChanged)
        for b in [replaceButton, replaceAllButton] {
            b.bezelStyle = .inline
            b.controlSize = .mini
            b.font = .systemFont(ofSize: 10, weight: .medium)
            b.target = self
        }
        replaceButton.action = #selector(replaceClicked)
        replaceAllButton.action = #selector(replaceAllClicked)
        previous.target = self
        previous.action = #selector(previousClicked)
        previous.toolTip = "Previous (⇧↩, ⇧⌘G)"
        next.target = self
        next.action = #selector(nextClicked)
        next.toolTip = "Next (↩, ⌘G)"
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Done (⎋)"
        for v in [field, count, caseButton, previous, next, close, replaceField, replaceButton, replaceAllButton] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    override func layout() {
        super.layout()
        let h = Self.rowHeight
        let top = bounds.height - h
        close.frame = NSRect(x: bounds.width - 26, y: top + (h - 20) / 2, width: 20, height: 20)
        next.frame = NSRect(x: close.frame.minX - 22, y: close.frame.minY, width: 20, height: 20)
        previous.frame = NSRect(x: next.frame.minX - 20, y: close.frame.minY, width: 20, height: 20)
        // Narrow (a thin tile): the count goes, then the case toggle, so the
        // query keeps its room.
        caseButton.isHidden = bounds.width < 200
        count.isHidden = bounds.width < 240
        var left = previous.frame.minX
        if !caseButton.isHidden {
            caseButton.frame = NSRect(x: left - 30, y: top + (h - 16) / 2, width: 26, height: 16)
            left = caseButton.frame.minX
        }
        if !count.isHidden {
            count.frame = NSRect(x: left - 48, y: top + (h - 14) / 2, width: 44, height: 14)
            left = count.frame.minX
        }
        field.frame = NSRect(x: 14, y: top + (h - 17) / 2, width: left - 18, height: 17)
        let shown = showsReplace
        replaceField.isHidden = !shown
        replaceButton.isHidden = !shown
        replaceAllButton.isHidden = !shown
        if shown {
            replaceAllButton.frame = NSRect(x: bounds.width - 40, y: (h - 16) / 2, width: 32, height: 16)
            replaceButton.frame = NSRect(x: replaceAllButton.frame.minX - 62, y: (h - 16) / 2, width: 58, height: 16)
            replaceField.frame = NSRect(x: 14, y: (h - 17) / 2, width: replaceButton.frame.minX - 18, height: 17)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Self.rowHeight / 2, yRadius: Self.rowHeight / 2)
        Theme.windowBackground.setFill()
        path.fill()
        Theme.sheetEdge(hovered: false).setStroke()
        path.lineWidth = 1
        path.stroke()
        if showsReplace {
            Theme.divider.setFill()
            NSRect(x: 12, y: Self.rowHeight + 0.5, width: bounds.width - 24, height: 1).fill()
        }
    }

    // MARK: Finding

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === field { refresh() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField { replaceClicked() } else { target?.findNext(forward: !NSEvent.modifierFlags.contains(.shift)) }
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    /// The matches found again, and counted.
    func refresh() {
        let q = field.stringValue
        guard let target else { return }
        target.search(q, caseSensitive: caseButton.state == .on) { [weak self] n in
            guard let self else { return }
            self.count.stringValue = q.isEmpty ? "" : (n.map { $0 == 0 ? "none" : "\($0)" } ?? "")
        }
    }

    @objc private func nextClicked() { target?.findNext(forward: true) }
    @objc private func previousClicked() { target?.findNext(forward: false) }

    /// ⌘G and ⇧⌘G while typing in the pill: the field's editor would take
    /// Find Next for itself, so the pill steps through its matches first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.charactersIgnoringModifiers?.lowercased() == "g", flags == [.command] || flags == [.command, .shift],
              let editor = window?.firstResponder as? NSText, [field, replaceField].contains(where: { $0.currentEditor() === editor })
        else { return super.performKeyEquivalent(with: event) }
        target?.findNext(forward: !flags.contains(.shift))
        return true
    }
    @objc private func optionChanged() { refresh() }
    @objc private func closeClicked() { onClose?() }

    @objc private func replaceClicked() {
        (target as? Replaceable)?.replaceCurrent(with: replaceField.stringValue)
        refresh()
    }

    @objc private func replaceAllClicked() {
        (target as? Replaceable)?.replaceAll(with: replaceField.stringValue)
        refresh()
    }
}

/// Finding in a web page, by script: counted over the page's text,
/// stepped through with the browser's own find (which selects and
/// scrolls), so a preview and a web page are searched as an editor is.
enum PageFind {
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Counts the matches and selects the first from the selection (or
    /// the top).
    static func search(_ q: String, caseSensitive: Bool) -> String {
        let e = escaped(q), cs = caseSensitive ? "true" : "false"
        return """
        (function(){ var q='\(e)'; if(!q){ window.getSelection().removeAllRanges(); return 0; }
          var t=document.body.innerText||''; var re=new RegExp(q.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&'), \(cs)?'g':'gi');
          var m=t.match(re); var n=m?m.length:0;
          var sel=window.getSelection(); if(sel.rangeCount){ var r=sel.getRangeAt(0); sel.removeAllRanges(); sel.addRange(r); sel.collapseToStart(); }
          window.find(q, \(cs), false, true, false, false, false); return n; })()
        """
    }

    static func next(_ q: String, caseSensitive: Bool, forward: Bool) -> String {
        "window.find('\(escaped(q))', \(caseSensitive ? "true" : "false"), \(forward ? "false" : "true"), true, false, false, false)"
    }

    static let end = "window.getSelection().removeAllRanges()"
    static let selection = "window.getSelection().toString()"
}

/// Keeps a view's find pill: shows it at the tile's upper right (one band
/// down where the tile's own pill would be in the way), hands it the Find
/// menu's actions, and takes it away.
final class FindHost {
    private(set) var pill: FindPill?
    private weak var view: NSView?
    private weak var target: Searchable?
    /// The pill in the view's superview, over the view, for a view whose
    /// own layer is not its own (a terminal's is Metal's): a subview of it
    /// would not show.
    var inSuperview = false
    /// Where in the view the pill may go, if not all of it (below a header).
    var area: (() -> NSRect)?

    init(view: NSView, target: Searchable) {
        self.view = view
        self.target = target
    }

    /// The Find menu's action, by its NSTextFinder tag: ⌘F shows the pill
    /// (with the selection as the query), ⌥⌘F with replace, ⌘E with the
    /// word at hand and goes to it, ⌘G and ⇧⌘G step.
    func perform(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .showReplaceInterface?: show(replace: true, fromSelection: true)
        case .nextMatch?: pill == nil ? show(fromSelection: true) : target?.findNext(forward: true)
        case .previousMatch?: pill == nil ? show(fromSelection: true) : target?.findNext(forward: false)
        case .setSearchString?:
            // ⌘E: the word at hand, found, and on to its next occurrence;
            // the keyboard stays where it was, ⌘G goes on from there.
            target?.textForFind { [weak self] word in
                guard let self, let word, !word.isEmpty else { return }
                self.show(query: word, fromSelection: false)
                self.target?.findNext(forward: true)
            }
        case .hideFindInterface?: hide()
        default: show(fromSelection: true)
        }
    }

    /// Shows the pill; with `fromSelection`, the selected text (a line of
    /// it) is the query.
    func show(replace: Bool = false, query: String? = nil, fromSelection: Bool) {
        guard let view, let target else { return }
        if pill == nil {
            let p = FindPill()
            p.target = target
            p.onClose = { [weak self] in self?.hide() }
            (inSuperview ? view.superview ?? view : view).addSubview(p)
            pill = p
        }
        pill?.showsReplace = replace
        if let query {
            pill?.query = query
        } else if fromSelection {
            target.textForFind { [weak self] s in
                if let s, !s.isEmpty, !s.contains("\n") { self?.pill?.query = s }
            }
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        layout(in: area?() ?? view.bounds)
        if query == nil { pill?.focus() }
    }

    func hide() {
        guard let pill else { return }
        let focused = pill.window?.firstResponder as? NSView
        pill.removeFromSuperview()
        self.pill = nil
        target?.endSearch()
        if let focused, focused.isDescendant(of: pill), let view { view.window?.makeFirstResponder(view) }
    }

    /// Found again after the content changed.
    func refresh() { pill?.refresh() }

    /// Where the pill sits: the upper right of `bounds`, in the tile's band
    /// when there's room beside the tile's own pill, else one band down.
    func layout(in bounds: NSRect) {
        guard let pill else { return }
        let w = min(FindPill.width, bounds.width - 20), h = pill.height
        let inBand = bounds.width >= 860
        let y = bounds.height - (inBand ? 4 : GridView.band + 6) - h
        var frame = NSRect(x: bounds.width - 10 - w, y: y, width: w, height: h)
        if inSuperview, let view {
            // Over the view, in its superview; along when the view moves.
            if let parent = view.superview, pill.superview !== parent { parent.addSubview(pill) }
            frame = frame.offsetBy(dx: view.frame.minX, dy: view.frame.minY)
            pill.isHidden = view.isHidden
        }
        pill.frame = frame
    }
}

/// Find (⌘F) over a text view's text, for the find pill: every match
/// marked as the editor marks them, the current one stronger and scrolled
/// to, with the system's find indicator.
final class TextViewSearch {
    private weak var textView: NSTextView?
    private var matches: [NSRange] = []
    private var current: Int?
    private var query = ""
    /// Debugging: how many, and which is current.
    var debugState: String { "\(matches.count) matches, current \(current.map(String.init) ?? "none")" }
    private var caseSensitive = false

    init(_ textView: NSTextView) { self.textView = textView }

    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        clearMarks()
        self.query = query
        self.caseSensitive = caseSensitive
        guard let tv = textView, !query.isEmpty else {
            matches = []
            current = nil
            return done(nil)
        }
        let s = tv.string as NSString
        var found: [NSRange] = []
        var from = 0
        while from < s.length, found.count < 10_000 {
            let r = s.range(of: query, options: caseSensitive ? [] : [.caseInsensitive], range: NSRange(location: from, length: s.length - from))
            guard r.location != NSNotFound else { break }
            found.append(r)
            from = NSMaxRange(r)
        }
        matches = found
        for r in found { tv.layoutManager?.addTemporaryAttribute(.backgroundColor, value: TextView.matchColor, forCharacterRange: r) }
        // The first from where the selection is.
        let at = tv.selectedRange().location
        current = found.isEmpty ? nil : (found.firstIndex { $0.location >= at } ?? 0)
        go()
        done(found.count)
    }

    /// Found again (the text changed under the pill).
    func refresh() {
        guard !query.isEmpty else { return }
        search(query, caseSensitive: caseSensitive) { _ in }
    }

    func findNext(forward: Bool) {
        guard !matches.isEmpty else { return }
        let n = matches.count
        current = ((current ?? (forward ? -1 : 0)) + (forward ? 1 : n - 1)) % n
        go()
    }

    private func go() {
        guard let tv = textView else { return }
        for r in matches { tv.layoutManager?.addTemporaryAttribute(.backgroundColor, value: TextView.matchColor, forCharacterRange: r) }
        guard let i = current, i < matches.count else { return }
        let r = matches[i]
        tv.layoutManager?.addTemporaryAttribute(.backgroundColor, value: SearchPreviewView.currentMatch, forCharacterRange: r)
        tv.scrollRangeToVisible(r)
        tv.showFindIndicator(for: r)
    }

    func end() {
        clearMarks()
        matches = []
        current = nil
        query = ""
    }

    private func clearMarks() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    /// The selection, for ⌘E and as the pill's first query.
    var selectedText: String? {
        guard let tv = textView, tv.selectedRange().length > 0 else { return nil }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
}
