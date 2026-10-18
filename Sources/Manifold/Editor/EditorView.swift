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
    /// What the block's language server says about it.
    func editorDiagnostics(_ view: EditorView) -> [Diagnostic]
    /// How the block's lines stand against what's committed.
    func editorGutter(_ view: EditorView) -> [GutterMark]
    /// The editor asks the block's language server something.
    func editor(_ view: EditorView, lsp request: LSPRequest, done: @escaping (LSPResult) -> Void)
    /// Opens another file at a line and column (from 1), beside this one.
    func editor(_ view: EditorView, open path: String, line: Int, column: Int)
    /// Applies a server's edits to files other than this one.
    func editor(_ view: EditorView, apply edits: [LSPFileEdit])
}

/// The editor lens on a text block: Manifold's own text view over the
/// block's rope (§7.1), in the theme's proportional or fixed-width font,
/// with a find bar, and a banner when the file changed on disk. Every edit
/// is an entry in the block's log, so unsaved changes, the selection and
/// the scroll position are all there again after a quit, and undo is more
/// entries.
final class EditorView: NSView, PaneContent, TextViewDocument, TextViewDelegate, NSMenuItemValidation {
    let placement: PlacementID
    let block: BlockID
    private(set) var path: String
    weak var delegate: EditorViewDelegate?

    let scroll = NSScrollView()
    let textView = TextView()
    private var banner: EditorBanner?
    private var findBar: FindBar?
    private var isEdited = false
    private var stateWork: DispatchWorkItem?
    private var restored = false
    private var lastVersion = -1
    var completion: CompletionPopup?
    var hover: NSPopover?
    let status = NSTextField(labelWithString: "")
    let statusBox = NSView()
    var statusMessage: String? { didSet { if statusMessage != oldValue { layoutStatus() } } }
    /// Something the server is doing for us, shown while it lasts.
    var busyMessage: String? { didSet { if busyMessage != oldValue { layoutStatus() } } }

    var font: EditorFont { didSet { if font != oldValue { applyFont() } } }
    var theme: FontTheme { didSet { if theme != oldValue { applyFont() } } }
    private var sizeAdjust: CGFloat = 0

