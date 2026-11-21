import CoreGraphics

/// Turns the jittery points of a hand-drawn stroke into a clean, smooth line.
public enum StrokeSmoothing {
    /// A live low-pass filter for the pointer. Small movements (hand tremor, mouse noise) barely move the line, while quick,
    /// deliberate movements follow the pointer almost exactly, so the line feels steady without feeling slow.
    public struct Stabilizer: Sendable {
        public private(set) var current: CGPoint

        public init(start: CGPoint) { current = start }

        /// `softness` is how far (in the same units as the points) the pointer must move before the line follows it closely.
        public mutating func filter(_ raw: CGPoint, softness: CGFloat) -> CGPoint {
            let distance = hypot(raw.x - current.x, raw.y - current.y)
            guard distance > 0 else { return current }
            let follow = distance / (distance + max(softness, 0.0001))                  // 0 = ignore, 1 = follow exactly
            current = CGPoint(x: current.x + (raw.x - current.x) * follow, y: current.y + (raw.y - current.y) * follow)
            return current
        }
    }

    /// Removes points that do not change the line's shape by more than `tolerance` (Ramer–Douglas–Peucker). A stroke of
    /// thousands of mouse samples becomes a few dozen points, which is smaller to store and faster to draw and hit-test.
    public static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            var farthest = -1
            var farthestDistance = tolerance
            for i in (first + 1)..<last {
                let d = distance(from: points[i], toLine: points[first], points[last])
                if d > farthestDistance { farthestDistance = d; farthest = i }
            }
            if farthest >= 0 {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    /// The path through `points` as smooth cubic curves (Catmull-Rom): it passes through every point, with no corners.
    public static func addSmoothPath(through points: [CGPoint], to context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        guard points.count > 2 else {
            if let last = points.last, points.count == 2 { context.addLine(to: last) }
            return
        }
        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            context.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    private static func distance(from p: CGPoint, toLine a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }
}
