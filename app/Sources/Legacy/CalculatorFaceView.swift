// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// CalculatorFaceView.swift - the iOS 12 drawn calculator face. A UIKit port of Views/CalculatorView.swift
// and Views/KeyView.swift: the body, the display bezel with the model name, the metal band, the gold
// legends with their brackets, and the keys (cap, label, blue legend on the front). Every key answers
// over its cap, its gold legend above it and its blue legend on the front, as in the SwiftUI app.
//
// The faces are drawn, not photographed: the public repository ships no photo faces, and the SwiftUI
// app falls back to the same drawing when they are absent.
//
// Touches are tracked by hand so a key stays down while the finger is on it, and a key held for 0.8 s
// latches down (haptic tick) for chords, like the iOS long press in KeyView.swift.

import UIKit

/// Landscape: 4 rows x 10 columns. Portrait: the left and right halves stacked (5 x 8).
struct LegacyKeyboardLayout {
    let landscape: Bool
    var rows: Int { landscape ? 4 : 8 }
    var columns: Int { landscape ? 10 : 5 }

    func place(_ k: KeySpec) -> (row: Int, col: Int) {
        if landscape { return (k.row, k.column) }
        return (k.row + (k.column >= 5 ? 4 : 0), k.column % 5)
    }
}

struct LegacyKeyboardGeometry {
    let layout: LegacyKeyboardLayout
    let rect: CGRect
    var cellW: CGFloat { rect.width / CGFloat(layout.columns) }
    var rowH: CGFloat { rect.height / CGFloat(layout.rows) }
    var legendH: CGFloat { rowH * 0.27 }
    var keyH: CGFloat { rowH * 0.64 }
    var keyW: CGFloat { cellW * 0.80 }

    func legendRect(_ k: KeySpec) -> CGRect {
        let p = layout.place(k)
        return CGRect(x: rect.minX + CGFloat(p.col) * cellW, y: rect.minY + CGFloat(p.row) * rowH,
                      width: cellW, height: legendH)
    }

    func keyRect(_ k: KeySpec) -> CGRect {
        let p = layout.place(k)
        let x = rect.minX + CGFloat(p.col) * cellW + (cellW - keyW) / 2
        let y = rect.minY + CGFloat(p.row) * rowH + legendH
        let h = k.rowSpan == 2 ? rowH + keyH : keyH
        return CGRect(x: x, y: y, width: keyW, height: h)
    }

    func zones(_ k: KeySpec) -> KeyZones {
        KeyZones.drawn(legend: legendRect(k), key: keyRect(k), unit: keyH, spec: k)
    }
}

final class CalculatorFaceView: UIView {
    var model: CalculatorModel = .hp16c { didSet { if model.id != oldValue.id { setNeedsLayout() } } }
    var pressed: Set<Int> = [] { didSet { if pressed != oldValue { setNeedsDisplay() } } }
    var latched: Set<Int> = [] { didSet { if latched != oldValue { setNeedsDisplay() } } }

    var onPress: ((Int, KeyPart) -> Void)?
    var onRelease: ((Int) -> Void)?
    var onLatch: ((Int) -> Void)?

    let lcdView = LCDCanvasView(frame: .zero)

