import AppKit
import CoreModels
import DesignSystem
import EditorEngine

/// Draws the working image 1:1 (one view unit = one image pixel); the scroll view provides the zoom.
/// Shows a checkerboard behind transparent images.
@MainActor
final class CanvasView: NSView {
    var image: CGImage? {
        didSet {
            hasTransparency = image.map(Self.hasTransparentPixels) ?? false
            setFrameSize(NSSize(width: image?.width ?? 0, height: image?.height ?? 0))
            needsDisplay = true
        }
    }
    private var hasTransparency = false

    /// The selected area (image pixels) drawn over the picture, and what to do with the mouse and keys.
    var selection: EditorSelection? { didSet { needsDisplay = true } }
    var showSelectionSize = true { didSet { needsDisplay = true } }
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var selectedAnnotationIDs: [UUID] = [] { didSet { needsDisplay = true } }
    var previewProvider: (() -> [Annotation])?
    private var lastPreviewRect: CGRect?
    private var lastOverlayRect: CGRect?
    /// Where the pointer last was over the picture (image pixels), for the Option-to-pick magnifier.
    private var lastPointer: CGPoint?
    /// A colour was picked with Option held (the editor applies it to the active tool).
    var onPickColor: ((RGBAColor) -> Void)?
    /// Esc was pressed in a drawing tool with nothing to cancel: go back to the default tool.
    var onExitTool: (() -> Void)?
    /// Annotations not drawn right now (the text being edited is shown by the inline editor instead).
    var hiddenAnnotationIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    var toolContext: (() -> ToolContext)?
    var activeTool: (any EditorTool)? {
        didSet {
            (oldValue as? OverlayTool)?.overlayChanged = nil
            (activeTool as? OverlayTool)?.overlayChanged = { [weak self] in
                self?.needsDisplay = true
                self?.onToolStatusChanged?()
            }
            needsDisplay = true
        }
    }
    /// The active tool's status line or button changed (Hide Text finished reading the picture).
    var onToolStatusChanged: (() -> Void)?
    var onToolKey: ((String) -> Bool)?       // single-letter tool switching
    var onCycleTool: ((Bool) -> Void)?       // Tab / Shift+Tab

    /// While a drawing tool is active, the handles of the object you just drew still work, and Delete / arrow keys
    /// still act on it. The pointer tool does that work.
    private let direct = PointerTool()
    private var gestureTool: (any EditorTool)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// Whether pressing on an existing object picks it up instead of drawing. Drawing tools do this so objects can be moved
    /// without switching tools, except the freehand ones (pencil, redact brush) and Hide Text: a press there always does the
    /// tool's own job, even right on top of an earlier stroke. (Use the Select tool to move strokes.)
    static func allowsGrabbing(from tool: any EditorTool) -> Bool {
        tool.descriptor.kind == .draw && !(tool is FreehandTool) && !(tool is HideTextTool) && !(tool is EyedropperTool)
    }

    /// With a colour tool active, holding Option turns the pointer into an eyedropper: click to pick a colour from the picture
    /// without leaving the tool. (Not Hide Text, where Option already means "the whole line".)
    private var optionPicking: Bool {
        guard NSEvent.modifierFlags.contains(.option), let tool = activeTool, tool.descriptor.kind == .draw, !(tool is HideTextTool),
              !(tool is EyedropperTool) else { return false }
        return tool.descriptor.styleProperties.contains(.stroke)
    }

    private func pixelSampler() -> PixelSampler? { image.flatMap { PixelSampler.shared(for: $0) } }

