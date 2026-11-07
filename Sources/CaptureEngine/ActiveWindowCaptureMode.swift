import AppKit
import CoreGraphics
import CoreModels

/// Captures the frontmost application's main window on its own (transparent corners, no shadow).
public struct ActiveWindowCaptureMode: CaptureMode {
    public let id = "activeWindow"
    public let title = "Capture Active Window"
    public let defaultShortcut: KeyShortcut? = .digit(3, [.control, .shift])

    private let windowProvider: @Sendable () async -> CGWindowID?

    public init(windowProvider: @escaping @Sendable () async -> CGWindowID? = WindowLocator.frontmostWindowID) {
        self.windowProvider = windowProvider
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        guard let windowID = await windowProvider() else {
            throw CaptureError.captureFailed("There is no active window to capture.")
        }
        let image = try await context.grabber.capture(.window(windowID), includeCursor: context.includeCursor)
        return .image(image)
    }
}

public enum WindowLocator {
    /// The frontmost window of the frontmost app (never CaptureDeck itself).
    @Sendable public static func frontmostWindowID() async -> CGWindowID? {
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return pickWindow(from: info, ownerPID: pid)
    }

    /// `info` is ordered front to back. Picks the first normal-layer, visible, non-tiny window of the app.
    static func pickWindow(from info: [[String: Any]], ownerPID: pid_t) -> CGWindowID? {
        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == ownerPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 50, height >= 50,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(number)
        }
        return nil
    }
}
