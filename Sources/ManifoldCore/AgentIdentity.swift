import Foundation

/// Who an agent is, to tell it from the others at work (§3.7): a name of
/// its own — a plant's or a bird's, stable for its life whatever it's
/// working on, as most agents share a worktree and their tasks drift — and
/// a colour, one of a few that stay apart for eyes that don't tell red from
/// green. Both are annotations (`agent.name`, `agent.color`, the palette's
/// slot) — not its title, which stays what its program says it's doing
/// (Claude Code's summary of what it was asked, or done). The host gives
/// both, once, the first time it hears from the agent.
public enum AgentIdentity {
    /// The annotation that holds an agent's colour: its slot in the palette.
    public static let colorKey = "agent.color"
    /// The annotation that holds its name.
    public static let nameKey = "agent.name"

    /// How many colours there are (the app has them: Paul Tol's bright
    /// palette, less its grey).
    public static let colors = 6

    /// Names given, short and unlike one another, few sharing an initial.
    public static let names = [
        "Fern", "Juniper", "Wren", "Basil", "Heron", "Clover", "Sorrel", "Linden", "Kestrel", "Maple",
        "Tansy", "Robin", "Aster", "Moss", "Yarrow", "Olive", "Pine", "Hazel", "Ivy", "Lark",
        "Birch", "Dahlia", "Elm", "Finch", "Quill", "Rowan", "Sage", "Thistle", "Umber", "Vetch",
        "Willow", "Zinnia", "Cedar", "Nettle", "Oriole", "Gorse",
    ]

    /// What the agents at work already are: their names and colours.
    public struct Taken {
        public var names: Set<String>
        public var colors: [Int]

        public init(names: Set<String> = [], colors: [Int] = []) {
            self.names = names
            self.colors = colors
        }
    }

    /// A name and a colour for an agent new to the host, unlike those at
    /// work: a name none has (and, while there are some, an initial none
    /// starts with), the colour fewest have — `seed` choosing among equals,
    /// so two hosts don't hand out the same ones in the same order.
    public static func choose(taken: Taken, seed: UInt64) -> (name: String, color: Int) {
        let initials = Set(taken.names.compactMap { $0.first.map { Character($0.uppercased()) } })
        let free = names.filter { !taken.names.contains($0) }
        let fresh = free.filter { !initials.contains($0.first!) }
        let pool = !fresh.isEmpty ? fresh : !free.isEmpty ? free : names.map { "\($0) \(taken.names.count + 1)" }
        let name = pool[Int(seed % UInt64(pool.count))]
        var counts = [Int](repeating: 0, count: colors)
        for c in taken.colors where counts.indices.contains(c) { counts[c] += 1 }
        let least = counts.min() ?? 0
        let open = counts.indices.filter { counts[$0] == least }
        let color = open[Int((seed / 7) % UInt64(open.count))]
        return (name, color)
    }

    /// An agent block's name, if it has been given one.
    public static func name(of block: Block) -> String? {
        block.annotations?[nameKey].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// An agent block's colour slot, if it has been given one.
    public static func color(of block: Block) -> Int? {
        block.annotations?[colorKey].flatMap(Int.init).flatMap { (0..<colors).contains($0) ? $0 : nil }
    }
}
