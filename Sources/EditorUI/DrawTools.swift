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
        if start != nil { start = nil; return true }
        return dismissSelection(context.document)               // nothing to cancel or deselect: the editor leaves the tool
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

/// Esc, once nothing is in progress: deselects whatever object is selected (true), or does nothing (false), so the editor can
/// take Esc to leave the tool.
@MainActor
func dismissSelection(_ document: EditorDocument) -> Bool {
    guard !document.selectedAnnotationIDs.isEmpty else { return false }
    document.clearAnnotationSelection()
    return true
}

/// Freehand painting with a steadied, smoothed line: the pencil and the redact brush. Pressing always starts a new stroke (it
/// never picks up what is underneath), a finished stroke is not selected, and Shift draws a straight line.
@MainActor
class FreehandTool: EditorTool {
    let descriptor: EditorToolDescriptor
    private let makeShape: ([CGPoint]) -> any AnnotationShape
    private let undoName: String?
    private var points: [CGPoint] = []
    private var start = CGPoint.zero
    private var end = CGPoint.zero
    private var drawing = false
    private var straight = false
    private var stabilizer = StrokeSmoothing.Stabilizer(start: .zero)
    private var style = AnnotationStyle.default
    /// Whether Shift is held (replaceable in tests).
    var shiftHeld: () -> Bool = { NSEvent.modifierFlags.contains(.shift) }

    init(_ descriptor: EditorToolDescriptor, undoName: String? = nil, makeShape: @escaping ([CGPoint]) -> any AnnotationShape) {
        self.descriptor = descriptor
        self.undoName = undoName
        self.makeShape = makeShape
    }

    var previewAnnotations: [Annotation] {
        guard drawing else { return [] }
        return [Annotation(shape: makeShape(currentPoints), style: style)]
    }

    /// The stroke so far. With Shift held it is a straight line from where the press began, snapped to 45° steps like the
    /// arrows; otherwise it is the smoothed freehand path.
    private var currentPoints: [CGPoint] {
        straight ? [start, ShapeDragTool.end(start, end, snap: true)] : points
    }

    /// A round cursor as big as the line will be, so the user sees exactly what a stroke will look like.
    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        let screenPerImagePixel = context.zoom / (NSScreen.main?.backingScaleFactor ?? 2)
        return BrushCursor.cursor(diameter: CGFloat(context.style.lineWidth) * screenPerImagePixel)
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        drawing = true
        start = point
        end = point
        points = [point]
        stabilizer = StrokeSmoothing.Stabilizer(start: point)
        straight = shiftHeld()
        style = context.style
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard drawing else { return }
        end = point
        straight = shiftHeld()
        let step = context.imagePixels(forScreenPoints: 1)
        let softness = context.imagePixels(forScreenPoints: 5)
        let smoothed = stabilizer.filter(point, softness: softness)
        if let last = points.last, hypot(smoothed.x - last.x, smoothed.y - last.y) >= step { points.append(smoothed) }
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { drawing = false; points = [] }
        guard drawing else { return }
        end = point
        straight = shiftHeld() && hypot(point.x - start.x, point.y - start.y) >= 1
        var final = currentPoints
        if !straight, final.count > 1, let last = final.last, hypot(point.x - last.x, point.y - last.y) >= 0.5 {
            final.append(point)                                  // the filter trails the pointer a little: finish exactly where it was let go
        }
        if !straight { final = StrokeSmoothing.simplified(final, tolerance: context.imagePixels(forScreenPoints: 1.4)) }
        // Not selected afterwards: no handle box, and nothing in the way of the next stroke. A single click makes a dot.
        context.document.addAnnotation(Annotation(shape: makeShape(final), style: style), select: false)
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        if drawing { drawing = false; points = []; return true }
        return dismissSelection(context.document)
    }

    func deactivate() { drawing = false; points = [] }
}

/// The pencil: a smooth freehand line.
final class PencilTool: FreehandTool {
    init() { super.init(EditorToolRegistry.pencil) { PencilShape(points: $0) } }
}

