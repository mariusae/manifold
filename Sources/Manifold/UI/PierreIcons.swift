import AppKit
import ManifoldCore

/// Which set the app's own icons are drawn from (Settings ▸ Appearance ▸
/// Icons): Pierre's, or the system's SF Symbols. Agents' and programs'
/// marks, a space's symbol (chosen from the system's) and what Pierre
/// has nothing for are the same in either.
enum Icons {
    static private(set) var current: IconSet = .pierre
    static var pierre: Bool { current == .pierre }

    /// The set changed: what was made in the other forgotten, and every
    /// view in the app's windows showing one shown the new set's (a
    /// button's, an image's) — what's drawn as it's drawn is drawn again.
    static func use(_ s: IconSet) {
        guard s != current else { return }
        current = s
        let old = makers
        makers = [:]
        Theme.forgetSymbols()
        var tables: [NSTableView] = []
        func reissue(_ v: NSView) {
            if let iv = v as? NSImageView, let i = iv.image, let m = old[ObjectIdentifier(i)], m.image === i { iv.image = m.make() }
            if let b = v as? NSButton, let i = b.image, let m = old[ObjectIdentifier(i)], m.image === i { b.image = m.make() }
            if let t = v as? NSTableView { tables.append(t) }
            v.needsDisplay = true
            v.needsLayout = true
            v.subviews.forEach(reissue)
        }
        for w in NSApp.windows { w.contentView.map(reissue) }
        // A list's rows shown made again (what they set in an icon — a
        // tinted one, a git change's squircle in its text — made anew),
        // what's chosen and open in it kept.
        for t in tables {
            let rows = t.rows(in: t.visibleRect)
            guard rows.length > 0, t.numberOfColumns > 0 else { continue }
            t.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)), columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns))
        }
        NotificationCenter.default.post(name: .manifoldAppearanceChanged, object: nil)
    }

    /// Each symbol's image made (kept, so it's the same object while
    /// it's shown), and how to make it again — in the other set, when
    /// the set changes.
    private static var makers: [ObjectIdentifier: (image: NSImage, make: () -> NSImage?)] = [:]

    static func noteMade(_ image: NSImage, _ make: @escaping () -> NSImage?) {
        makers[ObjectIdentifier(image)] = (image, make)
    }

    /// How an image was made, if it's a symbol's.
    static func maker(of image: NSImage) -> (() -> NSImage?)? {
        makers[ObjectIdentifier(image)].flatMap { $0.image === image ? $0.make : nil }
    }
}

/// Pierre's icons (@pierre/icons, by the Pierre Computer Company,
/// Apache-2.0; Resources/PierreIcons, its licence beside them): drawn for
/// a file tree, a diff and a review's comments — what Manifold shows most
/// — as one family: a file with a badge for what kind it is, a squircle
/// for a change's state (added, modified, deleted, renamed), a circle for
/// work's. Each is drawn at 12, 16 and 24 pixels, not scaled from one, in
/// outline and fill; the drawing nearest the size asked for is taken.
/// Where a symbol is asked for by its SF name (`Theme.symbol`), the icon
/// standing for it here is drawn instead, when Pierre's are the set; one
/// that isn't here stays the system's. `scripts/update-pierre-icons.sh`
/// copies in what's named here from a checkout of the library.
enum PierreIcons {
    /// One of its icons: its name (without "Icon"), filled or not, turned
    /// (degrees anticlockwise: its chevron points down).
    struct Use: Equatable {
        var icon: String
        var fill = false
        var turn: CGFloat = 0
        init(_ icon: String, fill: Bool = false, turn: CGFloat = 0) {
            self.icon = icon
            self.fill = fill
            self.turn = turn
        }
    }

