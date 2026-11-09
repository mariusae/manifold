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

    /// Here (§2.5): the command it's the output of, in its terminal.
    var here: Place? {
        guard let o = source()?.output, let terminal = o.source, let n = o.command else { return nil }
        return Place(block: terminal, at: .command(n), name: String(o.line.prefix(60)))
    }
    var font: NSFont = .systemMono(ofSize: 12.5, weight: .regular) { didSet { if font != oldValue { shown = nil; refresh() } } }

    private let header = NSView()
    private let prompt = NSTextField(labelWithString: "")
    private let outcome = NSTextField(labelWithString: "")
    private let back = FlatButton("Show in Terminal", symbol: "arrow.uturn.backward", font: UIType.footnote)
    private let copy = FlatButton("Copy", symbol: "doc.on.doc", font: UIType.footnote)
    private let scroll = ClippingScrollView()
    private let text = OutputFindTextView()
    private var shown: OutputState?
    private var plainText = ""
    private lazy var finder: FindHost = {
        let f = FindHost(view: self, target: self)
        f.area = { [weak self] in self?.findArea ?? .zero }
        return f
    }()
    /// The find pill below the header, clear of its buttons.
    private var findArea: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
    }
    private lazy var textSearch = TextViewSearch(text)

    var focusView: NSView { text }
    static let headerHeight: CGFloat = 44
    private var copied = false
    /// The buttons, under the pointer on the header (the copy's check
    /// shown till it's gone).
    private lazy var reveal: HoverReveal = {
        let r = HoverReveal(in: self) { [unowned self] in [back, copy] }
        r.pinned = { [unowned self] in copied }
        return r
    }()
    /// Where Copy puts it (another, in debugging).
    var pasteboard = NSPasteboard.general

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = TerminalPalette.current(for: $0).background.cgColor }
        header.wantsLayer = true

        prompt.lineBreakMode = .byTruncatingTail
        prompt.textColor = Theme.text
        outcome.lineBreakMode = .byTruncatingTail
        outcome.font = UIType.footnote
        outcome.textColor = Theme.secondaryText
        for (b, action) in [(back, #selector(backClicked)), (copy, #selector(copyClicked))] {
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
        keeper.keepScroll(of: scroll, x: true)
    }

    required init?(coder: NSCoder) { fatalError() }

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
        // A file's old version (§3.6) is no command: no prompt.
        let ran = o.source != nil
        prompt.attributedStringValue = NSAttributedString(string: (ran ? "$ " : "") + o.line, attributes: [
            .font: font.emphasized(bold: true), .foregroundColor: Theme.text])
        var words: [String] = []
        if let s = o.status { words.append(s == 0 ? "ok" : "exit \(s)") } else if o.ran != nil { words.append(o.ended == nil ? "running" : "ok") }
        if let took = BlockSummary.took(from: o.ran, to: o.ended) { words.append("took " + took) }
        if let at = o.ended ?? o.ran { words.append(Age.ago(at)) }
        if o.plain, ran { words.append("from the screen") }
        outcome.stringValue = words.joined(separator: " · ")
        outcome.textColor = (o.status ?? 0) == 0 ? Theme.secondaryText : Theme.statusError
        // A notebook's cell has no terminal to go back to.
        back.isHidden = o.source == nil || o.command == nil
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
        keeper.restoreScroll(of: scroll, x: true)
    }

    @objc private func backClicked() {
        guard let o = shown, let s = o.source, let c = o.command else { return }
        delegate?.output(self, showSource: s, command: c)
    }

    @objc private func copyClicked() {
        guard let o = shown else { return }
        pasteboard.clearContents()
        pasteboard.setString((o.source != nil ? "$ " : "") + o.line + "\n" + plainText + (plainText.hasSuffix("\n") ? "" : "\n"), forType: .string)
        copied = true
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copied = false; self?.needsLayout = true }
    }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("Copy Command and Output", symbol: "doc.on.doc") { [weak self] in self?.copyClicked() }]
            + (back.isHidden ? [] : [ClosureMenuItem("Show in Terminal", symbol: "arrow.uturn.backward") { [weak self] in self?.backClicked() }])
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - Self.headerHeight, width: w, height: Self.headerHeight)
        finder.layout(in: findArea)
        // The command over how it went, at the left; at the right, the
        // buttons' glyphs, shown under the pointer (Dia's way); the copy's
        // check says it took.
        reveal.track(header.frame)
        back.title = ""
        copy.title = ""
        copy.symbolName = copied ? "checkmark" : "doc.on.doc"
        for b in [back, copy] { b.sizeToFit() }
        let by = ((Self.headerHeight - copy.frame.height) / 2).rounded()
        copy.frame = NSRect(x: w - 10 - copy.frame.width, y: by, width: copy.frame.width, height: copy.frame.height)
        back.frame = NSRect(x: copy.frame.minX - 4 - back.frame.width, y: by, width: back.frame.width, height: back.frame.height)
        let tw = max(0, (back.isHidden ? copy : back).frame.minX - 12 - 12)
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
        return "\(prompt.stringValue) [\(outcome.stringValue)] \(runs) runs\n" + plainText.prefix(400)
    }
}

