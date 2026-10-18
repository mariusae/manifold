import AppKit
import ManifoldCore

protocol EditorViewDelegate: AnyObject {
    /// The editor appends to its block's log.
    func editor(_ view: EditorView, append events: [Event])
    /// The editor asks the host for something (a save, a reload).
    func editor(_ view: EditorView, propose proposal: Proposal)
    /// The block's text, as the replica has it.
    func editorText(_ view: EditorView) -> TextState?
    /// The editor's text now differs from the file's, or no longer does.
    func editorEditedChanged(_ view: EditorView)
}

/// The editor lens on a text block: plain text, in the theme's proportional
/// or fixed-width font, with the usual Mac editing (undo, find, and so on).
/// Every edit is an entry in the block's log, so unsaved changes, the
/// selection and the scroll position are all there again after a quit.
final class EditorView: NSView, PaneContent, NSTextViewDelegate, NSMenuItemValidation {
    let placement: PlacementID
    let block: BlockID
    private(set) var path: String
    weak var delegate: EditorViewDelegate?

    private let scroll: NSScrollView
    private let text: EditorTextView
    private var banner: EditorBanner?
    /// The block's version the view's text matches.
    private var appliedVersion = -1
    private var applying = false
    private var isEdited = false
    private var stateWork: DispatchWorkItem?
    private var restored = false

    var font: EditorFont { didSet { if font != oldValue { applyFont() } } }
    var theme: FontTheme { didSet { if theme != oldValue { applyFont() } } }
    private var sizeAdjust: CGFloat = 0

