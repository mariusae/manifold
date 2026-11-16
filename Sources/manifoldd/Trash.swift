import Foundation

/// The host's trash: what's thrown away put there, not removed — the
/// Finder's on a Mac, elsewhere the freedesktop one (~/.local/share/Trash,
/// each with its .trashinfo, as a file manager there puts it back from).
enum Trash {
    /// `path` moved to the trash; what went wrong, if anything.
    static func put(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) || (try? fm.attributesOfItem(atPath: path)) != nil else {
            return "“\((path as NSString).lastPathComponent)” isn't there"
        }
        #if os(macOS)
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
        #else
        let env = ProcessInfo.processInfo.environment
        let data = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.local/share")
        let trash = data + "/Trash", files = trash + "/files", info = trash + "/info"
        do {
            try fm.createDirectory(atPath: files, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(atPath: info, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // A name of its own there: "name", else "name.2", "name.3"…,
            // its .trashinfo taken first (O_EXCL) so two can't share it.
            let name = (path as NSString).lastPathComponent
            var taken = name, n = 2
            while true {
                let fd = Foundation.open(info + "/" + taken + ".trashinfo", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                if fd >= 0 { Foundation.close(fd); break }
                guard errno == EEXIST, n < 10_000 else { return "couldn't write in \(info)" }
                taken = name + ".\(n)"
                n += 1
            }
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate])
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            try "[Trash Info]\nPath=\(encoded)\nDeletionDate=\(stamp)\n".write(toFile: info + "/" + taken + ".trashinfo", atomically: false, encoding: .utf8)
            do {
                try fm.moveItem(atPath: path, toPath: files + "/" + taken)
            } catch {
                try? fm.removeItem(atPath: info + "/" + taken + ".trashinfo")
                throw error
            }
            return nil
        } catch {
            return error.localizedDescription
        }
        #endif
    }
}
