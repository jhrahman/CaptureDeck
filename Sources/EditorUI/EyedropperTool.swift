import AppKit
import CoreModels
import EditorEngine

/// Picks the exact colour of any pixel of the picture. A magnifier follows the pointer and shows the pixels around it and the
/// colour value live; click (or press, slide to the right pixel and let go) to pick it. The colour becomes the Paint Bucket's
/// colour, ready to fill a region.
@MainActor
final class EyedropperTool: OverlayTool {
    let descriptor = EditorToolRegistry.pickColor
    var overlayChanged: (() -> Void)?

    private var sampler: PixelSampler?
    private var samplerPicture: ObjectIdentifier?
    private var hover: CGPoint?
    private var imageBounds = CGRect.zero
    private var unit: CGFloat = 1
    private var lastHex = ""

    var statusText: String {
        lastHex.isEmpty ? "Click any pixel to pick its colour" : "\(lastHex) · click to pick it"
    }

    var overlayRect: CGRect? {
        guard let hover else { return nil }
        return ColorLoupe.area(around: hover, unit: unit, bounds: imageBounds)
    }

    // MARK: Reading pixels

    func prepare(context: ToolContext) {
        let picture = context.document.workingImage.cgImage
        imageBounds = context.document.imageBounds
        unit = context.imagePixels(forScreenPoints: 1)
        let id = ObjectIdentifier(picture)
        guard samplerPicture != id else { return }
        samplerPicture = id
        sampler = nil
        // Unpacking a large picture takes a moment: do it away from the main thread, then redraw.
        Task.detached(priority: .userInitiated) {
            let made = PixelSampler.shared(for: picture)
            await MainActor.run { [weak self] in
                guard let self, self.samplerPicture == id else { return }
                self.sampler = made
                self.overlayChanged?()
            }
        }
    }

    private func track(_ point: CGPoint, context: ToolContext) {
        unit = context.imagePixels(forScreenPoints: 1)
        hover = point
        let hex = sampler?.color(at: point).map { String($0.hex.prefix(7)).uppercased() } ?? ""
        if hex != lastHex { lastHex = hex; overlayChanged?() }                    // the bar's status line follows the colour
    }

    // MARK: Pointer

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        prepare(context: context)
        return EyedropperCursor.cursor
    }

    func pointerMoved(to point: CGPoint, context: ToolContext) -> Bool {
        prepare(context: context)
        track(point, context: context)
        return true
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        prepare(context: context)
        track(point, context: context)
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) { track(point, context: context) }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        track(point, context: context)
        guard let color = sampler?.color(at: point) else { return }
        context.host?.pickedColor(color)
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool { false }

    func deactivate() { hover = nil; lastHex = "" }

    func drawOverlay(in context: CGContext, unit: CGFloat) {
        guard let hover, let sampler else { return }
        ColorLoupe.draw(sampler: sampler, at: hover, in: context, unit: unit, bounds: imageBounds)
    }
}
