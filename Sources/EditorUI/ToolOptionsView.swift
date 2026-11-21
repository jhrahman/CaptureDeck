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
    /// True when the controls do not fit on one line, so the bar grows to two.
    @Published var wraps = false
    /// Shown for the area-selection tools: the selected rectangle in pixels (nil = nothing selected).
    @Published var areaSelection: CGRect?
    @Published var isAreaTool = false
    /// A status line and an extra button supplied by the active tool (Hide Text: how many words were found, and Hide All).
    @Published var toolStatus: String?
    @Published var toolButton: (title: String, symbol: String)?

    /// Called whenever the user changes something in the bar.
    var onStyleEdited: ((AnnotationStyle) -> Void)?
    var onAction: ((ObjectAction) -> Void)?

    enum ObjectAction { case duplicate, delete, bringToFront, sendToBack, crop, copyArea, deselectArea, selectAllArea, toolButton, eraseArea, fillArea }

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

func swiftUIColor(_ c: RGBAColor) -> Color { Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }

func rgba(_ color: Color) -> RGBAColor {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return RGBAColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
}

/// The contextual tool settings strip above the canvas.
struct ToolOptionsView: View {
    @ObservedObject var model: ToolOptionsModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            controlsBody
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(widthProbe(ideal: true))
            if model.selectionCount > 0 && !model.isAreaTool {
                HStack(spacing: 2) {
                    iconButton("plus.square.on.square", "Duplicate (⌘J)") { model.onAction?(.duplicate) }
                    iconButton("square.3.layers.3d.top.filled", "Bring to Front") { model.onAction?(.bringToFront) }
                    iconButton("square.3.layers.3d.bottom.filled", "Send to Back") { model.onAction?(.sendToBack) }
                    iconButton("trash", "Delete (⌫)") { model.onAction?(.delete) }
                }
                .frame(height: 38)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
        .onPreferenceChange(IdealWidthKey.self) { ideal in
            // Re-measured whenever the controls change; one line is preferred.
            if let ideal { measuredIdeal = ideal; recompute() }
        }
        .background(GeometryReader { proxy in Color.clear.onAppear { available = proxy.size.width; recompute() }
            .onChange(of: proxy.size.width) { available = $0; recompute() } })
    }

    @State private var measuredIdeal: CGFloat = 0
    @State private var available: CGFloat = 10_000

    private func recompute() {
        let reserved: CGFloat = model.selectionCount > 0 ? 130 : 24
        let wraps = measuredIdeal + reserved > available
        if wraps != model.wraps { model.wraps = wraps }
    }

