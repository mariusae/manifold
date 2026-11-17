import AppKit
import ManifoldCore

/// A part of a note the app may draw a view of its own in place of: a
/// row of code (a query, shown as what it finds), or a line that is only
/// pictures, shown as the pictures — or a line with pictures among its
/// words, shown under them. The view hands the app these (`OutlinerView.
/// blockView`); none, and the row is shown as it is written.
public struct OutlinerBlock: Hashable {
    /// What follows a code block's opening fence (`swift`, `query`); for
    /// pictures, `OutlinerBlock.picture`.
    public var info: String
    /// The code; for pictures, their Markdown, as written: `![alt](path)`,
    /// perhaps with its size after it, a space between several.
    public var source: String
    /// Writes other words in the block's place: how a picture, resized,
    /// has its new size written beside it. Only a line of pictures is
    /// rewritten so.
    public var rewrite: ((String) -> Void)?
    /// How wide the room it is drawn in is.
    public var room: CGFloat = 0
    /// Tells the view that what stands in the block's place has changed its
    /// size, and the note is to be laid out around it again.
    public var resized: (() -> Void)?

    /// The `info` of a line of pictures.
    public static let picture = "picture"

    public init(info: String, source: String, rewrite: ((String) -> Void)? = nil) {
        self.info = info
        self.source = source
        self.rewrite = rewrite
    }

    public static func == (a: OutlinerBlock, b: OutlinerBlock) -> Bool { a.info == b.info && a.source == b.source }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(info)
        hasher.combine(source)
    }
}

/// A picture as a note writes it: `![alt](address)`, and — when it has
/// been given a size — a comment after it that says so:
/// `<!-- {"width":425,"height":270} -->`.
public struct OutlinerPicture: Hashable {
    public var alt: String
    /// Where it is: a path beside the note, an address on the web, or a block (`manifold:…`).
    public var address: String
    public var width: CGFloat?
    public var height: CGFloat?

    public init(alt: String = "", address: String, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.alt = alt
        self.address = address
        self.width = width
        self.height = height
    }

    private static let pattern = try? NSRegularExpression(pattern: #"^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*(?:<!--\s*(\{[^>]*\})\s*-->)?\s*$"#)

    /// Reads a line that is only a picture; nil for any other line.
    public init?(line: String) {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.pattern?.firstMatch(in: line, range: whole) else { return nil }
        let part = { (index: Int) -> String? in match.range(at: index).location == NSNotFound ? nil : (line as NSString).substring(with: match.range(at: index)) }
        guard let address = part(2), !address.isEmpty else { return nil }
        alt = part(1) ?? ""
        self.address = address
        if let size = part(3), let read = try? JSONSerialization.jsonObject(with: Data(size.utf8)) as? [String: Any] {
            width = (read["width"] as? NSNumber).map { CGFloat(truncating: $0) }
            height = (read["height"] as? NSNumber).map { CGFloat(truncating: $0) }
        }
    }

    private static let each = try? NSRegularExpression(pattern: #"\s*!\[([^\]]*)\]\(([^)\s]+)\)[ \t]*(?:<!--\s*(\{[^>]*\})\s*-->)?\s*"#)

    /// Reads a line that is only pictures — one, or several with spaces
    /// between them — in the order written; nil for any other line.
    public static func all(line: String) -> [OutlinerPicture]? {
        guard let each else { return nil }
        let text = line as NSString
        var found: [OutlinerPicture] = []
        var at = 0
        while at < text.length {
            guard let match = each.firstMatch(in: line, options: .anchored, range: NSRange(location: at, length: text.length - at)), match.range.length > 0,
                  let picture = OutlinerPicture(line: text.substring(with: match.range))
            else { return nil }
            found.append(picture)
            at = NSMaxRange(match.range)
        }
        return found.isEmpty ? nil : found
    }

    /// The pictures written among a line's words, each with where it is written.
    public static func among(line: String) -> [(picture: OutlinerPicture, range: NSRange)] {
        guard let each else { return [] }
        let text = line as NSString
        return each.matches(in: line, range: NSRange(location: 0, length: text.length)).compactMap { match in
            guard match.range.length > 0, let picture = OutlinerPicture(line: text.substring(with: match.range)) else { return nil }
            let written = text.substring(with: match.range)
            let lead = written.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let trail = written.reversed().prefix { $0 == " " || $0 == "\t" }.count
            return (picture, NSRange(location: match.range.location + lead, length: max(match.range.length - lead - trail, 0)))
        }
    }

    /// The line that writes it.
    public var line: String {
        guard let width else { return "![\(alt)](\(address))" }
        let size = height.map { #"{"width":\#(Int(width.rounded())),"height":\#(Int($0.rounded()))}"# } ?? #"{"width":\#(Int(width.rounded()))}"#
        return "![\(alt)](\(address)) <!-- \(size) -->"
    }
}

/// One of the app's own views, standing in the text in place of a block.
final class OutlinerBlockHost {
    private(set) var view: NSView?
    private weak var text: NSView?

    init(in text: NSView) { self.text = text }

    /// Shows this, at a width. Says how tall it is.
    func show(_ content: NSView, width: CGFloat) -> CGFloat {
        if content !== view {
            view?.removeFromSuperview()
            view = content
            text?.addSubview(content)
        }
        content.setFrameSize(CGSize(width: width, height: content.frame.height))
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize.height
        let height = fitting > 0 ? fitting : content.frame.height
        content.setFrameSize(CGSize(width: width, height: height))
        return height
    }

    func move(to origin: CGPoint) { view?.setFrameOrigin(origin) }

    var bottom: CGFloat { view?.frame.maxY ?? 0 }

    func remove() {
        view?.removeFromSuperview()
        view = nil
    }
}