/// The redact brush: paint over anything to blur, pixelate or cover it. The effect shows live while painting.
final class RedactBrushTool: FreehandTool {
    init() { super.init(EditorToolRegistry.redactBrush) { RedactBrushShape(points: $0) } }
}

/// Round brush-size cursors (white ring, dark ring, centre dot), cached by size.
@MainActor
enum BrushCursor {
    private static var cache: [Int: NSCursor] = [:]

    static func cursor(diameter: CGFloat) -> NSCursor {
        let size = Int(min(max(diameter.rounded(), 7), 96))
        if let cached = cache[size] { return cached }
        let side = CGFloat(size) + 6
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = rect.insetBy(dx: 3, dy: 3)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let outer = NSBezierPath(ovalIn: ring.insetBy(dx: -0.5, dy: -0.5)); outer.lineWidth = 2.5; outer.stroke()
            NSColor.black.withAlphaComponent(0.85).setStroke()
            let inner = NSBezierPath(ovalIn: ring); inner.lineWidth = 1; inner.stroke()
            let dot = NSRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2)
            NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: dot).fill()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cache[size] = cursor
        return cursor
    }
}

// MARK: - Pointer: select, move and resize objects

@MainActor
final class PointerTool: EditorTool {
    let descriptor = EditorToolRegistry.pointer

    private enum State {
        case idle
        case marquee(from: CGPoint, additive: [UUID])
        case tail(original: Annotation, index: Int)
        case moving(from: CGPoint, originals: [Annotation])
        case resizing(handle: SelectionHandle, startBounds: CGRect, originals: [Annotation])
    }
    private var state = State.idle
    /// The rubber band while dragging on empty space.
    private var band: CGRect?
    var previewAnnotations: [Annotation] {
        guard let band else { return [] }
        var look = AnnotationStyle.default
        look.strokeColor = RGBAColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
        look.fillColor = RGBAColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.12)
        look.lineWidth = 1
        look.dash = .dashed
        return [Annotation(shape: RectangleShape(rect: band), style: look)]
    }
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

    /// True when the point is on a handle of the selected object, or on the object itself, so any drawing tool can hand the gesture over.
    func grabs(_ point: CGPoint, context: ToolContext) -> Bool {
        extraHandle(at: point, context: context) != nil || handle(at: point, context: context) != nil || objectBody(at: point, context: context)
    }

    /// Shapes that cover an area of the picture (effects). Their whole surface can't be a grab target, or the user could
    /// never draw over them. So they are grabbed by their edge, or anywhere inside once they are selected.
    private static let areaEffects: Set<String> = ["blur", "pixelate", "highlighter", "spotlight", "fill"]

    /// True when the point is on an existing object, so any drawing tool can select and drag it, and shows the hand cursor,
    /// without switching to the pointer. Ordinary objects (arrows, rectangles, text, bubbles, steps...) are grabbed anywhere
    /// on them; area effects follow the edge / selected-interior rule above.
    private func objectBody(at point: CGPoint, context: ToolContext) -> Bool {
        let document = context.document
        let tolerance = context.imagePixels(forScreenPoints: 5)
        if let hit = document.annotation(at: point, tolerance: tolerance), !Self.areaEffects.contains(hit.shape.shapeType) { return true }
        for annotation in document.annotations.reversed() where Self.areaEffects.contains(annotation.shape.shapeType) {
            let box = annotation.bounds
            let nearEdge = box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !box.insetBy(dx: tolerance, dy: tolerance).contains(point)
            let insideSelected = document.selectedAnnotationIDs.contains(annotation.id) && box.contains(point)
            if nearEdge || insideSelected { return true }
        }
        return false
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
            // Empty space: drag to rubber-band several objects. Shift keeps the current selection and adds to it.
            let keep = NSEvent.modifierFlags.contains(.shift) ? document.selectedAnnotationIDs : []
            if keep.isEmpty { document.clearAnnotationSelection() }
            state = .marquee(from: point, additive: keep)
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
        case .marquee(let from, let keep):
            let rect = CGRect(x: min(from.x, point.x), y: min(from.y, point.y), width: abs(point.x - from.x), height: abs(point.y - from.y))
            band = rect
            let inside = document.annotations.filter { $0.bounds.intersects(rect) }.map(\.id)
            document.selectAnnotations(keep + inside.filter { !keep.contains($0) })
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
        defer { state = .idle; band = nil }
        switch state {
        case .idle, .marquee: break
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

    func deactivate() { state = .idle; band = nil }
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
        return dismissSelection(context.document)
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
        if start != nil { start = nil; return true }
        return dismissSelection(context.document)               // nothing to cancel or deselect: the editor leaves the tool
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
        if start != nil { start = nil; return true }
        return dismissSelection(context.document)               // nothing to cancel or deselect: the editor leaves the tool
    }

    func deactivate() { start = nil }
}

