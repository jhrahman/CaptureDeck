import AppKit
import CoreModels

/// Transparent view drawn over the frozen screen: dim, selection, size label, magnifier.
/// Flipped, so its coordinates are display points with the origin at the top-left.
@MainActor
final class RegionOverlayView: NSView {
    private var model: RegionSelectionModel
    /// Non-nil in fixed-size mode: a rectangle of fixed pixel size follows the pointer.
    private var fixed: FixedSizeSelectionModel?
    /// Non-nil in freehand mode.
    private var freehand: FreehandSelectionModel?
    private var presets: [CGSize] = []
    /// Non-nil in window/object mode: hover highlights what is under the pointer.
    private var finder: (any PickTargetFinder)?
    private var pick = ObjectPickModel()
    private var globalOrigin = CGPoint.zero
    private let snapshot: CapturedImage
    private let style: OverlayStyle
    private var mouse: CGPoint?

    var onClaim: (() -> Void)?
    var onRelease: (() -> Void)?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onPick: ((PickCandidate) -> Void)?
    var onFinishPolygon: (([CGPoint]) -> Void)?

    /// True while the user is selecting on a different display.
    var isLocked = false { didSet { needsDisplay = true } }

    private static let loupeSize: CGFloat = 128
    private static let loupeSourcePoints: CGFloat = 16   // 8x magnification

    init(frame: CGRect, snapshot: CapturedImage, style: OverlayStyle, kind: RegionSelectionKind) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        self.model = RegionSelectionModel(bounds: bounds)
        self.snapshot = snapshot
        self.style = style
        super.init(frame: frame)
        if case .freehand = kind { self.freehand = FreehandSelectionModel(bounds: bounds) }
        if case .fixedSize(let presets) = kind {
            self.presets = presets
            let initial = FixedSizePreference.load(default: presets.first ?? CGSize(width: 800, height: 600))
            self.fixed = FixedSizeSelectionModel(bounds: bounds, scale: snapshot.scale, sizePx: initial)
        }
    }

    /// Window/object mode.
    init(frame: CGRect, snapshot: CapturedImage, style: OverlayStyle, finder: any PickTargetFinder, globalOrigin: CGPoint) {
        self.model = RegionSelectionModel(bounds: CGRect(origin: .zero, size: frame.size))
        self.snapshot = snapshot
        self.style = style
        self.finder = finder
        self.globalOrigin = globalOrigin
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
        if bounds.contains(p) { track(p) }
    }

    // MARK: Mouse

    private func point(for event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseEntered(with event: NSEvent) { track(point(for: event)) }
    override func mouseExited(with event: NSEvent) { mouse = nil; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { track(point(for: event)) }

    private func track(_ p: CGPoint) {
        mouse = p
        fixed?.move(to: p)
        if let finder {
            pick.update(finder.candidates(at: CGPoint(x: globalOrigin.x + p.x, y: globalOrigin.y + p.y)))
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if finder != nil {   // window/object mode: a click captures the highlighted candidate
            window?.makeKey()
            track(point(for: event))
            if let candidate = pick.current { onPick?(candidate) }
            return
        }
        if fixed != nil {   // fixed-size mode: a click captures the rectangle under the pointer
            window?.makeKey()
            let p = point(for: event)
            track(p)
            if let rect = fixed?.selection { onFinish?(rect) }
            return
        }
        guard !isLocked else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        onClaim?()
        let p = point(for: event)
        if freehand != nil { freehand?.begin(at: p) } else { model.begin(at: p) }
        mouse = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if finder != nil { track(point(for: event)); return }
        if fixed != nil { track(point(for: event)); return }
        let p = point(for: event)
        if freehand != nil { freehand?.add(p) } else { model.drag(to: p) }
        mouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if fixed != nil || finder != nil { return }
        if freehand != nil {
            if let outline = freehand?.end(at: point(for: event)) { onFinishPolygon?(outline) } else { onRelease?() }
            needsDisplay = true
            return
        }
        if let rect = model.end(at: point(for: event)) {
            onFinish?(rect)
        } else {
            onRelease?()  // clicked without dragging: allow selecting on any display again
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if finder != nil { return }
        if fixed != nil { showPresetMenu(for: event) } else { resetSelection() }
    }

    private func showPresetMenu(for event: NSEvent) {
        guard let current = fixed?.sizePx else { return }
        let menu = NSMenu()
        for size in presets {
            let item = NSMenuItem(title: "\(Int(size.width)) × \(Int(size.height))", action: #selector(choosePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSValue(size: size)
            item.state = size == current ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        guard let size = (sender.representedObject as? NSValue)?.sizeValue else { return }
        applyFixedSize(size)
    }

    private func applyFixedSize(_ size: CGSize) {
        fixed?.setSize(px: size)
        if let now = fixed?.sizePx { FixedSizePreference.save(now) }
        needsDisplay = true
    }

    private func resetSelection() {
        model.reset()
        freehand?.reset()
        onRelease?()
        needsDisplay = true
    }

    // MARK: Keyboard

    private func fixedKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags
        let step: CGFloat = flags.contains(.option) ? 10 : 1
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76:
            if let rect = fixed?.selection { onFinish?(rect) }
        case 123, 124, 125, 126:
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0)
            if flags.contains(.shift) {           // Shift + arrows: change the size, one pixel at a time
                fixed?.resize(dxPx: dx, dyPx: dy)
                if let now = fixed?.sizePx { FixedSizePreference.save(now) }
            } else {
                fixed?.nudge(dx: dx, dy: dy)
            }
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }

    private func freehandKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76:
            if let outline = freehand?.confirm() { onFinishPolygon?(outline) } else { NSSound.beep() }
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                resetSelection()
            } else {
                super.keyDown(with: event)
            }
        }
        needsDisplay = true
    }

    private func pickKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: if let candidate = pick.current { onPick?(candidate) } else { NSSound.beep() }
        case 126: pick.selectParent()   // Up: the surrounding element
        case 125: pick.selectChild()    // Down: back to the inner element
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if finder != nil { pickKeyDown(event); return }
        if fixed != nil { fixedKeyDown(event); return }
        if freehand != nil { freehandKeyDown(event); return }
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
        let selection: CGRect?
        if finder != nil {
            let local = pick.current.map { $0.rect.offsetBy(dx: -globalOrigin.x, dy: -globalOrigin.y).intersection(bounds) }
            selection = (mouse != nil && local?.isNull == false) ? local : nil
        } else if fixed != nil {
            selection = mouse != nil ? fixed?.selection : nil
        } else if freehand != nil {
            selection = freehand?.boundingRect
        } else {
            selection = model.selection
        }
        // Freehand: the outline itself is the "hole" in the dim layer; its bounding box only labels the size.
        var outline: NSBezierPath?
        if let points = freehand?.points, points.count >= 2 {
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            outline = path
        }
        if let outline {
            dim.append(outline)
            dim.windingRule = .evenOdd
        } else if let selection, freehand == nil {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        guard !isLocked else { return }

        if let selection {
            style.accent.setStroke()
            if let outline {
                outline.lineWidth = 1.5
                outline.lineJoinStyle = .round
                outline.stroke()
            } else {
                let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
                border.lineWidth = 1
                border.stroke()
            }
            drawSizeLabel(for: selection)
        }
        if finder != nil {
            drawPill(pick.candidates.count > 1 ? "Click to capture   ↑ ↓ choose parent / child   Esc cancel"
                                                : "Click to capture a window   Esc cancel",
                     at: CGPoint(x: bounds.midX - 150, y: 24))
        } else if let mouse {
            drawLoupe(at: mouse)
        }
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
