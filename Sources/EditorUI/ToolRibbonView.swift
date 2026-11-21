import AppKit
import DesignSystem
import EditorEngine
import SwiftUI

@MainActor
final class ToolRibbonModel: ObservableObject {
    @Published var selectedID = ""
    var onSelect: ((EditorToolDescriptor) -> Void)?
}

/// The row of tools along the top of the editor. Each tool has its own icon color; sections are separated by dividers.
/// If the window is narrower than the ribbon, it scrolls sideways.
struct ToolRibbonView: View {
    @ObservedObject var model: ToolRibbonModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(EditorToolRegistry.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider().frame(height: 18).padding(.horizontal, 5).opacity(0.7) }
                    ForEach(group) { tool in
                        RibbonButton(tool: tool, selected: tool.id == model.selectedID) { model.onSelect?(tool) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 42)
        .glassBar()
        .glassEdge(.bottom)
    }
}

private struct RibbonButton: View {
    let tool: EditorToolDescriptor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        Button(action: action) {
            // A live vector symbol (not a pre-rendered bitmap), so every icon stays sharp on any display and scale.
            Image(systemName: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil ? tool.symbol : "questionmark.square")
                .font(.system(size: 16, weight: .regular))
                .imageScale(.medium)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(selected ? accent : Color.primary.opacity(hovering ? 1 : 0.78))
                .frame(width: 34, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent.opacity(0.22) : (hovering ? Color(Glass.fill) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? accent.opacity(0.55) : (hovering ? Color(Glass.stroke) : Color.clear), lineWidth: 1)
                )
                .shadow(color: selected ? accent.opacity(0.25) : .clear, radius: 5, y: 1)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .overlay(NativeToolTip(text: "\(tool.title)  (\(tool.key.uppercased()))").allowsHitTesting(false))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A real AppKit tooltip. SwiftUI's `.help` does not reliably appear for buttons inside this embedded ribbon.
private struct NativeToolTip: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.toolTip = text; return view }
    func updateNSView(_ view: NSView, context: Context) { view.toolTip = text }
}
