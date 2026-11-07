import AppKit
import DesignSystem

/// Draws the working image 1:1 (one view unit = one image pixel); the scroll view provides the zoom.
/// Shows a checkerboard behind transparent images.
@MainActor
final class CanvasView: NSView {
    var image: CGImage? {
        didSet {
            hasTransparency = image.map(Self.hasTransparentPixels) ?? false
            setFrameSize(NSSize(width: image?.width ?? 0, height: image?.height ?? 0))
            needsDisplay = true
        }
    }
    private var hasTransparency = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let backing = window?.backingScaleFactor ?? 2
        let devicePixelsPerImagePixel = (enclosingScrollView?.magnification ?? 1) * backing

        if hasTransparency { drawCheckerboard(in: dirtyRect.intersection(bounds), square: 8 / devicePixelsPerImagePixel, context) }

        context.saveGState()
        // Crisp pixels when zoomed in, smooth when zoomed out.
        context.interpolationQuality = devicePixelsPerImagePixel >= 1 ? .none : .high
        context.translateBy(x: 0, y: bounds.height)   // the view is flipped; images are drawn y-up
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    private func drawCheckerboard(in rect: CGRect, square: CGFloat, _ context: CGContext) {
        guard !rect.isEmpty, square > 0 else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        let firstRow = Int((rect.minY / square).rounded(.down)), lastRow = Int((rect.maxY / square).rounded(.up))
        let firstCol = Int((rect.minX / square).rounded(.down)), lastCol = Int((rect.maxX / square).rounded(.up))
        for row in firstRow..<lastRow {
            for col in firstCol..<lastCol where (row + col) & 1 == 1 {
                context.fill(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square)
                    .intersection(rect))
            }
        }
    }

    /// True if any pixel is not fully opaque (stops at the first one found).
    static func hasTransparentPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return false }
        var row = [UInt8](repeating: 0, count: w * 4)
        // Check one row at a time so a huge image never needs a second full-size buffer.
        for y in 0..<h {
            let found: Bool = row.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: 1))
                ctx.draw(image, in: CGRect(x: 0, y: -(h - 1 - y), width: w, height: h))
                let bytes = buffer.bindMemory(to: UInt8.self)
                var i = 3
                while i < w * 4 { if bytes[i] != 255 { return true }; i += 4 }
                return false
            }
            if found { return true }
        }
        return false
    }
}

/// Keeps a document that is smaller than the window centered.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        }
        return rect
    }
}
