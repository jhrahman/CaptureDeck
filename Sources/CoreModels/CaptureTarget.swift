import CoreGraphics

/// What to capture. Selection UIs return a target, not an image, so other features can reuse them.
public enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    /// A rectangle in the display's point coordinate space (origin top-left).
    case rect(CGRect, display: CGDirectDisplayID)
    /// A freehand outline in the display's point coordinates (origin top-left). The result is the
    /// outline's bounding box with everything outside the outline transparent.
    case polygon([CGPoint], display: CGDirectDisplayID)
    /// A single window, captured on its own (transparent corners, no desktop behind it).
    case window(CGWindowID)
}

public enum CaptureError: Error, Sendable, Equatable {
    case permissionDenied
    case noDisplayAvailable
    /// The user pressed Esc or otherwise backed out. Not an error to show.
    case cancelled
    case captureFailed(String)
}
