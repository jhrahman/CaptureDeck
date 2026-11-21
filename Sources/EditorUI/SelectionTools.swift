import AppKit
import CoreModels
import EditorEngine

// MARK: - Rectangle select

@MainActor
final class SelectRectTool: EditorTool {
    let descriptor = EditorToolRegistry.rectangleSelect

    private enum State {
        case idle
        case creating(anchor: CGPoint)
        case editing(handle: SelectionHandle, startRect: CGRect, startPoint: CGPoint)
    }
    private var state = State.idle

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        guard case .rect(let rect)? = context.document.selection,
              let handle = RectSelectionEditing.hitTest(rect: rect, point: point, tolerance: context.imagePixels(forScreenPoints: 6)) else {
            return .crosshair
        }
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return Self.diagonalCursor(backslash: true)
        case .topRight, .bottomLeft: return Self.diagonalCursor(backslash: false)
        case .move: return rect == context.document.imageBounds ? .crosshair : .openHand   // the whole picture: dragging starts a new selection
        }
    }

    /// A corner resize cursor. Older macOS has no public one, so those versions get the crosshair.
    private static func diagonalCursor(backslash: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: backslash ? .topLeft : .topRight, directions: .all)
        }
        return .crosshair
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        let document = context.document
        if case .rect(let rect)? = document.selection,
           let handle = RectSelectionEditing.hitTest(rect: rect, point: point, tolerance: context.imagePixels(forScreenPoints: 6)) {
            if handle == .move, rect == document.imageBounds {
                // The whole picture is selected: pressing inside it starts a new, smaller selection (moving it would do nothing).
                document.clearSelection()
                state = .creating(anchor: point)
            } else {
                state = .editing(handle: handle, startRect: rect, startPoint: point)
            }
        } else {
            document.clearSelection()
            state = .creating(anchor: point)
        }
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        let document = context.document
        switch state {
        case .idle: break
        case .creating(let anchor):
            document.setSelection(RectSelectionEditing.rect(from: anchor, to: point, within: document.imageBounds).map { .rect($0) })
        case .editing(let handle, let start, let from):
            let delta = CGSize(width: point.x - from.x, height: point.y - from.y)
            document.setSelection(.rect(RectSelectionEditing.dragged(start, handle: handle, by: delta, within: document.imageBounds)))
        }
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { state = .idle }
        let document = context.document
        switch state {
        case .editing(let handle, let start, _) where handle != .move:
            // Dragging an edge or corner of the WHOLE-picture selection crops right away when that is wanted: no trip to the
            // Crop button. (A smaller selection the user drew is left alone: they may want to copy or annotate it.)
            guard context.cropOnSelectionDrag, start == document.imageBounds,
                  case .rect(let rect)? = document.selection, rect != document.imageBounds else { return }
            if document.cropToSelection(), context.keepWholeImageSelected { document.selectAll() }
        case .creating:
            // A plain click (no drag) left nothing selected: bring the whole picture back.
            if document.selection == nil, context.keepWholeImageSelected { document.selectAll() }
        default: break
        }
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        let document = context.document
        if event.keyCode == 53, document.selection != nil { document.clearSelection(); return true }   // Esc
        if event.keyCode == 51 || event.keyCode == 117, document.selection != nil { return document.eraseSelection() }   // Delete: erase the area
        guard case .rect(let rect)? = document.selection else { return false }
        let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
        let delta: (CGFloat, CGFloat)
        switch event.keyCode {
        case 123: delta = (-step, 0)
        case 124: delta = (step, 0)
        case 125: delta = (0, step)
        case 126: delta = (0, -step)
        default: return false
        }
        // Arrows move the selection; Shift + arrows change its size.
        document.setSelection(.rect(RectSelectionEditing.nudged(
            rect, dx: delta.0, dy: delta.1, resize: event.modifierFlags.contains(.shift), within: document.imageBounds)))
        return true
    }

    func deactivate() { state = .idle }
}

// MARK: - Freehand select

@MainActor
final class SelectFreehandTool: EditorTool {
    let descriptor = EditorToolRegistry.freehandSelect
    private var path: FreehandPath?

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor { .crosshair }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        context.document.clearSelection()
        path = FreehandPath(start: point, within: context.document.imageBounds)
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard path != nil else { return }
        path?.append(point)
        if let points = path?.points, points.count >= 3 { context.document.setSelection(.freehand(points)) }
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { path = nil }
        guard let path else { return }
        if let outline = path.finished() { context.document.setSelection(.freehand(outline)) } else { context.document.clearSelection() }
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        if (event.keyCode == 51 || event.keyCode == 117), context.document.selection != nil { return context.document.eraseSelection() }   // Delete
        guard event.keyCode == 53, context.document.selection != nil else { return false }   // Esc
        context.document.clearSelection()
        return true
    }

    func deactivate() { path = nil }
}

extension CapturedImage {
    /// A 1x1 transparent image, used only as a safe fallback when an editor view is being torn down.
    static var placeholder: CapturedImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
    }
}
