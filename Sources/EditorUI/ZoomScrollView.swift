import AppKit
import DesignSystem
import UniformTypeIdentifiers

/// Scroll view with pinch / Cmd+scroll zoom from 1% to 5000%, fit-to-window and actual size.
/// Zoom percentages are in device pixels: 100% = one image pixel per screen pixel.
@MainActor
final class ZoomScrollView: NSScrollView {
    var onFilesDropped: (([URL]) -> Void)?

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        drawsBackground = true
        backgroundColor = Theme.canvasBackground.withAlphaComponent(0.6)      // a little glass shows through around the picture
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        minMagnification = Self.minPercent / 100 / backing
        maxMagnification = Self.maxPercent / 100 / backing
    }

    var zoomPercent: Double { Double(magnification * backing * 100) }

    /// The zoom range, as percentages of device pixels.
    static let minPercent = 1.0, maxPercent = 5000.0

    // MARK: Zooming (smooth)

    /// Identifies the animation in progress; starting another (or stopping) makes the old one end at its next step.
    private var animationToken: UUID?

    /// Sets the zoom so that the picture point `anchor` (document coordinates) stays at the same place in the visible area
    /// (`fraction`: 0...1 across and down it). Zooming around the pointer or the middle of the view then feels natural.
    private func applyMagnification(_ target: CGFloat, anchor: NSPoint, fraction: NSPoint) {
        let clamped = min(max(target, minMagnification), maxMagnification)
        setMagnification(clamped, centeredAt: anchor)
        let bounds = contentView.bounds
        contentView.scroll(to: NSPoint(x: anchor.x - fraction.x * bounds.width, y: anchor.y - fraction.y * bounds.height))
        reflectScrolledClipView(contentView)
    }

    /// The point of the picture under `viewPoint` (in this view's coordinates), and where in the visible area it sits.
    private func anchor(atDocumentPoint point: NSPoint) -> (point: NSPoint, fraction: NSPoint) {
        let b = contentView.bounds
        let fx = b.width > 0 ? (point.x - b.minX) / b.width : 0.5
        let fy = b.height > 0 ? (point.y - b.minY) / b.height : 0.5
        return (point, NSPoint(x: min(max(fx, 0), 1), y: min(max(fy, 0), 1)))
    }

    private var visibleCenter: NSPoint { NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY) }

    func stopAnimation() { animationToken = nil }

    /// True while a zoom is gliding to its target.
    var isAnimating: Bool { animationToken != nil }

    /// The zoom a fraction `progress` (0...1) of the way from `start` to `goal`: it starts quickly and settles gently, and moves
    /// in even steps of percentage, so zooming from 100% to 400% spends equal time on 100->200 and on 200->400.
    static func eased(start: CGFloat, goal: CGFloat, progress: Double) -> CGFloat {
        let t = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - t, 3)
        return start * pow(goal / start, CGFloat(eased))
    }

    /// Eases from the current zoom to `target` (a magnification) in a fraction of a second. The pictured point stays put.
    func animateMagnification(to target: CGFloat, around point: NSPoint? = nil, duration: TimeInterval = 0.22) {
        let goal = min(max(target, minMagnification), maxMagnification)
        let start = magnification
        stopAnimation()
        guard abs(goal - start) / max(start, 0.0001) > 0.001, window != nil else { applyMagnification(goal, anchor: point ?? visibleCenter, fraction: point.map { anchor(atDocumentPoint: $0).fraction } ?? NSPoint(x: 0.5, y: 0.5)); return }
        let held = anchor(atDocumentPoint: point ?? visibleCenter)
        let token = UUID()
        animationToken = token
        animationStep(token: token, began: CACurrentMediaTime(), start: start, goal: goal, duration: duration, held: held)
    }

    /// One step per screen refresh. Each step schedules the next, so nothing keeps running once the view is gone.
    private func animationStep(token: UUID, began: CFTimeInterval, start: CGFloat, goal: CGFloat, duration: TimeInterval,
                               held: (point: NSPoint, fraction: NSPoint)) {
        guard animationToken == token else { return }
        let t = min((CACurrentMediaTime() - began) / duration, 1)
        let value = Self.eased(start: start, goal: goal, progress: t)
        applyMagnification(t >= 1 ? goal : value, anchor: held.point, fraction: held.fraction)
        if t >= 1 { animationToken = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            MainActor.assumeIsolated { self?.animationStep(token: token, began: began, start: start, goal: goal, duration: duration, held: held) }
        }
    }

    func zoomToFit(animated: Bool = false) {
        guard let document = documentView, document.frame.width > 0, document.frame.height > 0 else { return }
        let available = NSSize(width: max(contentSize.width - 24, 1), height: max(contentSize.height - 24, 1))
        let fit = min(available.width / document.frame.width, available.height / document.frame.height)
        let target = min(fit, 1 / backing)                 // never enlarge past 100%
        let center = NSPoint(x: document.frame.midX, y: document.frame.midY)
        if animated { animateMagnification(to: target, around: center) } else { stopAnimation(); setMagnification(target, centeredAt: center) }
    }

    func zoomActualSize(animated: Bool = true) { zoom(toPercent: 100, animated: animated) }

    /// Zooms to a percentage of device pixels (100 = one image pixel per screen pixel).
    func zoom(toPercent percent: Double, animated: Bool = true, around point: NSPoint? = nil) {
        let target = CGFloat(percent / 100) / backing
        if animated { animateMagnification(to: target, around: point) }
        else { stopAnimation(); let held = anchor(atDocumentPoint: point ?? visibleCenter); applyMagnification(target, anchor: held.point, fraction: held.fraction) }
    }

    func zoom(by factor: CGFloat, around point: NSPoint? = nil, animated: Bool = true) {
        let target = min(max(magnification * factor, minMagnification), maxMagnification)
        if animated { animateMagnification(to: target, around: point) }
        else { stopAnimation(); let held = anchor(atDocumentPoint: point ?? visibleCenter); applyMagnification(target, anchor: held.point, fraction: held.fraction) }
    }

    // Cmd + scroll wheel zooms around the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let point = document.convert(event.locationInWindow, from: nil)
        zoom(by: exp(event.scrollingDeltaY * 0.01), around: point, animated: false)       // continuous input: follow it directly
    }

    // MARK: Drag and drop of image files

    private func imageURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}
