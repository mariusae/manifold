import Foundation

/// Links written in a text (§3.6): `[[title]]` as a wiki has them, and
/// Markdown's `[words](target)` to a file (not to the web, not within the
/// page). Found by the host as the text changes, so the graph knows a
/// link the moment it is written, not when it is followed.
public struct Mention: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// `[[title]]`: a block by its title, or a file named so beside this one.
        case title(String)
        /// A path, as written: relative to the file's folder unless absolute.
        case path(String)
    }
    public var target: Target
    /// The words of the link.
    public var text: String

    public static func find(in text: String) -> [Mention] {
        var out: [Mention] = []
        var seen: Set<String> = []
        func add(_ m: Mention) {
            let key = "\(m.target)"
            if seen.insert(key).inserted { out.append(m) }
        }
        let s = text
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "[", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "[" {
                // [[title]]
                let start = s.index(i, offsetBy: 2)
                if let close = s[start...].range(of: "]]") {
                    let title = String(s[start..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty, !title.contains("\n") { add(Mention(target: .title(title.components(separatedBy: "|").first!.trimmingCharacters(in: .whitespaces)), text: title)) }
                    i = close.upperBound
                    continue
                }
            } else if c == "[", let closeBracket = s[i...].firstIndex(of: "]"),
                      s.index(after: closeBracket) < s.endIndex, s[s.index(after: closeBracket)] == "(",
                      let closeParen = s[closeBracket...].firstIndex(of: ")") {
                // [words](target)
                let words = String(s[s.index(after: i)..<closeBracket])
                var target = String(s[s.index(closeBracket, offsetBy: 2)..<closeParen])
                if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
                if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
                if !target.isEmpty, !target.contains("://"), !target.hasPrefix("mailto:"), !words.contains("\n") {
                    add(Mention(target: .path(target.removingPercentEncoding ?? target), text: words))
                }
                i = s.index(after: closeParen)
                continue
            }
            i = s.index(after: i)
        }
        return out
    }

    /// A path target resolved against the mentioning file's folder.
    public static func resolve(_ target: String, from path: String?) -> String? {
        if target.hasPrefix("/") { return target }
        if target.hasPrefix("~") { return target.expandingTildeInPath }
        guard let path else { return nil }
        return URL(fileURLWithPath: path.deletingLastPathComponent).appendingPathComponent(target).standardizedFileURL.path
    }
}

extension BlockKind {
    /// The kind of block a file opens as, by its name.
    public static func forFile(_ path: String) -> BlockKind {
        switch path.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg", "icns": .image
        case "pdf": .pdf
        default: .text
        }
    }
}
