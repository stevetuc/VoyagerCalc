// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LCDCanvasView.swift - the iOS 12 drawing of the display: ten seven-segment digits with points and
// commas, a minus sign and the annunciators. A UIKit port of Views/LCDView.swift (SwiftUI Canvas);
// the geometry is the same, including the slanted segments and the comma tail measured on the glass.

import UIKit

final class LCDCanvasView: UIView {
    var lcd: LCDState = .blank { didSet { if lcd != oldValue { setNeedsDisplay() } } }
    var model: CalculatorModel = .hp16c { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        layer.cornerRadius = 4
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        layer.cornerRadius = 4
        layer.masksToBounds = true
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let size = bounds.size
        guard size.width > 4, size.height > 4 else { return }
        let c = model.colors

        // glass
        let glass = UIColor(rgb: c.lcd)
        let bottom = c.lcd == ModelColors.greyLCD ? glass : glass.withAlphaComponent(0.85)
        LegacyDraw.verticalGradient(ctx, in: bounds, top: glass, bottom: bottom)
        UIColor.black.withAlphaComponent(0.35).setStroke()
        let edge = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
        edge.lineWidth = 1
        edge.stroke()

        let ink = UIColor(rgb: c.segment)
        let faint = UIColor(rgb: c.segment, alpha: 0.045)

        // 11 cells: sign + 10 digits; digits use the upper part, annunciators the rest.
        let cellW = size.width / 11.2
        let digitH = size.height * 0.62
        let top = size.height * 0.10
        let left = cellW * 0.35

        for i in 0..<10 {
            let x = left + CGFloat(i + 1) * cellW
            let digit = CGRect(x: x + cellW * 0.14, y: top, width: cellW * 0.62, height: digitH)
            for s in 0..<7 { fill(segmentPath(s, in: digit), faint) }
            let bits: UInt8 = i < lcd.segments.count ? lcd.segments[i] : 0
            for s in 0..<7 where (bits >> UInt8(s)) & 1 == 1 {
                fill(segmentPath(s, in: digit), ink)
            }
            let dotSize = cellW * 0.13
            let dot = CGRect(x: digit.maxX + cellW * 0.06, y: digit.maxY - dotSize, width: dotSize, height: dotSize)
            let showsDot = i < lcd.dots.count && lcd.dots[i]
            let comma = i < lcd.commas.count && lcd.commas[i]
            if showsDot || comma { fill(UIBezierPath(ovalIn: dot), ink) }
            if comma { fill(commaTail(dot), ink) }
        }

        // minus sign in the sign cell
        let sign = CGRect(x: left + cellW * 0.15, y: top, width: cellW * 0.62, height: digitH)
        fill(segmentPath(6, in: sign), lcd.minus ? ink : faint)

        drawAnnunciators(size: size, cellW: cellW, left: left, digitH: digitH, top: top, ink: ink, faint: faint)
    }

    private func fill(_ path: UIBezierPath, _ color: UIColor) {
        color.setFill()
        path.fill()
    }

    /// Tail of a comma: thin, slanting down-left, separated from the dot by a hair.
    /// Points are in dot units (D = dot width), origin at the dot's top-left corner, y down.
    private static let commaTailPoints: [(CGFloat, CGFloat)] = [
        (-0.10, 1.06), (0.66, 1.06), (0.12, 1.68), (-0.08, 1.86), (-0.30, 1.84), (-0.34, 1.66),
    ]

    private func commaTail(_ dot: CGRect) -> UIBezierPath {
        let d = dot.width
        let path = UIBezierPath()
        for (i, pt) in LCDCanvasView.commaTailPoints.enumerated() {
            let p = CGPoint(x: dot.minX + pt.0 * d, y: dot.minY + pt.1 * d)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.close()
        return path
    }

    /// Path of segment s (0 = a ... 6 = g) in a digit box, slanted like the Voyager LCD.
    private func segmentPath(_ s: Int, in r: CGRect) -> UIBezierPath {
        let t = r.width * 0.17            // stroke thickness
        let g = t * 0.18                  // gap between segments
        let w = r.width, h = r.height, mid = h / 2
        let slant: CGFloat = 0.10         // x shift per unit of height (italic)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x + (h - y) * slant, y: r.minY + y)
        }
        let path = UIBezierPath()
        var started = false
        func go(_ point: CGPoint) {
            if !started { path.move(to: point); started = true }
            else { path.addLine(to: point) }
        }
        func horizontal(_ y: CGFloat) {
            go(p(t / 2 + g, y))
            go(p(t + g, y - t / 2))
            go(p(w - t - g, y - t / 2))
            go(p(w - t / 2 - g, y))
            go(p(w - t - g, y + t / 2))
            go(p(t + g, y + t / 2))
            path.close()
        }
        func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            go(p(x, y0 + g))
            go(p(x + t / 2, y0 + t / 2 + g))
            go(p(x + t / 2, y1 - t / 2 - g))
            go(p(x, y1 - g))
            go(p(x - t / 2, y1 - t / 2 - g))
            go(p(x - t / 2, y0 + t / 2 + g))
            path.close()
        }
        switch s {
        case 0: horizontal(t / 2)
        case 1: vertical(w - t / 2, t / 2, mid)
        case 2: vertical(w - t / 2, mid, h - t / 2)
        case 3: horizontal(h - t / 2)
        case 4: vertical(t / 2, mid, h - t / 2)
        case 5: vertical(t / 2, t / 2, mid)
        default: horizontal(mid)
        }
        return path
    }

    private func drawAnnunciators(size: CGSize, cellW: CGFloat, left: CGFloat, digitH: CGFloat, top: CGFloat,
                                  ink: UIColor, faint: UIColor) {
        let anns = model.annunciators
        guard !anns.isEmpty else { return }
        let annY = top + digitH + size.height * 0.08
        var fontSize = max(6, size.height * 0.15)
        var xs = [CGFloat](repeating: 0, count: anns.count)
        var widths = [CGFloat](repeating: 0, count: anns.count)
        // shrink until no label runs into the next one
        for _ in 0..<12 {
            var fits = true
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            for (i, a) in anns.enumerated() {
                widths[i] = (a.label as NSString).size(withAttributes: [.font: font]).width
                xs[i] = left + CGFloat(a.cell + 1) * cellW
                guard i > 0 else { continue }
                if a.label == "RAD", anns[i - 1].label == "G" { xs[i] = xs[i - 1] + widths[i - 1] }
                else if xs[i] < xs[i - 1] + widths[i - 1] + cellW * 0.08 { fits = false }
            }
            if fits || fontSize <= 4 { break }
            fontSize = max(4, fontSize * 0.92)
        }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        for (i, a) in anns.enumerated() {
            let color = a.isLit(lcd.annunciatorBits) ? ink : faint
            (a.label as NSString).draw(at: CGPoint(x: xs[i], y: annY),
                                       withAttributes: [.font: font, .foregroundColor: color])
        }
    }
}
