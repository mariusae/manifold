import AppKit
import ManifoldCore

// MARK: - Pictures in an outline (Prism's)

/// A note's pictures, as the outline lens shows them, Prism's way: the
/// whole `![…](…)` (and the size noted after it) hidden, one thing to the
/// caret, the picture drawn under its line's words — in place of them on a
/// line with nothing else. A grip in its corner, while the pointer is over
/// it, makes it larger or smaller: the width it's given written after it,
/// `<!-- {"width":320} -->`, as Prism's editor reads one, so it's the
/// note's (every Mac's, the Markdown view's too); a double click on the
/// grip takes that away, the picture its own size again.
extension NSAttributedString.Key {
    /// On a picture's first character: the picture, as a `NotePicture`.
    static let notePicture = NSAttributedString.Key("ManifoldNotePicture")
}

/// A picture in the text, and the size it's drawn at before fitting the
/// column: the note's, or its own (no taller than `tallest`, given none).
final class NotePicture: NSObject {
    let reference: ImageReference
    let image: NSImage
    /// Changed while its grip is dragged; the note's again when it's let go.
    var size: CGSize

    init(reference: ImageReference, image: NSImage) {
        self.reference = reference
        self.image = image
        let natural = image.size
        if natural.width <= 0 || natural.height <= 0 {
            size = CGSize(width: 80, height: 80)
        } else {
            switch (reference.width, reference.height) {
            case let (w?, h?): size = CGSize(width: w, height: h)
            case let (w?, nil): size = CGSize(width: w, height: (w * natural.height / natural.width).rounded())
            case let (nil, h?): size = CGSize(width: (h * natural.width / natural.height).rounded(), height: h)
            case (nil, nil):
                let scale = min(1, Self.tallest / natural.height)
                size = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
            }
        }
    }

    /// A picture given no size: no taller than this (a phone's screenshot
    /// doesn't take a tile's height); its grip makes it larger.
    static let tallest: CGFloat = 420
    /// The narrowest it's made by its grip.
    static let narrowest: CGFloat = 60
    /// Room above and below a picture.
    static let margin: CGFloat = 4

    /// Its size in a column so wide: never wider, never stretched.
    func fitted(to width: CGFloat) -> CGSize {
        guard size.width > width, width > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        return CGSize(width: width.rounded(), height: (size.height * width / size.width).rounded())
    }

    /// The Markdown that shows it, at a width (nil: its own size).
    func markdown(width: CGFloat?) -> String {
        "![\(reference.alt)](\(reference.source))" + (width.map { "<!-- {\"width\":\(Int($0.rounded()))} -->" } ?? "")
    }
}

/// Where the pictures on a line go.
enum NotePictureLine {
    /// The pictures on a line, in order, at the size they're drawn.
    static func pictures(in storage: NSTextStorage, characters: NSRange, container: NSTextContainer) -> [(picture: NotePicture, size: CGSize, location: Int)] {
        guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return [] }
        var found: [(NotePicture, CGSize, Int)] = []
        storage.enumerateAttribute(.notePicture, in: characters) { value, range, _ in
            guard let picture = value as? NotePicture else { return }
            let indent = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            found.append((picture, picture.fitted(to: container.size.width - indent - 2 * container.lineFragmentPadding - 4), range.location))
        }
        return found
    }

    /// Whether a line shows anything but pictures and space.
    static func hasText(_ storage: NSTextStorage, _ characters: NSRange) -> Bool {
        let text = storage.string as NSString
        var shown = false
        storage.enumerateAttribute(.noteHidden, in: characters) { value, range, stop in
            guard value == nil else { return }
            let visible = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: NoteOutlineText.lineSeparator)))
            if !visible.isEmpty {
                shown = true
                stop.pointee = true
            }
        }
        return shown
    }

    static func height(of pictures: [(picture: NotePicture, size: CGSize, location: Int)]) -> CGFloat {
        pictures.reduce(0) { $0 + $1.size.height + 2 * NotePicture.margin }
    }

    /// Where, in the container, a line's pictures are drawn: stacked down
    /// from under its words (its used room, which is theirs) — from its
    /// top, on a line with nothing else shown.
    static func frames(in storage: NSTextStorage, characters: NSRange, container: NSTextContainer, used: NSRect,
                       indent: CGFloat) -> [(picture: NotePicture, frame: NSRect, location: Int)] {
        let pictures = pictures(in: storage, characters: characters, container: container)
        var y = hasText(storage, characters) ? used.maxY : used.minY
        return pictures.map { p in
            let frame = NSRect(x: indent, y: y + NotePicture.margin, width: p.size.width, height: p.size.height)
            y += p.size.height + 2 * NotePicture.margin
            return (p.picture, frame, p.location)
        }
    }
}

