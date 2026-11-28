import AppKit
import SwiftUI

/// Semantic color tokens. Views use these names, never raw hex values.
/// Each token resolves to its Dark Ash or Light value from the effective appearance.
public enum Theme {
    public static let windowBackground = token(dark: 0x17191B, light: 0xF4F1EA)
    public static let surface = token(dark: 0x202326, light: 0xFAF8F3)
    public static let raisedPanel = token(dark: 0x2A2E32, light: 0xFFFFFF)
    public static let border = token(dark: 0x363B40, light: 0xE0DBD0)
    public static let textPrimary = token(dark: 0xECE9E1, light: 0x1B1F22)
    public static let textSecondary = token(dark: 0x9AA0A6, light: 0x6B6F73)
    /// The brand's record red (a little deeper on light backgrounds, so white on it stays readable).
    public static let accent = token(dark: 0xFF4D4F, light: 0xE5383B)
    public static let textOnAccent = token(dark: 0xFFFFFF, light: 0xFFFFFF)
    /// Neutral grey behind screenshots, so image colors are never tinted by the theme.
    public static let canvasBackground = token(dark: 0x262626, light: 0xD4D4D4)
    public static let destructive = token(dark: 0xFF6B5E, light: 0xC93A2E)

    private static func token(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

public extension Color {
    /// SwiftUI access to a theme token, e.g. `Color(Theme.surface)`.
    init(_ token: NSColor) { self.init(nsColor: token) }
}

extension NSColor {
    /// sRGB color from 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
