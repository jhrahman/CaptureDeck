import AppKit
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
                    if index > 0 { Divider().frame(height: 22).padding(.horizontal, 4) }
                    ForEach(group) { tool in
                        RibbonButton(tool: tool, selected: tool.id == model.selectedID) { model.onSelect?(tool) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 42)
        .background(.bar)
    }
}

private struct RibbonButton: View {
    let tool: EditorToolDescriptor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = ToolIcons.image(for: tool, pointSize: 17) {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "questionmark.square")
                }
            }
            .frame(width: 34, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
                                   : (hovering ? Color.primary.opacity(0.08) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(tool.title)  (\(tool.key.uppercased()))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
