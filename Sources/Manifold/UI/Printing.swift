import AppKit
import ManifoldCore

/// A tile that prints (⌘P, §3.1): what it shows, as it best goes on paper.
protocol Printable {
    func printOperation() -> NSPrintOperation?
}

/// Text on paper: as wide as the page, in the font given, as many pages
/// as it takes, a title at the top of the first.
enum TextPrint {
    static func operation(_ text: String, title: String, font: NSFont) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 42
        info.bottomMargin = 42
        info.leftMargin = 42
        info.rightMargin = 42
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isEditable = false
        view.drawsBackground = false
        let body = NSMutableAttributedString(string: title + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
        body.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        view.textStorage?.setAttributedString(body)
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = title
        return op
    }

    static var codeFont: NSFont { FontTheme.current.font(.monospaced, size: 9.5) }
}
