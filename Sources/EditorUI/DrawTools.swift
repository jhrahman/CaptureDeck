import AppKit
import CoreModels
import EditorEngine

// MARK: - Click-and-drag shapes (rectangle, ellipse, line, arrows, highlighter)

@MainActor
final class ShapeDragTool: EditorTool {
    let descriptor: EditorToolDescriptor
    /// Builds the shape from the two drag points; the Bool is "Shift held" (square / circle / 45° snap).
    private let make: (CGPoint, CGPoint, Bool) -> any AnnotationShape
    private var start: CGPoint?
    private var current = CGPoint.zero
    private var style = AnnotationStyle.default
    private var snap = false

    init(_ descriptor: EditorToolDescriptor, make: @escaping (CGPoint, CGPoint, Bool) -> any AnnotationShape) {
        self.descriptor = descriptor
        self.make = make
    }

    var previewAnnotations: [Annotation] {
        guard let start else { return [] }
        return [Annotation(shape: make(start, current, snap), style: style)]
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .crosshair }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        start = point
        current = point
        style = context.style
        snap = NSEvent.modifierFlags.contains(.shift)
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard start != nil else { return }
        current = point
        snap = NSEvent.modifierFlags.contains(.shift)
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { start = nil }
        guard let start else { return }
        let shape = make(start, point, NSEvent.modifierFlags.contains(.shift))
        let box = shape.geometryBounds
        guard max(box.width, box.height) >= 3 else { return }              // a stray click draws nothing
        context.document.addAnnotation(Annotation(shape: shape, style: style))
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }                    // Esc: cancel the shape in progress, or deselect
        if start != nil { start = nil } else { context.document.clearAnnotationSelection() }
        return true
    }

    func deactivate() { start = nil }

    // MARK: Geometry helpers

    /// The rectangle between two corners; with `square`, the longer side wins and the shape stays on the drag's side.
    static func rect(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var end = b
        if square {
            let side = max(abs(b.x - a.x), abs(b.y - a.y))
            end = CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
        }
        return CGRect(x: min(a.x, end.x), y: min(a.y, end.y), width: abs(end.x - a.x), height: abs(end.y - a.y))
    }

    /// The line's end point; with `snap`, the angle is rounded to the nearest 45°.
    static func end(_ a: CGPoint, _ b: CGPoint, snap: Bool) -> CGPoint {
        guard snap else { return b }
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + length * cos(angle), y: a.y + length * sin(angle))
    }
}

// MARK: - Pencil

@MainActor
final class PencilTool: EditorTool {
    let descriptor = EditorToolRegistry.pencil
    private var points: [CGPoint] = []
    private var style = AnnotationStyle.default

    var previewAnnotations: [Annotation] {
        points.isEmpty ? [] : [Annotation(shape: PencilShape(points: points), style: style)]
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .crosshair }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        points = [point]
        style = context.style
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1 else { return }
        points.append(point)
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { points = [] }
        guard !points.isEmpty else { return }
        context.document.addAnnotation(Annotation(shape: PencilShape(points: points), style: style))   // a single click makes a dot
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        if points.isEmpty { context.document.clearAnnotationSelection() } else { points = [] }
        return true
    }

    func deactivate() { points = [] }
}

// MARK: - Pointer: select, move and resize objects

@MainActor
final class PointerTool: EditorTool {
    let descriptor = EditorToolRegistry.pointer

    private enum State {
        case idle
        case moving(from: CGPoint, originals: [Annotation])
        case resizing(handle: SelectionHandle, startBounds: CGRect, originals: [Annotation])
    }
    private var state = State.idle
    private static let huge = CGRect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000)

    private func handle(at point: CGPoint, context: ToolContext) -> SelectionHandle? {
        guard let bounds = context.document.selectedAnnotationBounds else { return nil }
        return RectSelectionEditing.handleHit(rect: bounds, point: point, tolerance: context.imagePixels(forScreenPoints: 7))
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        if let handle = handle(at: point, context: context) {
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
        return context.document.annotation(at: point, tolerance: context.imagePixels(forScreenPoints: 5)) != nil ? .openHand : .arrow
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        let document = context.document
        if let handle = handle(at: point, context: context), let bounds = document.selectedAnnotationBounds {
            state = .resizing(handle: handle, startBounds: bounds, originals: document.selectedAnnotations)
            return
        }
        guard let hit = document.annotation(at: point, tolerance: context.imagePixels(forScreenPoints: 5)) else {
            document.clearAnnotationSelection()
            state = .idle
            return
        }
        if NSEvent.modifierFlags.contains(.shift) {                       // Shift-click adds to / removes from the selection
            var ids = document.selectedAnnotationIDs
            if let index = ids.firstIndex(of: hit.id) { ids.remove(at: index); document.selectAnnotations(ids); state = .idle; return }
            document.selectAnnotations(ids + [hit.id])
        } else if !document.selectedAnnotationIDs.contains(hit.id) {
            document.selectAnnotations([hit.id])
        }
        state = .moving(from: point, originals: document.selectedAnnotations)
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        let document = context.document
        switch state {
        case .idle: break
        case .moving(let from, let originals):
            let move = CGAffineTransform(translationX: (point.x - from.x).rounded(), y: (point.y - from.y).rounded())
            document.previewAnnotations(originals.map { $0.applying(move) })
        case .resizing(let handle, let start, let originals):
            let delta = CGSize(width: point.x - handle.anchor(in: start).x, height: point.y - handle.anchor(in: start).y)
            let target = RectSelectionEditing.dragged(start, handle: handle, by: delta, within: Self.huge)
            let transform = RectSelectionEditing.transform(from: start, to: target)
            document.previewAnnotations(originals.map { $0.applying(transform) })
        }
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { state = .idle }
        switch state {
        case .idle: break
        case .moving(_, let originals): context.document.commitAnnotationEdit(from: originals, name: "Move")
        case .resizing(_, _, let originals): context.document.commitAnnotationEdit(from: originals, name: "Resize")
        }
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        let document = context.document
        switch event.keyCode {
        case 51, 117:                                                     // Delete, Forward Delete
            return document.deleteSelectedAnnotations()
        case 53:                                                          // Esc
            guard !document.selectedAnnotationIDs.isEmpty else { return false }
            document.clearAnnotationSelection()
            return true
        case 123, 124, 125, 126:                                          // arrows nudge the selection
            let selected = document.selectedAnnotations
            guard !selected.isEmpty else { return false }
            let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0)
            let move = CGAffineTransform(translationX: dx, y: dy)
            return document.updateAnnotations(selected.map { $0.applying(move) }, name: "Nudge")
        default:
            return false
        }
    }

    func deactivate() { state = .idle }
}

extension SelectionHandle {
    /// The point of `rect` this handle grabs (so a drag delta is measured from where the handle really is).
    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .move: CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}