    var focusView: NSView { text }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID, path: String, font: EditorFont, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.path = path
        self.font = font
        self.theme = theme
        scroll = NSScrollView()
        text = EditorTextView(usingTextLayoutManager: true)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }

        scroll.drawsBackground = false
        // No room kept for the (hidden) title bar.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        text.delegate = self
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.usesFontPanel = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 26, height: 20)
        text.insertionPointColor = .dynamic(NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1),
                                            NSColor(srgbRed: 0.04, green: 0.518, blue: 1, alpha: 1))
        text.selectedTextAttributes = [.backgroundColor: NSColor.dynamic(
            NSColor(srgbRed: 0.81, green: 0.886, blue: 0.984, alpha: 1),
            NSColor(srgbRed: 0.149, green: 0.31, blue: 0.47, alpha: 1))]
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        documentChanged()
    }

    override func layout() {
        super.layout()
        let bannerHeight: CGFloat = banner == nil ? 0 : 34
        banner?.frame = NSRect(x: 0, y: bounds.height - bannerHeight, width: bounds.width, height: bannerHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bannerHeight)
    }

    func destroy() {
        stateWork?.cancel()
    }

    // MARK: The block

    private var document: TextState? { delegate?.editorText(self) }

    /// The block's log moved: if not by us, the text is set to it again.
    func documentChanged() {
        guard let doc = document else { return }
        if doc.version != appliedVersion {
            let selection = text.selectedRange()
            let y = scroll.contentView.bounds.origin.y
            applying = true
            setText(doc.text.string)
            applying = false
            appliedVersion = doc.version
            let length = (text.string as NSString).length
            if !restored {
                restored = true
                if let ranges = doc.selections[placement], let first = ranges.first {
                    let loc = doc.text.utf16Offset(ofByte: first.start)
                    let end = doc.text.utf16Offset(ofByte: first.end)
                    text.setSelectedRange(NSRange(location: min(loc, length), length: max(0, min(end, length) - min(loc, length))))
                }
                if let sy = doc.scroll[placement] {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, sy)))
                        self.scroll.reflectScrolledClipView(self.scroll.contentView)
                    }
                }
            } else {
                text.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if doc.unreadable {
            text.isEditable = false
        }
        if doc.stale, banner == nil { showBanner() }
        if !doc.stale, banner != nil { hideBanner() }
        if doc.isDirty != isEdited {
            isEdited = doc.isDirty
            delegate?.editorEditedChanged(self)
        }
        if let p = document?.text, path.isEmpty, p.count == 0 {}
    }

    var isDirty: Bool { document?.isDirty == true }

    private func setText(_ s: String) {
        let attributes = text.typingAttributes
        text.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: attributes))
    }

    /// An edit about to be made in the view becomes an entry; the view then
    /// makes it too (NSTextView's own undo passes through here as well, so
    /// undo and redo are entries like any other).
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !applying, let doc = document, let replacement = replacementString else { return true }
        let rope = doc.text
        let start = rope.byteOffset(ofUTF16: range.location)
        let end = rope.byteOffset(ofUTF16: range.location + range.length)
        delegate?.editor(self, append: [.edit([TextEdit(start: start, end: end, text: replacement)])])
        appliedVersion = (document?.version) ?? appliedVersion
        return true
    }

    // MARK: Fonts

    private var textFont: NSFont {
        theme.font(font, size: max(8, theme.editorSize(font) + sizeAdjust))
    }

    private func applyFont() {
        let f = textFont
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = font == .proportional ? 1.2 : 1.15
        let space = (" " as NSString).size(withAttributes: [.font: f]).width
        style.defaultTabInterval = space * 4
        style.tabStops = []
        let attributes: [NSAttributedString.Key: Any] = [
            .font: f, .foregroundColor: Theme.text, .paragraphStyle: style,
        ]
        text.typingAttributes = attributes
        text.defaultParagraphStyle = style
        if let storage = text.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
    }

    @objc func increaseFontSize(_ sender: Any?) { sizeAdjust += 1; applyFont() }
    @objc func decreaseFontSize(_ sender: Any?) { sizeAdjust -= 1; applyFont() }
    @objc func resetFontSize(_ sender: Any?) { sizeAdjust = 0; applyFont() }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = document, !doc.unreadable else { return }
        if path.isEmpty { return saveAs() }
        delegate?.editor(self, propose: .writeFile(block, version: doc.version, text: doc.text.string))
    }

    /// A note, saved: it becomes a file.
    private func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Note.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let doc = self.document else { return }
            self.path = url.path
            self.delegate?.editor(self, append: [.path(url.path)])
            self.delegate?.editor(self, propose: .writeFile(self.block, version: doc.version, text: doc.text.string))
        }
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        guard !path.isEmpty else { return }
        delegate?.editor(self, propose: .readFile(block))
    }

    private func showBanner() {
        guard banner == nil else { return }
        let b = EditorBanner(message: "This file changed on disk.")
        b.onReload = { [weak self] in self?.revertDocumentToSaved(nil) }
        b.onKeep = { [weak self] in
            guard let self else { return }
            // Keep the edits, against what's on disk now.
            self.delegate?.editor(self, append: [.stale(false)])
        }
        addSubview(b)
        banner = b
        needsLayout = true
    }

    private func hideBanner() {
        banner?.removeFromSuperview()
        banner = nil
        needsLayout = true
    }

    // MARK: Edited

    func textDidChange(_ notification: Notification) {
        text.highlightedLine = nil
        scheduleStateSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // A line gone to stays marked until the caret leaves it.
        if let line = text.highlightedLine {
            let caret = text.selectedRange()
            if caret.location < line.location || NSMaxRange(caret) > NSMaxRange(line) { text.highlightedLine = nil }
        }
        scheduleStateSave()
    }

    // MARK: Kept state

    private func scheduleStateSave() {
        guard restored else { return }
        stateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        stateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveState() {
        stateWork?.cancel()
        guard let doc = document else { return }
        let sel = text.selectedRange()
        let range = TextRange(doc.text.byteOffset(ofUTF16: sel.location), doc.text.byteOffset(ofUTF16: sel.location + sel.length))
        var events: [Event] = []
        if doc.selections[placement] != [range] { events.append(.selection(placement: placement, ranges: [range])) }
        let y = Double(scroll.contentView.bounds.origin.y)
        if abs((doc.scroll[placement] ?? -1) - y) > 0.5 { events.append(.scroll(placement: placement, y: y)) }
        if !events.isEmpty { delegate?.editor(self, append: events) }
    }

    // MARK: Go to line

    @objc func goToLine(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "Line"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), line > 0 else { return }
            self.select(line: line)
        }
    }

    /// Goes to a line (from 1): selects it, or, given a column (from 1),
    /// puts the caret there.
    func select(line: Int, column: Int? = nil) {
        let s = text.string as NSString
        var start = 0, n = 1
        while n < line, start < s.length {
            let r = s.range(of: "\n", range: NSRange(location: start, length: s.length - start))
            guard r.location != NSNotFound else { break }
            start = r.location + 1
            n += 1
        }
        let range = s.lineRange(for: NSRange(location: min(start, s.length), length: 0))
        if let column {
            let end = range.length > 0 && s.character(at: NSMaxRange(range) - 1) == 10 ? NSMaxRange(range) - 1 : NSMaxRange(range)
            text.setSelectedRange(NSRange(location: min(range.location + column - 1, end), length: 0))
        } else {
            text.setSelectedRange(range)
        }
        text.scrollRangeToVisible(range)
        text.highlightedLine = range
        window?.makeFirstResponder(text)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)):
            return isDirty || path.isEmpty
        case #selector(revertDocumentToSaved(_:)):
            return (isDirty || banner != nil) && !path.isEmpty
        default:
            return true
        }
    }
}