extension OutputView: Printable {
    /// The command, how it ended, and what it printed, as text.
    func printOperation() -> NSPrintOperation? {
        TextPrint.operation(text.string, title: prompt.stringValue + "  (" + outcome.stringValue + ")", font: TextPrint.codeFont)
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

/// A terminal's colours in one appearance (§7.2), as the theme in use has
/// them (`Palette.terminal`): Ghostty is set up with them, and a command's
/// output, a notebook's cells drawn in them.
struct TerminalPalette {
    /// Each as `#rrggbb`, as Ghostty's config takes it.
    var backgroundHex: String
    var foregroundHex: String
    var cursorHex: String
    /// The character under a block cursor (nil: Ghostty's choice).
    var cursorTextHex: String?
    var selectionBackgroundHex: String
    var selectionForegroundHex: String
    /// All 256: the sixteen, then the extended palette.
    var colorsHex: [String]

    var background: NSColor
    var foreground: NSColor
    /// All 256, as a 256-colour terminal numbers them: the sixteen (black,
    /// red, green, yellow, blue, magenta, cyan, white, then bright), the
    /// 6×6×6 cube (16–231), the 24 greys (232–255).
    var colors: [NSColor]

    /// `ansi`: the sixteen; `extended`: the 240 after them (16–255), else xterm's.
    init(background: String, foreground: String, cursor: String, cursorText: String? = nil, selectionBackground: String,
         selectionForeground: String, ansi: [String], extended: [String] = TerminalPalette.xtermExtended) {
        precondition(ansi.count == 16 && extended.count == 240, "a terminal palette is 16 colours and 240 more")
        backgroundHex = background
        foregroundHex = foreground
        cursorHex = cursor
        cursorTextHex = cursorText
        selectionBackgroundHex = selectionBackground
        selectionForegroundHex = selectionForeground
        colorsHex = ansi + extended
        self.background = Self.hex(background)
        self.foreground = Self.hex(foreground)
        colors = colorsHex.map(Self.hex)
    }

    /// The sixteen.
    var ansi: ArraySlice<NSColor> { colors.prefix(16) }

    /// xterm's extended palette, as most terminals have it (Ghostty's own
    /// too): the 6×6×6 cube, each channel 0, 95, 135, 175, 215 or 255;
    /// then 24 greys from 8, 10 apart.
    static let xtermExtended: [String] = {
        let steps: [Int] = [0, 95, 135, 175, 215, 255]
        func hex(_ r: Int, _ g: Int, _ b: Int) -> String { String(format: "#%02x%02x%02x", r, g, b) }
        let cube: [String] = (0..<216).map { (i: Int) -> String in hex(steps[i / 36], steps[(i / 6) % 6], steps[i % 6]) }
        let greys: [String] = (0..<24).map { (i: Int) -> String in hex(8 + i * 10, 8 + i * 10, 8 + i * 10) }
        return cube + greys
    }()

    /// An extended palette made of a theme's own colours, as Ghostty's
    /// `palette-generate` makes one, so that programs' 256 colours sit in
    /// the theme: the cube's eight corners are the background, the six
    /// colours red to cyan of `ansi`, and the text — each step between
    /// them taken in CIELAB, evenly to the eye — and the greys run from
    /// the background to the text. `fromBackground` (Ghostty's
    /// "harmonious"): the cube and greys start at the background whatever
    /// it is; else, for a light background, they're turned round to go
    /// dark to light, as xterm's do.
    static func generated(background: String, foreground: String, ansi: [String], fromBackground: Bool = true) -> [String] {
        var corners = [background] + ansi[1...6] + [foreground]
        if !fromBackground, Tints.luminance(hex(background)) > Tints.luminance(hex(foreground)) { corners.swapAt(0, 7) }
        let lab = corners.map { Lab(hex($0)) }
        let steps: [Double] = (0..<6).map { Double($0) / 5 }
        var out: [String] = []
        for r in steps {
            let c0 = lab[0].mix(lab[1], r), c1 = lab[2].mix(lab[3], r), c2 = lab[4].mix(lab[5], r), c3 = lab[6].mix(lab[7], r)
            for g in steps {
                let c4 = c0.mix(c1, g), c5 = c2.mix(c3, g)
                for b in steps { out.append(c4.mix(c5, b).hex) }
            }
        }
        for i in 0..<24 { out.append(lab[0].mix(lab[7], Double(i + 1) / 25).hex) }
        return out
    }

    /// A colour in CIELAB (D65), for mixing evenly to the eye.
    private struct Lab {
        var l: Double, a: Double, b: Double

        init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }

        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? color
            func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let (r, g, b) = (linear(c.redComponent), linear(c.greenComponent), linear(c.blueComponent))
            let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
            let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
            let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
            l = 116 * f(y) - 16
            a = 500 * (f(x) - f(y))
            self.b = 200 * (f(y) - f(z))
        }

        func mix(_ o: Lab, _ t: Double) -> Lab { Lab(l: l + (o.l - l) * t, a: a + (o.a - a) * t, b: b + (o.b - b) * t) }

        /// As `#rrggbb`, clipped into sRGB.
        var hex: String {
            let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
            func finv(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27) }
            let x = finv(fx) * 0.95047, y = finv(fy), z = finv(fz) * 1.08883
            let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
            let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
            let bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
            func encode(_ v: Double) -> Int {
                let v = max(0, min(1, v))
                let s = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
                return Int((s * 255).rounded())
            }
            return String(format: "#%02x%02x%02x", encode(r), encode(g), encode(bl))
        }
    }

    static func current(for view: NSView) -> TerminalPalette {
        current(dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    static func current(dark: Bool) -> TerminalPalette {
        dark ? Palette.current.terminal.dark : Palette.current.terminal.light
    }

    /// As lines of Ghostty's config.
    var config: String {
        let cursor = ["cursor-color = \(cursorHex)"] + (cursorTextHex.map { ["cursor-text = \($0)"] } ?? [])
        return (["background = \(backgroundHex)", "foreground = \(foregroundHex)"] + cursor
            + ["selection-background = \(selectionBackgroundHex)", "selection-foreground = \(selectionForegroundHex)"]
            + colorsHex.enumerated().map { "palette = \($0.offset)=\($0.element)" }).joined(separator: "\n")
    }

    static func hex(_ s: String) -> NSColor {
        let v = Int(s.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// A 256-colour index: the sixteen, the 6×6×6 cube, the greys.
    func color(_ n: Int) -> NSColor { colors[max(0, min(n, colors.count - 1))] }
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
        let bold = font.emphasized(bold: true)
        let italic = font.emphasized(italic: true)
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

/// The output's text: the Find menu's actions (⌘F, ⌘G, ⌘E) go to the
/// tile's find pill, as an editor's do; a plain text view without a find
/// bar would only beep.
final class OutputFindTextView: NSTextView {
    override func performTextFinderAction(_ sender: Any?) {
        guard let host = enclosingOutput else { return super.performTextFinderAction(sender) }
        host.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)), enclosingOutput != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    private var enclosingOutput: OutputView? { enclosing(OutputView.self) }
}