    /// Each symbol Manifold asks for by its SF name, as Pierre draws it.
    static let replacing: [String: Use] = [
        // Ours: a terminal's squircle, and a note's — its pencil, written in.
        Marks.terminal: Use("SquircleTerminal"),
        Marks.note: Use("SquirclePencil"),
        // What a tile or a row is: its kind.
        "folder": Use("Folder"),
        "folder.fill": Use("Folder", fill: true),
        "shippingbox": Use("Box"),
        "folder.badge.plus": Use("FolderBadgePlus"),
        "doc": Use("File"),
        "doc.fill": Use("File", fill: true),
        "doc.text": Use("FileText"),
        "doc.plaintext": Use("FileText"),
        "doc.richtext": Use("FileRichText"),
        "doc.badge.plus": Use("FileBadgePlus"),
        "photo": Use("FileImage"),
        "globe": Use("Globe"),
        "magnifyingglass": Use("MagnifyingGlass"),
        // A diff: the changes' ± in a squircle, as git's changes are.
        "plus.forwardslash.minus": Use("SquircleDiffstat"),
        "arrow.triangle.branch": Use("Branch"),
        "arrow.triangle.pull": Use("Commit"),
        "arrow.triangle.merge": Use("Merge"),
        "gauge.medium": Use("LineGraph"),
        "chart.bar": Use("BarChart"),
        // An agent: a squircle with a sparkle — beside the terminal's and
        // the note's, what thinks beside what runs and what's written (ours,
        // of Pierre's parts, till its set has a sparkle: Resources/OwnIcons).
        "sparkle": Use("SquircleSparkle"),
        "text.alignleft": Use("Logs"),
        "list.bullet.rectangle": Use("ListBullet"),
        "list.bullet": Use("ListBullet"),
        "list.bullet.indent": Use("ListDash"),
        "list.number": Use("ListNumber"),
        "slider.horizontal.3": Use("Sliders"),
        // A thread: a comment; resolved, its comment ticked.
        "bubble.left.and.bubble.right": Use("Comment"),
        "text.bubble": Use("Comment"),
        "text.bubble.fill": Use("Comment", fill: true),
        "checkmark.bubble": Use("CommentCheck"),
        "plus.bubble": Use("CommentPlus"),
        // A file's type, in a tree (its kind's colour kept).
        "chevron.left.forwardslash.chevron.right": Use("FileCode"),
        "curlybraces": Use("FileBadgeGear"),
        "archivebox": Use("FileZip"),
        "apple.terminal": Use("SquircleBash"),
        "lock.doc": Use("FileLock"),
        "tablecells": Use("FileSpreadsheet"),
        "text.quote": Use("Blockquote"),
        // Work's states: circles.
        "checkmark.circle": Use("CircleCheck"),
        "checkmark.circle.fill": Use("CircleCheck", fill: true),
        "xmark.circle": Use("CircleX"),
        "xmark.circle.fill": Use("CircleX", fill: true),
        "exclamationmark.circle": Use("CircleBang"),
        "info.circle": Use("CircleInfo"),
        "questionmark.circle": Use("CircleQuestion"),
        "plus.circle": Use("CirclePlus"),
        "minus.circle": Use("CircleMinus"),
        "circle.dashed": Use("CircleDash"),
        "ellipsis.circle": Use("CircleEllipsis"),
        "clock": Use("CircleClock"),
        "clock.arrow.circlepath": Use("ClockArrow"),
        "exclamationmark.triangle": Use("TriangleBang"),
        // The chrome's.
        "xmark": Use("X"),
        "plus": Use("Plus"),
        "minus": Use("Minus"),
        "checkmark": Use("Check"),
        "chevron.down": Use("Chevron"),
        "chevron.up": Use("Chevron", turn: 180),
        "chevron.right": Use("Chevron", turn: 90),
        "chevron.forward": Use("Chevron", turn: 90),
        "chevron.left": Use("Chevron", turn: -90),
        "sidebar.left": Use("SidebarLeft"),
        "sidebar.right": Use("SidebarRight"),
        "arrow.up.left.and.arrow.down.right": Use("Arrows"),
        "arrow.down.right.and.arrow.up.left": Use("ArrowsContract"),
        "doc.on.doc": Use("Copy"),
        "doc.on.clipboard": Use("Copy"),
        "line.3.horizontal.decrease": Use("Filter"),
        "line.3.horizontal.decrease.circle": Use("Filter"),
        "line.3.horizontal.decrease.circle.fill": Use("Filter", fill: true),
        "pencil": Use("Pencil"),
        "square.and.pencil": Use("SquirclePencil"),
        "trash": Use("Trash"),
        "eye": Use("Eye"),
        "eye.fill": Use("Eye", fill: true),
        "eye.slash": Use("EyeSlash"),
        "tray": Use("Inbox"),
        "tray.full": Use("InboxFull"),
        "tray.and.arrow.down": Use("ArrowTrayIn"),
        // Dock: into the sidebar, at the left, where a docked tile's listed.
        "dock.arrow.down.rectangle": Use("ArrowTrayIn", turn: 180),
        "square.and.arrow.down": Use("ArrowTrayDown"),
        "bell": Use("Bell"),
        "bell.slash": Use("BellSlash"),
        "bell.badge": Use("BellUnread"),
        "gearshape": Use("Gear"),
        "gearshape.2": Use("Gear"),
        "link": Use("Link"),
        "diff.more.above": Use("ArrowsRowExpand"),
        "thread.new": Use("CommentPlus"),
        "arrow.up": Use("ArrowUp"),
        "arrow.down": Use("ArrowDown"),
        "arrow.left": Use("ArrowLeft"),
        "arrow.right": Use("ArrowRight"),
        "arrow.up.right": Use("ArrowUpRight"),
        "arrow.up.right.square": Use("ArrowUpRight"),
        "arrow.up.and.down": Use("ArrowUpDown"),
        "arrow.up.arrow.down": Use("ArrowUpDown"),
        "star": Use("Star"),
        "star.fill": Use("Star", fill: true),
        "flag.fill": Use("Flag", fill: true),
        "bolt.fill": Use("Bolt", fill: true),
        "heart.fill": Use("Heart", fill: true),
        "flame.fill": Use("Fire", fill: true),
        "lock": Use("Lock"),
        "lock.fill": Use("Lock", fill: true),
        "bookmark": Use("Bookmark"),
        "bookmark.fill": Use("Bookmark", fill: true),
        "tag": Use("Tag"),
        "number": Use("Hash"),
        "paperclip": Use("Paperclip"),
    ]

