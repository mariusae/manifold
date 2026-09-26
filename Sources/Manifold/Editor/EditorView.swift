import AppKit
import ManifoldCore

protocol EditorViewDelegate: AnyObject {
    /// The editor's text now differs from the file's, or no longer does.
    func editorEditedChanged(_ view: EditorView)
}

/// A text file, being edited: plain text, in the theme's proportional or fixed-width font,
/// with the usual Mac editing (undo, find, and so on) and nothing clever.
///
/// Unsaved changes, the selection, and the scroll position are kept on disk
/// beside the server's state, so they're there again after a quit.
final class EditorView: NSView, PaneContent, NSTextViewDelegate, NSMenuItemValidation {
    let pane: UUID
    private(set) var path: String
    weak var delegate: EditorViewDelegate?

    private let scroll: NSScrollView
    private let text: EditorTextView
    private var banner: EditorBanner?
    private var watcher: FileWatcher?

    /// The file's text, as last loaded or saved.
    private var saved = ""
    private var encoding: String.Encoding = .utf8
    private var lineEnding = "\n"
    private(set) var isEdited = false
    private var checkWork: DispatchWorkItem?
    private var stateWork: DispatchWorkItem?
    private var loadFailed = false

    var font: EditorFont { didSet { if font != oldValue { applyFont() } } }
    var theme: FontTheme { didSet { if theme != oldValue { applyFont() } } }
    private var sizeAdjust: CGFloat = 0

    var focusView: NSView { text }
    var isDead: Bool { false }

