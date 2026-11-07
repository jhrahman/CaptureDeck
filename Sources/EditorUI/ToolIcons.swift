import AppKit
import CoreModels

/// Colored toolbar and menu icons. Every tool and command gets its own color, so they are easy to tell apart.
enum ToolIcons {
    /// The first available SF Symbol of `symbols`, drawn in `color` (not tinted by the toolbar).
    static func image(symbols: [String], color: RGBAColor, description: String, pointSize: CGFloat = 16) -> NSImage? {
        let nsColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [nsColor]))
        for name in symbols {
            if let base = NSImage(systemSymbolName: name, accessibilityDescription: description),
               let colored = base.withSymbolConfiguration(configuration) {
                colored.isTemplate = false          // a template image would be re-tinted to the system color
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
