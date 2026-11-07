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

    public init(grabber: any ScreenGrabber, includeCursor: Bool) {
        self.grabber = grabber
        self.includeCursor = includeCursor
    }
}

/// A way of capturing (full screen, region, window, ...). Register one per mode;
/// hotkeys, menu items and panel buttons are generated from the registered modes.
public protocol CaptureMode: Sendable {
    var id: String { get }
    var title: String { get }
    var defaultShortcut: KeyShortcut? { get }
    func run(_ context: CaptureContext) async throws -> CaptureResult
}

/// Pixel dimensions for a point-sized area at a given scale (rounded, at least 1x1).
func pixelDimensions(pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
    (max(1, Int((pointSize.width * scale).rounded())), max(1, Int((pointSize.height * scale).rounded())))
}
