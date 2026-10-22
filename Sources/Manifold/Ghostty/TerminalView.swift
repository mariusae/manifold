import AppKit
import GhosttyKit
import ManifoldCore

protocol TerminalViewDelegate: AnyObject {
    func terminalDidFocus(_ view: TerminalView)
    func terminalDidClose(_ view: TerminalView)
    /// A link in the terminal was opened (⌘-clicked): a URL, or a path;
    /// `over`: ⌥ was held too, for what opens to go over the terminal.
    func terminal(_ view: TerminalView, open target: String, over: Bool)
    /// ⌘-clicked on a word ghostty doesn't take for a link (a folder's
    /// name, as `ls` prints it): opened if it names a folder.
    func terminal(_ view: TerminalView, openFolder name: String, over: Bool)
    /// A command on the scrubber was opened: it and its output, as a block.
    /// A command and its output, to show as a block of their own, beside
    /// a placement (an outline's) if given.
    func terminal(_ view: TerminalView, show command: ShellCommand, output: String, beside: PlacementID?)
    /// Copy on Select was switched from the pill's menu: a setting.
    func terminal(_ view: TerminalView, setCopyOnSelect on: Bool)
    /// A block was ⇧-dragged onto the terminal (its path typed): linked to it.
    func terminal(_ view: TerminalView, linkedFrom block: BlockID)
    /// What runs under the terminal's shell, as last listed: the tree its
    /// menu shows. `refresh`: a fresh listing is asked for too.
    func terminalProcesses(_ view: TerminalView, refresh: Bool) -> [ProcessEntry]
    /// A process in the menu's tree is to be ended or killed.
    func terminal(_ view: TerminalView, signal pid: Int32, _ signal: Int32)
    /// A command right-clicked in the outline: its menu (an agent's turn's).
    func terminal(_ view: TerminalView, menuFor command: ShellCommand) -> NSMenu?
}

/// A terminal block's view: a ghostty surface running `manifoldd attach
/// <block>`, which connects it to the block's shell in the server.
final class TerminalView: NSView, PaneContent, NSTextInputClient, NSMenuItemValidation, NSMenuDelegate {
    let placement: PlacementID
    let block: BlockID
    private(set) var surface: ghostty_surface_t?
    weak var delegate: TerminalViewDelegate?
    var cellSize = NSSize(width: 8, height: 16)
    let created = Date()