/// The editor's text view: indents a new line as the one before it, and
/// marks a line gone to with a band across the page.
final class EditorTextView: NSTextView {
    var highlightedLine: NSRange? {
        didSet { if highlightedLine != oldValue { needsDisplay = true } }
    }

    static let highlight = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.95, blue: 0.72, alpha: 1),
                                           NSColor(srgbRed: 0.32, green: 0.28, blue: 0.12, alpha: 1))

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let band = highlightBand() else { return }
        Self.highlight.setFill()
        band.fill()
    }

    /// The highlighted line's full-width band, in view coordinates.
    private func highlightBand() -> NSRect? {
        guard let line = highlightedLine, let layout = textLayoutManager, let content = layout.textContentManager,
              NSMaxRange(line) <= (string as NSString).length,
              let start = content.location(content.documentRange.location, offsetBy: line.location),
              let end = content.location(start, offsetBy: line.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var union = NSRect.null
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            union = union.union(frame)
            return true
        }
        guard !union.isNull else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: 0, y: union.minY + origin.y, width: bounds.width, height: union.height)
    }

    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let caret = selectedRange().location
        let line = s.lineRange(for: NSRange(location: caret, length: 0))
        let head = s.substring(with: NSRange(location: line.location, length: caret - line.location))
        let indent = String(head.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// A bar across the top of an editor, for a file changed on disk.
final class EditorBanner: NSView {
    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?
    private let label: NSTextField
    private let reload: NSButton
    private let keep: NSButton

    init(message: String) {
        label = NSTextField(labelWithString: message)
        reload = NSButton(title: "Reload", target: nil, action: nil)
        keep = NSButton(title: "Keep Mine", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        themed {
            $0.layer?.backgroundColor = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 1),
                                                        NSColor(srgbRed: 0.27, green: 0.24, blue: 0.13, alpha: 1)).cgColor
        }
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = Theme.text
        for b in [reload, keep] {
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = .systemFont(ofSize: 12)
            b.target = self
        }
        reload.action = #selector(reloadClicked)
        keep.action = #selector(keepClicked)
        for v in [label, reload, keep] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        label.frame = NSRect(x: 26, y: (h - 16) / 2, width: bounds.width - 240, height: 16)
        keep.sizeToFit()
        reload.sizeToFit()
        keep.frame.origin = NSPoint(x: bounds.width - 16 - keep.frame.width, y: (h - keep.frame.height) / 2)
        reload.frame.origin = NSPoint(x: keep.frame.minX - 6 - reload.frame.width, y: (h - reload.frame.height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeep?() }
}
