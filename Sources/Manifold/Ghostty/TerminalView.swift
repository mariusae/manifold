import AppKit
import GhosttyKit
import ManifoldCore

protocol TerminalViewDelegate: AnyObject {
    func terminalDidFocus(_ view: TerminalView)
    func terminalDidClose(_ view: TerminalView)
    /// A link in the terminal was opened (command-clicked): a URL, or a path.
    func terminal(_ view: TerminalView, open target: String)
    /// A command on the scrubber was opened: it and its output, as a block.
    func terminal(_ view: TerminalView, show command: ShellCommand, output: String)
    /// Copy on Select was switched from the pill's menu: a setting.
    func terminal(_ view: TerminalView, setCopyOnSelect on: Bool)
}

/// A terminal block's view: a ghostty surface running `manifoldd attach
/// <block>`, which connects it to the block's shell in the server.
final class TerminalView: NSView, PaneContent, NSTextInputClient, NSMenuItemValidation {
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
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        finder.layout(in: bounds)
        layoutScroller()
    }

    override var isHidden: Bool { didSet { finder.layout(in: bounds); layoutScroller() } }

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
        if grew { scheduleLocate() }
    }

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

    /// A command and its output, as shown: the rows from its prompt to
    /// the next command's (or the end).
    private func transcript(of mark: ScrubMark) -> (ShellCommand, String)? {
        guard let c = commands.first(where: { $0.id == mark.id }), let row = located[c.id] else { return nil }
        let next = commands.compactMap { located[$0.id] }.filter { $0 > row }.min() ?? scrollbar.total
        var output = text(rows: (row + 1)..<min(next, row + 20000))
        while output.hasSuffix("\n") || output.hasSuffix(" ") { output.removeLast() }
        return (c, output)
    }

    /// The command and its output, as a block.
    private func open(_ mark: ScrubMark) {
        guard let (c, output) = transcript(of: mark) else { return }
        hideTip(now: true)
        delegate?.terminal(self, show: c, output: output)
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

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

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
        if let window, window.isKeyWindow, let loc = window.mouseLocationOutsideOfEventStream as NSPoint?,
           bounds.contains(convert(loc, from: nil)) {
            cursor.set()
        }
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
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event.modifierFlags))
    }

    /// Whether a selection made with the mouse goes to the clipboard at
    /// once (a setting, the same for every terminal) — not in full screen,
    /// where selecting is for reading.
    static var copyOnSelect = true

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
        if Self.copyOnSelect, !(window?.styleMask.contains(.fullScreen) ?? false), let text = selectedText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
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

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
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
        return menu
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

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface, let text = Self.dropText(sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        return true
    }

    /// What a drop types: each file's path, quoted if the shell would
    /// need it, a space between; else the text as it is.
    static func dropText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { shellQuoted($0.path) }.joined(separator: " ")
        }
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
