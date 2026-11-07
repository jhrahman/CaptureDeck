import ApplicationServices

/// Accessibility permission. Optional: it lets window/object capture pick individual UI elements.
/// Without it, only whole windows can be chosen.
public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (the app is then listed in System Settings > Privacy > Accessibility).
    @discardableResult
    public static func requestPrompt() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