    var focusView: NSView { textView }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID, path: String, font: EditorFont, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.path = path
        self.font = font
        self.theme = theme
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
        scroll.documentView = textView
        addSubview(scroll)
        textView.document = self
        textView.delegate = self
        textView.autoresizingMask = [.width]
        textView.commentLeader = Self.commentLeader(for: path)
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = Theme.text
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        statusBox.wantsLayer = true
        statusBox.isHidden = true
        statusBox.addSubview(status)
        addSubview(statusBox)
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        documentChanged()
    }

    override func layout() {
        super.layout()
        var top = bounds.height
        if let banner {
            banner.frame = NSRect(x: 0, y: top - 34, width: bounds.width, height: 34)
            top -= 34
        }
        if let findBar {
            findBar.frame = NSRect(x: 0, y: top - findBar.height, width: bounds.width, height: findBar.height)
            top -= findBar.height
        }
        var bottom: CGFloat = 0
        if !statusBox.isHidden {
            statusBox.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.statusHeight)
            status.frame = NSRect(x: 10, y: 3, width: bounds.width - 20, height: Self.statusHeight - 6)
            bottom = Self.statusHeight
        }
        scroll.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: top - bottom)
        textView.frame.size.width = scroll.contentSize.width
    }

    static let statusHeight: CGFloat = 24

    func destroy() {
        stateWork?.cancel()
        completion?.close()
        hover?.close()
    }

    // MARK: TextViewDocument

    private var document: TextState? { delegate?.editorText(self) }

    var rope: Rope { document?.text ?? Rope() }
    var version: Int { document?.version ?? 0 }

    func apply(_ edits: [TextEdit]) {
        delegate?.editor(self, append: [.edit(edits)])
    }

    /// The block's log moved: the view catches up, and the first time, the
    /// selection and scroll position come back.
    func documentChanged() {
        guard let doc = document else { return }
        let external = doc.version != lastVersion && doc.version != textView.undoKnownVersion
        lastVersion = doc.version
        textView.documentChanged()
        if !restored, doc.version > 0 || doc.unreadable {
            restored = true
            if let ranges = doc.selections[placement], !ranges.isEmpty {
                textView.setSelections(ranges.map { Selection($0.start, $0.end) }, scroll: false)
            }
            if let y = doc.scroll[placement] {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            }
        }
        if external { textView.savedUndoDepth = textView.undoDepth }
        textView.isEditable = !doc.unreadable
        if doc.stale, banner == nil { showBanner() }
        if !doc.stale, banner != nil { hideBanner() }
        if doc.isDirty != isEdited {
            isEdited = doc.isDirty
            delegate?.editorEditedChanged(self)
        }
        findBar?.refresh()
        diagnosticsChanged()
        gutterChanged()
    }

    /// The host redid the block's git gutter.
    func gutterChanged() {
        let marks = delegate?.editorGutter(self) ?? []
        if marks != textView.gutterMarks { textView.gutterMarks = marks }
    }

    /// The language server said something new about the block.
    func diagnosticsChanged() {
        let items = delegate?.editorDiagnostics(self) ?? []
        if items != textView.diagnostics { textView.diagnostics = items }
        updateStatus()
    }

    var isDirty: Bool { document?.isDirty == true }
    /// The file's text has arrived (or it couldn't be read).
    var isLoaded: Bool { (document?.version ?? 0) > 0 || document?.unreadable == true }

    // MARK: TextViewDelegate

    func textViewDidChangeSelection(_ view: TextView) {
        scheduleStateSave()
        updateStatus()
        hover?.close()
    }

    func textViewDidScroll(_ view: TextView) {
        scheduleStateSave()
        completion?.close()
        hover?.close()
    }

    func textViewDidEdit(_ view: TextView) {
        // Undone back to what was saved: clean again, as the log sees it.
        if let doc = document, doc.isDirty, textView.undoDepth == textView.savedUndoDepth, !path.isEmpty, doc.cleanVersion > 0 {
            delegate?.editor(self, append: [.clean(version: doc.version, fingerprint: nil)])
        }
        scheduleStateSave()
        findBar?.refresh()
        completionTextChanged()
    }

    // MARK: Fonts

    private var textFont: NSFont {
        theme.font(font, size: max(8, theme.editorSize(font) + sizeAdjust))
    }

    private func applyFont() {
        textView.font = textFont
        textView.lineHeightMultiple = font == .proportional ? 1.25 : 1.2
    }

    @objc func increaseFontSize(_ sender: Any?) { sizeAdjust += 1; applyFont() }
    @objc func decreaseFontSize(_ sender: Any?) { sizeAdjust -= 1; applyFont() }
    @objc func resetFontSize(_ sender: Any?) { sizeAdjust = 0; applyFont() }

    static func commentLeader(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "sh", "zsh", "bash", "rb", "yaml", "yml", "toml", "pl", "r", "conf", "cfg", "ini", "zig", "nix", "make", "mk", "dockerfile", "gitignore": "#"
        case "lua", "sql", "hs", "elm": "--"
        case "lisp", "el", "clj", "scm": ";"
        case "tex": "%"
        case "vim": "\""
        default: "//"
        }
    }

    // MARK: Saving

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = document, !doc.unreadable else { return }
        if path.isEmpty { return saveAs() }
        textView.savedUndoDepth = textView.undoDepth
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
            self.textView.commentLeader = Self.commentLeader(for: url.path)
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
        let ranges = textView.selections.map { $0.range }
        var events: [Event] = []
        if doc.selections[placement] != ranges { events.append(.selection(placement: placement, ranges: ranges)) }
        let y = Double(scroll.contentView.bounds.origin.y)
        if abs((doc.scroll[placement] ?? -1) - y) > 0.5 { events.append(.scroll(placement: placement, y: y)) }
        if !events.isEmpty { delegate?.editor(self, append: events) }
    }

    // MARK: Find

    @objc override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .showFindInterface?: showFind(replace: false)
        case .showReplaceInterface?: showFind(replace: true)
        case .nextMatch?: findBar == nil ? showFind(replace: false) : findBar?.find(forward: true)
        case .previousMatch?: findBar == nil ? showFind(replace: false) : findBar?.find(forward: false)
        case .hideFindInterface?: hideFind()
        default: showFind(replace: false)
        }
    }

    private func showFind(replace: Bool) {
        if findBar == nil {
            let bar = FindBar(text: textView)
            bar.onClose = { [weak self] in self?.hideFind() }
            addSubview(bar)
            findBar = bar
        }
        findBar?.showsReplace = replace
        if !textView.selectedText.isEmpty, !textView.selectedText.contains("\n") { findBar?.query = textView.selectedText }
        needsLayout = true
        layoutSubtreeIfNeeded()
        findBar?.focus()
    }

    private func hideFind() {
        findBar?.removeFromSuperview()
        findBar = nil
        textView.highlights = []
        needsLayout = true
        window?.makeFirstResponder(textView)
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
        let r = textView.offset(line: line, column: column)
        textView.setSelections([Selection(r.start, r.end)])
        textView.highlightedLine = line - 1
        window?.makeFirstResponder(textView)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)):
            return isDirty || path.isEmpty
        case #selector(revertDocumentToSaved(_:)):
            return (isDirty || banner != nil) && !path.isEmpty
        case #selector(goToDefinition(_:)), #selector(findReferences(_:)), #selector(showDocumentation(_:)),
             #selector(renameSymbol(_:)), #selector(formatDocument(_:)), #selector(completeSymbol(_:)):
            return !path.isEmpty
        default:
            return true
        }
    }
}