    private var pad: CGFloat = 12
    private var topH: CGFloat = 0
    private var kbRect: CGRect = .zero
    private var geometry: LegacyKeyboardGeometry?
    private var keys: [(spec: KeySpec, rect: CGRect, zones: KeyZones)] = []
    private var active: (code: Int, part: KeyPart)?
    private var latchedByTouch = false
    private var touching = false
    private var latchTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = true
        backgroundColor = UIColor(rgb: 0x3B302A)
        isMultipleTouchEnabled = false
        addSubview(lcdView)
    }

    deinit {
        latchTimer?.invalidate()
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 40, size.height > 40 else { return }
        let landscape = size.width >= size.height * 1.05
        let layout = LegacyKeyboardLayout(landscape: landscape)
        pad = min(size.width, size.height) * 0.035
        topH = landscape ? size.height * 0.30 : size.height * 0.235
        kbRect = CGRect(x: pad * 1.4, y: topH + pad * 0.8,
                        width: size.width - pad * 2.8, height: size.height - topH - pad * 2.0)
        let g = LegacyKeyboardGeometry(layout: layout, rect: kbRect)
        geometry = g
        keys = model.keys.map { (spec: $0, rect: g.keyRect($0), zones: g.zones($0)) }

        let lcdW = landscape ? size.width * 0.52 : size.width - pad * 4
        let lcdH = landscape ? topH * 0.48 : min(topH * 0.48, lcdW * 0.22)
        let lcdX = landscape ? size.width * 0.14 : pad * 2
        let lcdY = (topH - lcdH) / 2 + pad * 0.3
        lcdView.model = model
        lcdView.frame = CGRect(x: lcdX, y: lcdY, width: lcdW, height: lcdH).integral
        setNeedsDisplay()
    }

    // MARK: drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let g = geometry else { return }
        let c = model.colors
        let size = bounds.size

        // body
        ctx.saveGState()
        UIBezierPath(roundedRect: bounds, cornerRadius: pad * 1.2).addClip()
        LegacyDraw.verticalGradient(ctx, in: bounds,
                                    top: UIColor(rgb: c.body, alpha: 0.92),
                                    bottom: UIColor(rgb: c.body))
        ctx.restoreGState()

        // display bezel (the LCD view is a subview, drawn after this)
        UIColor(rgb: c.bezel).setFill()
        UIBezierPath(roundedRect: lcdView.frame.insetBy(dx: -pad * 0.8, dy: -pad * 0.7),
                     cornerRadius: pad * 0.6).fill()

        // the metal band around the keyboard
        let band = UIBezierPath(roundedRect: CGRect(x: kbRect.minX - pad * 0.45, y: kbRect.minY - pad * 0.35,
                                                    width: kbRect.width + pad * 0.9, height: kbRect.height + pad * 0.7),
                                cornerRadius: pad * 0.5)
        UIColor(rgb: c.band).setStroke()
        band.lineWidth = max(2, pad * 0.22)
        band.stroke()

        drawModelName(g)
        drawLegends(g)
        for k in keys {
            drawKey(k.spec, rect: k.rect, unit: g.keyH)
        }
        _ = size
    }

    private func drawModelName(_ g: LegacyKeyboardGeometry) {
        let c = model.colors
        let size = bounds.size
        let landscape = g.layout.landscape
        let nameSize = max(10, topH * (landscape ? 0.20 : 0.13))
        let subSize = max(7, topH * (landscape ? 0.075 : 0.05))
        let width = landscape ? size.width * 0.22 : size.width * 0.5
        let x = landscape ? size.width * 0.73 : size.width * 0.5 - pad * 2
        let y = landscape ? lcdView.frame.minY : lcdView.frame.maxY + pad * 0.9
        let nameRect = CGRect(x: x, y: y, width: width, height: nameSize * 1.4)
        let subRect = CGRect(x: x, y: nameRect.maxY, width: width, height: subSize * 1.6)
        LegacyDraw.text(model.name, in: nameRect, size: nameSize, color: UIColor(rgb: c.band),
                        weight: .bold, alignment: .right)
        LegacyDraw.text(model.subtitle.uppercased(), in: subRect, size: subSize,
                        color: UIColor(rgb: c.band, alpha: 0.8), weight: .semibold, alignment: .right)
    }

    private func drawLegends(_ g: LegacyKeyboardGeometry) {
        let c = model.colors
        let fontSize = max(6, g.legendH * 0.50)
        let bracketCodes = Set(model.brackets.flatMap { b in
            model.keys.filter { $0.code >= b.fromCode && $0.code <= b.toCode }.map { $0.code }
        })
        for k in model.keys where !k.f.isEmpty {
            let r = g.legendRect(k)
            let inBracket = bracketCodes.contains(k.code)
            let size = inBracket ? fontSize * 0.85 : fontSize
            let area = inBracket
                ? CGRect(x: r.minX + r.width * 0.02, y: r.minY + r.height * 0.45,
                         width: r.width * 0.96, height: r.height * 0.55)
                : CGRect(x: r.minX + r.width * 0.02, y: r.minY, width: r.width * 0.96, height: r.height)
            LegacyDraw.text(k.f, in: area, size: size, color: UIColor(rgb: c.fLegend), minimum: size * 0.4)
        }
        for seg in bracketSegments(g) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: seg.rect.minX, y: seg.rect.maxY))
            path.addLine(to: CGPoint(x: seg.rect.minX, y: seg.rect.minY))
            path.addLine(to: CGPoint(x: seg.rect.maxX, y: seg.rect.minY))
            path.addLine(to: CGPoint(x: seg.rect.maxX, y: seg.rect.maxY))
            UIColor(rgb: c.fLegend).setStroke()
            path.lineWidth = 1
            path.stroke()

            let labelRect = CGRect(x: seg.rect.minX, y: seg.rect.minY - seg.rect.height * 0.45,
                                   width: seg.rect.width, height: seg.rect.height * 0.9)
            UIColor(rgb: c.body).setFill()
            UIBezierPath(rect: labelRect).fill()
            LegacyDraw.text(seg.label, in: labelRect, size: fontSize * 0.8,
                            color: UIColor(rgb: c.fLegend), weight: .bold)
        }
    }

    private struct BracketSegment { let label: String; let rect: CGRect }

    /// Brackets split into one piece per display row.
    private func bracketSegments(_ g: LegacyKeyboardGeometry) -> [BracketSegment] {
        var out: [BracketSegment] = []
        for b in model.brackets {
            let ks = model.keys.filter { $0.code >= b.fromCode && $0.code <= b.toCode }
            var rows: [Int: [KeySpec]] = [:]
            for k in ks { rows[g.layout.place(k).row, default: []].append(k) }
            for (_, group) in rows.sorted(by: { $0.key < $1.key }) {
                let rects = group.map { g.legendRect($0) }
                guard let minX = rects.map({ $0.minX }).min(),
                      let maxX = rects.map({ $0.maxX }).max(),
                      let y = rects.first?.minY else { continue }
                out.append(BracketSegment(label: b.label,
                                          rect: CGRect(x: minX + g.cellW * 0.12, y: y + g.legendH * 0.22,
                                                       width: maxX - minX - g.cellW * 0.24,
                                                       height: g.legendH * 0.40)))
            }
        }
        return out
    }

    private func drawKey(_ spec: KeySpec, rect: CGRect, unit: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = model.colors
        let shownCode = spec.code == 35 ? 25 : spec.code
        let down = pressed.contains(shownCode)
        let frontH = KeyZones.drawnFrontHeight(keyHeight: rect.height, unit: unit, isEnter: spec.style == .enter)
        let r = rect.offsetBy(dx: 0, dy: down ? rect.height * 0.025 : 0)
        let w = r.width, h = r.height
        let radius = w * 0.08

        // key body / front face
        UIColor(rgb: c.keyFront).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: radius).fill()

        // top face
        let capRect = CGRect(x: r.minX, y: r.minY, width: w, height: h - frontH)
        let cap: UIColor
        switch spec.style {
        case .fShift: cap = UIColor(rgb: c.fKey)
        case .gShift: cap = UIColor(rgb: c.gKey)
        case .normal, .enter, .on: cap = UIColor(rgb: c.keyCap)
        }
        ctx.saveGState()
        UIBezierPath(roundedRect: capRect, cornerRadius: w * 0.07).addClip()
        LegacyDraw.verticalGradient(ctx, in: capRect, top: cap.withAlphaComponent(0.95), bottom: cap)
        ctx.restoreGState()

        if down {
            UIColor(white: 0, alpha: 0.18).setFill()
            UIBezierPath(roundedRect: r, cornerRadius: radius).fill()
        }

        // the key's label
        let faceColor = (spec.style == .fShift || spec.style == .gShift) ? UIColor(rgb: 0x1E1A17) : .white
        let base = min(capRect.height * 0.48, unit * 0.40)
        let size = spec.face.count > 3 ? base * 0.72 : base
        LegacyDraw.text(spec.face, in: capRect.insetBy(dx: w * 0.06, dy: 0),
                        size: size, color: faceColor, minimum: 5)

        // the blue legend on the front face
        if !spec.g.isEmpty {
            let frontRect = CGRect(x: r.minX, y: r.minY + h - frontH, width: w, height: frontH)
            LegacyDraw.text(spec.g, in: frontRect, size: unit * 0.22,
                            color: UIColor(rgb: c.gLegend), weight: .medium, minimum: 5)
        }

        // a latched key is outlined in gold
        if latched.contains(shownCode) {
            let ring = UIBezierPath(roundedRect: r, cornerRadius: radius)
            UIColor(rgb: 0xE3A63A).setStroke()
            ring.lineWidth = max(1.5, unit * 0.06)
            ring.stroke()
        }
    }

    // MARK: touches

    private func hit(_ point: CGPoint) -> (spec: KeySpec, part: KeyPart)? {
        for k in keys {
            if let part = k.zones.part(at: point) { return (k.spec, part) }
        }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let found = hit(t.location(in: self)) else { return }
        active = (found.spec.code, found.part)
        latchedByTouch = false
        touching = true
        onPress?(found.spec.code, found.part)
        latchTimer?.invalidate()
        latchTimer = Timer.scheduledTimer(timeInterval: 0.8, target: self,
                                          selector: #selector(latchFired), userInfo: nil, repeats: false)
    }

    @objc private func latchFired() {
        guard touching, let a = active, !latchedByTouch else { return }
        latchedByTouch = true
        onLatch?(a.code)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    private func finishTouch() {
        latchTimer?.invalidate()
        latchTimer = nil
        touching = false
        guard let a = active else { return }
        active = nil
        if !latchedByTouch { onRelease?(a.code) }
        latchedByTouch = false
    }
}
