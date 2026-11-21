import CaptureEngine
import DesignSystem
import SwiftUI

/// SF Symbol for each capture mode. Unknown modes get a generic camera icon, so adding a mode never breaks the panel.
enum CaptureModeIcon {
    static func symbol(for modeID: String) -> String {
        let name: String
        switch modeID {
        case "fullScreen": name = "display"
        case "allDisplays": name = "rectangle.on.rectangle"
        case "region": name = "rectangle.dashed"
        case "activeWindow": name = "macwindow"
        case "scrollingWindow": name = "arrow.up.and.down.text.horizontal"
        case "windowObject": name = "cursorarrow.click.2"
        case "freehand": name = "lasso"
        case "fixedSize": name = "aspectratio"
        case "repeatLast": name = "arrow.counterclockwise"
        default: name = "camera"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "camera"
    }
}

/// A button on the panel that is not a capture mode.
struct PanelExtra: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let action: () -> Void
}

/// Button size choices on the Capture Panel tab.
enum PanelButtonSize: String {
    case small, medium, large

    var side: CGFloat {
        switch self {
        case .small: 28
        case .medium: 34
        case .large: 42
        }
    }
    var iconSize: CGFloat { side * 0.47 }
}

struct CapturePanelView: View {
    let modes: [any CaptureMode]
    let buttonSize: PanelButtonSize
    /// Display text of each mode's current shortcut, for tooltips.
    let shortcuts: [String: String]
    /// Non-capture buttons shown after a divider (open an image, edit the clipboard image).
    let extras: [PanelExtra]
    let run: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                PanelButton(symbol: CaptureModeIcon.symbol(for: mode.id), title: mode.title, shortcut: shortcut(for: mode), size: buttonSize) {
                    run(mode.id)
                }
            }
            if !extras.isEmpty {
                Divider().frame(height: buttonSize.side * 0.6).padding(.horizontal, 3)
                ForEach(extras) { extra in
                    PanelButton(symbol: extra.symbol, title: extra.title, shortcut: nil, size: buttonSize, action: extra.action)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(Theme.border), lineWidth: 1))
        .padding(4)   // room for the window shadow
    }

    private func shortcut(for mode: any CaptureMode) -> String? { shortcuts[mode.id] }
}

private struct PanelButton: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let size: PanelButtonSize
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size.iconSize, weight: .regular))
                .frame(width: size.side, height: size.side)
                .foregroundStyle(hovering ? Color(Theme.textOnAccent) : Color(Theme.textPrimary))
                .background(hovering ? Color(Theme.accent) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(title)  \($0)" } ?? title)
        .accessibilityLabel(title)
    }
}
