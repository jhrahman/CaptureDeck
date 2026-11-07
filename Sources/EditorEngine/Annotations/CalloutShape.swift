import CoreGraphics
import Foundation

/// A text bubble with a pointed tail, to point at something in the picture.
///
/// The bubble's fill is the style's `fillColor`, its outline `strokeColor` / `lineWidth`, and its text `textColor`.
/// `oval` makes the body an ellipse instead of a rounded rectangle (`cornerRadius` sets the rounding).
/// The tail runs from the body to `tip`; drag the tip to aim it. If the tip is inside the body there is no tail.
public struct CalloutShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "callout"
    public var rect: CGRect
    public var text: String
    public var tip: CGPoint
    public var oval: Bool

    public init(rect: CGRect, text: String, tip: CGPoint, oval: Bool = false) {
        self.rect = rect.standardized
        self.text = text
        self.tip = tip
        self.oval = oval
    }

    /// Space between the bubble's edge and its text.
    public static func padding(oval: Bool, in rect: CGRect) -> CGSize {
        oval ? CGSize(width: max(14, rect.width * 0.14), height: max(10, rect.height * 0.14)) : CGSize(width: 14, height: 12)
    }

    /// The area the text is laid out in.
    public var textRect: CGRect {
        let pad = Self.padding(oval: oval, in: rect)
        return rect.insetBy(dx: pad.width, dy: pad.height)
    }

    /// A body tall enough for the text at the given width.
    public static func fittingRect(origin: CGPoint, width: CGFloat, text: String, style: AnnotationStyle, oval: Bool) -> CGRect {
        let probe = CGRect(x: 0, y: 0, width: width, height: 100)
        let pad = padding(oval: oval, in: probe)
        let size = TextRenderer.suggestedSize(of: text, style: style, width: width - 2 * pad.width)
        // An oval needs more height for the same text, since its corners are cut off.
        let height = (ceil(size.height) + 2 * pad.height) * (oval ? 1.25 : 1)
        return CGRect(x: origin.x, y: origin.y, width: width, height: max(height, 40))
    }

    // MARK: Geometry

    public var geometryBounds: CGRect { rect.union(CGRect(x: tip.x, y: tip.y, width: 0, height: 0)) }

    /// The tail as a triangle (two points on the body, then the tip), or nil if the tip is inside the body.
    public static func tail(rect: CGRect, oval: Bool, tip: CGPoint) -> [CGPoint]? {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = tip.x - c.x, dy = tip.y - c.y
        let length = hypot(dx, dy)
        guard length > 0, rect.width > 0, rect.height > 0 else { return nil }

        // How far along the line from the center to the tip the body's edge lies (1 = at the tip).
        let edge: CGFloat
        if oval {
            let rx = rect.width / 2, ry = rect.height / 2
            edge = 1 / sqrt((dx / rx) * (dx / rx) + (dy / ry) * (dy / ry))
        } else {
            edge = min(dx != 0 ? rect.width / 2 / abs(dx) : .infinity, dy != 0 ? rect.height / 2 / abs(dy) : .infinity)
        }
        guard edge < 1 else { return nil }                                  // tip is inside the body

        let base = CGPoint(x: c.x + dx * edge * 0.94, y: c.y + dy * edge * 0.94)    // slightly inside, so the join is hidden
        let half = min(max(min(rect.width, rect.height) * 0.2, 10), 36)
        let px = -dy / length * half, py = dx / length * half
        return [CGPoint(x: base.x + px, y: base.y + py), CGPoint(x: base.x - px, y: base.y - py), tip]
    }

    private func bodyPath(radius: CGFloat) -> CGPath {
        if oval { return CGPath(ellipseIn: rect, transform: nil) }
        let r = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Body and tail as one outline.
    private func outline(radius: CGFloat) -> CGPath {
        let body = bodyPath(radius: radius)
        guard let points = Self.tail(rect: rect, oval: oval, tip: tip) else { return body }
        let triangle = CGMutablePath()
        triangle.move(to: points[0]); triangle.addLine(to: points[2]); triangle.addLine(to: points[1]); triangle.closeSubpath()
        return body.union(triangle, using: .winding)
    }

    // MARK: AnnotationShape

    public func draw(in context: CGContext, style: AnnotationStyle) {
        let path = outline(radius: CGFloat(style.cornerRadius))
        let fill = style.fillColor.alpha > 0 ? style.fillColor : .white
        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()
        if style.lineWidth > 0, style.strokeColor.alpha > 0 {
            context.applyStroke(style)
            context.addPath(path)
            context.strokePath()
        }
        var textStyle = style
        textStyle.strokeColor = style.textColor
        TextRenderer.draw(text, in: textRect, style: textStyle, verticallyCentered: true, in: context)
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        let reach = tolerance + CGFloat(style.lineWidth) / 2
        let inflated = rect.insetBy(dx: -reach, dy: -reach)
        if oval {
            let rx = inflated.width / 2, ry = inflated.height / 2
            if rx > 0, ry > 0 {
                let nx = (point.x - inflated.midX) / rx, ny = (point.y - inflated.midY) / ry
                if nx * nx + ny * ny <= 1 { return true }
            }
        } else if inflated.contains(point) {
            return true
        }
        guard let t = Self.tail(rect: rect, oval: oval, tip: tip) else { return false }
        return Self.triangle(t, contains: point, margin: reach)
    }

    private static func triangle(_ t: [CGPoint], contains p: CGPoint, margin: CGFloat) -> Bool {
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y) }
        let d1 = side(p, t[0], t[1]), d2 = side(p, t[1], t[2]), d3 = side(p, t[2], t[0])
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0, hasPos = d1 > 0 || d2 > 0 || d3 > 0
        if !(hasNeg && hasPos) { return true }
        // Just outside: close enough to an edge counts (thin tails are hard to click).
        let edges = [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])]
        return edges.contains { a, b in
            let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let u = l2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0), 1) : 0
            return hypot(p.x - (a.x + u * dx), p.y - (a.y + u * dy)) <= margin
        }
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        let r = rect.applying(transform)
        let t = tip.applying(transform)
        func tidy(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }
        return CalloutShape(rect: CGRect(x: tidy(r.minX), y: tidy(r.minY), width: tidy(r.width), height: tidy(r.height)),
                            text: text, tip: CGPoint(x: tidy(t.x), y: tidy(t.y)), oval: oval)
    }

    public var extraHandles: [CGPoint] { [tip] }

    public func movingHandle(_ index: Int, to point: CGPoint) -> any AnnotationShape {
        guard index == 0 else { return self }
        return CalloutShape(rect: rect, text: text, tip: point, oval: oval)
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
