import CoreGraphics

/// Pure state machine for dragging out a rectangle on one display.
/// Coordinates are display points with the origin at the top-left (the overlay view is flipped).
struct RegionSelectionModel {
    enum Phase: Equatable { case idle, dragging }

    let bounds: CGRect
    private(set) var phase: Phase = .idle
    private var fixed = CGPoint.zero    // the corner that stays put
    private var moving = CGPoint.zero   // the corner that follows the mouse
    private var offset = CGPoint.zero   // arrow-key nudges applied on top of the mouse position

    init(bounds: CGRect) { self.bounds = bounds }

    /// The rectangle currently being dragged, if any.
    var selection: CGRect? {
        guard phase == .dragging else { return nil }
        return CGRect(x: min(fixed.x, moving.x), y: min(fixed.y, moving.y),
                      width: abs(fixed.x - moving.x), height: abs(fixed.y - moving.y))
    }

    mutating func begin(at point: CGPoint) {
        phase = .dragging
        fixed = clamp(point)
        moving = fixed
        offset = .zero
    }

    mutating func drag(to point: CGPoint) {
        guard phase == .dragging else { return }
        moving = clamp(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
    }

    /// Tab: make the opposite corner the one that follows the mouse.
    mutating func switchCorner() {
        guard phase == .dragging else { return }
        swap(&fixed, &moving)
        offset = .zero
    }

    /// Arrow keys: move the active corner by whole points.
    mutating func nudge(dx: CGFloat, dy: CGFloat) {
        guard phase == .dragging else { return }
        offset.x += dx
        offset.y += dy
        moving = clamp(CGPoint(x: moving.x + dx, y: moving.y + dy))
    }

    /// Mouse released. Returns the final whole-point rectangle, or nil if it is empty.
    mutating func end(at point: CGPoint) -> CGRect? {
        guard phase == .dragging else { return nil }
        drag(to: point)
        return finish()
    }

    /// Return key: accept the rectangle as it is now.
    mutating func confirm() -> CGRect? {
        guard phase == .dragging else { return nil }
        return finish()
    }

    mutating func reset() { phase = .idle }

    private mutating func finish() -> CGRect? {
        let rect = selection?.integral.intersection(bounds)
        phase = .idle
        guard let rect, !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }
}
