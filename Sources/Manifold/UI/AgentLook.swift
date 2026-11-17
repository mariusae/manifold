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
        return NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
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

    /// The first letter of its name: what its face shows.
    static func initial(of block: Block) -> String {
        String(block.displayTitle.first(where: \.isLetter) ?? "A").uppercased()
    }

    /// Its face: a disc of its colour, its initial on it.
    static func drawFace(of block: Block, in r: NSRect) {
        guard let color = color(of: block) else { return }
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r.height * 0.52, weight: .bold), .foregroundColor: ink(on: block)]
        let s = initial(of: block) as NSString
        let size = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: a)
    }

    /// What it is and what it's doing, in a line, to tell it from another
    /// at a glance: its kind, its task (the title its program gives its
    /// terminal, Claude Code's summary of what it was asked), how it stands.
    static func description(of b: Block) -> String {
        var parts: [String] = []
        if let a = b.agent { parts.append(a.name) }
        if let t = b.terminal?.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != b.displayTitle {
            // Claude Code's spinner and mark before its summary: the words alone.
            let words = t.drop { !$0.isLetter && !$0.isNumber }
            if !words.isEmpty { parts.append(String(words)) }
        }
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
    /// Its name as it reads now: an agent's its block's title (its name,
    /// renamed or not), else the name it wrote with.
    var shownName: String {
        switch self {
        case .you: "You"
        case let .agent(b, name, _): AgentLook.block?(b)?.displayTitle ?? name
        case .manifold: "Manifold"
        }
    }

    /// Its agent's block, as it is now.
    var agentNow: Block? { agentBlock.flatMap { AgentLook.block?($0) } }
}
