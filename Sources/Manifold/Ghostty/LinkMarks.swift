import AppKit
import CoreImage
import GhosttyKit
import QuartzCore

/// The links in a terminal's screen while ⌘ is held over it, marked as
/// an editor marks the names ⌘ makes links of: their text in the link
/// color (a color blend over them: the hue the link's, the lightness the
/// text's, so the background stays as it is), the one under the pointer
/// underlined too. Over the terminal's drawing; clicks go through.
final class LinkMarks: NSView {
    private var marks: [CALayer] = []
    private var underline: CALayer?
    private(set) var shown: [(row: Int, from: Int, to: Int)] = []
    private(set) var hovered: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rect(_ m: (row: Int, from: Int, to: Int), _ info: ghostty_manifold_info_s) -> CGRect {
        let cw = CGFloat(info.cell_width), ch = CGFloat(info.cell_height)
        return CGRect(x: CGFloat(info.pad_left) + CGFloat(m.from) * cw, y: bounds.height - CGFloat(info.pad_top) - CGFloat(m.row + 1) * ch,
                      width: CGFloat(m.to - m.from) * cw, height: ch)
    }

    /// Marks these runs of cells (rows of the viewport, columns from one to
    /// past another); `hovered`, the one under the pointer, underlined.
    func show(_ runs: [(row: Int, from: Int, to: Int)], hovered: Int?, info: ghostty_manifold_info_s) {
        hide()
        guard let root = layer else { return }
        shown = runs
        self.hovered = hovered
        var color = TextView.linkColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = TextView.linkColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for m in runs {
            let l = CALayer()
            l.frame = rect(m, info)
            l.backgroundColor = color
            l.compositingFilter = CIFilter(name: "CIColorBlendMode")
            root.addSublayer(l)
            marks.append(l)
        }
        if let h = hovered, runs.indices.contains(h) {
            let r = rect(runs[h], info)
            let u = CALayer()
            u.frame = CGRect(x: r.minX, y: r.minY + r.height * 0.1, width: r.width, height: 1.5)
            u.backgroundColor = color
            root.addSublayer(u)
            underline = u
        }
        CATransaction.commit()
    }

    func hide() {
        guard !marks.isEmpty || underline != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.forEach { $0.removeFromSuperlayer() }
        underline?.removeFromSuperlayer()
        CATransaction.commit()
        marks = []
        underline = nil
        shown = []
        hovered = nil
    }

    /// Debugging: the marks drawn into a snapshot (which draws views, not
    /// their layers), at `r`, blended as on the screen.
    func drawSnapshot(_ ctx: CGContext, in r: CGRect) {
        for l in marks {
            guard let c = l.backgroundColor else { continue }
            ctx.saveGState()
            ctx.setBlendMode(.color)
            ctx.setFillColor(c)
            ctx.fill(l.frame.offsetBy(dx: r.minX, dy: r.minY))
            ctx.restoreGState()
        }
        if let u = underline, let c = u.backgroundColor {
            ctx.setFillColor(c)
            ctx.fill(u.frame.offsetBy(dx: r.minX, dy: r.minY))
        }
    }
}
