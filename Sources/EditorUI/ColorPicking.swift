import AppKit
import CoreModels
import EditorEngine

/// The magnifier that follows the pointer while picking a colour: the pixels around the pointer, enlarged, with the one that
/// will be picked outlined, and its colour value underneath. Drawn on the canvas, in image coordinates.
@MainActor
enum ColorLoupe {
    /// 13 x 13 pixels are shown, each as a square of `cell` screen points.
    static let radius = 6
    static let cell: CGFloat = 9
    private static let gap: CGFloat = 26                  // from the pointer to the loupe, so the pointer stays visible
    private static let labelHeight: CGFloat = 24

    private static var side: CGFloat { cell * CGFloat(2 * radius + 1) }

    /// Everything the loupe covers for a pointer at `point` (in image pixels), so only that part of the canvas is redrawn.
    static func area(around point: CGPoint, unit: CGFloat, bounds: CGRect) -> CGRect {
        let placed = origin(for: point, unit: unit, bounds: bounds)
        return CGRect(x: placed.x, y: placed.y, width: side * unit, height: (side + 6 + labelHeight) * unit).insetBy(dx: -8 * unit, dy: -8 * unit)
    }

    /// The loupe sits to the lower right of the pointer, and swaps sides near the edges of the picture.
    private static func origin(for point: CGPoint, unit: CGFloat, bounds: CGRect) -> CGPoint {
        var x = point.x + gap * unit
        var y = point.y + gap * unit
        if x + side * unit > bounds.maxX { x = point.x - (gap + side) * unit }
        if y + (side + 6 + labelHeight) * unit > bounds.maxY { y = point.y - (gap + side + 6 + labelHeight) * unit }
        return CGPoint(x: max(x, bounds.minX), y: max(y, bounds.minY))
    }

    static func draw(sampler: PixelSampler, at point: CGPoint, in context: CGContext, unit: CGFloat, bounds: CGRect) {
        let patch = sampler.patch(around: point, radius: radius)
        guard let centre = patch[radius][radius] else { return }
        let origin = origin(for: point, unit: unit, bounds: bounds)
        let size = side * unit
        let circle = CGRect(x: origin.x, y: origin.y, width: size, height: size)

        context.saveGState()
        // A soft shadow, then the magnified pixels clipped to a circle.
        context.setShadow(offset: CGSize(width: 0, height: 2 * unit), blur: 8 * unit, color: CGColor(gray: 0, alpha: 0.4))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0)
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        let step = cell * unit
        for (row, line) in patch.enumerated() {
            for (column, color) in line.enumerated() {
                let box = CGRect(x: circle.minX + CGFloat(column) * step, y: circle.minY + CGFloat(row) * step, width: step, height: step)
                if let color {
                    context.setFillColor(color.cgColor)
                } else {
                    context.setFillColor(CGColor(gray: 0.15, alpha: 1))                // outside the picture
                }
                context.fill(box)
            }
        }
        // Faint grid, so single pixels can be told apart.
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.25))
        context.setLineWidth(0.5 * unit)
        for i in 0...(2 * radius + 1) {
            let offset = CGFloat(i) * step
            context.move(to: CGPoint(x: circle.minX + offset, y: circle.minY)); context.addLine(to: CGPoint(x: circle.minX + offset, y: circle.maxY))
            context.move(to: CGPoint(x: circle.minX, y: circle.minY + offset)); context.addLine(to: CGPoint(x: circle.maxX, y: circle.minY + offset))
        }
        context.strokePath()
        // The pixel that will be picked.
        let middle = CGRect(x: circle.minX + CGFloat(radius) * step, y: circle.minY + CGFloat(radius) * step, width: step, height: step)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(2.5 * unit); context.stroke(middle.insetBy(dx: -unit, dy: -unit))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(1.2 * unit); context.stroke(middle.insetBy(dx: -unit, dy: -unit))
        context.restoreGState()
        // Ring.
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); context.setLineWidth(3 * unit); context.strokeEllipse(in: circle.insetBy(dx: 1.5 * unit, dy: 1.5 * unit))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.5)); context.setLineWidth(1 * unit); context.strokeEllipse(in: circle)
        context.restoreGState()

        // The value, in a small chip under the loupe: a swatch of the colour and its hex code.
        let text = String(centre.hex.prefix(7)).uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11 * unit, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let chipWidth = textSize.width + (14 + 10 + 8 + 8) * unit
        let chip = CGRect(x: circle.midX - chipWidth / 2, y: circle.maxY + 6 * unit, width: chipWidth, height: labelHeight * unit)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 8 * unit, yRadius: 8 * unit).fill()
        let swatch = CGRect(x: chip.minX + 8 * unit, y: chip.midY - 7 * unit, width: 14 * unit, height: 14 * unit)
        context.setFillColor(centre.cgColor); context.fillEllipse(in: swatch)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); context.setLineWidth(1.2 * unit); context.strokeEllipse(in: swatch)
        (text as NSString).draw(at: CGPoint(x: swatch.maxX + 8 * unit, y: chip.midY - textSize.height / 2), withAttributes: attributes)
    }
}

/// The eyedropper pointer: the tip is the hot spot.
@MainActor
enum EyedropperCursor {
    static let cursor: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let symbol else { return false }
            // A white outline (the symbol drawn slightly offset in white), then the symbol in black on top, so it reads on any picture.
            for offset in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                symbol.tinted(.white).draw(in: NSRect(x: 2 + CGFloat(offset.0), y: 2 + CGFloat(offset.1), width: 22, height: 22))
            }
            symbol.tinted(.black).draw(in: NSRect(x: 2, y: 2, width: 22, height: 22))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: size.height - 3))     // the tip points to the lower left
    }()
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return result
    }
}
