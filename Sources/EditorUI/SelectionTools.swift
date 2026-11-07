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
        case .move: return .openHand
        default: return .crosshair
        }
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        let document = context.document
        if case .rect(let rect)? = document.selection,
           let handle = RectSelectionEditing.hitTest(rect: rect, point: point, tolerance: context.imagePixels(forScreenPoints: 6)) {
            state = .editing(handle: handle, startRect: rect, startPoint: point)
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

    func mouseUp(at point: CGPoint, context: ToolContext) { state = .idle }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        let document = context.document
        if event.keyCode == 53, document.selection != nil { document.clearSelection(); return true }   // Esc
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
