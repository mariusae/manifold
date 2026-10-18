import Foundation

/// Path pieces, as NSString has them, for every platform.
public extension String {
    var lastPathComponent: String {
        let trimmed = hasSuffix("/") && count > 1 ? String(dropLast()) : self
        if let i = trimmed.lastIndex(of: "/") { return String(trimmed[trimmed.index(after: i)...]) }
        return trimmed
    }

    var deletingLastPathComponent: String {
        let trimmed = hasSuffix("/") && count > 1 ? String(dropLast()) : self
        guard let i = trimmed.lastIndex(of: "/") else { return "" }
        if i == trimmed.startIndex { return "/" }
        return String(trimmed[..<i])
    }

    var pathExtension: String {
        let name = lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    func appendingPathComponent(_ component: String) -> String {
        if isEmpty { return component }
        if hasSuffix("/") { return self + component }
        return self + "/" + component
    }

    var expandingTildeInPath: String {
        guard hasPrefix("~") else { return self }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == "~" { return home }
        if hasPrefix("~/") { return home + dropFirst(1) }
        return self
    }

    /// Ordered as the Finder orders names: by number where numbers differ.
    func standardCompare(_ other: String) -> Bool {
        compare(other, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending
    }
}
