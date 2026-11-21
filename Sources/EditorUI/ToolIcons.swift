import AppKit
import CoreModels

/// Toolbar and menu icons: single-color template symbols (the color arguments are kept but no longer used).
enum ToolIcons {
    /// The first available SF Symbol of `symbols`, tinted by the system.
    static func image(symbols: [String], color: RGBAColor, description: String, pointSize: CGFloat = 16) -> NSImage? {
        // Plain template icons: the system tints them, like the icons of any standard Mac toolbar.
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        for name in symbols {
            if let base = NSImage(systemSymbolName: name, accessibilityDescription: description),
               let colored = base.withSymbolConfiguration(configuration) {
                colored.isTemplate = true
                return colored
            }
        }
        return nil
    }

    static func image(for tool: EditorToolDescriptor, pointSize: CGFloat = 16) -> NSImage? {
        image(symbols: [tool.symbol], color: tool.iconColor, description: tool.title, pointSize: pointSize)
    }

    /// Colors for the non-tool toolbar buttons, grouped by what they do.
    static let history = "#8E9AAF"      // undo, redo
    static let crop = "#FF5A4F"
    static let rotate = "#FF9F0A"
    static let flip = "#AF7BFF"
    static let zoom = "#30B0C7"
    static let copy = "#5B9DFF"
    static let save = "#34C759"
}
