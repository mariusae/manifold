import AppKit

/// How colours look to eyes that see them differently: typical vision,
/// and the three dichromacies (Machado, Oliveira and Fernandes, 2009, at
/// full severity), so marks told apart by colour alone — a host's line,
/// a chart's series — can be checked to be told apart by anyone.
enum ColorVision: CaseIterable {
    case typical, protanopia, deuteranopia, tritanopia

    /// What two marks told apart by colour must differ by, as seen: a
    /// distance in Oklab (0.02 is about the least anyone sees); a thin
    /// mark asks for plenty more.
    static let apart: CGFloat = 0.1

    /// How far apart two colours look to these eyes, in Oklab.
    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let x = Self.oklab(seen(a)), y = Self.oklab(seen(b))
        return sqrt(pow(x.l - y.l, 2) + pow(x.a - y.a, 2) + pow(x.b - y.b, 2))
    }

    /// A colour as these eyes see it, in linear sRGB.
    func seen(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = (linear(c.redComponent), linear(c.greenComponent), linear(c.blueComponent))
        let m: [[CGFloat]]
        switch self {
        case .typical: return l
        case .protanopia: m = [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
        case .deuteranopia: m = [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
        case .tritanopia: m = [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
        }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return (clamp(m[0][0] * l.0 + m[0][1] * l.1 + m[0][2] * l.2),
                clamp(m[1][0] * l.0 + m[1][1] * l.1 + m[1][2] * l.2),
                clamp(m[2][0] * l.0 + m[2][1] * l.1 + m[2][2] * l.2))
    }

    /// Linear sRGB in Oklab (Björn Ottosson's).
    static func oklab(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> (l: CGFloat, a: CGFloat, b: CGFloat) {
        let l = cbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b)
        let m = cbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b)
        let s = cbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}