    init(pane: UUID, path: String, font: EditorFont, theme: FontTheme) {
        self.pane = pane
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

        load(restoring: true)
        watch()
        NotificationCenter.default.addObserver(self, selector: #selector(saveState),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let bannerHeight: CGFloat = banner == nil ? 0 : 34
        banner?.frame = NSRect(x: 0, y: bounds.height - bannerHeight, width: bounds.width, height: bannerHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bannerHeight)
    }

    /// The pane's gone: its unsaved changes go with it.
    func destroy() {
        watcher = nil
        try? FileManager.default.removeItem(at: stateFile)
        NotificationCenter.default.removeObserver(self)
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

    // MARK: Loading and saving

    /// Reads the file; the first time, puts back unsaved changes, selection,
    /// and scroll position from before.
    private func load(restoring: Bool) {
        let disk = Self.read(path)
        loadFailed = disk == nil
        saved = disk?.text ?? ""
        encoding = disk?.encoding ?? .utf8
        lineEnding = disk?.lineEnding ?? "\n"
        var shown = saved
        var state: EditorState?
        if restoring, let s = EditorState.load(from: stateFile) {
            state = s
            if let draft = s.draft { shown = draft }
        }
        setText(shown)
        if let state {
            let length = (text.string as NSString).length
            let sel = NSRange(location: min(state.selection[0], length), length: 0)
            let end = min(state.selection[0] + state.selection[1], length)
            text.setSelectedRange(NSRange(location: sel.location, length: max(0, end - sel.location)))
            DispatchQueue.main.async { [weak self] in
                self?.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, state.scrollY)))
                self?.scroll.reflectScrolledClipView(self!.scroll.contentView)
            }
            // The file changed under unsaved changes while we were away.
            if state.draft != nil, let base = state.base, base != Self.fingerprint(saved) {
                showBanner()
            }
        }
        updateEdited()
        if loadFailed && FileManager.default.fileExists(atPath: path) {
            text.isEditable = false
            setText("\(path) can't be read as text.")
        }
    }

    private func setText(_ s: String) {
        let attributes = text.typingAttributes
        text.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: attributes))
        text.undoManager?.removeAllActions()
    }

    struct Disk {
        var text: String
        var encoding: String.Encoding
        var lineEnding: String
    }

    /// A text file's text, with its line endings made "\n".
    static func read(_ path: String) -> Disk? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let encoding: String.Encoding
        let raw: String
        if let s = String(data: data, encoding: .utf8) {
            (raw, encoding) = (s, .utf8)
        } else if let s = String(data: data, encoding: .isoLatin1) {
            (raw, encoding) = (s, .isoLatin1)
        } else {
            return nil
        }
        let crlf = raw.contains("\r\n")
        return Disk(text: crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw,
                    encoding: encoding, lineEnding: crlf ? "\r\n" : "\n")
    }

    /// Whether a file looks like text: no NULs near its start.
    static func isText(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0)
    }

    @objc func saveDocument(_ sender: Any?) {
        guard !loadFailed || !FileManager.default.fileExists(atPath: path) else { return }
        var out = text.string
        if lineEnding != "\n" { out = out.replacingOccurrences(of: "\n", with: lineEnding) }
        guard let data = out.data(using: encoding) ?? out.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        // An atomic write makes a new file; keep the old one's permissions.
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        do {
            try data.write(to: url, options: .atomic)
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            }
            saved = text.string
            hideBanner()
            updateEdited()
            saveState()
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    @objc func revertDocumentToSaved(_ sender: Any?) {
        reload()
    }

    private func reload() {
        let selection = text.selectedRange()
        let y = scroll.contentView.bounds.origin.y
        guard let disk = Self.read(path) else { return }
        saved = disk.text
        encoding = disk.encoding
        lineEnding = disk.lineEnding
        setText(saved)
        let length = (text.string as NSString).length
        text.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        hideBanner()
        updateEdited()
        saveState()
    }

    // MARK: Changes on disk

    private func watch() {
        watcher = FileWatcher(path: path) { [weak self] in self?.fileChanged() }
    }

    private func fileChanged() {
        guard let disk = Self.read(path), disk.text != saved else { return }
        if isEdited {
            showBanner()
        } else {
            reload()
        }
    }

    private func showBanner() {
        guard banner == nil else { return }
        let b = EditorBanner(message: "This file changed on disk.")
        b.onReload = { [weak self] in self?.reload() }
        b.onKeep = { [weak self] in
            guard let self else { return }
            // Keep the edits, against what's on disk now.
            if let disk = Self.read(self.path) { self.saved = disk.text }
            self.hideBanner()
            self.updateEdited()
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
        checkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateEdited() }
        checkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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

    private func updateEdited() {
        let edited = !loadFailed && text.string != saved
        guard edited != isEdited else { return }
        isEdited = edited
        delegate?.editorEditedChanged(self)
    }

    // MARK: Kept state

    private var stateFile: URL { Self.stateFile(pane) }

    static func stateFile(_ pane: UUID) -> URL {
        Paths.directory.appendingPathComponent("editors").appendingPathComponent("\(pane.uuidString).json")
    }

    /// Whether an editor has unsaved changes kept, open or not.
    static func hasUnsavedChanges(_ pane: UUID) -> Bool {
        EditorState.load(from: stateFile(pane))?.draft != nil
    }

    private func scheduleStateSave() {
        stateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        stateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func saveState() {
        stateWork?.cancel()
        let sel = text.selectedRange()
        let draft = text.string != saved ? text.string : nil
        let state = EditorState(selection: [sel.location, sel.length], scrollY: scroll.contentView.bounds.origin.y,
                                draft: draft, base: draft == nil ? nil : Self.fingerprint(saved))
        state.save(to: stateFile)
    }

    /// Enough to tell whether a file's text changed.
    static func fingerprint(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(s.utf8.count)-\(String(hash, radix: 16))"
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
        case #selector(saveDocument(_:)), #selector(revertDocumentToSaved(_:)):
            return isEdited || banner != nil
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

/// What an editor keeps between runs: where it was, and unsaved changes
/// (with a fingerprint of the file they were made against).
struct EditorState: Codable {
    var selection: [Int]
    var scrollY: Double
    var draft: String?
    var base: String?

    static func load(from url: URL) -> EditorState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditorState.self, from: data)
    }

    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
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