extension NoteOutlineLayoutManager {
    /// Each picture shown in some characters, where it's drawn in the view.
    func pictureFrames(in characters: NSRange, origin: NSPoint) -> [(picture: NotePicture, frame: NSRect, location: Int)] {
        guard let storage = textStorage, let container = textContainers.first, characters.length > 0,
              NSMaxRange(characters) <= storage.length else { return [] }
        var lines = Set<Int>()
        var found: [(NotePicture, NSRect, Int)] = []
        storage.enumerateAttribute(.notePicture, in: characters) { value, range, _ in
            guard value is NotePicture else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            var lineGlyphs = NSRange()
            _ = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            guard lines.insert(lineGlyphs.location).inserted else { return }
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let line = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            let indent = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            for p in NotePictureLine.frames(in: storage, characters: line, container: container, used: used, indent: indent) {
                found.append((p.picture, p.frame.offsetBy(dx: origin.x, dy: origin.y), p.location))
            }
        }
        return found
    }

    /// The picture at a point in the view, where it's drawn, and where its
    /// Markdown starts.
    func pictureFrame(at point: NSPoint, origin: NSPoint) -> (picture: NotePicture, frame: NSRect, location: Int)? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = glyphIndex(for: p, in: container)
        guard glyph < numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        guard fragment.contains(p) else { return nil }
        let line = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        return pictureFrames(in: line, origin: origin).first { $0.frame.contains(point) }
    }

    /// The baseline of the line a glyph is on, in the container: the foot
    /// of its used room (its words', pictures under them or not), less how
    /// far the type descends.
    func baseline(atGlyph glyph: Int, font: NSFont) -> CGFloat? {
        guard glyph < numberOfGlyphs else { return nil }
        return lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY + font.descender
    }

    /// Selected hidden markup — a picture's — isn't filled (a sliver by
    /// the picture); the picture is ringed instead.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        if let storage = textStorage, charRange.length > 0, NSMaxRange(charRange) <= storage.length {
            var effective = NSRange()
            if storage.attribute(.noteHidden, at: charRange.location, longestEffectiveRange: &effective, in: charRange) != nil,
               NSMaxRange(effective) >= NSMaxRange(charRange) { return }
        }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    /// Draws a row's pictures: clipped round, a hairline round each (a
    /// picture as light as the page reads as one), a ring round one
    /// selected, the grip on the one under the pointer.
    func drawPictures(in paragraph: NSRange, origin: NSPoint) {
        guard let view, paragraph.length > 0 else { return }
        let selection = view.selectedRange()
        for (picture, rect, location) in pictureFrames(in: paragraph, origin: origin) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            picture.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
            edge.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            edge.stroke()
            if selection.length > 0, NSLocationInRange(location, selection) {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
                ring.lineWidth = 2.5
                Theme.accent.setStroke()
                ring.stroke()
            }
            if view.hoveredPicture == location, view.isEditable { Self.drawPictureGrip(in: rect) }
        }
    }

    /// The grip in a picture's corner: three strokes on a dark rounded square.
    static func drawPictureGrip(in frame: NSRect) {
        let grip = NoteOutlineTextView.grip(in: frame)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        for inset in [4.0, 8.0, 12.0] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: grip.maxX - 3, y: grip.minY + inset))
            line.line(to: NSPoint(x: grip.minX + inset, y: grip.maxY - 3))
            line.lineWidth = 1.2
            line.stroke()
        }
    }
}

extension NoteHiddenGlyphs {
    /// A line holding pictures grows to hold them: below its words, or, on
    /// a line with nothing else shown, in place of them. Its used room
    /// stays its words' — the caret, a misspelling's dots, its handle are
    /// where they'd be without them.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let pictures = NotePictureLine.pictures(in: storage, characters: characters, container: textContainer)
        guard !pictures.isEmpty else { return false }
        let total = NotePictureLine.height(of: pictures)
        let used = lineFragmentUsedRect.pointee.height
        let extra = NotePictureLine.hasText(storage, characters) ? total : max(0, total - used)
        guard extra > 0 else { return false }
        lineFragmentRect.pointee.size.height += extra
        return true
    }
}

extension NoteOutlineTextView {
    static let gripSide: CGFloat = 18
    /// Over a grip: the corner's resize pointer.
    static let gripCursor = NSCursor.frameResize(position: .bottomRight, directions: .all)

