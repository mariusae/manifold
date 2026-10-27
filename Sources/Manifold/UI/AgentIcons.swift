import AppKit

/// Coding agents' own marks (Claude Code's, Codex's, Gemini CLI's…), from
/// Resources/AgentIcons, by the command that starts each: shown wherever
/// the block an agent works in shows its symbol, as `agent:<command>`
/// (`Theme.symbol`). Each is in one color (`currentColor`), a template
/// tinted as symbols are — their tiles and gradients don't read at a
/// bar's size: Claude's, Amp's and Pi's as they are in one color, Codex's
/// mark without its tile, Gemini CLI's tile with its chevron cut out, Meta
/// AI's ring (Muse) in one. A mark that keeps colors is drawn in them.
/// Lobe Icons' (MIT), Pi's from pi.dev; the marks are their makers'
/// trademarks.
enum AgentIcons {
    static let prefix = "agent:"
    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("AgentIcons")
    private static var known: [String: Bool] = [:]

    /// Whether there's a mark for an agent's command.
    static func has(_ command: String) -> Bool {
        if let k = known[command] { return k }
        let k = folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(command + ".svg").path) } ?? false
        known[command] = k
        return k
    }

    /// The mark, in a square a symbol of `size` points would fill.
    static func image(_ command: String, size: CGFloat) -> NSImage? {
        guard has(command), let url = folder?.appendingPathComponent(command + ".svg"),
              let svg = NSImage(contentsOf: url), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let side = (size * 1.15).rounded()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            svg.draw(in: r)
            return true
        }
        image.isTemplate = text.contains("currentColor")
        return image
    }
}
