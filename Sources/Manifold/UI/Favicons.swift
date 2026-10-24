import AppKit
import ManifoldCore

/// Sites' icons, by origin (scheme, host, port): taken from a page as it
/// loads — the icon it declares, else its /favicon.ico, fetched by the page
/// itself, so one through another host's localhost comes too — and kept
/// on disk, so a page's block shows its site's icon (in the sidebar, on its
/// bar) when it isn't open.
enum Favicons {
    private static var images: [String: NSImage] = [:]
    /// Origins looked for on disk and not there: not looked for again.
    private static var missing: Set<String> = []
    private static let folder = Paths.directory.appendingPathComponent("favicons")

    /// A page's site, as the key of its icon: "https://example.com:443".
    static func origin(of page: String?) -> String? {
        guard var page, !page.isEmpty else { return nil }
        if !page.contains("://") { page = "http://" + page }
        guard let u = URLComponents(string: page), let scheme = u.scheme, ["http", "https"].contains(scheme), let host = u.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host.lowercased())" + (u.port.map { ":\($0)" } ?? "")
    }

    /// The icon of a page's site, if one has been seen.
    static func image(forPage page: String?) -> NSImage? {
        guard let key = origin(of: page) else { return nil }
        if let i = images[key] { return i }
        guard !missing.contains(key) else { return nil }
        if let data = try? Data(contentsOf: file(key)), let i = NSImage(data: data) {
            images[key] = i
            return i
        }
        missing.insert(key)
        return nil
    }

    /// An icon taken from a page (as a data: URL): kept, and said.
    static func take(_ dataURL: String, forPage page: String?) {
        guard let key = origin(of: page), let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:") else { return }
        let header = dataURL[..<comma], body = String(dataURL[dataURL.index(after: comma)...])
        guard header.contains(";base64"), let data = Data(base64Encoded: body), let image = NSImage(data: data),
              image.size.width > 0 else { return }
        image.isTemplate = false
        // Drawn small: kept as a PNG at the size it's shown, twice over.
        let side: CGFloat = 32
        let png = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            image.draw(in: r)
            return true
        }
        guard let tiff = png.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let out = rep.representation(using: .png, properties: [:]) else { return }
        if let old = images[key], old.tiffRepresentation == png.tiffRepresentation { return }
        images[key] = png
        missing.remove(key)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? out.write(to: file(key))
        NotificationCenter.default.post(name: .manifoldFaviconsChanged, object: nil)
    }

    private static func file(_ key: String) -> URL {
        let name = key.replacingOccurrences(of: "://", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(name + ".png")
    }

    /// What a page runs to hand over its icon: its declared icon (an
    /// apple-touch one last), else /favicon.ico, as a data: URL; nil if none.
    static let script = """
        const links = [...document.querySelectorAll('link[rel]')].filter(l => /(^|\\s)(icon|shortcut icon)(\\s|$)/i.test(l.rel) || /apple-touch-icon/i.test(l.rel));
        links.sort((a, b) => (/apple/i.test(a.rel) ? 1 : 0) - (/apple/i.test(b.rel) ? 1 : 0));
        const href = links.length ? links[0].href : location.origin + '/favicon.ico';
        try {
            const r = await fetch(href);
            if (!r.ok) return null;
            const blob = await r.blob();
            if (!blob.size || blob.size > 1000000) return null;
            return await new Promise(done => { const f = new FileReader(); f.onload = () => done(f.result); f.onerror = () => done(null); f.readAsDataURL(blob); });
        } catch (e) { return null; }
        """
}

extension Notification.Name {
    /// A site's icon arrived.
    static let manifoldFaviconsChanged = Notification.Name("ManifoldFaviconsChanged")
}