// MARK: - Paint bucket

/// Click an area to fill it with a color.
@MainActor
/// The paint bucket. While the pointer moves, the region a click would fill is previewed in the chosen colour, so there are no
/// surprises; clicking fills it. Hold Option to pick the colour from the picture instead (the eyedropper, without leaving the tool).
final class FillTool: OverlayTool {
    let descriptor = EditorToolRegistry.fill
    var overlayChanged: (() -> Void)?

    private var previewMask: CGImage?
    private var previewPicture: ObjectIdentifier?
    private var previewTolerance = -1.0
    private var previewColor = CGColor(gray: 0, alpha: 1)
    private var pending: (seed: CGPoint, picture: CGImage, tolerance: Double)?
    private var working = false

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .crosshair }

    func mouseDown(at point: CGPoint, context: ToolContext) {}
    func mouseDragged(to point: CGPoint, context: ToolContext) {}

    func mouseUp(at point: CGPoint, context: ToolContext) {
        guard context.document.imageBounds.contains(point) else { return }
        // Several regions can be filled one after another: the new fill is not selected, so nothing gets in the way of the next click.
        context.document.addAnnotation(Annotation(shape: FillShape(seed: point), style: context.style), select: false)
        previewMask = nil                                    // that region is filled now: look again on the next move
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        return dismissSelection(context.document)
    }

    func deactivate() { previewMask = nil; pending = nil }

    // MARK: Live preview

    func pointerMoved(to point: CGPoint, context: ToolContext) -> Bool {
        let picture = context.document.workingImage.cgImage
        let id = ObjectIdentifier(picture)
        previewColor = context.style.strokeColor.cgColor.copy(alpha: 0.55) ?? previewColor
        guard context.document.imageBounds.contains(point) else {
            let had = previewMask != nil
            previewMask = nil
            return had
        }
        // A different picture (after a crop) or a different tolerance makes the old preview wrong.
        if previewPicture != id || previewTolerance != context.style.strength { previewMask = nil; previewPicture = id; previewTolerance = context.style.strength }
        if let mask = previewMask, FillRegion.contains(mask, point: point) { return false }        // still inside the highlighted region
        pending = (point, picture, context.style.strength)
        if !working { work() }
        return false                                                                                // the region arrives a moment later
    }

    /// Finds the region under the latest pointer position in the background, so moving stays smooth however large the region is.
    private func work() {
        guard let request = pending else { return }
        pending = nil
        working = true
        let id = ObjectIdentifier(request.picture)
        Task.detached(priority: .userInitiated) {
            let mask = FillRegion.mask(in: request.picture, seed: request.seed, tolerance: request.tolerance)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.working = false
                if self.previewPicture == id, request.tolerance == self.previewTolerance {
                    self.previewMask = mask
                    self.overlayChanged?()
                }
                if self.pending != nil { self.work() }                                              // the pointer moved on: look again
            }
        }
    }

    func drawOverlay(in context: CGContext, unit: CGFloat) {
        guard let mask = previewMask else { return }
        let w = CGFloat(mask.width), h = CGFloat(mask.height)
        context.saveGState()
        context.translateBy(x: 0, y: h)                       // our space is y-down; masks are y-up
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask)
        context.setFillColor(previewColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.restoreGState()
    }
}
