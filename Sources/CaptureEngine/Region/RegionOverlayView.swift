import AppKit
import CoreModels

/// Transparent view drawn over the frozen screen: dim, selection, size label, magnifier.
/// Flipped, so its coordinates are display points with the origin at the top-left.
@MainActor
final class RegionOverlayView: NSView {
    private var model: RegionSelectionModel
    private let snapshot: CapturedImage
    private let style: OverlayStyle
    private var mouse: CGPoint?

    var onClaim: (() -> Void)?
    var onRelease: (() -> Void)?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// True while the user is selecting on a different display.
    var isLocked = false { didSet { needsDisplay = true } }

    private static let loupeSize: CGFloat = 128
    private static let loupeSourcePoints: CGFloat = 16   // 8x magnification

    init(frame: CGRect, snapshot: CapturedImage, style: OverlayStyle) {
        self.model = RegionSelectionModel(bounds: CGRect(origin: .zero, size: frame.size))
        self.snapshot = snapshot
        self.style = style
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let inWindow = window.mouseLocationOutsideOfEventStream
        let p = convert(inWindow, from: nil)
        if bounds.contains(p) { mouse = p }
    }

    // MARK: Mouse

    private func point(for event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseEntered(with event: NSEvent) { mouse = point(for: event); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouse = nil; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { mouse = point(for: event); needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        onClaim?()
        let p = point(for: event)
        model.begin(at: p)
        mouse = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(for: event)
        model.drag(to: p)
        mouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect = model.end(at: point(for: event)) {
            onFinish?(rect)
        } else {
            onRelease?()  // clicked without dragging: allow selecting on any display again
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { resetSelection() }

    private func resetSelection() {
        model.reset()
        onRelease?()
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53:                       // Esc
            onCancel?()
        case 36, 76:                   // Return, keypad Enter
            if let rect = model.confirm() { onFinish?(rect) } else { NSSound.beep() }
        case 48:                       // Tab
            model.switchCorner()
        case 123: model.nudge(dx: -step, dy: 0)
        case 124: model.nudge(dx: step, dy: 0)
        case 125: model.nudge(dx: 0, dy: step)
        case 126: model.nudge(dx: 0, dy: -step)
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                resetSelection()       // Cmd+Z: choose again
            } else {
                super.keyDown(with: event)
            }
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let selection = model.selection
        if let selection {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        guard !isLocked else { return }

        if let selection {
            style.accent.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawSizeLabel(for: selection)
        }
        if let mouse { drawLoupe(at: mouse) }
    }

    private func drawPill(_ text: String, at origin: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: attributes)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let w = Int((selection.width * snapshot.scale).rounded())
        let h = Int((selection.height * snapshot.scale).rounded())
        let y = selection.minY >= 26 ? selection.minY - 26 : selection.minY + 4
        drawPill("\(w) × \(h)", at: CGPoint(x: max(selection.minX, 0), y: y))
    }

    private func drawLoupe(at point: CGPoint) {
        let size = Self.loupeSize
        var origin = CGPoint(x: point.x + 24, y: point.y + 24)
        if origin.x + size > bounds.maxX { origin.x = point.x - 24 - size }
        if origin.y + size + 28 > bounds.maxY { origin.y = point.y - 24 - size - 28 }
        let loupe = CGRect(origin: origin, size: CGSize(width: size, height: size))

        // Source pixels around the cursor, kept inside the image.
        let n = Int((Self.loupeSourcePoints * snapshot.scale).rounded())
        let cx = Int((point.x * snapshot.scale).rounded()), cy = Int((point.y * snapshot.scale).rounded())
        let x = min(max(cx - n / 2, 0), max(snapshot.cgImage.width - n, 0))
        let y = min(max(cy - n / 2, 0), max(snapshot.cgImage.height - n, 0))
        if let crop = snapshot.cgImage.cropping(to: CGRect(x: x, y: y, width: n, height: n)) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: loupe).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: crop, size: loupe.size).draw(
                in: loupe, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Center marker on the pixel under the cursor.
        let cell = size / CGFloat(n)
        style.accent.setStroke()
        let marker = NSBezierPath(rect: CGRect(x: loupe.midX - cell / 2, y: loupe.midY - cell / 2, width: cell, height: cell))
        marker.lineWidth = 1
        marker.stroke()
        NSColor.white.setStroke()
        let frame = NSBezierPath(rect: loupe.insetBy(dx: -1, dy: -1))
        frame.lineWidth = 2
        frame.stroke()

        drawPill("\(Int(point.x)), \(Int(point.y))", at: CGPoint(x: loupe.minX, y: loupe.maxY + 4))
    }
}
