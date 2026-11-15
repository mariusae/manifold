import AppKit

/// The system's symbols as SF Symbols has them: every one, in its order,
/// in its categories, with the words it's found by — read from the
/// system's own lists (CoreGlyphs), the language variants left out. Where
/// those can't be read, the few a space's menu offers.
enum SymbolCatalog {
    struct Category { var key: String; var icon: String; var title: String }

    struct Catalog {
        var names: [String] = []
        var categories: [Category] = []
        var inCategory: [String: Set<String>] = [:]
        var keywords: [String: [String]] = [:]
    }

    static let shared: Catalog = load()

    private static let base = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/"
    /// Scripts' variants of a symbol (its letters in Arabic, Hindi…): not
    /// shapes of their own.
    private static let variants: Set<String> = ["ar", "he", "hi", "ja", "ko", "th", "zh", "rtl", "km", "my", "bn", "gu", "kn", "ml", "mr", "or", "pa", "ta", "te", "si", "el", "ru", "sat", "mni"]
    private static let titles: [String: String] = ["all": "All", "whatsnew": "What's New", "draw": "Draw", "variable": "Variable", "multicolor": "Multicolor",
                                                   "communication": "Communication", "weather": "Weather", "maps": "Maps", "objectsandtools": "Objects & Tools",
                                                   "devices": "Devices", "cameraandphotos": "Camera & Photos", "gaming": "Gaming", "connectivity": "Connectivity",
                                                   "transportation": "Transportation", "automotive": "Automotive", "accessibility": "Accessibility",
                                                   "privacyandsecurity": "Privacy & Security", "human": "Human", "home": "Home", "fitness": "Fitness",
                                                   "nature": "Nature", "editing": "Editing", "textformatting": "Text Formatting", "media": "Media",
                                                   "keyboard": "Keyboard", "commerce": "Commerce", "time": "Time", "health": "Health", "shapes": "Shapes",
                                                   "arrows": "Arrows", "indices": "Indices", "math": "Math"]

    private static func plist(_ name: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: base + name) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func load() -> Catalog {
        var c = Catalog()
        let order = plist("symbol_order.plist") as? [String] ?? []
        c.names = order.filter { n in
            guard let last = n.split(separator: ".").last.map(String.init) else { return false }
            return !variants.contains(last)
        }
        if c.names.isEmpty { c.names = SpaceLook.markSymbols.map(\.symbol) }
        for item in plist("categories.plist") as? [[String: String]] ?? [] {
            guard let key = item["key"], let icon = item["icon"] else { continue }
            c.categories.append(Category(key: key, icon: icon, title: titles[key] ?? key.capitalized))
        }
        for (name, cats) in plist("symbol_categories.plist") as? [String: [String]] ?? [:] {
            for cat in cats { c.inCategory[cat, default: []].insert(name) }
        }
        c.keywords = plist("symbol_search.plist") as? [String: [String]] ?? [:]
        return c
    }

    /// The symbols in a category (nil or "all": every one) that answer what's
    /// typed — in their names or their words — those whose names do first.
    static func find(_ query: String, in category: String?) -> [String] {
        let c = shared
        var names = c.names
        if let category, category != "all", let set = c.inCategory[category] { names = names.filter(set.contains) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return names }
        let words = q.split(separator: " ").map(String.init)
        var byName: [String] = [], byWord: [String] = []
        for n in names {
            if words.allSatisfy({ n.contains($0) }) { byName.append(n); continue }
            let k = c.keywords[n] ?? []
            if words.allSatisfy({ w in n.contains(w) || k.contains { $0.hasPrefix(w) } }) { byWord.append(n) }
        }
        return byName + byWord
    }
}

