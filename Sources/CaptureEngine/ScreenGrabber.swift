import CoreGraphics
import CoreModels

/// Hides the screen-capture API so modes can be tested with a mock and the
/// macOS 13 / 14+ differences live in one place.
public protocol ScreenGrabber: Sendable {
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage
}

/// Everything a capture mode needs from the outside world.
public struct CaptureContext: Sendable {
    public let grabber: any ScreenGrabber
    public let includeCursor: Bool
    /// When several displays end up in one picture, mark each with a numbered badge and a divider.
    public let labelDisplays: Bool
    /// How fast a scrolling capture scrolls the window.
    public let scrollSpeed: ScrollSpeed

    public init(grabber: any ScreenGrabber, includeCursor: Bool, labelDisplays: Bool = false, scrollSpeed: ScrollSpeed = .medium) {
        self.grabber = grabber
        self.includeCursor = includeCursor
        self.labelDisplays = labelDisplays
        self.scrollSpeed = scrollSpeed
    }
}

/// A way of capturing (full screen, region, window, ...). Register one per mode;
/// hotkeys, menu items and panel buttons are generated from the registered modes.
public protocol CaptureMode: Sendable {
    var id: String { get }
    var title: String { get }
    var defaultShortcut: KeyShortcut? { get }
    /// True if the mode works better with the Accessibility permission (it must still work without it).
    var wantsAccessibility: Bool { get }
    func run(_ context: CaptureContext) async throws -> CaptureResult
}

public extension CaptureMode {
    var wantsAccessibility: Bool { false }
}

/// Pixel dimensions for a point-sized area at a given scale (rounded, at least 1x1).
func pixelDimensions(pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
    (max(1, Int((pointSize.width * scale).rounded())), max(1, Int((pointSize.height * scale).rounded())))
}