    private var pickingUnit: CGFloat { 1 / max(enclosingScrollView?.magnification ?? 1, 0.0001) }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let lastPointer {                                   // the magnifier appears or goes away as Option is pressed or released
            setNeedsDisplay(ColorLoupe.area(around: lastPointer, unit: pickingUnit, bounds: bounds).union(CGRect(origin: lastPointer, size: .zero).insetBy(dx: -4, dy: -4)))
        }
        if let window, let point = window.mouseLocationOutsideOfEventStream as NSPoint? {
            let local = convert(point, from: nil)
            if bounds.contains(local) { (optionPicking ? EyedropperCursor.cursor : NSCursor.arrow).set() }
        }
    }

    private func updateCursor(_ event: NSEvent) {
        if optionPicking { EyedropperCursor.cursor.set(); return }
        guard let tool = activeTool, let context = toolContext?() else { return }
        let point = imagePoint(event)
        if Self.allowsGrabbing(from: tool), direct.grabs(point, context: context) { direct.cursor(at: point, context: context).set(); return }
        tool.cursor(at: point, context: context).set()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) {
        handlePointerMoved(to: imagePoint(event))
        updateCursor(event)
    }

    /// The pointer moved with no button down (also used by tests, which have no events).
    func handlePointerMoved(to point: CGPoint) {
        let previous = lastPointer
        lastPointer = point
        if optionPicking {
            let unit = pickingUnit
            var dirty = ColorLoupe.area(around: point, unit: unit, bounds: bounds)
            if let previous { dirty = dirty.union(ColorLoupe.area(around: previous, unit: unit, bounds: bounds)) }
            setNeedsDisplay(dirty)
        }
        if let overlay = activeTool as? OverlayTool, let context = toolContext?() {
            let before = overlay.overlayRect
            if overlay.pointerMoved(to: point, context: context) { invalidateOverlay(before: before, overlay: overlay) }
        }
    }

    /// Redraws only what the overlay covered and covers now, when it can say so (the eyedropper's magnifier), else everything.
    private func invalidateOverlay(before: CGRect?, overlay: OverlayTool) {
        if let before, let after = overlay.overlayRect { setNeedsDisplay(before.union(after)) } else { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let tool = activeTool, var context = toolContext?() else { return }
        context.clickCount = event.clickCount
        let point = imagePoint(event)
        if optionPicking {                                       // Option held: pick a colour instead of drawing
            if let color = pixelSampler()?.color(at: point) { onPickColor?(color) }
            return
        }
        if Self.allowsGrabbing(from: tool), direct.grabs(point, context: context) {
            gestureTool = direct
            direct.mouseDown(at: point, context: context)
            return
        }
        gestureTool = nil
        // Pressing on empty space with a drawing tool deselects the previously selected object (its handles go away).
        if tool.descriptor.kind == .draw { context.document.clearAnnotationSelection() }
        tool.mouseDown(at: point, context: context)
        needsDisplay = true
    }

    /// The area covered by the shape being drawn (with room for its line and round ends), or nil when the preview affects
    /// more than its own area (the spotlight dims the whole picture) and everything must be redrawn.
    private func previewRect() -> CGRect? {
        guard let preview = previewProvider?(), !preview.isEmpty else { return nil }
        let local: Set<String> = ["pencil", "line", "rectangle", "ellipse"]
        guard preview.allSatisfy({ local.contains($0.shape.shapeType) }) else { return nil }
        var area = CGRect.null
        for annotation in preview {
            let margin = CGFloat(annotation.style.lineWidth) * 1.5 + 12                 // arrow heads and anti-aliasing
            area = area.union(annotation.bounds.insetBy(dx: -margin, dy: -margin))
        }
        return area.isNull ? nil : area
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tool = gestureTool ?? activeTool, let context = toolContext?() else { return }
        let before = lastPreviewRect
        let overlayBefore = (tool as? OverlayTool)?.overlayRect
        tool.mouseDragged(to: imagePoint(event), context: context)
        if let overlay = tool as? OverlayTool, overlay.overlayRect != nil || overlayBefore != nil, previewRect() == nil {
            invalidateOverlay(before: overlayBefore, overlay: overlay)
            autoscroll(with: event)
            return
        }
        // Live preview of the shape being drawn. Only the area around it is redrawn, so drawing stays quick on large pictures.
        if let after = previewRect() {
            setNeedsDisplay((before ?? after).union(after))
            lastPreviewRect = after
        } else {
            needsDisplay = true
            lastPreviewRect = nil
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let tool = gestureTool ?? activeTool, let context = toolContext?() else { return }
        gestureTool = nil
        lastPreviewRect = nil
        tool.mouseUp(at: imagePoint(event), context: context)
        needsDisplay = true
        updateCursor(event)
    }

    // MARK: Right-click menu

    /// Called with the chosen action; the editor performs it on the selection.
    var onObjectAction: ((ToolOptionsModel.ObjectAction) -> Void)?
    /// Selects the object under the pointer (so the menu acts on it) and says whether there is one.
    var onSelectObject: ((CGPoint) -> Bool)?

    private final class ActionItem: NSMenuItem {
        var action2: ToolOptionsModel.ObjectAction?
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onSelectObject?(imagePoint(event)) == true else { return nil }
        let menu = NSMenu()
        for (title, symbol, action, key) in [
            ("Duplicate", "plus.square.on.square", ToolOptionsModel.ObjectAction.duplicate, "j"),
            ("Bring to Front", "square.3.layers.3d.top.filled", .bringToFront, ""),
            ("Send to Back", "square.3.layers.3d.bottom.filled", .sendToBack, ""),
            ("Delete", "trash", .delete, ""),
        ] {
            if action == .delete { menu.addItem(.separator()) }
            let item = ActionItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
            item.target = self
            item.action2 = action
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        if let action = (sender as? ActionItem)?.action2 { onObjectAction?(action) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let tool = activeTool, let context = toolContext?(), tool.keyDown(event, context: context) { return }
        if let tool = activeTool, tool.descriptor.kind == .draw, let context = toolContext?(), direct.keyDown(event, context: context) { return }
        // Esc with a drawing tool and nothing left to cancel or deselect: leave the tool, back to the default one.
        if event.keyCode == 53, flags.isEmpty, activeTool?.descriptor.kind == .draw { onExitTool?(); return }
        if flags.isEmpty || flags == .shift {
            if event.keyCode == 48 { onCycleTool?(flags == .shift); return }          // Tab / Shift+Tab
            if let key = event.charactersIgnoringModifiers?.lowercased(), onToolKey?(key) == true { return }
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let backing = window?.backingScaleFactor ?? 2
        let devicePixelsPerImagePixel = (enclosingScrollView?.magnification ?? 1) * backing

        if hasTransparency { drawCheckerboard(in: dirtyRect.intersection(bounds), square: 8 / devicePixelsPerImagePixel, context) }

        context.saveGState()
        // Crisp pixels when zoomed in, smooth when zoomed out.
        context.interpolationQuality = devicePixelsPerImagePixel >= 1 ? .none : .high
        context.translateBy(x: 0, y: bounds.height)   // the view is flipped; images are drawn y-up
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()

        // Annotations sit on top of the picture, in order (the view is flipped, so image pixels draw as they are).
        AnnotationRenderer.draw(hiddenAnnotationIDs.isEmpty ? annotations : annotations.filter { !hiddenAnnotationIDs.contains($0.id) }, in: context, backdrop: image)
        if let preview = previewProvider?(), !preview.isEmpty { AnnotationRenderer.draw(preview, in: context, backdrop: image) }
        drawObjectSelection(in: context)

        if let selection { drawSelection(selection, in: context) }
        if let overlay = activeTool as? OverlayTool {
            overlay.drawOverlay(in: context, unit: 1 / max(enclosingScrollView?.magnification ?? 1, 0.0001))
        }
        if optionPicking, let lastPointer, let sampler = pixelSampler() {
            ColorLoupe.draw(sampler: sampler, at: lastPointer, in: context, unit: pickingUnit, bounds: bounds)
        }
    }

    // MARK: Object selection overlay

    private func drawObjectSelection(in context: CGContext) {
        let chosen = annotations.filter { selectedAnnotationIDs.contains($0.id) }
        guard var union = chosen.first?.bounds else { return }
        let unit = 1 / max(enclosingScrollView?.magnification ?? 1, 0.0001)      // image pixels per screen point
        context.saveGState()
        context.setLineWidth(unit)
        for annotation in chosen {
            let box = annotation.bounds.insetBy(dx: -CGFloat(annotation.style.lineWidth) / 2, dy: -CGFloat(annotation.style.lineWidth) / 2)
            union = union.union(annotation.bounds)
            context.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
            context.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
            if !(chosen.count == 1 && annotation.shape.handlesReplaceBounds) { context.stroke(box) }
        }
        // A shape's own handles (the tip of a speech bubble's tail) show when it is the only thing selected.
        let onlyOwnHandles = chosen.count == 1 && chosen[0].shape.handlesReplaceBounds
        if chosen.count == 1 {
            let radius: CGFloat = onlyOwnHandles ? 6 : 5
            for point in chosen[0].shape.extraHandles {
                let dot = CGRect(x: point.x - radius * unit, y: point.y - radius * unit, width: radius * 2 * unit, height: radius * 2 * unit)
                context.setLineDash(phase: 0, lengths: [])
                if onlyOwnHandles {
                    // A hollow ring, so the arrowhead underneath stays visible.
                    context.setLineWidth(4 * unit); context.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); context.strokeEllipse(in: dot)
                    context.setLineWidth(2 * unit); context.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)); context.strokeEllipse(in: dot)
                } else {
                    context.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1))
                    context.fillEllipse(in: dot)
                    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
                    context.setLineWidth(1.5 * unit)
                    context.strokeEllipse(in: dot)
                }
            }
            context.setLineWidth(unit)
        }
        context.setLineDash(phase: 0, lengths: [])
        if onlyOwnHandles { context.restoreGState(); return }
        let handle = 7 * unit
        let xs: [CGFloat] = [union.minX, union.midX, union.maxX]
        let ys: [CGFloat] = [union.minY, union.midY, union.maxY]
        for (i, x) in xs.enumerated() {
            for (j, y) in ys.enumerated() where !(i == 1 && j == 1) {
                let box = CGRect(x: x - handle / 2, y: y - handle / 2, width: handle, height: handle)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(box)
                context.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
                context.stroke(box)
            }
        }
        context.restoreGState()
    }

    // MARK: Selection overlay

    /// Marching-ants outline, handles for a rectangle, and the size label. Everything is sized in screen
    /// points, so it looks the same at any zoom.
    private func drawSelection(_ selection: EditorSelection, in context: CGContext) {
        let unit = 1 / max(enclosingScrollView?.magnification ?? 1, 0.0001)      // image pixels per screen point
        context.saveGState()
        context.setLineWidth(unit)

        func outline(_ draw: () -> Void) {
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineDash(phase: 0, lengths: [])
            draw(); context.strokePath()
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineDash(phase: 0, lengths: [4 * unit, 4 * unit])
            draw(); context.strokePath()
        }

        switch selection {
        case .rect(let rect):
            outline { context.addRect(rect) }
            let handle = 9 * unit
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(unit)
            let xs: [CGFloat] = [rect.minX, rect.midX, rect.maxX]
            let ys: [CGFloat] = [rect.minY, rect.midY, rect.maxY]
            var handlePoints: [CGPoint] = []
            for (i, x) in xs.enumerated() {
                for (j, y) in ys.enumerated() where !(i == 1 && j == 1) { handlePoints.append(CGPoint(x: x, y: y)) }
            }
            for point in handlePoints {
                // On the edge of the picture a handle would be cut in half by the view's edge, so it is drawn just inside.
                let inner = bounds.insetBy(dx: handle / 2 + unit, dy: handle / 2 + unit)
                let centre = inner.width > 0 && inner.height > 0
                    ? CGPoint(x: min(max(point.x, inner.minX), inner.maxX), y: min(max(point.y, inner.minY), inner.maxY)) : point
                let box = CGRect(x: centre.x - handle / 2, y: centre.y - handle / 2, width: handle, height: handle)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(box)
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                context.stroke(box)
            }
        case .freehand(let points):
            outline {
                guard let first = points.first else { return }
                context.move(to: first)
                points.dropFirst().forEach { context.addLine(to: $0) }
                context.closePath()
            }
        }
        context.restoreGState()

        if showSelectionSize {
            let box = selection.bounds
            let text = "\(Int(box.width)) × \(Int(box.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * unit, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let pad = 5 * unit
            let labelRect = CGRect(x: box.minX, y: box.minY - size.height - 2 * pad - 2 * unit,
                                   width: size.width + 2 * pad, height: size.height + pad)
            let placed = labelRect.minY < 0 ? labelRect.offsetBy(dx: 0, dy: box.height + labelRect.height + 4 * unit) : labelRect
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: placed, xRadius: 4 * unit, yRadius: 4 * unit).fill()
            (text as NSString).draw(at: CGPoint(x: placed.minX + pad, y: placed.minY + pad / 2), withAttributes: attributes)
        }
    }

    private func drawCheckerboard(in rect: CGRect, square: CGFloat, _ context: CGContext) {
        guard !rect.isEmpty, square > 0 else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        let firstRow = Int((rect.minY / square).rounded(.down)), lastRow = Int((rect.maxY / square).rounded(.up))
        let firstCol = Int((rect.minX / square).rounded(.down)), lastCol = Int((rect.maxX / square).rounded(.up))
        for row in firstRow..<lastRow {
            for col in firstCol..<lastCol where (row + col) & 1 == 1 {
                context.fill(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square)
                    .intersection(rect))
            }
        }
    }

    /// True if any pixel is not fully opaque (stops at the first one found).
    static func hasTransparentPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return false }
        var row = [UInt8](repeating: 0, count: w * 4)
        // Check one row at a time so a huge image never needs a second full-size buffer.
        for y in 0..<h {
            let found: Bool = row.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: 1))
                ctx.draw(image, in: CGRect(x: 0, y: -(h - 1 - y), width: w, height: h))
                let bytes = buffer.bindMemory(to: UInt8.self)
                var i = 3
                while i < w * 4 { if bytes[i] != 255 { return true }; i += 4 }
                return false
            }
            if found { return true }
        }
        return false
    }
}

/// Keeps a document that is smaller than the window centered.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        }
        return rect
    }
}

