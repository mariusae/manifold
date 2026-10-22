import AppKit
import ManifoldCore

protocol OutputViewDelegate: AnyObject {
    /// Back to the command in its terminal.
    func output(_ view: OutputView, showSource source: BlockID, command: Int)
}

/// A command's output (§3.8), as the terminal showed it: the command line,
/// how it ended, and what it printed in the terminal's own colours and
/// face. Read-only; Copy puts it on the clipboard as text, and the link
/// goes back to the command in its terminal.
final class OutputView: NSView, PaneContent, KeepsViewState {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: OutputViewDelegate?
    var source: () -> Block? = { nil }
    var font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular) { didSet { if font != oldValue { shown = nil; refresh() } } }

    private let header = NSView()
    private let prompt = NSTextField(labelWithString: "")
    private let outcome = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Show in Terminal", target: nil, action: nil)
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private var shown: OutputState?
    private var plainText = ""
    private lazy var finder: FindHost = {
        let f = FindHost(view: self, target: self)
        f.area = { [weak self] in self?.findArea ?? .zero }
        return f
    }()
    /// The find pill below the header, clear of its buttons.
    private var findArea: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight + GridView.band)
    }
    private lazy var textSearch = TextViewSearch(text)

    var focusView: NSView { text }
    var isDead: Bool { false }
    static let headerHeight: CGFloat = 44
    /// Narrower than this, the buttons are their symbols alone.
    static let titledWidth: CGFloat = 380
    private var copied = false
    /// Where Copy puts it (another, in debugging).
    var pasteboard = NSPasteboard.general

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = TerminalPalette.current(for: $0).background.cgColor }
        header.wantsLayer = true
        header.themed { $0.layer?.backgroundColor = Theme.text.withAlphaComponent(0.04).cgColor }
        prompt.lineBreakMode = .byTruncatingTail
        prompt.textColor = Theme.text
        outcome.lineBreakMode = .byTruncatingTail
        outcome.font = .systemFont(ofSize: 11)
        outcome.textColor = Theme.secondaryText
        for (b, symbol, action) in [(back, "arrow.uturn.backward", #selector(backClicked)), (copy, "doc.on.doc", #selector(copyClicked))] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.image = Theme.symbol(symbol, size: 10)
            b.imagePosition = .imageLeading
            b.target = self
            b.action = action
        }
        back.toolTip = "Go to this command in its terminal"
        copy.toolTip = "Copy the command and its output"
        for v in [prompt, outcome, back, copy] { header.addSubview(v) }
        addSubview(header)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.height]
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        scroll.watchScrolling { [weak self] x, y in self?.keeper.note(["scrollX": "\(x)", "scroll": "\(y)"]) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shown = nil
        refresh()
    }

    /// The block's state again: drawn anew if it changed (it arrives a
    /// moment after the block is made).
    func refresh() {
        guard let o = source()?.output, o != shown else { return }
        shown = o
        prompt.attributedStringValue = NSAttributedString(string: "$ " + o.line, attributes: [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), .foregroundColor: Theme.text])
        var words: [String] = []
        if let s = o.status { words.append(s == 0 ? "ok" : "exit \(s)") } else if o.ran != nil { words.append(o.ended == nil ? "running" : "ok") }
        if let at = o.ended ?? o.ran { words.append(Age.ago(at)) }
        if o.plain { words.append("from the screen") }
        outcome.stringValue = words.joined(separator: " · ")
        outcome.textColor = (o.status ?? 0) == 0 ? Theme.secondaryText : Theme.statusError
        back.isEnabled = o.source != nil && o.command != nil
        let palette = TerminalPalette.current(for: self)
        let rendered = o.plain
            ? NSAttributedString(string: o.output, attributes: [.font: font, .foregroundColor: palette.foreground])
            : ANSIText.render(OutputState.trimmed(o.output), font: font, palette: palette)
        // Copied as text: without the spaces a terminal pads lines with.
        plainText = rendered.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.reversed().drop { $0 == " " }.reversed()) }.joined(separator: "\n")
        text.textStorage?.setAttributedString(rendered)
        text.sizeToFit()
        textSearch.refresh()
        needsLayout = true
        restoreScroll()
    }

    private func restoreScroll() {
        guard !keeper.restored else { return }
        keeper.restored = true
        let x = keeper.double("scrollX") ?? 0, y = keeper.double("scroll") ?? 0
        if x != 0 || y != 0 { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: x, y: y) } }
    }

    @objc private func backClicked() {
        guard let o = shown, let s = o.source, let c = o.command else { return }
        delegate?.output(self, showSource: s, command: c)
    }

    @objc private func copyClicked() {
        guard let o = shown else { return }
        pasteboard.clearContents()
        pasteboard.setString("$ " + o.line + "\n" + plainText + (plainText.hasSuffix("\n") ? "" : "\n"), forType: .string)
        copied = true
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copied = false; self?.needsLayout = true }
    }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("Copy Command and Output", symbol: "doc.on.doc") { [weak self] in self?.copyClicked() },
         ClosureMenuItem("Show in Terminal", symbol: "arrow.uturn.backward") { [weak self] in self?.backClicked() }]
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - Self.headerHeight, width: w, height: Self.headerHeight)
        finder.layout(in: findArea)
        // The command over how it went, at the left; the buttons at the
        // right, their titles dropped when the tile is narrow.
        let titled = w >= Self.titledWidth
        back.title = titled ? "Show in Terminal" : ""
        copy.title = titled ? (copied ? "Copied" : "Copy") : ""
        copy.image = Theme.symbol(copied ? "checkmark" : "doc.on.doc", size: 10)
        for b in [back, copy] { b.imagePosition = titled ? .imageLeading : .imageOnly; b.sizeToFit() }
        let by = ((Self.headerHeight - copy.frame.height) / 2).rounded()
        copy.frame = NSRect(x: w - 10 - copy.frame.width, y: by, width: copy.frame.width, height: copy.frame.height)
        back.frame = NSRect(x: copy.frame.minX - 4 - back.frame.width, y: by, width: back.frame.width, height: back.frame.height)
        let tw = max(0, back.frame.minX - 12 - 12)
        let ph = ceil(prompt.intrinsicContentSize.height)
        prompt.frame = NSRect(x: 12, y: Self.headerHeight / 2 - 1, width: tw, height: ph)
        outcome.frame = NSRect(x: 12, y: Self.headerHeight / 2 - 16, width: tw, height: 14)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - Self.headerHeight))
        text.minSize = NSSize(width: scroll.contentSize.width, height: scroll.contentSize.height)
    }

    /// Debugging: Copy pressed, onto a pasteboard of its own, and what it put there.
    func debugCopy() -> String {
        pasteboard = NSPasteboard(name: .init("manifold.debug"))
        defer { pasteboard = .general }
        copy.performClick(nil)
        return pasteboard.string(forType: .string) ?? "nothing"
    }

    /// Debugging: the find pill shown with a query typed; "next" steps.
    func debugFind(_ query: String) -> String {
        if query == "next" { findNext(forward: true) } else { finder.show(query: query, fromSelection: false) }
        return textSearch.debugState + (finder.pill == nil ? ", no pill" : ", pill up")
    }

    /// Debugging: Show in Terminal pressed.
    func debugBack() { back.performClick(nil) }

    /// Debugging: what it shows, as text, and how much of it is coloured.
    var debugDescription_: String {
        var runs = 0
        text.textStorage?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { v, _, _ in if v != nil { runs += 1 } }
        return "$ \(shown?.line ?? "?") [\(outcome.stringValue)] \(runs) runs\n" + plainText.prefix(400)
    }
}