    var focusView: NSView { self }
    /// A surface can't be made while no display is awake; one that failed
    /// is made again after a moment.
    var isDead: Bool { surface == nil && Date().timeIntervalSince(created) >= 2 }

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var cursor = NSCursor.iBeam
    private var contentSize = NSSize.zero
    private var trackingArea: NSTrackingArea?

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    init(placement: PlacementID, block: BlockID, command: String) {
        self.placement = placement
        self.block = block
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .string])

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        surface = command.withCString { cmd in
            config.command = cmd
            return ghostty_surface_new(GhosttyRuntime.shared.app, &config)
        }
        if surface == nil { NSLog("manifold: could not create a terminal surface for %@", block.description) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Frees the surface, which hangs up on the attach helper; the session
    /// itself lives on in the server.
    func destroy() {
        finder.hide()
        scrubber.removeFromSuperview()
        tip.removeFromSuperview()
        locateWork?.cancel()
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    deinit { destroy() }

    func surfaceClosed() {
        destroy()
        delegate?.terminalDidClose(self)
    }

    // MARK: Size and focus

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
        finder.layout(in: NSRect(origin: .zero, size: newSize))
        layoutLock()
    }

    /// The program is reading a password: a lock at the lower right says
    /// the keyboard is kept from other apps (Secure Keyboard Entry).
    var readingPassword = false {
        didSet {
            guard readingPassword != oldValue else { return }
            if readingPassword, lock == nil {
                let l = NSTextField(labelWithString: "")
                let text = NSMutableAttributedString()
                let a = NSTextAttachment()
                a.image = Theme.symbol("lock.fill", size: 10, weight: .semibold)
                text.append(NSAttributedString(attachment: a))
                text.append(NSAttributedString(string: " Secure Input", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
                l.attributedStringValue = text
                l.textColor = Theme.text
                l.wantsLayer = true
                l.layer?.cornerRadius = 9
                l.layer?.backgroundColor = Theme.panel.cgColor
                l.toolTip = "A password is being read: other apps can't see what you type"
                addSubview(l)
                lock = l
            }
            lock?.isHidden = !readingPassword
            layoutLock()
        }
    }
    private var lock: NSTextField?

    private func layoutLock() {
        guard let lock, !lock.isHidden else { return }
        let size = lock.fittingSize
        lock.frame = NSRect(x: bounds.width - size.width - 28, y: 10, width: size.width + 16, height: 18)
        lock.alignment = .center
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        finder.layout(in: bounds)
        layoutScroller()
    }

    override var isHidden: Bool {
        didSet {
            finder.layout(in: bounds)
            layoutScroller()
            // The outline hides with the terminal (stashed, out of sight), and comes back with it.
            sidebar?.isHidden = isHidden || !sidebarOn
        }
    }
    /// The outline asked for, shown or not just now.
    private var sidebarOn = false

    private func sizeDidChange(_ size: NSSize) {
        contentSize = size
        guard let surface, size.width > 0, size.height > 0 else { return }
        // The scroller's column at the right is not the terminal's.
        let scaled = convertToBacking(NSSize(width: max(size.width - Self.scrollerWidth, 1), height: size.height))
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
        layoutScroller()
    }

    // MARK: The scrubber (§3.1)

    static let scrollerWidth: CGFloat = ScrubberView.width
    /// In the superview, over the tile's right edge, as the find pill is:
    /// Ghostty's layer is this view's, under which a subview wouldn't show.
    private lazy var scrubber: ScrubberView = {
        let s = ScrubberView(frame: NSRect(x: 0, y: 0, width: Self.scrollerWidth, height: 100))
        s.layer?.zPosition = 5
        s.onScroll = { [weak self] fraction in self?.scroll(toFraction: fraction) }
        s.onPick = { [weak self] mark in self?.go(to: mark) }
        s.onOpen = { [weak self] mark in self?.open(mark) }
        s.onHover = { [weak self] mark, y in self?.hover(mark, at: y) }
        s.markMenu = { [weak self] mark in self?.markMenu(mark) }
        return s
    }()
    private lazy var tip: ScrubTip = {
        let t = ScrubTip(frame: .zero)
        t.isHidden = true
        t.onEnter = { [weak self] in self?.tipHideWork?.cancel() }
        t.onExit = { [weak self] in self?.hideTip() }
        t.onClick = { [weak self] in
            guard let self, let mark = self.tipMark else { return }
            self.open(mark)
        }
        t.onCopy = { [weak self] in
            guard let self, let mark = self.tipMark else { return }
            self.copyTranscript(mark)
        }
        return t
    }()
    private var tipMark: ScrubMark?
    private var tipHideWork: DispatchWorkItem?
    private var scrollbar = (total: 0, offset: 0, len: 0)

    /// What the core says of the screen and its history: how many rows,
    /// which the top one is, how many show.
    func scrollbarChanged(total: Int, offset: Int, len: Int) {
        let grew = total != scrollbar.total
        scrollbar = (total, offset, len)
        layoutScroller()
        updateMarks()
        markCurrentCommand()
        if grew { scheduleLocate() }
    }

    // MARK: The outline (§7.5)

    /// The commands (an agent's turns) at the tile's left, each with how
    /// it ended; clicked, the terminal goes there and the command's whole
    /// output opens beside as a block of its own. In the superview, as the
    /// scrubber is (Ghostty's layer is this view's): the terminal moves
    /// over to make room for it.
    private var sidebar: TileSidebar?
    /// The frame the grid gave, the sidebar's room taken from it.
    private var given: NSRect?
    var hasSidebar: Bool { true }
    var sidebarShown: Bool { sidebarOn }
    /// Kept with the tile: shown or not.
    var onToggleSidebar: ((Bool) -> Void)?

    func toggleSidebar() {
        setSidebar(!sidebarShown)
        onToggleSidebar?(sidebarShown)
    }

    func setSidebar(_ shown: Bool) {
        guard shown != sidebarShown else { return }
        if shown, sidebar == nil {
            let s = TileSidebar(emptyText: "No commands yet")
            s.layer?.zPosition = 5
            s.onPick = { [weak self] i in
                guard let self, self.commands.indices.contains(i) else { return }
                let id = self.commands[i].id
                self.go(toCommand: id)
                _ = self.showOutput(ofCommand: id, beside: self.placement)
                self.sidebar?.current = i
            }
            // A command dragged out: its text (to type again, to keep in a note).
            s.writerFor = { [weak self] i in
                guard let self, self.commands.indices.contains(i) else { return nil }
                let item = NSPasteboardItem()
                item.setString(self.commands[i].text, forType: .string)
                return item
            }
            s.menuFor = { [weak self] i in
                guard let self, self.commands.indices.contains(i) else { return nil }
                return self.delegate?.terminal(self, menuFor: self.commands[i])
            }
            sidebar = s
        }
        sidebarOn = shown
        sidebar?.isHidden = !shown || isHidden
        if let given { frame = given }
        fillSidebar()
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            given = newValue
            guard let sidebar, sidebarOn, let parent = superview else { return super.frame = newValue }
            let w = min(TileSidebar.width, (newValue.width / 3).rounded())
            if sidebar.superview !== parent { parent.addSubview(sidebar) }
            sidebar.frame = NSRect(x: newValue.minX, y: newValue.minY, width: w, height: newValue.height)
            super.frame = NSRect(x: newValue.minX + w, y: newValue.minY, width: newValue.width - w, height: newValue.height)
        }
    }

    private func fillSidebar() {
        guard let sidebar, sidebarOn else { return }
        sidebar.set(commands.map { c in
            var detail: String
            if let st = c.status { detail = st == 0 ? Age.short(c.at) : "exit \(st) · \(Age.short(c.at))" } else { detail = c.id == commands.last?.id ? "running" : Age.short(c.at) }
            if detail == "now" { detail = "just now" }
            return TileSidebar.Entry(title: c.text, detail: detail, failed: (c.status ?? 0) != 0, running: c.status == nil && c.id == commands.last?.id, code: true)
        })
        markCurrentCommand()
    }

    /// The last command at or above the top of what shows.
    private func markCurrentCommand() {
        guard let sidebar, sidebarOn else { return }
        let top = scrollbar.offset + 1
        sidebar.current = commands.lastIndex { (located[$0.id] ?? Int.max) <= top } ?? (commands.isEmpty ? nil : 0)
    }

    var debugSidebar: String { sidebar.map { $0.isHidden ? "hidden" : $0.debugEntries } ?? "none" }
    func debugSidebarPick(_ i: Int) -> String { sidebar?.debugPick(i) ?? "none" }

    private func layoutScroller() {
        guard let parent = superview else { return }
        if scrubber.superview !== parent { parent.addSubview(scrubber) }
        if tip.superview !== parent { parent.addSubview(tip) }
        scrubber.frame = NSRect(x: frame.maxX - Self.scrollerWidth, y: frame.minY, width: Self.scrollerWidth, height: max(0, frame.height - GridView.band))
        scrubber.isHidden = isHidden || scrollbar.total <= scrollbar.len && commands.isEmpty
        if isHidden { hideTip(now: true) }
    }

    private func updateMarks() {
        let marks = commands.compactMap { c -> ScrubMark? in
            guard let row = located[c.id] else { return nil }
            let last = c.id == commands.last?.id
            var words: [String] = []
            if let st = c.status { words.append(st == 0 ? "ok" : "exit \(st)") } else if last { words.append("running") }
            let age = Age.short(c.at)
            words.append(age == "now" ? age : age + " ago")
            return ScrubMark(id: c.id, at: Double(row), title: c.text, detail: words.joined(separator: " · "),
                             failed: c.failed, running: c.ended == nil && last)
        }
        scrubber.update(marks: marks, total: Double(scrollbar.total), offset: Double(scrollbar.offset), shown: Double(scrollbar.len))
    }

    private func scroll(toFraction fraction: Double) {
        let span = max(scrollbar.total - scrollbar.len, 0)
        perform("scroll_to_row:\(Int((fraction * Double(span)).rounded()))")
    }

    private func go(to mark: ScrubMark) {
        perform("scroll_to_row:\(Int(mark.at))")
    }

    /// A command's row scrolled to, by its id (an outline's click).
    /// Scrolls to a command's row; false if it isn't found on the screen (yet).
    /// The command last gone to, while it's the place the terminal is at.
    private var commandGoneTo: Int?
    var navLocation: NavLocation? { commandGoneTo.map { .command($0) } }
    func go(to location: NavLocation) {
        if case let .command(id) = location { _ = go(toCommand: id) }
    }

    @discardableResult
    func go(toCommand id: Int) -> Bool {
        NavJumps.willJump?(self)
        commandGoneTo = id
        // Not found yet (a terminal just come into view, its rows not read
        // since): looked for now, rather than after the usual pause.
        if located[id] == nil { locate() }
        guard let row = located[id] else { return false }
        perform("scroll_to_row:\(row)")
        return true
    }

    /// A command's output as a block of its own (§3.8), beside a placement.
    @discardableResult
    func showOutput(ofCommand id: Int, beside: PlacementID?) -> Bool {
        // The host keeps what the command wrote; the screen's rows are only
        // a fallback, for a command it didn't see (one from before).
        guard let c = commands.first(where: { $0.id == id }) else { return false }
        delegate?.terminal(self, show: c, output: transcript(ofCommand: id)?.1 ?? "", beside: beside)
        return true
    }

    /// A command and its output, as shown: the rows from its prompt to
    /// the next command's (or the end).
    private func transcript(of mark: ScrubMark) -> (ShellCommand, String)? { transcript(ofCommand: mark.id) }

    private func transcript(ofCommand id: Int) -> (ShellCommand, String)? {
        guard let c = commands.first(where: { $0.id == id }), let row = located[c.id] else { return nil }
        let next = commands.compactMap { located[$0.id] }.filter { $0 > row }.min() ?? scrollbar.total
        var output = text(rows: (row + 1)..<min(next, row + 20000))
        while output.hasSuffix("\n") || output.hasSuffix(" ") { output.removeLast() }
        return (c, output)
    }

    /// The command and its output, as a block.
    private func open(_ mark: ScrubMark) {
        guard let (c, output) = transcript(of: mark) else { return }
        hideTip(now: true)
        delegate?.terminal(self, show: c, output: output, beside: nil)
    }

    /// The command and its output, onto the clipboard.
    private func copyTranscript(_ mark: ScrubMark) {
        guard let (c, output) = transcript(of: mark) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("$ " + c.text + "\n" + output + "\n", forType: .string)
        hideTip(now: true)
    }

    private func markMenu(_ mark: ScrubMark) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Go to Command", symbol: "arrow.right.circle") { [weak self] in self?.go(to: mark) })
        menu.addItem(ClosureMenuItem("Show Command and Output", symbol: "doc.text") { [weak self] in self?.open(mark) })
        menu.addItem(ClosureMenuItem("Copy Command and Output", symbol: "doc.on.doc") { [weak self] in self?.copyTranscript(mark) })
        return menu
    }

    private func hover(_ mark: ScrubMark?, at y: CGFloat) {
        tipHideWork?.cancel()
        guard let mark, let parent = superview else { hideTip(); return }
        tipMark = mark
        tip.show(mark)
        let size = tip.fittingSize
        let point = parent.convert(NSPoint(x: 0, y: y), from: scrubber)
        let top = min(max(point.y - size.height / 2, frame.minY), frame.maxY - size.height)
        tip.frame = NSRect(x: scrubber.frame.minX - size.width - 4, y: round(top), width: size.width, height: size.height)
        tip.isHidden = false
    }

    /// Gone, after a moment: time to move onto it from the strip.
    private func hideTip(now: Bool = false) {
        tipHideWork?.cancel()
        if now { tip.isHidden = true; tipMark = nil; return }
        let work = DispatchWorkItem { [weak self] in self?.tip.isHidden = true; self?.tipMark = nil }
        tipHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Commands on the scrubber (§3.8)

    /// The shell's commands, from the block; each is found on the screen
    /// by its line, and marked there.
    var commands: [ShellCommand] = [] {
        didSet {
            guard commands != oldValue else { return }
            scheduleLocate()
            updateMarks()
            fillSidebar()
        }
    }
    /// Each command's row on the screen, once found.
    private(set) var located: [Int: Int] = [:]
    private var locateWork: DispatchWorkItem?

    private func scheduleLocate() {
        locateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.locate() }
        locateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The screen's text, its history and all: each logical line, and the
    /// row it starts on. Ghostty joins soft-wrapped rows (and reaches the
    /// history only for the whole screen), so a line's rows are counted
    /// from its width.
    fileprivate var transcriptLines: String? { screenLines()?.map { String($0.text) }.joined(separator: "\n") }

    private func screenLines() -> [(row: Int, text: Substring)]? {
        guard let surface else { return nil }
        let cols = max(Int(ghostty_surface_size(surface).columns), 1)
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let p = out.text else { return [] }
        let all = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: Int(out.text_len)), as: UTF8.self)
        var lines: [(row: Int, text: Substring)] = []
        var row = 0
        for line in all.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append((row, line))
            row += max(1, (Self.cells(line) + cols - 1) / cols)
        }
        return lines
    }

    /// How many cells a line takes: wide characters two.
    static func cells(_ s: Substring) -> Int {
        var n = 0
        for u in s.unicodeScalars {
            let v = u.value
            if v < 0x20 || (0x7F...0x9F).contains(v) || (0x300...0x36F).contains(v) || v == 0x200B || v == 0xFE0F { continue }
            n += (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v)
                || (0x20000...0x3FFFD).contains(v) ? 2 : 1
        }
        return n
    }

    /// Whether a line is the one a command was typed on: the prompt, then
    /// the command — with nothing after it, or a gap and a prompt's right
    /// side; or, the command longer than the line shows (continued on
    /// lines of its own), the start of it.
    static func lineShows(_ command: String, in line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if let r = t.range(of: command) {
            let rest = t[r.upperBound...]
            if rest.isEmpty || rest.hasPrefix("  ") { return true }
        }
        if command.count > 16, t.count >= 16 {
            let tail = t.suffix(min(t.count, command.count - 1))
            for k in stride(from: tail.count, through: 16, by: -1) where command.hasPrefix(tail.suffix(k)) { return true }
        }
        return false
    }

    /// Finds the commands on the screen, in order: each on the first line
    /// after the one before that shows it. A line showing a later command
    /// leaves the ones between unmarked; they are all looked for again
    /// each time, so a screen cleared or trimmed is simply read anew.
    func locate() {
        guard scrollbar.total > 0, !commands.isEmpty else {
            if !located.isEmpty { located = [:]; updateMarks() }
            return
        }
        guard let lines = screenLines() else { return }
        var found: [Int: Int] = [:]
        var i = commands.startIndex
        for (row, line) in lines where i < commands.endIndex {
            for j in i..<min(i + 3, commands.endIndex) where Self.lineShows(commands[j].text, in: line) {
                found[commands[j].id] = row
                i = j + 1
                break
            }
        }
        if found != located {
            located = found
            updateMarks()
        }
    }

    /// What the screen shows now, as text: the rows in view, blank ones
    /// at the end left off (for a card of the terminal).
    var visibleText: String {
        let rows = text(rows: scrollbar.offset..<(scrollbar.offset + scrollbar.len))
        var lines = rows.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(14).joined(separator: "\n")
    }

    /// The text shown from one row up to another: for a command's output.
    private func text(rows range: Range<Int>) -> String {
        guard let lines = screenLines() else { return "" }
        return lines.filter { range.contains($0.row) }.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    // MARK: Debugging

    var debugScrubber: String {
        "total \(scrollbar.total) offset \(scrollbar.offset) len \(scrollbar.len) commands \(commands.count) located \(located.count)\n" + scrubber.debugMarks
    }

    func debugScrub(_ what: String, _ arg: String) -> String {
        switch what {
        case "hover":
            guard let f = Double(arg) else { return "usage: scrub hover <fraction>" }
            let mark = scrubber.debugHover(fraction: f)
            return mark.map { "\($0.id) \($0.title) tip \(tip.isHidden ? "hidden" : "shown")" } ?? "nothing"
        case "go", "open":
            guard let id = Int(arg), let c = commands.first(where: { $0.id == id }), let row = located[id] else { return "no such command" }
            let mark = ScrubMark(id: id, at: Double(row), title: c.text)
            if what == "go" { go(to: mark) } else { open(mark) }
            return "ok"
        case "locate":
            locate()
            return debugScrubber
        case "row":
            guard let r = Int(arg) else { return "usage: scrub row <n>" }
            return screenLines()?.last(where: { $0.row <= r }).map { "\($0.row): \($0.text)" } ?? "none"
        case "lines":
            return (screenLines() ?? []).suffix(Int(arg) ?? 20).map { "\($0.row): \($0.text)" }.joined(separator: "\n")
        default:
            return debugScrubber
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface else { return }
        let fb = convertToBacking(frame)
        if frame.width > 0, frame.height > 0 {
            ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        }
        sizeDidChange(contentSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let surface, let screen = window?.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        viewDidChangeBackingProperties()
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
        syncFocus()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncFocus()
        finder.layout(in: bounds)
        if superview == nil { scrubber.removeFromSuperview(); tip.removeFromSuperview() } else { layoutScroller() }
        // The outline goes with it (lent to a card, put back).
        if superview == nil { sidebar?.removeFromSuperview() } else if let given { frame = given }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            setFocus(true)
            delegate?.terminalDidFocus(self)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocus(false) }
        return ok
    }

    /// Whether ghostty thinks this terminal has the keyboard: a new surface
    /// starts out thinking it has.
    private var hasFocus = true

    private func setFocus(_ focused: Bool) {
        hasFocus = focused
        if let surface { ghostty_surface_set_focus(surface, focused) }
    }

    /// Tells ghostty whether this terminal really has the keyboard. A view
    /// taken out of its window (another tab shown, or lent to the stack
    /// switcher) while it has it loses it without being asked to resign,
    /// and would otherwise go on drawing its cursor as the focused one.
    func syncFocus() {
        let focused = window != nil && window?.firstResponder === self
        if focused != hasFocus { setFocus(focused) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { if isUnderPointer { cursor.set() } }

    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        default: cursor = .arrow
        }
        if let window, window.isKeyWindow, isUnderPointer { cursor.set() }
    }

    private func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e { Self.ghosttyMods(flags) }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods(event.modifierFlags))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        commandClickAt = event.modifierFlags.contains(.command) ? event.locationInWindow : nil
        linkOpened = false
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, clickMods(event))
    }

    /// Whether a selection made with the mouse goes to the clipboard at
    /// once (a setting, the same for every terminal) — not in full screen,
    /// where selecting is for reading.
    static var copyOnSelect = true

    /// ⌘⌥-click: ghostty opens a link on ⌘-click alone (its modifiers must
    /// match), so ⌥ is kept from it and remembered here, for the open that
    /// follows to put what it opens over the terminal.
    private(set) var openOver = false

    /// The click's modifiers for ghostty, ⌥ taken off a ⌘⌥-click and noted.
    private func clickMods(_ event: NSEvent) -> ghostty_input_mods_e {
        var flags = event.modifierFlags
        openOver = flags.contains(.command) && flags.contains(.option)
        if openOver { flags.remove(.option) }
        return mods(flags)
    }

    /// Where a ⌘-click went down, until it comes up.
    private var commandClickAt: NSPoint?
    /// Ghostty opened a link in the click under way (its patterns knew it).
    var linkOpened = false

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, clickMods(event))
        ghostty_surface_mouse_pressure(surface, 0, 0)
        // A ⌘-click ghostty took for no link: the word there, for a folder.
        if let down = commandClickAt, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) < 4 {
            let over = openOver
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.linkOpened, let word = self.wordUnderPointer, !word.isEmpty else { return }
                self.delegate?.terminal(self, openFolder: word, over: over)
            }
        }
        commandClickAt = nil
        if Self.copyOnSelect, !(window?.styleMask.contains(.fullScreen) ?? false), let text = selectedText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pulseSelection(text)
        }
    }

    /// The selection just copied, pulsed once: its cells lit for a moment
    /// and fading, so the copy is seen to happen (§3.8).
    private func pulseSelection(_ text: String) {
        guard let surface, let layer else { return }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return }
        ghostty_surface_free_text(surface, &t)
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0, size.columns > 0, t.offset_len > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let cw = CGFloat(size.cell_width_px) / scale, ch = CGFloat(size.cell_height_px) / scale
        let cols = Int(size.columns)
        // The offsets count cells of the viewport; the point is the first
        // cell's left and baseline, in points from the surface's top left.
        let start = Int(t.offset_start), end = start + Int(t.offset_len)
        let r0 = start / cols, c0 = start % cols
        let r1 = end / cols, c1 = end % cols
        let left = CGFloat(t.tl_px_x) - CGFloat(c0) * cw
        let firstTop = CGFloat(t.tl_px_y) - ch * 0.8
        func rowRect(_ r: Int, from: Int, to: Int) -> NSRect {
            NSRect(x: left + CGFloat(from) * cw, y: bounds.height - firstTop - CGFloat(r - r0 + 1) * ch, width: CGFloat(max(to - from, 1)) * cw, height: ch)
        }
        let path = CGMutablePath()
        if r1 == r0 {
            path.addRect(rowRect(r0, from: c0, to: c1))
        } else {
            path.addRect(rowRect(r0, from: c0, to: cols))
            for r in (r0 + 1)..<r1 { path.addRect(rowRect(r, from: 0, to: cols)) }
            if c1 > 0 { path.addRect(rowRect(r1, from: 0, to: c1)) }
        }
        let pulse = CAShapeLayer()
        pulse.path = path
        pulse.fillColor = Theme.accent.withAlphaComponent(0.45).cgColor
        pulse.opacity = 0
        pulse.frame = bounds
        layer.addSublayer(pulse)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.25, 1]
        fade.duration = 0.5
        fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        CATransaction.begin()
        CATransaction.setCompletionBlock { pulse.removeFromSuperlayer() }
        pulse.add(fade, forKey: "pulse")
        CATransaction.commit()
    }

    var pillItems: [NSMenuItem] {
        let item = ClosureMenuItem("Copy on Select", symbol: "doc.on.clipboard") { [weak self] in
            guard let self else { return }
            self.delegate?.terminal(self, setCopyOnSelect: !Self.copyOnSelect)
        }
        item.state = Self.copyOnSelect ? .on : .off
        return [item]
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event.modifierFlags))
    }

    /// Moved over the terminal — not over something covering it (the
    /// sidebar floating out), which would have it show a link's hand.
    override func mouseMoved(with event: NSEvent) { if isUnderPointer { sendMousePos(event) } }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func mouseEntered(with event: NSEvent) { sendMousePos(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        var momentum: Int32 = 0
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        let scrollMods: ghostty_input_scroll_mods_t = (precise ? 1 : 0) | (momentum << 1)
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }
        if let surface, ghostty_surface_mouse_captured(surface) { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear", action: #selector(clearScreen(_:)), keyEquivalent: "")
        // The processes under the shell, the shell first, each a submenu
        // of what to do with it and what runs under it. The host's
        // listing is asked for afresh; the menu, still open when it
        // comes, is filled in then.
        menu.addItem(.separator())
        processItemsStart = menu.items.count
        menu.delegate = self
        openMenu = menu
        fillProcesses(menu, with: delegate?.terminalProcesses(self, refresh: true) ?? [], listing: true)
        return menu
    }

    /// The host's own items, after the processes (which are filled in
    /// later, so kept apart from them).
    private func appendHostItems(_ menu: NSMenu) { HostMenu.append(for: block.host, to: menu) }

    /// The menu open now, to fill in when the listing comes.
    private weak var openMenu: NSMenu?
    private var processItemsStart = 0

    private func fillProcesses(_ menu: NSMenu, with entries: [ProcessEntry], listing: Bool) {
        while menu.items.count > processItemsStart { menu.removeItem(at: menu.items.count - 1) }
        if entries.isEmpty {
            let none = NSMenuItem(title: listing ? "Listing processes…" : "No processes under the shell", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let pids = Set(entries.map(\.pid))
            for item in processItems(entries, under: nil, pids: pids) { menu.addItem(item) }
        }
        appendHostItems(menu)
    }

    /// The host listed its processes: a menu open now shows them.
    func processesChanged() {
        guard let menu = openMenu else { return }
        fillProcesses(menu, with: delegate?.terminalProcesses(self, refresh: false) ?? [], listing: false)
    }

    func menuDidClose(_ menu: NSMenu) { if openMenu === menu { openMenu = nil } }

    /// The items for the processes whose parent is `parent` (nil: the
    /// roots, whose parents aren't listed), each with its submenu.
    private func processItems(_ entries: [ProcessEntry], under parent: Int32?, pids: Set<Int32>) -> [NSMenuItem] {
        let mine = entries.filter { parent == nil ? !pids.contains($0.parent) : $0.parent == parent }
        return mine.map { e in
            let item = NSMenuItem(title: "\(e.command)  ·  \(e.pid)", action: nil, keyEquivalent: "")
            item.setSymbol(parent == nil ? "terminal" : "circle.fill", size: parent == nil ? 11 : 5)
            if let path = e.path { item.toolTip = path }
            let sub = NSMenu()
            sub.addItem(ClosureMenuItem("End \(e.command)", symbol: "stop.circle") { [weak self] in
                guard let self else { return }
                self.delegate?.terminal(self, signal: e.pid, SIGTERM)
            })
            sub.addItem(ClosureMenuItem("Force End \(e.command)", symbol: "xmark.octagon") { [weak self] in
                guard let self else { return }
                self.delegate?.terminal(self, signal: e.pid, SIGKILL)
            })
            let children = processItems(entries, under: e.pid, pids: pids)
            if !children.isEmpty {
                sub.addItem(.separator())
                for c in children { sub.addItem(c) }
            }
            item.submenu = sub
            return item
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        let translated = Self.eventModifierFlags(ghostty_surface_key_translation_mods(surface, mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0

        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent),
                          composing: markedText.length > 0 || markedBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let m = mods(event.modifierFlags)
        let action = m.rawValue & mod != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        // Control-return and control-slash would otherwise be eaten by AppKit
        // (the latter with a beep); they belong to the terminal.
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        // Command-return is Edit or View for a text; here it's the terminal's, as it was.
        if flags == [.command], event.charactersIgnoringModifiers == "\r" {
            keyDown(with: event)
            return true
        }
        guard flags.contains(.control), !flags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers {
        case "\r", "/":
            keyDown(with: event)
            return true
        default:
            return false
        }
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = mods(event.modifierFlags)
        ev.consumed_mods = mods((translationEvent?.modifierFlags ?? event.modifierFlags).subtracting([.control, .command]))
        ev.composing = composing
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ghostty_surface_preedit(surface, $0, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// The terminal's cursor cell, in the window.
    var caretRectInWindow: NSRect? {
        guard let surface else { return nil }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let rect = NSRect(x: x, y: frame.height - y - h, width: max(w, cellSize.width), height: max(h, cellSize.height))
        return convert(rect, to: nil)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let rect = NSRect(x: x, y: frame.height - y, width: 0, height: max(h, cellSize.height))
        let win = convert(rect, to: nil)
        return window?.convertToScreen(win) ?? win
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil, let surface else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator!.append(chars)
            return
        }
        chars.withCString { ghostty_surface_text(surface, $0, UInt(chars.utf8.count)) }
    }

    override func doCommand(by selector: Selector) {
        // Keys that map to editing commands are encoded by ghostty in keyDown.
    }

    // MARK: Drops

    /// Files or text dropped on the terminal are typed into it, paths
    /// quoted for the shell, as a terminal takes them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.dropText(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    /// On another host: this Mac's files dropped are sent to the shell's
    /// folder there, and their paths there typed (what they're called
    /// there, given back when they're in).
    var uploadDrop: (([URL], @escaping ([String]) -> Void) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let uploadDrop, pb.types?.contains(.manifoldPath) != true,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            window?.makeFirstResponder(self)
            uploadDrop(urls) { [weak self] paths in
                guard let self, let surface = self.surface, !paths.isEmpty else { return }
                let text = paths.map(Self.shellQuoted).joined(separator: " ")
                text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
            }
            return true
        }
        guard let surface, let text = Self.dropText(pb) else { return false }
        window?.makeFirstResponder(self)
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        if let link = pb.string(forType: .manifoldBlockLink), let block = TextView.blockID(inLink: link) {
            delegate?.terminal(self, linkedFrom: block)
        }
        return true
    }

    /// What a drop types: each file's path, quoted if the shell would
    /// need it, a space between; else the text as it is.
    static func dropText(_ pb: NSPasteboard) -> String? {
        // A folder tile's entries (a folder, another host's file: no file
        // URL) by their paths, each quoted.
        let entries = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .manifoldPath)?.split(separator: "\t", omittingEmptySubsequences: false) }
            .filter { $0.count == 3 }.map { String($0[1]) }
        if !entries.isEmpty { return entries.map(shellQuoted).joined(separator: " ") }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { shellQuoted($0.path) }.joined(separator: " ")
        }
        // A tile ⇧-dragged: its path (or address), quoted as one word.
        if pb.types?.contains(.manifoldBlockLink) == true, let s = pb.string(forType: .string), !s.isEmpty { return shellQuoted(s) }
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        return nil
    }

    static func shellQuoted(_ path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+:@%,=~".unicodeScalars.contains($0) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Actions

    private func perform(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Find (§3.1)

    private lazy var finder: FindHost = {
        let f = FindHost(view: self, target: self)
        f.inSuperview = true
        return f
    }()
    private var searchCount: ((Int?) -> Void)?
    private var endingFromCore = false

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    /// The core began a search (a binding of its own): the pill shows,
    /// with the needle it has.
    func searchStarted(needle: String) {
        finder.show(query: needle.isEmpty ? nil : needle, fromSelection: needle.isEmpty)
    }

    func searchEnded() {
        endingFromCore = true
        finder.hide()
        endingFromCore = false
    }

    func searchTotal(_ total: Int?) {
        searchCount?(total)
        searchCount = nil
    }

    func searchSelected(_ selected: Int?) {}

    /// The selected text, if any.
    /// The word under the pointer, as a double-click would select it.
    private var wordUnderPointer: String? {
        guard let surface else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let p = out.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: Int(out.text_len)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedText: String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(t.text_len)), as: UTF8.self)
    }

    @objc func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { perform("select_all") }
    @objc func clearScreen(_ sender: Any?) { perform("clear_screen") }
    @objc func increaseFontSize(_ sender: Any?) { perform("increase_font_size:1") }
    @objc func decreaseFontSize(_ sender: Any?) { perform("decrease_font_size:1") }
    @objc func resetFontSize(_ sender: Any?) { perform("reset_font_size") }
    @objc func scrollToTop(_ sender: Any?) { perform("scroll_to_top") }
    @objc func scrollToBottom(_ sender: Any?) { perform("scroll_to_bottom") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return surface.map { ghostty_surface_has_selection($0) } ?? false
        }
        return surface != nil
    }

    // MARK: Helpers

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    /// The text for a key event, without control characters (ghostty encodes
    /// those itself) or the private-use characters AppKit gives function keys.
    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}

extension TerminalView: Searchable {
    /// The core searches the screen and its history, highlighting every
    /// match and selecting the nearest; it says how many when it has
    /// looked (case as the core takes it).
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        guard !query.isEmpty else {
            searchCount = nil
            perform("search:")
            return done(nil)
        }
        searchCount = done
        perform("search:" + query)
    }

    func findNext(forward: Bool) { perform(forward ? "navigate_search:next" : "navigate_search:previous") }

    func endSearch() {
        searchCount = nil
        if !endingFromCore { perform("end_search") }
        window?.makeFirstResponder(self)
    }

    func textForFind(_ done: @escaping (String?) -> Void) { done(selectedText) }
}

extension TerminalView: Printable {
    /// The transcript as the terminal has it, history and all, as text.
    func printOperation() -> NSPrintOperation? {
        guard let lines = transcriptLines else { return nil }
        return TextPrint.operation(lines, title: "Terminal", font: TextPrint.codeFont)
    }
}
