import CaptureEngine
import DesignSystem
import SwiftUI

/// SF Symbol for each capture mode. Unknown modes get a generic camera icon, so adding a mode never breaks the panel.
enum CaptureModeIcon {
    static func symbol(for modeID: String) -> String {
        let name: String
        switch modeID {
        case "fullScreen": name = "display"
        case "region": name = "rectangle.dashed"
        case "activeWindow": name = "macwindow"
        case "windowObject": name = "cursorarrow.click.2"
        case "freehand": name = "lasso"
        case "fixedSize": name = "aspectratio"
        case "repeatLast": name = "arrow.counterclockwise"
        default: name = "camera"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "camera"
    }
}

struct CapturePanelView: View {
    let modes: [any CaptureMode]
    let run: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                PanelButton(symbol: CaptureModeIcon.symbol(for: mode.id), title: mode.title, shortcut: mode.defaultShortcut?.displayString) {
                    run(mode.id)
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(Theme.border), lineWidth: 1))
        .padding(4)   // room for the window shadow
    }
}

private struct PanelButton: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 34, height: 34)
                .foregroundStyle(hovering ? Color(Theme.textOnAccent) : Color(Theme.textPrimary))
                .background(hovering ? Color(Theme.accent) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(title)  \($0)" } ?? title)
        .accessibilityLabel(title)
    }
}
