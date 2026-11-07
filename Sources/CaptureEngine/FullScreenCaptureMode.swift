import AppKit
import CoreGraphics
import CoreModels

/// Captures the whole display that currently contains the mouse pointer, at native (Retina) resolution.
public struct FullScreenCaptureMode: CaptureMode {
    public let id = "fullScreen"
    public let title = "Capture Full Screen"
    public let defaultShortcut: KeyShortcut? = .digit(1, [.control, .shift])

    private let displayProvider: @Sendable () async -> CGDirectDisplayID?

    public init(displayProvider: @escaping @Sendable () async -> CGDirectDisplayID? = DisplayLocator.displayUnderCursor) {
        self.displayProvider = displayProvider
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        guard let displayID = await displayProvider() else { throw CaptureError.noDisplayAvailable }
        let target = CaptureTarget.display(displayID)
        let image = try await context.grabber.capture(target, includeCursor: context.includeCursor)
        return .image(image.withSource(target))
    }
}

public enum DisplayLocator {
    /// The display containing the mouse pointer, falling back to the main display.
    @Sendable public static func displayUnderCursor() async -> CGDirectDisplayID? {
        await MainActor.run {
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value
        }
    }
}
