import CoreGraphics
import CoreModels
import Foundation

/// One JSON style for everything saved, with sorted keys so files are stable and diff-friendly.
public enum AnnotationJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

// MARK: - Drawing helpers

extension CGContext {
    /// Sets stroke color, width, dash and round caps/joins from a style.
    func applyStroke(_ style: AnnotationStyle) {
        setStrokeColor(style.strokeColor.cgColor)
        setLineWidth(CGFloat(style.lineWidth))
        setLineCap(.round)
        setLineJoin(.round)
        setLineDash(phase: 0, lengths: style.dash.pattern(lineWidth: CGFloat(style.lineWidth)))
    }

}

/// Coordinates are kept to a thousandth of a pixel, so repeated moves and resizes do not pile up floating-point noise.
private func tidy(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }
private func tidy(_ p: CGPoint) -> CGPoint { CGPoint(x: tidy(p.x), y: tidy(p.y)) }
private func tidy(_ r: CGRect) -> CGRect { CGRect(x: tidy(r.minX), y: tidy(r.minY), width: tidy(r.width), height: tidy(r.height)) }

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

private func boundingRect(of points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .zero }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in points {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// MARK: - Rectangle (also rounded)

public struct RectangleShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "rectangle"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }

    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        let radius = min(CGFloat(style.cornerRadius), min(rect.width, rect.height) / 2)
        let path = radius > 0
            ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            : CGPath(rect: rect, transform: nil)
        if style.fillColor.alpha > 0 {
            context.setFillColor(style.fillColor.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        if style.lineWidth > 0, style.strokeColor.alpha > 0 {
            context.applyStroke(style)
            context.addPath(path)
            context.strokePath()
        }
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        let reach = tolerance + CGFloat(style.lineWidth) / 2
        if style.fillColor.alpha > 0, rect.insetBy(dx: -reach, dy: -reach).contains(point) { return true }
        // Unfilled: only the outline counts, so clicking inside selects whatever is underneath.
        let outer = rect.insetBy(dx: -reach, dy: -reach)
        let inner = rect.insetBy(dx: reach, dy: reach)
        return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        RectangleShape(rect: tidy(rect.applying(transform)))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

// MARK: - Ellipse (also circle)

public struct EllipseShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "ellipse"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }

    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        if style.fillColor.alpha > 0 {
            context.setFillColor(style.fillColor.cgColor)
            context.fillEllipse(in: rect)
        }
        if style.lineWidth > 0, style.strokeColor.alpha > 0 {
            context.applyStroke(style)
            context.strokeEllipse(in: rect)
        }
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        let reach = tolerance + CGFloat(style.lineWidth) / 2
        let rx = rect.width / 2 + reach, ry = rect.height / 2 + reach
        guard rx > 0, ry > 0 else { return false }
        let nx = (point.x - rect.midX) / rx, ny = (point.y - rect.midY) / ry
        let outside = nx * nx + ny * ny
        if style.fillColor.alpha > 0 { return outside <= 1 }
        let irx = rect.width / 2 - reach, iry = rect.height / 2 - reach
        guard irx > 0, iry > 0 else { return outside <= 1 }
        let ix = (point.x - rect.midX) / irx, iy = (point.y - rect.midY) / iry
        return outside <= 1 && ix * ix + iy * iy >= 1
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        EllipseShape(rect: tidy(rect.applying(transform)))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

// MARK: - Line, arrow, double arrow

/// A straight line. What its two ends look like (arrowheads and so on) comes from the style, so one shape covers
/// plain lines, arrows and double arrows.
public struct LineShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "line"
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    public var geometryBounds: CGRect { boundingRect(of: [start, end]) }

    public var extraHandles: [CGPoint] { [start, end] }
    public var handlesReplaceBounds: Bool { true }

    public func movingHandle(_ index: Int, to point: CGPoint) -> any AnnotationShape {
        // Holding the other end still, a drag may land anywhere; the caller snaps to angles when Shift is held.
        index == 0 ? LineShape(start: point, end: end) : LineShape(start: start, end: point)
    }

    static func headLength(for style: AnnotationStyle) -> CGFloat { max(12, CGFloat(style.lineWidth) * 3.5) }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        guard style.strokeColor.alpha > 0 else { return }
        context.applyStroke(style)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        drawHead(at: end, from: start, kind: style.endHead, in: context, style: style)
        drawHead(at: start, from: end, kind: style.startHead, in: context, style: style)
    }

    private func drawHead(at tip: CGPoint, from tail: CGPoint, kind: ArrowHeadStyle, in context: CGContext, style: AnnotationStyle) {
        guard kind != .none else { return }
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = Self.headLength(for: style)
        let ux = cos(angle), uy = sin(angle)                  // along the line, toward the tip
        let nx = -uy, ny = ux                                 // across it
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - ux * along + nx * across, y: tip.y - uy * along + ny * across)
        }
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(style.strokeColor.cgColor)
        switch kind {
        case .none: break
        case .filled:
            let spread = length * 0.45
            context.move(to: tip); context.addLine(to: point(length, spread)); context.addLine(to: point(length, -spread)); context.closePath()
            context.drawPath(using: .fillStroke)
        case .open:
            let spread = length * 0.45
            context.move(to: point(length, spread)); context.addLine(to: tip); context.addLine(to: point(length, -spread))
            context.strokePath()
        case .diamond:
            let half = length * 0.5, spread = length * 0.32
            context.move(to: tip); context.addLine(to: point(half, spread)); context.addLine(to: point(length, 0)); context.addLine(to: point(half, -spread))
            context.closePath()
            context.drawPath(using: .fillStroke)
        case .dot:
            let r = length * 0.32
            let center = point(r, 0)
            context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        case .bar:
            let half = length * 0.5
            context.move(to: point(0, half)); context.addLine(to: point(0, -half))
            context.strokePath()
        }
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        var reach = tolerance + CGFloat(style.lineWidth) / 2
        if style.endHead != .none || style.startHead != .none { reach = max(reach, Self.headLength(for: style) / 3) }
        return distance(from: point, toSegment: start, end) <= reach
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        LineShape(start: tidy(start.applying(transform)), end: tidy(end.applying(transform)))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

// MARK: - Pencil (freehand)

public struct PencilShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "pencil"
    public var points: [CGPoint]

    public init(points: [CGPoint]) { self.points = points }

    public var geometryBounds: CGRect { boundingRect(of: points) }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        guard let first = points.first, style.strokeColor.alpha > 0 else { return }
        context.applyStroke(style)
        if points.count == 1 {                                    // a dot
            let r = CGFloat(style.lineWidth) / 2
            context.setFillColor(style.strokeColor.cgColor)
            context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r))
            return
        }
        // Smooth the line by curving through the midpoints between samples.
        context.move(to: first)
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            if i == 1 { context.addLine(to: mid) } else { context.addQuadCurve(to: mid, control: points[i - 1]) }
        }
        context.addLine(to: points[points.count - 1])
        context.strokePath()
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        let reach = tolerance + CGFloat(style.lineWidth) / 2
        if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
        for i in 1..<points.count where distance(from: point, toSegment: points[i - 1], points[i]) <= reach { return true }
        return false
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        PencilShape(points: points.map { tidy($0.applying(transform)) })
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

// MARK: - Highlighter (translucent marker over a rectangle)

public struct HighlighterShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "highlighter"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }

    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        // Multiply keeps the text underneath readable, like a real marker.
        context.setBlendMode(.multiply)
        context.setFillColor(style.strokeColor.cgColor)
        context.fill(rect)
        context.setBlendMode(.normal)
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        HighlighterShape(rect: tidy(rect.applying(transform)))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
