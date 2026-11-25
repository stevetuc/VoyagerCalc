// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LegacyDrawing.swift - the small drawing helpers the iOS 12 face needs: colours from the model's
// 0xRRGGBB values (the SwiftUI app's Color(rgb:)), vertical gradients, and text that shrinks to fit
// the space (SwiftUI's minimumScaleFactor).

import UIKit

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum LegacyDraw {
    /// Fill `rect` of the current context with a top-to-bottom two-colour gradient.
    static func verticalGradient(_ ctx: CGContext, in rect: CGRect, top: UIColor, bottom: UIColor) {
        let colors = [top.cgColor, bottom.cgColor] as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
            top.setFill(); ctx.fill(rect); return
        }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY),
                               options: [])
        ctx.restoreGState()
    }

    static func attributes(_ font: UIFont, _ color: UIColor, alignment: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    /// A font size that makes `text` fit `width` (down to `minimum`), like minimumScaleFactor.
    static func fittedSize(_ text: String, from size: CGFloat, width: CGFloat, minimum: CGFloat, weight: UIFont.Weight = .semibold) -> CGFloat {
        var s = size
        while s > minimum {
            let w = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: s, weight: weight)]).width
            if w <= width { break }
            s *= 0.94
        }
        return max(minimum, s)
    }

    /// Draw text centred in `rect`, shrinking it if needed.
    static func text(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor,
                     weight: UIFont.Weight = .semibold, minimum: CGFloat = 5,
                     alignment: NSTextAlignment = .center) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let s = fittedSize(text, from: size, width: rect.width, minimum: minimum, weight: weight)
        let font = UIFont.systemFont(ofSize: s, weight: weight)
        let h = (text as NSString).size(withAttributes: [.font: font]).height
        let line = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h + 1)
        (text as NSString).draw(in: line, withAttributes: attributes(font, color, alignment: alignment))
    }
}
