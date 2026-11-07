import CoreGraphics

/// The selected part of the picture, in image pixels (origin top-left).
public enum EditorSelection: Equatable, Sendable {
    case rect(CGRect)
    case freehand([CGPoint])

    public var bounds: CGRect {
        switch self {
        case .rect(let r): return r
        case .freehand(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}

public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    /// Dragging inside the selection moves it.
    case move
}

/// Geometry for creating and editing a rectangular selection. Pure, so it is unit-tested.
public enum RectSelectionEditing {
    /// The rectangle spanned by two points (any direction), snapped to whole pixels and kept inside `bounds`.
    /// Returns nil if it would be empty.
    public static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect? {
        let x0 = clamp(min(a.x, b.x).rounded(.down), bounds.minX, bounds.maxX)
        let y0 = clamp(min(a.y, b.y).rounded(.down), bounds.minY, bounds.maxY)
        let x1 = clamp(max(a.x, b.x).rounded(.up), bounds.minX, bounds.maxX)
        let y1 = clamp(max(a.y, b.y).rounded(.up), bounds.minY, bounds.maxY)
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Which part of `rect` is under `point`: corners first, then edges, then the inside (move).
    /// `tolerance` is in image pixels (callers convert from screen pixels using the zoom).
    public static func hitTest(rect: CGRect, point: CGPoint, tolerance: CGFloat) -> SelectionHandle? {
        let nearLeft = abs(point.x - rect.minX) <= tolerance
        let nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearTop = abs(point.y - rect.minY) <= tolerance
        let nearBottom = abs(point.y - rect.maxY) <= tolerance
        let withinX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let withinY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        if rect.contains(point) { return .move }
        return nil
    }

    /// The rectangle after dragging `handle` by `delta` from `start`, snapped to pixels and kept inside `bounds`.
    /// Dragging an edge past the opposite edge flips the rectangle rather than collapsing it.
    public static func dragged(_ start: CGRect, handle: SelectionHandle, by delta: CGSize, within bounds: CGRect) -> CGRect {
        if handle == .move {
            let x = clamp((start.minX + delta.width).rounded(), bounds.minX, bounds.maxX - start.width)
            let y = clamp((start.minY + delta.height).rounded(), bounds.minY, bounds.maxY - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
        switch handle {
        case .topLeft: left += delta.width; top += delta.height
        case .top: top += delta.height
        case .topRight: right += delta.width; top += delta.height
        case .right: right += delta.width
        case .bottomRight: right += delta.width; bottom += delta.height
        case .bottom: bottom += delta.height
        case .bottomLeft: left += delta.width; bottom += delta.height
        case .left: left += delta.width
        case .move: break
        }
        let result = rect(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: bottom), within: bounds)
        return result ?? start
    }

    /// The eight resize handles of an object's bounds: only the small squares at the corners and edge midpoints grab,
    /// so the outline between them stays free for moving the object.
    public static func handleHit(rect: CGRect, point: CGPoint, tolerance: CGFloat) -> SelectionHandle? {
        let handles: [(SelectionHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)), (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
        return handles
            .map { ($0.0, hypot(point.x - $0.1.x, point.y - $0.1.y)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// The scale-and-move that turns `old` into `new`. An axis where `old` has no extent (a horizontal line)
    /// is only moved, never scaled, so nothing divides by zero.
    public static func transform(from old: CGRect, to new: CGRect) -> CGAffineTransform {
        let sx = old.width > 0 ? new.width / old.width : 1
        let sy = old.height > 0 ? new.height / old.height : 1
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: new.minX - old.minX * sx, ty: new.minY - old.minY * sy)
    }

    /// Moves or resizes with the arrow keys: plain arrows move, Shift+arrows (`resize`) change width/height.
    public static func nudged(_ rect: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, within bounds: CGRect) -> CGRect {
        if resize {
            let size = CGSize(width: max(1, rect.width + dx), height: max(1, rect.height + dy))
            return CGRect(origin: rect.origin, size: CGSize(width: min(size.width, bounds.maxX - rect.minX),
                                                              height: min(size.height, bounds.maxY - rect.minY)))
        }
        return dragged(rect, handle: .move, by: CGSize(width: dx, height: dy), within: bounds)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
}

/// Collects a freehand outline. Points closer than one pixel are skipped.
public struct FreehandPath: Equatable, Sendable {
    public private(set) var points: [CGPoint] = []
    private let bounds: CGRect

    public init(start: CGPoint, within bounds: CGRect) {
        self.bounds = bounds
        points = [Self.clamp(start, bounds)]
    }

    public mutating func append(_ point: CGPoint) {
        let p = Self.clamp(point, bounds)
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1 { return }
        points.append(p)
    }

    /// The finished outline, or nil if it is too small to select anything.
    public func finished() -> [CGPoint]? {
        let box = EditorSelection.freehand(points).bounds
        guard points.count >= 3, box.width >= 2, box.height >= 2 else { return nil }
        return points
    }

    private static func clamp(_ p: CGPoint, _ b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }
}
