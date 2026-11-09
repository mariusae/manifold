import AppKit
import ManifoldCore

/// An image on a pasteboard (pasted, dropped, from an iPhone), as the
/// editor and the outline take one.
enum PasteboardImages {
    /// The kinds of image it can hold.
    static let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .jpeg, .heic]

    /// Whether a paste is of the image a pasteboard holds rather than its
    /// text: there's no text, or files; or the text only says where the
    /// image is from (its address, its file's name — as a browser's Copy
    /// Image gives) or is listed after it (the source would rather the
    /// image were taken).
    static func preferred(on pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        guard let image = types.firstIndex(where: Self.types.contains) else { return types.contains(.fileURL) }
        guard let s = pb.string(forType: .string), let text = types.firstIndex(of: .string) else { return true }
        if types.contains(.fileURL) || TextLinks.isAddress(s) || image < text { return true }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(where: \.isWhitespace) && BlockKind.forFile(t) == .image
    }

    /// The image a pasteboard holds, as bytes to keep: a file's as it is
    /// (a photo stays a JPEG), else PNG.
    static func images(on pb: NSPasteboard) -> [(Data, String)] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { BlockKind.forFile($0.path) == .image }
            guard images.count == urls.count else { return [] }
            return images.compactMap { u in (try? Data(contentsOf: u)).map { ($0, u.pathExtension.lowercased()) } }
        }
        if let png = pb.data(forType: .png) { return [(png, "png")] }
        if let jpeg = pb.data(forType: .jpeg) { return [(jpeg, "jpeg")] }
        if let heic = pb.data(forType: .heic) { return [(heic, "heic")] }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return [(png, "png")]
        }
        return []
    }
}
