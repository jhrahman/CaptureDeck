import CoreGraphics
import Foundation

/// A stroke painted over the picture that hides what is under it: blurred, pixelated or covered. The brush size is the
/// style's line width, the effect strength is the style's strength, the mode is the style's redaction, and a solid cover
/// uses the stroke color.
///
/// It is vector: the pixels are only changed when the picture is exported, so a stroke can be undone, moved or deleted.
public struct RedactBrushShape: BackdropAnnotationShape, Codable, Equatable {
    public static let typeID = "redactBrush"
    public var points: [CGPoint]

    public init(points: [CGPoint]) { self.points = points }

    public var geometryBounds: CGRect { boundingRect(of: points) }

    public func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage) {
        guard let first = points.first else { return }
        let diameter = max(CGFloat(style.lineWidth), 1)
        context.saveGState()
        // Clip to the painted area, then fill that area with the effect.
        if points.count == 1 {
            context.addEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter))
            context.clip()
        } else {
            StrokeSmoothing.addSmoothPath(through: points, to: context)
            context.setLineWidth(diameter)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
            context.clip()
        }
        switch style.redaction {
        case .solid:
            context.setFillColor(style.strokeColor.alpha > 0 ? style.strokeColor.cgColor : CGColor(gray: 0, alpha: 1))
            context.fill(context.boundingBoxOfClipPath)
        case .blur:
            PixelEffects.drawThroughClip(.blur, strength: style.strength, backdrop: backdrop, in: context)
        case .pixelate:
            PixelEffects.drawThroughClip(.pixelate, strength: style.strength, backdrop: backdrop, in: context)
        }
        context.restoreGState()
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        let reach = tolerance + CGFloat(style.lineWidth) / 2
        if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
        for i in 1..<points.count where distance(from: point, toSegment: points[i - 1], points[i]) <= reach { return true }
        return false
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        RedactBrushShape(points: points.map { CGPoint(x: (($0.applying(transform)).x * 1000).rounded() / 1000, y: (($0.applying(transform)).y * 1000).rounded() / 1000) })
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