    /// A space's badges (`SpaceLook.badges`, by their SF names) as Pierre
    /// draws them, filled — a square its squircle; the diamond, leaf, drop
    /// and moon, which it hasn't, the system's. Only here: a space's own
    /// symbol is chosen from the system's, and stays theirs.
    static let badges: [String: Use] = [
        "circle.fill": Use("Circle", fill: true), "square.fill": Use("Squircle", fill: true),
        "triangle.fill": Use("Triangle", fill: true), "star.fill": Use("Star", fill: true),
        "heart.fill": Use("Heart", fill: true), "bolt.fill": Use("Bolt", fill: true),
        "flame.fill": Use("Fire", fill: true), "flag.fill": Use("Flag", fill: true),
        "bookmark.fill": Use("Bookmark", fill: true), "eye.fill": Use("Eye", fill: true),
        "checkmark": Use("Check"),
    ]

    /// A git change's letter (porcelain's: A, M, D, R…) as its squircle.
    static func change(_ letter: Character) -> String? {
        switch letter {
        case "A": "SquircleAdded"
        case "M", "T": "SquircleModified"
        case "D": "SquircleDeleted"
        case "R", "C": "SquircleRenamed"
        case "U": "StateConflict"
        case "?": "SquircleDash"
        default: nil
        }
    }

    /// A change's letter as its squircle, in its colour — filled for what's
    /// staged (in the index), outlined for what isn't — while Pierre's are
    /// the set; nil otherwise, or for a letter that's none.
    static func change(_ letter: Character, staged: Bool, size: CGFloat) -> NSImage? {
        guard Icons.pierre, let icon = change(letter) else { return nil }
        return image(Use(icon, fill: staged), size: size)?.tinted(changeColor(letter))
    }

    static func changeColor(_ letter: Character) -> NSColor {
        switch letter {
        case "A": TextView.addedColor
        case "D": TextView.deletedColor
        case "U": Status.failed
        case "?": Theme.secondaryText
        default: TextView.modifiedColor
        }
    }

    /// A change's two letters (porcelain's, the index's and the work
    /// tree's) as squircles, to set before its path; nil unless Pierre's
    /// are the set.
    static func changeMarks(index: String, workTree: String, font: NSFont) -> NSAttributedString? {
        guard Icons.pierre else { return nil }
        let size = font.pointSize
        let side = (size * 1.15).rounded()
        let out = NSMutableAttributedString()
        func mark(_ letter: String, staged: Bool) {
            let a = NSTextAttachment()
            let image = letter.first.flatMap { change($0, staged: staged, size: size) }
            a.image = image ?? NSImage(size: NSSize(width: side, height: side))
            a.bounds = NSRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
            out.append(NSAttributedString(attachment: a))
            out.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        if index == "?" {
            mark("?", staged: false)
            mark(" ", staged: false)
        } else {
            mark(index, staged: true)
            mark(workTree, staged: false)
        }
        return out
    }

    static let folder = Bundle.main.resourceURL?.appendingPathComponent("PierreIcons")
    /// Ours in its style, for what its set hasn't yet (Resources/OwnIcons).
    static let own = Bundle.main.resourceURL?.appendingPathComponent("OwnIcons")

    /// The icon standing for a symbol, while Pierre's are the set.
    static func use(_ symbol: String) -> Use? { Icons.pierre ? replacing[symbol] : nil }

    /// A symbol as Pierre draws it, at the size a symbol of `size` points
    /// would take: a template, tinted as symbols are; nil where there's
    /// none, or Pierre's aren't the set.
    static func image(_ symbol: String, size: CGFloat) -> NSImage? {
        use(symbol).flatMap { image($0, size: size) }
    }

    private static var made: [String: NSImage] = [:]

    /// One of its icons, at the size a symbol of `size` points would take.
    static func image(_ u: Use, size: CGFloat) -> NSImage? {
        let side = (size * 1.15).rounded()
        let key = "\(u.icon)/\(u.fill)/\(u.turn)/\(side)"
        if let i = made[key] { return i }
        // The drawing nearest the size: each is its own, not one scaled.
        let px = side <= 13 ? 12 : side <= 20 ? 16 : 24
        let kinds = [u.fill ? "fill" : "outline", "outline"]
        let places = [folder, own].compactMap { $0 }
        guard let url = kinds.lazy.flatMap({ k in places.map { $0.appendingPathComponent("Icon\(u.icon)/\(k)-\(px)px.svg") } })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let svg = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            guard u.turn != 0, let ctx = NSGraphicsContext.current?.cgContext else {
                svg.draw(in: r)
                return true
            }
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: u.turn * .pi / 180)
            ctx.translateBy(x: -r.midX, y: -r.midY)
            svg.draw(in: r)
            return true
        }
        image.isTemplate = true
        made[key] = image
        return image
    }

    /// Every icon named here, for the script that copies them in and the
    /// test that they're there.
    static var named: Set<String> {
        Set(replacing.values.map(\.icon)).union(badges.values.map(\.icon)).union(["A", "M", "D", "R", "U", "?"].compactMap { change(Character($0)) })
    }
}
