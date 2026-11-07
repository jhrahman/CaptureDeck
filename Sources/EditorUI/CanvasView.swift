import AppKit
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
    /// Annotations not drawn right now (the text being edited is shown by the inline editor instead).
    var hiddenAnnotationIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    var toolContext: (() -> ToolContext)?
    var activeTool: (any EditorTool)?
    var onToolKey: ((String) -> Bool)?       // single-letter tool switching
    var onCycleTool: ((Bool) -> Void)?       // Tab / Shift+Tab

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

    private func updateCursor(_ event: NSEvent) {
        guard let tool = activeTool, let context = toolContext?() else { return }
        tool.cursor(at: imagePoint(event), context: context).set()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let tool = activeTool, var context = toolContext?() else { return }
        context.clickCount = event.clickCount
        tool.mouseDown(at: imagePoint(event), context: context)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tool = activeTool, let context = toolContext?() else { return }
        tool.mouseDragged(to: imagePoint(event), context: context)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let tool = activeTool, let context = toolContext?() else { return }
        tool.mouseUp(at: imagePoint(event), context: context)
        updateCursor(event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let tool = activeTool, let context = toolContext?(), tool.keyDown(event, context: context) { return }
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
            context.stroke(box)
        }
        context.setLineDash(phase: 0, lengths: [])
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
            let handle = 7 * unit
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(unit)
            let xs: [CGFloat] = [rect.minX, rect.midX, rect.maxX]
            let ys: [CGFloat] = [rect.minY, rect.midY, rect.maxY]
            var handlePoints: [CGPoint] = []
            for (i, x) in xs.enumerated() {
                for (j, y) in ys.enumerated() where !(i == 1 && j == 1) { handlePoints.append(CGPoint(x: x, y: y)) }
            }
            for point in handlePoints {
                let box = CGRect(x: point.x - handle / 2, y: point.y - handle / 2, width: handle, height: handle)
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
