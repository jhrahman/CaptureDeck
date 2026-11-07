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
        case tail(original: Annotation, index: Int)
        case moving(from: CGPoint, originals: [Annotation])
        case resizing(handle: SelectionHandle, startBounds: CGRect, originals: [Annotation])
    }
    private var state = State.idle
    static func snapped(_ point: CGPoint, around anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: (anchor.x + cos(angle) * length).rounded(), y: (anchor.y + sin(angle) * length).rounded())
    }
    private static let huge = CGRect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000)

    private func handle(at point: CGPoint, context: ToolContext) -> SelectionHandle? {
        guard let bounds = context.document.selectedAnnotationBounds else { return nil }
        let selected = context.document.selectedAnnotations
        if selected.count == 1, selected[0].shape.handlesReplaceBounds { return nil }
        return RectSelectionEditing.handleHit(rect: bounds, point: point, tolerance: context.imagePixels(forScreenPoints: 7))
    }

    /// A shape's own handle (a bubble's tail tip) under the pointer: only when exactly one object is selected.
    private func extraHandle(at point: CGPoint, context: ToolContext) -> (annotation: Annotation, index: Int)? {
        let selected = context.document.selectedAnnotations
        guard selected.count == 1, let annotation = selected.first else { return nil }
        let reach = context.imagePixels(forScreenPoints: 9)
        for (index, handle) in annotation.shape.extraHandles.enumerated() where hypot(point.x - handle.x, point.y - handle.y) <= reach {
            return (annotation, index)
        }
        return nil
    }

    /// True when the point is on a handle of the selected object, so any drawing tool can hand the gesture over.
    func grabs(_ point: CGPoint, context: ToolContext) -> Bool {
        extraHandle(at: point, context: context) != nil || handle(at: point, context: context) != nil
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        if extraHandle(at: point, context: context) != nil { return .crosshair }
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
        if let hit = extraHandle(at: point, context: context) {
            state = .tail(original: hit.annotation, index: hit.index)
            return
        }
        if let handle = handle(at: point, context: context), let bounds = document.selectedAnnotationBounds {
            state = .resizing(handle: handle, startBounds: bounds, originals: document.selectedAnnotations)
            return
        }
        guard let hit = document.annotation(at: point, tolerance: context.imagePixels(forScreenPoints: 5)) else {
            document.clearAnnotationSelection()
            state = .idle
            return
        }
        if context.clickCount >= 2 {                                            // double-click text or a bubble to edit it
            if let text = hit.shape as? TextShape {
                document.selectAnnotations([hit.id])
                context.host?.editText(annotationID: hit.id, rect: text.rect, text: text.text, style: hit.style, kind: .plain)
                state = .idle
                return
            }
            if let bubble = hit.shape as? CalloutShape {
                document.selectAnnotations([hit.id])
                context.host?.editText(annotationID: hit.id, rect: bubble.rect, text: bubble.text, style: hit.style,
                                       kind: .callout(oval: bubble.oval, tip: bubble.tip))
                state = .idle
                return
            }
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
        case .tail(let original, let index):
            var target = point
            // Shift snaps a line to 0°, 45°, 90°… around its other end.
            if NSEvent.modifierFlags.contains(.shift), let line = original.shape as? LineShape {
                target = Self.snapped(point, around: index == 0 ? line.end : line.start)
            }
            document.previewAnnotations([Annotation(id: original.id, shape: original.shape.movingHandle(index, to: target), style: original.style)])
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
        case .tail(let original, _): context.document.commitAnnotationEdit(from: [original], name: "Move Tail")
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

// MARK: - Step numbers and letters

@MainActor
final class StepTool: EditorTool {
    let descriptor: EditorToolDescriptor
    private let letters: Bool

    init(_ descriptor: EditorToolDescriptor, letters: Bool) {
        self.descriptor = descriptor
        self.letters = letters
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .crosshair }

    /// One more than the highest step of this kind already on the picture (so deleting the last one reuses its number).
    private func nextNumber(in document: EditorDocument) -> Int {
        let numbers = document.annotations.compactMap { ($0.shape as? StepShape).flatMap { $0.letters == letters ? $0.number : nil } }
        return (numbers.max() ?? 0) + 1
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {}
    func mouseDragged(to point: CGPoint, context: ToolContext) {}

    func mouseUp(at point: CGPoint, context: ToolContext) {
        let radius = CGFloat(context.style.fontSize) * 0.9
        let shape = StepShape(center: point, radius: radius, number: nextNumber(in: context.document), letters: letters)
        context.document.addAnnotation(Annotation(shape: shape, style: context.style))
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        context.document.clearAnnotationSelection()
        return true
    }

    func deactivate() {}
}

// MARK: - Text

@MainActor
final class TextTool: EditorTool {
    let descriptor = EditorToolRegistry.text
    private var start: CGPoint?
    private var current = CGPoint.zero
    private var style = AnnotationStyle.default

    static let defaultWidth: CGFloat = 300
    static let minimumWidth: CGFloat = 60

    var previewAnnotations: [Annotation] {
        guard let start, hypot(current.x - start.x, current.y - start.y) > 4 else { return [] }
        let outline = AnnotationStyle(strokeColor: style.strokeColor, lineWidth: 2, dash: .dashed)
        return [Annotation(shape: RectangleShape(rect: ShapeDragTool.rect(start, current, square: false)), style: outline)]
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .iBeam }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        style = context.style
        // Clicking existing text edits it instead of starting a new box.
        if let hit = context.document.annotation(at: point, tolerance: context.imagePixels(forScreenPoints: 4)),
           let text = hit.shape as? TextShape {
            context.document.selectAnnotations([hit.id])
            context.host?.editText(annotationID: hit.id, rect: text.rect, text: text.text, style: hit.style, kind: .plain)
            start = nil
            return
        }
        start = point
        current = point
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard start != nil else { return }
        current = point
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { start = nil }
        guard let start else { return }
        let dragged = ShapeDragTool.rect(start, point, square: false)
        let box: CGRect
        if dragged.width >= Self.minimumWidth {
            box = CGRect(x: dragged.minX, y: dragged.minY, width: dragged.width, height: max(dragged.height, 1))
        } else {
            box = CGRect(x: start.x, y: start.y, width: Self.defaultWidth, height: 1)     // a click: default-width box
        }
        context.host?.editText(annotationID: nil, rect: box, text: "", style: style, kind: .plain)
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        if start != nil { start = nil } else { context.document.clearAnnotationSelection() }
        return true
    }

    func deactivate() { start = nil }
}

// MARK: - Speech bubbles

@MainActor
final class CalloutTool: EditorTool {
    let descriptor: EditorToolDescriptor
    private let oval: Bool
    private var start: CGPoint?
    private var current = CGPoint.zero
    private var style = AnnotationStyle.default

    static let defaultWidth: CGFloat = 280

    init(_ descriptor: EditorToolDescriptor, oval: Bool) {
        self.descriptor = descriptor
        self.oval = oval
    }

    var previewAnnotations: [Annotation] {
        guard let start, hypot(current.x - start.x, current.y - start.y) > 4 else { return [] }
        let outline = AnnotationStyle(strokeColor: style.strokeColor, lineWidth: 2, dash: .dashed)
        return [Annotation(shape: RectangleShape(rect: ShapeDragTool.rect(start, current, square: false)), style: outline)]
    }

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .iBeam }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        style = context.style
        // Clicking an existing bubble edits its text instead of starting a new one.
        if let hit = context.document.annotation(at: point, tolerance: context.imagePixels(forScreenPoints: 4)),
           let bubble = hit.shape as? CalloutShape {
            context.document.selectAnnotations([hit.id])
            context.host?.editText(annotationID: hit.id, rect: bubble.rect, text: bubble.text, style: hit.style,
                                   kind: .callout(oval: bubble.oval, tip: bubble.tip))
            start = nil
            return
        }
        start = point
        current = point
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard start != nil else { return }
        current = point
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { start = nil }
        guard let start else { return }
        let dragged = ShapeDragTool.rect(start, point, square: false)
        let box = dragged.width >= TextTool.minimumWidth
            ? CGRect(x: dragged.minX, y: dragged.minY, width: dragged.width, height: max(dragged.height, 1))
            : CGRect(x: start.x, y: start.y, width: Self.defaultWidth, height: 1)
        context.host?.editText(annotationID: nil, rect: box, text: "", style: style, kind: .callout(oval: oval, tip: nil))
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        if start != nil { start = nil } else { context.document.clearAnnotationSelection() }
        return true
    }

    func deactivate() { start = nil }
}

// MARK: - Paint bucket

/// Click an area to fill it with a color.
@MainActor
final class FillTool: EditorTool {
    let descriptor = EditorToolRegistry.fill

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .crosshair }
    func mouseDown(at point: CGPoint, context: ToolContext) {}
    func mouseDragged(to point: CGPoint, context: ToolContext) {}

    func mouseUp(at point: CGPoint, context: ToolContext) {
        guard context.document.imageBounds.contains(point) else { return }
        context.document.addAnnotation(Annotation(shape: FillShape(seed: point), style: context.style))
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        context.document.clearAnnotationSelection()
        return true
    }

    func deactivate() {}
}
