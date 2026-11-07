import CoreGraphics
import Foundation

private func tidyRect(_ r: CGRect) -> CGRect {
    CGRect(x: (r.minX * 1000).rounded() / 1000, y: (r.minY * 1000).rounded() / 1000,
           width: (r.width * 1000).rounded() / 1000, height: (r.height * 1000).rounded() / 1000)
}

/// Dims everything except a region, to draw the eye to it. The dim color is the style's `strokeColor` (black by default)
/// and the dim strength is its `opacity`. `cornerRadius` rounds the bright window (a large radius makes it an oval).
public struct SpotlightShape: BackdropAnnotationShape, Codable, Equatable {
    public static let typeID = "spotlight"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }
    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage) {
        let whole = CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height)
        let radius = min(CGFloat(style.cornerRadius), min(rect.width, rect.height) / 2)
        let window = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let path = CGMutablePath()
        path.addRect(whole)
        path.addPath(window)
        context.setFillColor(style.strokeColor.cgColor)
        context.addPath(path)
        context.fillPath(using: .evenOdd)                  // the area outside the window, not the window itself
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape { SpotlightShape(rect: tidyRect(rect.applying(transform))) }
    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

/// A round lens that shows the picture underneath it enlarged. The zoom is the style's `strength` (2 = twice as big);
/// the border uses `strokeColor` and `lineWidth`.
public struct MagnifierShape: BackdropAnnotationShape, Codable, Equatable {
    public static let typeID = "magnifier"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }
    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let zoom = max(CGFloat(style.strength), 1)
        let h = CGFloat(backdrop.height)
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        // Scale the picture up around the lens center so the pixels under the lens fill it.
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.translateBy(x: 0, y: h)                        // our space is y-down; images draw y-up
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(backdrop, in: CGRect(x: 0, y: 0, width: CGFloat(backdrop.width), height: h))
        context.restoreGState()

        if style.lineWidth > 0, style.strokeColor.alpha > 0 {
            context.applyStroke(style)
            context.strokeEllipse(in: rect)
        }
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        let rx = rect.width / 2 + tolerance, ry = rect.height / 2 + tolerance
        guard rx > 0, ry > 0 else { return false }
        let nx = (point.x - rect.midX) / rx, ny = (point.y - rect.midY) / ry
        return nx * nx + ny * ny <= 1
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape { MagnifierShape(rect: tidyRect(rect.applying(transform))) }
    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