    /// Where a picture's grip is, in its frame (its lower right).
    static func grip(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - gripSide - 4, y: frame.maxY - gripSide - 4, width: gripSide, height: gripSide)
    }

    var pictureLayout: NoteOutlineLayoutManager? { layoutManager as? NoteOutlineLayoutManager }

    /// Whether some characters hold a picture.
    static func hasPicture(_ storage: NSTextStorage, in range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        var found = false
        storage.enumerateAttribute(.notePicture, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The picture under the pointer noted, its grip shown.
    func hoverPicture(at point: NSPoint?) {
        let next = point.flatMap { pictureLayout?.pictureFrame(at: $0, origin: textContainerOrigin)?.location }
        guard next != hoveredPicture else { return }
        hoveredPicture = next
        needsDisplay = true
    }

    /// Whether a point is on the grip of the picture under the pointer.
    func onPictureGrip(_ point: NSPoint) -> Bool {
        guard isEditable, let hit = pictureLayout?.pictureFrame(at: point, origin: textContainerOrigin) else { return false }
        return Self.grip(in: hit.frame).insetBy(dx: -3, dy: -3).contains(point)
    }

    /// Follows the grip until the button comes up, sizing the picture as
    /// it goes, its width written into the note then; twice clicked, the
    /// width it was given taken away.
    func dragPictureGrip(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (picture, frame, location) = pictureLayout?.pictureFrame(at: point, origin: textContainerOrigin) else { return }
        if event.clickCount >= 2 { return setPictureWidth(nil, at: location) }
        let start = event.locationInWindow
        var width = frame.width
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            width = resizePicture(picture, at: location, from: frame, by: CGSize(width: next.locationInWindow.x - start.x, height: start.y - next.locationInWindow.y))
            if next.type == .leftMouseUp { break }
        }
        if abs(width - frame.width) >= 1 { setPictureWidth(width, at: location) }
        hoverPicture(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    /// A picture shown at a size while its grip is dragged: no narrower than
    /// can be seen, no wider than its column, in its own shape — the
    /// further of the two ways the pointer went. Gives the width.
    @discardableResult
    func resizePicture(_ picture: NotePicture, at location: Int, from frame: NSRect, by delta: CGSize) -> CGFloat {
        let indent = frame.minX - textContainerOrigin.x
        let column = max(NotePicture.narrowest, (textContainer?.size.width ?? 600) - indent - 4)
        let aspect = frame.width > 0 ? frame.height / frame.width : 1
        let byHeight = aspect > 0 ? delta.height / aspect : 0
        let grow = abs(byHeight) > abs(delta.width) ? byHeight : delta.width
        let width = min(max(frame.width + grow, NotePicture.narrowest), column).rounded()
        picture.size = CGSize(width: width, height: (width * aspect).rounded())
        if let layout = layoutManager, let storage = textStorage, location < storage.length {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            layout.invalidateLayout(forCharacterRange: paragraph, actualCharacterRange: nil)
            layout.ensureLayout(forCharacterRange: paragraph)
        }
        needsDisplay = true
        return width
    }

    /// The width written after a picture's Markdown (nil: taken away), an
    /// edit of its own to undo.
    func setPictureWidth(_ width: CGFloat?, at location: Int) {
        guard isEditable, let storage = textStorage, location < storage.length,
              let picture = storage.attribute(.notePicture, at: location, effectiveRange: nil) as? NotePicture,
              let span = spans(atRowOf: location).first(where: { $0.isImage && $0.range.location == location }) else { return }
        let markdown = picture.markdown(width: width)
        let delta = (markdown as NSString).length - span.range.length
        let selection = selectedRange()
        let after = selection.location >= NSMaxRange(span.range) ? NSRange(location: selection.location + delta, length: selection.length) : selection
        replaceCharacters(span.range, with: markdown, selecting: after, name: width == nil ? "Picture's Own Size" : "Resize Picture")
    }

    /// Pictures that weren't here when the rows were styled came: styled
    /// again, shown.
    func picturesArrived() {
        guard let storage = textStorage, storage.length > 0 else { return }
        styler.styleAll(storage)
        needsDisplay = true
    }

    /// Debugging: each picture, where it's drawn.
    var debugPictures: String {
        guard let layout = pictureLayout, let storage = textStorage else { return "no layout" }
        let all = layout.pictureFrames(in: NSRange(location: 0, length: storage.length), origin: textContainerOrigin)
        guard !all.isEmpty else { return "no pictures" }
        return all.enumerated().map { i, p in
            "\(i) row \(rowIndex(at: p.location)) at \(p.location) \(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(p.frame.width))×\(Int(p.frame.height)) \(p.picture.reference.source)"
        }.joined(separator: "\n")
    }
}
