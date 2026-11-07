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
        backgroundColor = Theme.canvasBackground
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        minMagnification = 0.01 / backing     // 1%
        maxMagnification = 50 / backing       // 5000%
    }

    var zoomPercent: Double { Double(magnification * backing * 100) }

    func zoomToFit() {
        guard let document = documentView, document.frame.width > 0, document.frame.height > 0 else { return }
        let available = NSSize(width: max(contentSize.width - 24, 1), height: max(contentSize.height - 24, 1))
        let fit = min(available.width / document.frame.width, available.height / document.frame.height)
        let target = min(fit, 1 / backing)                 // never enlarge past 100%
        setMagnification(target, centeredAt: NSPoint(x: document.frame.midX, y: document.frame.midY))
    }

    func zoomActualSize() {
        guard let document = documentView else { return }
        setMagnification(1 / backing, centeredAt: NSPoint(x: document.frame.midX, y: document.frame.midY))
    }

    func zoom(by factor: CGFloat, around point: NSPoint? = nil) {
        let target = min(max(magnification * factor, minMagnification), maxMagnification)
        let center = point ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(target, centeredAt: center)
    }

    // Cmd + scroll wheel zooms around the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let point = document.convert(event.locationInWindow, from: nil)
        zoom(by: exp(event.scrollingDeltaY * 0.01), around: point)
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