    /// Reports how wide all the controls would be on a single line.
    private func widthProbe(ideal: Bool) -> some View {
        controlsRow.fixedSize().hidden().background(GeometryReader { proxy in
            Color.clear.preference(key: IdealWidthKey.self, value: proxy.size.width)
        })
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(model.properties, id: \.self) { control(for: $0) }
            toolExtras
        }
    }

    /// What the active tool adds to the bar: a status line and a button (Hide Text).
    @ViewBuilder private var toolExtras: some View {
        if let button = model.toolButton { actionButton(button.symbol, button.title) { model.onAction?(.toolButton) } }
        if let status = model.toolStatus { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
    }

    private var areaBar: some View {
        HStack(spacing: 10) {
            Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if let r = model.areaSelection {
                Text("\(Int(r.width)) × \(Int(r.height)) px  at  \(Int(r.minX)), \(Int(r.minY))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                actionButton("crop", "Crop") { model.onAction?(.crop) }
                actionButton("doc.on.doc", "Copy") { model.onAction?(.copyArea) }
                actionButton("trash", "Delete") { model.onAction?(.eraseArea) }
                actionButton("paintbrush.fill", "Fill") { model.onAction?(.fillArea) }
                actionButton("xmark.circle", "Deselect") { model.onAction?(.deselectArea) }
            } else {
                Text("Drag on the picture to choose an area, then crop, copy, delete or fill it.").font(.caption).foregroundStyle(.secondary)
            }
            actionButton("rectangle.dashed", "Select All") { model.onAction?(.selectAllArea) }
        }
    }

    private func actionButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 12)) }
            .buttonStyle(.bordered).controlSize(.small)
    }

    @ViewBuilder private var controlsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hint = model.hint, model.properties.isEmpty {
                HStack(spacing: 10) {
                    Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 38)
            } else if model.isAreaTool {
                areaBar.frame(height: 38)
            } else if model.wraps {
                WrapLayout(spacing: 10, rowSpacing: 4) {
                    Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(model.properties, id: \.self) { control(for: $0) }
                    toolExtras
                }
                .padding(.vertical, 6)
            } else {
                controlsRow.frame(height: 38)
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private func control(for property: StyleProperty) -> some View {
        switch property {
        case .stroke:
            labelled(model.title(.stroke, default: "Color")) {
                ColorSwatchButton(color: Binding(get: { model.style.strokeColor }, set: { c in model.edit { $0.strokeColor = c } }),
                                  allowsClear: false, help: "Color")
            }
        case .fill:
            labelled(model.title(.fill, default: "Fill")) {
                ColorSwatchButton(color: Binding(get: { model.style.fillColor }, set: { c in model.edit { $0.fillColor = c } }),
                                  allowsClear: true, help: "Fill color")
            }
        case .width:
            labelled(model.title(.width, default: "Width")) {
                Slider(value: Binding(get: { model.style.lineWidth }, set: { v in model.edit { $0.lineWidth = v.rounded() } }), in: 1...40)
                    .frame(width: 64)
                Text("\(Int(model.style.lineWidth))").monospacedDigit().frame(width: 22, alignment: .trailing).font(.caption)
            }
        case .opacity:
            labelled("Opacity") {
                Slider(value: Binding(get: { model.style.opacity }, set: { v in model.edit { $0.opacity = v } }), in: 0.05...1)
                    .frame(width: 56)
                Text("\(Int((model.style.opacity * 100).rounded()))%").monospacedDigit().frame(width: 32, alignment: .trailing).font(.caption)
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
                .labelsHidden().frame(width: 112)
            }
        case .fontSize:
            labelled(model.title(.fontSize, default: "Size")) {
                Slider(value: Binding(get: { model.style.fontSize }, set: { v in model.edit { $0.fontSize = v.rounded() } }), in: 8...200)
                    .frame(width: 64)
                Text("\(Int(model.style.fontSize))").monospacedDigit().frame(width: 22, alignment: .trailing).font(.caption)
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
                    .frame(width: 80)
                Text("\(Int(model.style.strength))").monospacedDigit().frame(width: 24, alignment: .trailing).font(.caption)
            }
        case .redaction:
            labelled(model.title(.redaction, default: "Hide with")) {
                Picker("Hide with", selection: Binding(get: { model.style.redaction }, set: { v in model.edit { $0.redaction = v } })) {
                    ForEach(RedactionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 168)
            }
        case .endHead:
            labelled(model.title(.endHead, default: "Head")) { headPicker(model.style.endHead, atStart: false) { v in model.edit { $0.endHead = v } } }
        case .startHead:
            labelled(model.title(.startHead, default: "Tail")) { headPicker(model.style.startHead, atStart: true) { v in model.edit { $0.startHead = v } } }
        case .textColor:
            labelled(model.title(.textColor, default: "Text")) {
                ColorSwatchButton(color: Binding(get: { model.style.textColor }, set: { c in model.edit { $0.textColor = c } }),
                                  allowsClear: false, help: "Text color")
            }
        case .zoom:
            labelled(model.title(.zoom, default: "Zoom")) {
                Slider(value: Binding(get: { model.style.strength }, set: { v in model.edit { $0.strength = v.rounded() } }), in: 2...8, step: 1)
                    .frame(width: 64)
                Text("\(Int(model.style.strength))×").monospacedDigit().frame(width: 26, alignment: .trailing).font(.caption)
            }
        case .cornerRadius:
            labelled("Corners") {
                Slider(value: Binding(get: { model.style.cornerRadius }, set: { v in model.edit { $0.cornerRadius = v.rounded() } }), in: 0...100)
                    .frame(width: 56)
            }
        }
    }

    private func headPicker(_ current: ArrowHeadStyle, atStart: Bool, _ set: @escaping (ArrowHeadStyle) -> Void) -> some View {
        HeadPickerButton(current: current, atStart: atStart, color: model.style.strokeColor, set: set)
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct IdealWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// Lays children left to right and wraps to a new row when the line is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: bounds.width)
        // Centre each item vertically within its row.
        var rowTops: [CGFloat: CGFloat] = [:]
        for f in laid.frames { rowTops[f.minY] = max(rowTops[f.minY] ?? 0, f.height) }
        for (view, frame) in zip(subviews, laid.frames) {
            let rowHeight = rowTops[frame.minY] ?? frame.height
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY + (rowHeight - frame.height) / 2),
                       proposal: ProposedViewSize(frame.size))
        }
    }
}
