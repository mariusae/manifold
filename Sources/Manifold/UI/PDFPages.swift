import AppKit
import ManifoldCore
import PDFKit

/// A PDF's pages as thumbnails down its tile's sidebar (§7.5): the page in
/// view chosen as it scrolls; clicked, gone to. Several chosen (⌘-, ⇧-click)
/// and dragged out, each page is a place in the PDF (`page=N`, as its
/// contents' entries are) — a link to it in a note, its reference for an
/// agent — and the page itself as a PDF for another app.
final class PDFPagesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let block: BlockID
    weak var pdfView: PDFView? {
        didSet {
            NotificationCenter.default.removeObserver(self)
            if let pdfView {
                NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
            }
            reload()
        }
    }
    private let scroll = ClippingScrollView()
    private let table = NSTableView()
    private var count = 0
    /// A page clicked: gone to (by its index), as the tile goes places.
    var onGo: ((Int) -> Void)?
    /// Each page's picture, drawn once.
    private var thumbnails: [Int: NSImage] = [:]
    /// Choosing a row as the PDF scrolls, not a click: not gone to.
    private var following = false
    static let thumbnail = NSSize(width: 120, height: 150)

    init(block: BlockID) {
        self.block = block
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = Self.thumbnail.height + 32
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    /// The document's pages listed again (it's loaded, or another).
    func reload() {
        count = pdfView?.document?.pageCount ?? 0
        thumbnails = [:]
        table.reloadData()
        pageChanged()
    }

    private var currentIndex: Int? {
        guard let p = pdfView, let page = p.currentPage, let doc = p.document else { return nil }
        return doc.index(for: page)
    }

    /// The page in view chosen, unless several are.
    @objc private func pageChanged() {
        guard let i = currentIndex, i < count, table.selectedRowIndexes.count <= 1, table.selectedRow != i else { return }
        following = true
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        following = false
    }

    /// A page clicked: gone to — but not one ⌘- or ⇧-clicked, chosen among others.
    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, !following, NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty != false else { return }
        onGo?(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PageCell.id, owner: nil) as? PageCell ?? PageCell()
        cell.show(thumbnail(row), number: row + 1)
        return cell
    }

    private func thumbnail(_ i: Int) -> NSImage? {
        if let t = thumbnails[i] { return t }
        guard let page = pdfView?.document?.page(at: i) else { return nil }
        let t = page.thumbnail(of: Self.thumbnail, for: .cropBox)
        thumbnails[i] = t
        return t
    }

    /// A page dragged: its place in the PDF, and the page as a PDF.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = Drags.place?(block, "page=\(row + 1)", "Page \(row + 1)") else { return nil }
        if let data = pdfView?.document?.page(at: row)?.dataRepresentation { item.setData(data, forType: .pdf) }
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        DragPill.dress(session, from: tableView, at: screenPoint)
        DragCursor.began()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
    }

    /// Debugging: the pages chosen (counted from 1) as ⌘-clicks, and what
    /// dragging them writes.
    func debugChoose(_ pages: [Int]) -> [NSPasteboardWriting] {
        if !pages.isEmpty { table.selectRowIndexes(IndexSet(pages.map { $0 - 1 }.filter { $0 >= 0 && $0 < count }), byExtendingSelection: false) }
        return table.selectedRowIndexes.compactMap { tableView(table, pasteboardWriterForRow: $0) }
    }

    /// Debugging: the list as drawn, written to `path`.
    func debugPicture(to path: String) -> String {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return "nothing drawn (\(Int(bounds.width))×\(Int(bounds.height)))" }
        cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return "wrote \(path)"
    }

    var debugState: String {
        "pages \(count), chosen \(table.selectedRowIndexes.map { "\($0 + 1)" }.joined(separator: " ")), current \(currentIndex.map { "\($0 + 1)" } ?? "-")"
    }
}

/// A page's thumbnail, framed, its number under it.
private final class PageCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("pdfPage")
    private let picture = NSImageView()
    private let number = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.borderWidth = 0.5
        picture.themed { $0.layer?.borderColor = EdgeColor.hairline.cgColor }
        number.font = UIType.caption
        number.textColor = Theme.secondaryText
        number.alignment = .center
        addSubview(picture)
        addSubview(number)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage?, number n: Int) {
        picture.image = image
        number.stringValue = "\(n)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = picture.image?.size ?? PDFPagesView.thumbnail
        let w = min(size.width, PDFPagesView.thumbnail.width), h = min(size.height, PDFPagesView.thumbnail.height)
        picture.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.height - 8 - h, width: w, height: h)
        number.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 16)
    }
}