extension TextView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo
        case #selector(redo(_:)): return canRedo
        case #selector(cut(_:)), #selector(copy(_:)): return !selectedText.isEmpty
        case #selector(paste(_:)): return isEditable && NSPasteboard.general.string(forType: .string) != nil
        default: return true
        }
    }
}

/// The find bar: a field, the next and previous matches, and, shown with
/// ⌥⌘F, a field to replace them with.
final class FindBar: NSView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    private weak var textView: TextView?
    private let field = NSTextField()
    private let replaceField = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private var matches: [TextRange] = []
    var showsReplace = false { didSet { needsLayout = true; superview?.needsLayout = true } }
    var height: CGFloat { showsReplace ? 66 : 36 }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue; refresh() }
    }

    init(text: TextView) {
        self.textView = text
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.sheet(level: 0).cgColor }
        field.placeholderString = "Find"
        field.delegate = self
        field.font = .systemFont(ofSize: 12.5)
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        replaceField.placeholderString = "Replace"
        replaceField.delegate = self
        replaceField.font = .systemFont(ofSize: 12.5)
        replaceField.controlSize = .small
        replaceField.bezelStyle = .roundedBezel
        count.font = .systemFont(ofSize: 11)
        count.textColor = Theme.secondaryText
        count.alignment = .right
        for b in [previous, next, caseButton, replaceButton, replaceAllButton, done] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.target = self
        }
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.toolTip = "Match Case"
        previous.action = #selector(previousClicked)
        next.action = #selector(nextClicked)
        caseButton.action = #selector(optionChanged)
        replaceButton.action = #selector(replaceClicked)
        replaceAllButton.action = #selector(replaceAllClicked)
        done.action = #selector(doneClicked)
        done.keyEquivalent = "\u{1b}"
        for v in [field, previous, next, caseButton, count, done, replaceField, replaceButton, replaceAllButton] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    override func layout() {
        super.layout()
        let y = height - 30
        field.frame = NSRect(x: 12, y: y, width: max(120, bounds.width - 330), height: 22)
        previous.frame = NSRect(x: field.frame.maxX + 6, y: y - 1, width: 28, height: 24)
        next.frame = NSRect(x: previous.frame.maxX + 2, y: y - 1, width: 28, height: 24)
        caseButton.frame = NSRect(x: next.frame.maxX + 8, y: y - 1, width: 36, height: 24)
        count.frame = NSRect(x: caseButton.frame.maxX + 6, y: y + 2, width: 70, height: 16)
        done.frame = NSRect(x: bounds.width - 70, y: y - 1, width: 58, height: 24)
        let shown = showsReplace
        replaceField.isHidden = !shown
        replaceButton.isHidden = !shown
        replaceAllButton.isHidden = !shown
        if shown {
            replaceField.frame = NSRect(x: 12, y: 6, width: field.frame.width, height: 22)
            replaceButton.frame = NSRect(x: replaceField.frame.maxX + 6, y: 5, width: 74, height: 24)
            replaceAllButton.frame = NSRect(x: replaceButton.frame.maxX + 2, y: 5, width: 44, height: 24)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === field { refresh(); find(forward: true, fromSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField { replaceClicked() } else { find(forward: !NSEvent.modifierFlags.contains(.shift)) }
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    /// The matches, highlighted, and counted.
    func refresh() {
        guard let textView else { return }
        let q = field.stringValue
        matches = q.isEmpty ? [] : textView.text.findAll(q, caseInsensitive: caseButton.state != .on, limit: 20_000)
        textView.highlights = matches
        count.stringValue = q.isEmpty ? "" : (matches.isEmpty ? "No matches" : "\(matches.count)")
    }

    /// Selects the next (or previous) match from the selection.
    func find(forward: Bool, fromSelection: Bool = true) {
        guard let textView, !matches.isEmpty else { return }
        let sel = textView.primarySelection
        let match: TextRange?
        if forward {
            let from = fromSelection ? sel.max : sel.min
            match = matches.first { $0.start >= from && !(fromSelection && $0.start == sel.min && $0.end == sel.max) } ?? matches.first
        } else {
            match = matches.last { $0.start < sel.min } ?? matches.last
        }
        if let match { textView.setSelections([Selection(match.start, match.end)]) }
    }

    @objc private func nextClicked() { find(forward: true) }
    @objc private func previousClicked() { find(forward: false) }
    @objc private func optionChanged() { refresh() }
    @objc private func doneClicked() { onClose?() }

    @objc private func replaceClicked() {
        guard let textView else { return }
        let sel = textView.primarySelection
        if matches.contains(where: { $0.start == sel.min && $0.end == sel.max }) {
            textView.replace([(sel.range, replaceField.stringValue)])
            refresh()
        }
        find(forward: true)
    }

    @objc private func replaceAllClicked() {
        guard let textView, !matches.isEmpty else { return }
        let r = replaceField.stringValue
        textView.replace(matches.map { ($0, r) })
        refresh()
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
