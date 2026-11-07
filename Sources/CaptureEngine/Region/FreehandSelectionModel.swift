import CoreGraphics

/// Pure state for drawing a freehand outline on one display (points, origin top-left).
struct FreehandSelectionModel {
    enum Phase: Equatable { case idle, drawing }

    let bounds: CGRect
    private(set) var phase: Phase = .idle
    private(set) var points: [CGPoint] = []

    init(bounds: CGRect) { self.bounds = bounds }

    var boundingRect: CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    mutating func begin(at point: CGPoint) {
        phase = .drawing
        points = [clamp(point)]
    }

    mutating func add(_ point: CGPoint) {
        guard phase == .drawing, let last = points.last else { return }
        let p = clamp(point)
        // Skip sub-point jitter so the outline stays small.
        if hypot(p.x - last.x, p.y - last.y) >= 1 { points.append(p) }
    }

    /// Mouse released: returns the closed outline, or nil if it is too small to be a region.
    mutating func end(at point: CGPoint) -> [CGPoint]? {
        guard phase == .drawing else { return nil }
        add(point)
        return finish()
    }

    /// Return key.
    mutating func confirm() -> [CGPoint]? {
        guard phase == .drawing else { return nil }
        return finish()
    }

    mutating func reset() {
        phase = .idle
        points = []
    }

    private mutating func finish() -> [CGPoint]? {
        let result = points
        let box = boundingRect
        reset()
        guard result.count >= 3, let box, box.width >= 2, box.height >= 2 else { return nil }
        return result
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }
}
