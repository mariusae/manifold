import Foundation

/// Where a shell's commands show on its screen (§3.8): each command's
/// line, found from its text as the shell said it (OSC 7502, control
/// characters blanked: a newline in it a space).
public enum CommandLines {
    /// Whether a line (trimmed) is the one a command was typed on: the
    /// prompt, then the command — with nothing after it, or a gap and a
    /// prompt's right side; or, the command longer than the line shows
    /// (continued on lines of its own), the start of it: a long one's
    /// first 16 characters and more, or a command over several lines (a
    /// newline in it) its first line, 8 characters and more, where its
    /// text goes on after a space.
    public static func lineShows(_ command: String, in t: String) -> Bool {
        lineShows(command, head: Array(command.prefix(8).utf8), in: t)
    }

    /// As `lineShows`, given the command's first 8 characters' bytes: a
    /// line that shows the command in any of those ways has them in it, so
    /// one without them (most) is passed over with memmem, not looked
    /// through a character at a time.
    static func lineShows(_ command: String, head: [UInt8], in t: String) -> Bool {
        guard !t.isEmpty, !command.isEmpty else { return false }
        var t = t
        let has = t.withUTF8 { hay in
            head.withUnsafeBufferPointer { needle in
                guard let h = hay.baseAddress, let n = needle.baseAddress, hay.count >= needle.count else { return false }
                return memmem(h, hay.count, n, needle.count) != nil
            }
        }
        guard has else { return false }
        if let r = t.range(of: command) {
            let rest = t[r.upperBound...]
            if rest.isEmpty || rest.hasPrefix("  ") { return true }
        }
        if command.count > 16, t.count >= 16 {
            let tail = t.suffix(min(t.count, command.count - 1))
            for k in stride(from: tail.count, through: 16, by: -1) where command.hasPrefix(tail.suffix(k)) { return true }
        }
        // The first line of several: what follows a space (the prompt's
        // end) to the line's end begins the command, and the command goes
        // on there with a space (the newline).
        var i = t.startIndex
        while let space = t[i...].firstIndex(of: " ") {
            let start = t.index(after: space)
            let head = t[start...]
            if head.count >= 8, command.count > head.count, command.hasPrefix(head),
               command[command.index(command.startIndex, offsetBy: head.count)] == " " { return true }
            i = start
        }
        if t.count >= 8, command.count > t.count, command.hasPrefix(t), command[command.index(command.startIndex, offsetBy: t.count)] == " " { return true }
        return false
    }

    /// Each command's line, by their indices: found from the newest up,
    /// each above the one after it — so commands gone from the top
    /// (scrolled off, the screen cleared) or not to be found leave the
    /// rest found. After `giveUp` missed in a row the older ones are taken
    /// to be gone, and the search stops after `budget` lines looked at.
    public static func locate(_ commands: [String], in lines: [String], giveUp: Int = 8, budget: Int = 400_000) -> [Int: Int] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let heads = commands.map { Array($0.prefix(8).utf8) }
        var found: [Int: Int] = [:]
        var bound = trimmed.count
        var misses = 0, looked = 0
        for k in commands.indices.reversed() {
            var l = bound - 1
            while l >= 0, looked < budget, !lineShows(commands[k], head: heads[k], in: trimmed[l]) {
                l -= 1
                looked += 1
            }
            if l >= 0, looked < budget {
                found[k] = l
                bound = l
                misses = 0
            } else {
                misses += 1
                if misses >= giveUp || looked >= budget { break }
            }
        }
        return found
    }
}