extension OutputView: Searchable {
    /// ⌘F, ⌘G, ⌘E: the find pill, over what the command printed.
    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        textSearch.search(query, caseSensitive: caseSensitive, done: done)
    }

    func findNext(forward: Bool) { textSearch.findNext(forward: forward) }

    func endSearch() {
        textSearch.end()
        window?.makeFirstResponder(text)
    }

    func textForFind(_ done: @escaping (String?) -> Void) { done(textSearch.selectedText) }
}

/// The terminal's colours, as Ghostty is set up with them (§7.2): Paper
/// and GitHub's palettes, light and dark.
struct TerminalPalette {
    var background: NSColor
    var foreground: NSColor
    var ansi: [NSColor]

    static func current(for view: NSView) -> TerminalPalette {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    private static func hex(_ s: String) -> NSColor {
        let v = Int(s.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static let light = TerminalPalette(background: hex("#fcfcfb"), foreground: hex("#24292f"), ansi: [
        "#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
        "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"].map(hex))
    static let dark = TerminalPalette(background: hex("#1c1c1b"), foreground: hex("#e3e3df"), ansi: [
        "#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
        "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc"].map(hex))

    /// A 256-colour index: the sixteen, the 6×6×6 cube, the greys.
    func color(_ n: Int) -> NSColor {
        if n < 16 { return ansi[max(0, n)] }
        if n < 232 {
            let i = n - 16, steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: steps[i / 36] / 255, green: steps[(i / 6) % 6] / 255, blue: steps[i % 6] / 255, alpha: 1)
        }
        let g = CGFloat(8 + (n - 232) * 10) / 255
        return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
    }
}

/// Terminal output as attributed text: SGR's colours (16, 256, true) and
/// faces, carriage returns and backspaces overwriting as a terminal does
/// (a progress bar ends as its last state), lines erased; other escapes
/// (moving about the screen, titles, marks) dropped.
enum ANSIText {
    private enum Color: Equatable { case palette(Int), rgb(CGFloat, CGFloat, CGFloat) }
    private struct Style: Equatable {
        var fg: Color?
        var bg: Color?
        var bold = false, dim = false, italic = false, underline = false, inverse = false
    }
    private struct Cell { var ch: Character; var style: Style }

    static func render(_ s: String, font: NSFont, palette: TerminalPalette) -> NSAttributedString {
        var lines: [[Cell]] = [[]]
        var row = 0, col = 0
        var style = Style()
        func put(_ ch: Character) {
            while lines.count <= row { lines.append([]) }
            while lines[row].count < col { lines[row].append(Cell(ch: " ", style: Style())) }
            if col < lines[row].count { lines[row][col] = Cell(ch: ch, style: style) } else { lines[row].append(Cell(ch: ch, style: style)) }
            col += 1
        }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\u{1b}":
                guard i + 1 < chars.count else { i += 1; continue }
                let n = chars[i + 1]
                if n == "[" {
                    // CSI: parameters, then a final byte.
                    var j = i + 2
                    var params = ""
                    while j < chars.count, let a = chars[j].asciiValue, a >= 0x20, a < 0x40 { params.append(chars[j]); j += 1 }
                    guard j < chars.count else { i = j; continue }
                    let final = chars[j]
                    let nums = params.filter { $0 != "?" }.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                    let n0 = max(1, nums.first ?? 1)
                    switch final {
                    case "m": style = sgr(nums.isEmpty ? [0] : nums, style)
                    case "K":
                        while lines.count <= row { lines.append([]) }
                        switch nums.first ?? 0 {
                        case 1: for k in 0..<min(col + 1, lines[row].count) { lines[row][k] = Cell(ch: " ", style: Style()) }
                        case 2: lines[row] = []
                        default: if col < lines[row].count { lines[row].removeSubrange(col...) }
                        }
                    case "A": row = max(0, row - n0)
                    case "B": row += n0
                    case "C": col += n0
                    case "D": col = max(0, col - n0)
                    case "G": col = max(0, n0 - 1)
                    default: break
                    }
                    i = j + 1
                } else if n == "]" {
                    // OSC: to BEL or ST.
                    var j = i + 2
                    while j < chars.count, chars[j] != "\u{07}", !(chars[j] == "\u{1b}" && j + 1 < chars.count && chars[j + 1] == "\\") { j += 1 }
                    i = j < chars.count && chars[j] == "\u{07}" ? j + 1 : j + 2
                } else {
                    i += 2
                }
                continue
            case "\r\n", "\n":
                row += 1
                col = 0
            case "\r": col = 0
            case "\u{08}": col = max(0, col - 1)
            case "\t":
                let next = (col / 8 + 1) * 8
                while col < next { put(" ") }
            default:
                if let a = c.asciiValue, a < 0x20 || a == 0x7f { break }
                put(c)
            }
            i += 1
        }
        while let last = lines.last, last.isEmpty, lines.count > 1 { lines.removeLast() }

        let out = NSMutableAttributedString()
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        func resolve(_ c: Color?, default d: NSColor) -> NSColor {
            switch c {
            case .palette(let n)?: palette.color(n)
            case .rgb(let r, let g, let b)?: NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            case nil: d
            }
        }
        func attributes(_ st: Style) -> [NSAttributedString.Key: Any] {
            var fg = resolve(st.fg, default: palette.foreground)
            var bg: NSColor? = st.bg.map { resolve($0, default: palette.background) }
            if st.inverse { let f = fg; fg = bg ?? palette.background; bg = f }
            if st.dim { fg = fg.withAlphaComponent(0.6) }
            var a: [NSAttributedString.Key: Any] = [.font: st.bold ? bold : st.italic ? italic : font, .foregroundColor: fg]
            if let bg { a[.backgroundColor] = bg }
            if st.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            return a
        }
        for (n, line) in lines.enumerated() {
            var k = 0
            while k < line.count {
                let st = line[k].style
                var run = ""
                while k < line.count, line[k].style == st { run.append(line[k].ch); k += 1 }
                out.append(NSAttributedString(string: run, attributes: attributes(st)))
            }
            if n < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return out
    }

    private static func sgr(_ p: [Int], _ s: Style) -> Style {
        var s = s
        var i = 0
        func extended() -> Color? {
            guard i + 1 < p.count else { return nil }
            if p[i + 1] == 5, i + 2 < p.count { defer { i += 2 }; return .palette(p[i + 2]) }
            if p[i + 1] == 2, i + 4 < p.count { defer { i += 4 }; return .rgb(CGFloat(p[i + 2]) / 255, CGFloat(p[i + 3]) / 255, CGFloat(p[i + 4]) / 255) }
            return nil
        }
        while i < p.count {
            switch p[i] {
            case 0: s = Style()
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4: s.underline = true
            case 7: s.inverse = true
            case 22: s.bold = false; s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 27: s.inverse = false
            case 30...37: s.fg = .palette(p[i] - 30)
            case 38: s.fg = extended() ?? s.fg
            case 39: s.fg = nil
            case 40...47: s.bg = .palette(p[i] - 40)
            case 48: s.bg = extended() ?? s.bg
            case 49: s.bg = nil
            case 90...97: s.fg = .palette(p[i] - 90 + 8)
            case 100...107: s.bg = .palette(p[i] - 100 + 8)
            default: break
            }
            i += 1
        }
        return s
    }
}
