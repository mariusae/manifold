import AppKit
import ManifoldCore

/// How an agent looks wherever it's shown (`AgentIdentity`): its colour —
/// Paul Tol's bright palette, less its grey, chosen to stay apart for every
/// common kind of colour blindness, a little lighter on a dark ground — and
/// its name's initial, on that colour, as its face. Never the colour
/// alone: its name is always beside it.
enum AgentLook {
    /// Blue, cyan, green, yellow, red, purple (light; dark).
    static let palette: [NSColor] = [
        dynamic(0x4477AA, 0x6A9BD8),
        dynamic(0x66CCEE, 0x66CCEE),
        dynamic(0x228833, 0x44AA55),
        dynamic(0xCCBB44, 0xDDCC55),
        dynamic(0xEE6677, 0xEE7788),
        dynamic(0xAA3377, 0xCC5599),
    ]

    /// The colour names, for a tooltip or a menu.
    static let colorNames = ["blue", "cyan", "green", "yellow", "red", "purple"]

    private static func dynamic(_ light: Int, _ dark: Int) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        // Eased to the theme's inks (Paul Tol's hues and lightnesses kept).
        return .identity(NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) })
    }

    /// An agent's colour, if it's an agent given one.
    static func color(of block: Block?) -> NSColor? {
        guard let block, let slot = AgentIdentity.color(of: block) else { return nil }
        return palette[slot]
    }

    /// Ink that reads on an agent's colour: white, but dark on the light ones (cyan, yellow).
    static func ink(on block: Block?) -> NSColor {
        guard let block, let slot = AgentIdentity.color(of: block) else { return .white }
        return slot == 1 || slot == 3 ? NSColor(white: 0.12, alpha: 1) : .white
    }

    /// Its name (`AgentIdentity`), else its title.
    static func name(of block: Block) -> String { AgentIdentity.name(of: block) ?? block.displayTitle }

    /// The first letter of its name: what its face shows.
    static func initial(of block: Block) -> String {
        String(name(of: block).first(where: \.isLetter) ?? "A").uppercased()
    }

    /// The face's letter: rounded and heavy, to stay whole at a sidebar's
    /// size (a thin bold one broke up at 13 points).
    static func initialFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// Its face: a disc of its colour, its initial on it — centred by the
    /// capital's height, not the line's (which sat it low).
    static func drawFace(of block: Block, in r: NSRect) {
        guard let color = color(of: block) else { return }
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        let font = initialFont((r.height * 0.6).rounded())
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink(on: block)]
        let s = initial(of: block) as NSString
        let width = s.size(withAttributes: a).width
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        // The baseline under the capital's middle at the disc's.
        let baseline = flipped ? r.midY + font.capHeight / 2 : r.midY - font.capHeight / 2
        s.draw(at: NSPoint(x: r.midX - width / 2, y: flipped ? baseline - font.ascender : baseline + font.descender), withAttributes: a)
    }

    /// What it is and what it's doing, in a line, to tell it from another
    /// at a glance: its kind, its task (the title its program gives its
    /// terminal, Claude Code's summary of what it was asked), how it stands.
    static func description(of b: Block) -> String {
        var parts: [String] = []
        if let a = b.agent { parts.append(a.name) }
        // Its title (Claude Code's summary of its task, its spinner and mark before it: the words alone).
        let words = b.displayTitle.drop { !$0.isLetter && !$0.isNumber }
        if !words.isEmpty, String(words) != name(of: b), String(words) != b.agent?.name { parts.append(String(words)) }
        switch b.statusState {
        case .working: parts.append("working")
        case .blocked: parts.append("waiting on you")
        case .error: parts.append("stopped with an error")
        case .idle, .done: parts.append(b.terminal?.dormantSince != nil ? "dormant" : "idle")
        }
        return parts.joined(separator: " · ")
    }

    /// Its face as an image, for a pill or a menu.
    static func face(of block: Block, size: CGFloat) -> NSImage? {
        guard color(of: block) != nil else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            drawFace(of: block, in: r)
            return true
        }
    }
}

extension AgentLook {
    /// A block by its id, as the window has it: given by it at its start,
    /// so wherever an author is drawn its agent's name and colour are its
    /// block's as they are now.
    nonisolated(unsafe) static var block: ((BlockID) -> Block?)?
}

extension ThreadAuthor {
    /// Its name as it reads now: an agent's its name (`AgentIdentity`), else
    /// its block's title, else the name it wrote with.
    var shownName: String {
        switch self {
        case .you: "You"
        case let .agent(b, name, _): AgentLook.block?(b).map(AgentLook.name(of:)) ?? name
        case .manifold: "Manifold"
        }
    }

    /// Its agent's block, as it is now.
    var agentNow: Block? { agentBlock.flatMap { AgentLook.block?($0) } }
}

/// Which agents you last talked to — asked in a thread, or Return pressed
/// in its terminal — kept on this Mac: a new thread's lead is the one you
/// talked to last.
enum AgentRecency {
    private static let key = "AgentRecency"

    private static var stored: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Talked to now.
    static func talked(to block: BlockID) {
        var d = stored
        d[block.description] = Date().timeIntervalSince1970
        // The last forty, no more.
        if d.count > 40 { for (k, _) in d.sorted(by: { $0.value < $1.value }).prefix(d.count - 40) { d[k] = nil } }
        stored = d
    }

    /// When it was last talked to (0: never, here).
    static func when(_ block: BlockID) -> Double { stored[block.description] ?? 0 }
}

extension AgentLook {
    /// An agent pointed at somewhere else (its face in a thread, its row,
    /// its name in a menu): its tile ringed in its colour, where it's on
    /// screen, while the pointer stays — so you see which one it is without
    /// going there. Nil: the ring gone. Given by the window.
    nonisolated(unsafe) static var spotlight: ((BlockID?) -> Void)?
    /// An agent's card beside a rect (window terms) — what it is, and what
    /// it's doing — and put away (nil).
    nonisolated(unsafe) static var card: ((BlockID, NSRect, NSWindow) -> Void)?
    nonisolated(unsafe) static var hideCard: (() -> Void)?
}

/// A menu of agents that rings each one's tile as it's highlighted.
final class AgentMenuSpotlight: NSObject, NSMenuDelegate {
    static let shared = AgentMenuSpotlight()
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        AgentLook.spotlight?(item?.representedObject as? BlockID)
    }
    func menuDidClose(_ menu: NSMenu) { AgentLook.spotlight?(nil) }
}