/// A palette of the system's symbols, as the Mac's emoji picker has its
/// emoji: a search field over a grid of them, their categories along a
/// row of icons; one clicked (or ⏎, the first found) chosen.
final class SymbolPalette: NSViewController, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onChoose: ((String) -> Void)?
    private let search = NSSearchField()
    private let categoryRow = NSStackView()
    private let categoryScroll = NSScrollView()
    private let grid = NSCollectionView()
    private let gridScroll = NSScrollView()
    private let none = NSTextField.label(font: UIType.detail, color: Theme.tertiaryText)
    private var category: String = "all"
    private var shown: [String] = []
    private var categoryButtons: [String: NSButton] = [:]

    static let size = NSSize(width: 380, height: 420)
    static let cell = NSSize(width: 38, height: 38)

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view = v
        search.placeholderString = "Search symbols"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)

        // The categories, a row of their icons.
        categoryRow.orientation = .horizontal
        categoryRow.spacing = 2
        for c in SymbolCatalog.shared.categories {
            let b = NSButton(image: NSImage(systemSymbolName: c.icon, accessibilityDescription: c.title) ?? NSImage(), target: self, action: #selector(categoryClicked(_:)))
            b.bezelStyle = .recessed
            b.isBordered = false
            b.setButtonType(.pushOnPushOff)
            b.toolTip = c.title
            b.identifier = .init(c.key)
            b.contentTintColor = Theme.secondaryText
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            categoryButtons[c.key] = b
            categoryRow.addArrangedSubview(b)
        }
        categoryScroll.documentView = categoryRow
        categoryScroll.drawsBackground = false
        categoryScroll.hasHorizontalScroller = false
        categoryScroll.horizontalScrollElasticity = .allowed

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.cell
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 4, left: 6, bottom: 6, right: 6)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.backgroundColors = [.clear]
        grid.register(SymbolCell.self, forItemWithIdentifier: SymbolCell.id)
        gridScroll.documentView = grid
        gridScroll.drawsBackground = false
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true

        for x in [search, categoryScroll, gridScroll, none] as [NSView] { v.addSubview(x) }
        let b = v.bounds
        search.frame = NSRect(x: 10, y: b.height - 36, width: b.width - 20, height: 24)
        categoryScroll.frame = NSRect(x: 8, y: b.height - 64, width: b.width - 16, height: 24)
        categoryRow.frame = NSRect(x: 0, y: 0, width: CGFloat(categoryButtons.count) * 28, height: 24)
        gridScroll.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - 68)
        none.frame = NSRect(x: 0, y: b.height / 2 - 30, width: b.width, height: 18)
        none.alignment = .center
        none.stringValue = "No symbols"
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The keyboard to its search only while the app's in front.
        if NSApp.isActive { view.window?.makeFirstResponder(search) }
    }

    @objc private func categoryClicked(_ b: NSButton) {
        category = b.identifier?.rawValue ?? "all"
        refresh()
    }

    @objc private func searched() { refresh() }
    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let first = shown.first {
            onChoose?(first)
            return true
        }
        return false
    }

    private func refresh() {
        shown = SymbolCatalog.find(search.stringValue, in: category)
        for (key, b) in categoryButtons {
            b.state = key == category ? .on : .off
            b.contentTintColor = key == category ? Theme.accent : Theme.secondaryText
        }
        none.isHidden = !shown.isEmpty
        grid.reloadData()
        grid.scroll(.zero)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SymbolCell.id, for: indexPath) as! SymbolCell
        item.show(shown[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let i = indexPaths.first?.item, shown.indices.contains(i) else { return }
        onChoose?(shown[i])
    }

    /// Debugging: what's found for a query in a category, its first few.
    static func debug(_ query: String, category: String? = nil) -> String {
        let found = SymbolCatalog.find(query, in: category)
        return "\(SymbolCatalog.shared.names.count) symbols, \(SymbolCatalog.shared.categories.count) categories · “\(query)”: \(found.count) — " + found.prefix(12).joined(separator: " ")
    }
}

/// A symbol in the palette: drawn large, its name as its tip; the
/// pointer on it, a ground under it.
private final class SymbolCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("symbol")
    private let image = NSImageView()

    override func loadView() {
        let v = HoverGround()
        image.imageScaling = .scaleNone
        v.addSubview(image)
        view = v
    }

    func show(_ name: String) {
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        image.contentTintColor = Theme.text
        image.frame = view.bounds
        view.toolTip = name
    }

    override var isSelected: Bool { didSet { (view as? HoverGround)?.lit = isSelected } }

    private final class HoverGround: NSView {
        var lit = false { didSet { needsDisplay = true } }
        private var hovering = false { didSet { needsDisplay = true } }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func draw(_ dirtyRect: NSRect) {
            guard lit || hovering else { return }
            (lit ? Theme.accent.withAlphaComponent(0.25) : Theme.text.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
    }
}
