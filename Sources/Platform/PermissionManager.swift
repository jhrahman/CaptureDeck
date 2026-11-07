import AppKit
import CoreGraphics

/// Screen Recording permission. Request it only when a capture is first attempted.
public enum ScreenRecordingPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only returns the current state.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }

    @MainActor
    public static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
