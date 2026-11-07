import AppKit
import CoreModels
import EditorEngine
import SwiftUI

/// What the properties bar shows and edits: the look of the selected objects, or of the active drawing tool.
@MainActor
final class ToolOptionsModel: ObservableObject {
    @Published var title = ""
    @Published var properties: [StyleProperty] = []
    @Published var style = AnnotationStyle.default
    /// How many objects are selected (enables the object buttons).
    @Published var selectionCount = 0
    /// Tool-specific names for properties ("Circle" / "Number" for steps).
    @Published var titles: [StyleProperty: String] = [:]
    /// Shown instead of controls when there is nothing to edit yet.
    @Published var hint: String?

    /// Called whenever the user changes something in the bar.
    var onStyleEdited: ((AnnotationStyle) -> Void)?
    var onAction: ((ObjectAction) -> Void)?

    enum ObjectAction { case duplicate, delete, bringToFront, sendToBack }

    func title(_ property: StyleProperty, default fallback: String) -> String { titles[property] ?? fallback }

    func edit(_ change: (inout AnnotationStyle) -> Void) {
        var new = style
        change(&new)
        guard new != style else { return }
        style = new
        onStyleEdited?(new)
    }
}

/// SwiftUI also has a `TextAlignment`; this one is ours.
private typealias Align = EditorEngine.TextAlignment

private func swiftUIColor(_ c: RGBAColor) -> Color { Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }

private func rgba(_ color: Color) -> RGBAColor {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return RGBAColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
}

/// The contextual tool settings strip above the canvas.
struct ToolOptionsView: View {
    @ObservedObject var model: ToolOptionsModel

    var body: some View {
        HStack(spacing: 14) {
            Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)

            if let hint = model.hint, model.properties.isEmpty {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.properties, id: \.self) { property in
                control(for: property)
            }

            Spacer(minLength: 8)

            if model.selectionCount > 0 {
                HStack(spacing: 2) {
                    iconButton("plus.square.on.square", "Duplicate (⌘J)") { model.onAction?(.duplicate) }
                    iconButton("square.3.layers.3d.top.filled", "Bring to Front") { model.onAction?(.bringToFront) }
                    iconButton("square.3.layers.3d.bottom.filled", "Send to Back") { model.onAction?(.sendToBack) }
                    iconButton("trash", "Delete (⌫)") { model.onAction?(.delete) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private func control(for property: StyleProperty) -> some View {
        switch property {
        case .stroke:
            labelled(model.title(.stroke, default: "Color")) {
                ColorPicker("Color", selection: Binding(get: { swiftUIColor(model.style.strokeColor) },
                                                        set: { c in model.edit { $0.strokeColor = rgba(c) } }), supportsOpacity: true)
                    .labelsHidden()
            }
        case .fill:
            labelled(model.title(.fill, default: "Fill")) {
                ColorPicker("Fill", selection: Binding(get: { swiftUIColor(model.style.fillColor) },
                                                       set: { c in model.edit { $0.fillColor = rgba(c) } }), supportsOpacity: true)
                    .labelsHidden()
                Button { model.edit { $0.fillColor = .clear } } label: { Image(systemName: "nosign") }
                    .buttonStyle(.borderless).help("No fill").opacity(model.style.fillColor.alpha > 0 ? 1 : 0.3)
            }
        case .width:
            labelled(model.title(.width, default: "Width")) {
                Slider(value: Binding(get: { model.style.lineWidth }, set: { v in model.edit { $0.lineWidth = v.rounded() } }), in: 1...40)
                    .frame(width: 90)
                Text("\(Int(model.style.lineWidth))").monospacedDigit().frame(width: 22, alignment: .trailing).font(.caption)
            }
        case .opacity:
            labelled("Opacity") {
                Slider(value: Binding(get: { model.style.opacity }, set: { v in model.edit { $0.opacity = v } }), in: 0.05...1)
                    .frame(width: 80)
                Text("\(Int((model.style.opacity * 100).rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing).font(.caption)
            }
        case .dash:
            labelled("Line") {
                Picker("Line", selection: Binding(get: { model.style.dash }, set: { v in model.edit { $0.dash = v } })) {
                    Text("Solid").tag(DashStyle.solid)
                    Text("Dashed").tag(DashStyle.dashed)
                    Text("Dotted").tag(DashStyle.dotted)
                }
                .labelsHidden().frame(width: 84)
            }
        case .fontName:
            labelled("Font") {
                let fonts = TextFonts.common.contains(model.style.fontName) ? TextFonts.common : [model.style.fontName] + TextFonts.common
                Picker("Font", selection: Binding(get: { model.style.fontName }, set: { v in model.edit { $0.fontName = v } })) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
        case .fontSize:
            labelled(model.title(.fontSize, default: "Size")) {
                Slider(value: Binding(get: { model.style.fontSize }, set: { v in model.edit { $0.fontSize = v.rounded() } }), in: 8...200)
                    .frame(width: 90)
                Text("\(Int(model.style.fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing).font(.caption)
            }
        case .bold:
            Toggle(isOn: Binding(get: { model.style.bold }, set: { v in model.edit { $0.bold = v } })) { Image(systemName: "bold") }
                .toggleStyle(.button).help("Bold").accessibilityLabel("Bold")
        case .italic:
            Toggle(isOn: Binding(get: { model.style.italic }, set: { v in model.edit { $0.italic = v } })) { Image(systemName: "italic") }
                .toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
        case .alignment:
            Picker("Alignment", selection: Binding(get: { model.style.alignment }, set: { v in model.edit { $0.alignment = v } })) {
                Image(systemName: "text.alignleft").tag(Align.left).accessibilityLabel("Align left")
                Image(systemName: "text.aligncenter").tag(Align.center).accessibilityLabel("Align center")
                Image(systemName: "text.alignright").tag(Align.right).accessibilityLabel("Align right")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 96)
        case .strength:
            labelled(model.title(.strength, default: "Strength")) {
                Slider(value: Binding(get: { model.style.strength }, set: { v in model.edit { $0.strength = v.rounded() } }), in: 1...60)
                    .frame(width: 120)
                Text("\(Int(model.style.strength))").monospacedDigit().frame(width: 24, alignment: .trailing).font(.caption)
            }
        case .zoom:
            labelled(model.title(.zoom, default: "Zoom")) {
                Slider(value: Binding(get: { model.style.strength }, set: { v in model.edit { $0.strength = v.rounded() } }), in: 2...8, step: 1)
                    .frame(width: 90)
                Text("\(Int(model.style.strength))×").monospacedDigit().frame(width: 26, alignment: .trailing).font(.caption)
            }
        case .cornerRadius:
            labelled("Corners") {
                Slider(value: Binding(get: { model.style.cornerRadius }, set: { v in model.edit { $0.cornerRadius = v.rounded() } }), in: 0...100)
                    .frame(width: 80)
            }
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
