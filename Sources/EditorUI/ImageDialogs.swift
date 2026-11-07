import AppKit
import CoreModels
import EditorEngine
import SwiftUI

/// Small helpers shared by the dialogs.
private func color(_ c: RGBAColor) -> Color { Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }

private struct DialogButtons: View {
    let applyTitle: String
    let canApply: Bool
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(applyTitle, action: onApply).keyboardShortcut(.defaultAction).disabled(!canApply)
        }
    }
}

// MARK: - Resize

struct ResizeSheet: View {
    enum Mode: String, CaseIterable { case pixels = "Pixels", percent = "Percent" }

    let original: (width: Int, height: Int)
    let onApply: (Int, Int) -> Void
    let onCancel: () -> Void

    @State private var mode = Mode.pixels
    @State private var width: Int
    @State private var height: Int
    @State private var percent = 100.0
    @State private var keepProportions: Bool

    init(original: (width: Int, height: Int), keepProportions: Bool, onApply: @escaping (Int, Int) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onApply = onApply
        self.onCancel = onCancel
        _width = State(initialValue: original.width)
        _height = State(initialValue: original.height)
        _keepProportions = State(initialValue: keepProportions)
    }

    private var result: (width: Int, height: Int) {
        mode == .percent ? ResizeMath.size(from: original, percent: percent) : (width, height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize Image").font(.headline)
            Text("Current size: \(original.width) × \(original.height) px").foregroundStyle(.secondary)
            Picker("Resize by", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()

            if mode == .pixels {
                Form {
                    TextField("Width (px)", value: $width, format: .number)
                        .onChange(of: width) { new in
                            if keepProportions, new >= 1 { height = ResizeMath.height(forWidth: new, keepingProportionsOf: original) }
                        }
                    TextField("Height (px)", value: $height, format: .number)
                        .onChange(of: height) { new in
                            if keepProportions, new >= 1 { width = ResizeMath.width(forHeight: new, keepingProportionsOf: original) }
                        }
                    Toggle("Keep proportions", isOn: $keepProportions)
                }
            } else {
                Form {
                    HStack {
                        Slider(value: $percent, in: 1...400, step: 1)
                        TextField("", value: $percent, format: .number).frame(width: 56).multilineTextAlignment(.trailing)
                        Text("%")
                    }
                    HStack {
                        ForEach([25.0, 50, 75, 200], id: \.self) { p in
                            Button("\(Int(p))%") { percent = p }
                        }
                    }
                }
            }
            Text("New size: \(result.width) × \(result.height) px").monospacedDigit()
            DialogButtons(applyTitle: "Resize", canApply: ResizeMath.isValid(width: result.width, height: result.height)
                          && (result.width, result.height) != original, onApply: { onApply(result.width, result.height) }, onCancel: onCancel)
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Canvas size

struct CanvasSizeSheet: View {
    let original: (width: Int, height: Int)
    let onApply: (Int, Int, CanvasAnchor, RGBAColor) -> Void
    let onCancel: () -> Void

    @State private var width: Int
    @State private var height: Int
    @State private var anchor = CanvasAnchor.center
    @State private var fill: Color

    init(original: (width: Int, height: Int), fill: RGBAColor, onApply: @escaping (Int, Int, CanvasAnchor, RGBAColor) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onApply = onApply
        self.onCancel = onCancel
        _width = State(initialValue: original.width)
        _height = State(initialValue: original.height)
        _fill = State(initialValue: color(fill))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Canvas Size").font(.headline)
            Text("Current size: \(original.width) × \(original.height) px. Making the canvas bigger adds space around the picture; smaller crops it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Width (px)", value: $width, format: .number)
                TextField("Height (px)", value: $height, format: .number)
                ColorPicker("New area color", selection: $fill, supportsOpacity: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep the picture at")
                AnchorGrid(anchor: $anchor)
            }
            DialogButtons(applyTitle: "Apply", canApply: ResizeMath.isValid(width: width, height: height) && (width, height) != original,
                          onApply: { onApply(width, height, anchor, rgba(fill)) }, onCancel: onCancel)
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct AnchorGrid: View {
    @Binding var anchor: CanvasAnchor
    private let rows: [[CanvasAnchor]] = [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { cell in
                        Button { anchor = cell } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(anchor == cell ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 30, height: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cell.rawValue)
                    }
                }
            }
        }
    }
}

// MARK: - Rotate by angle

struct RotateSheet: View {
    let onApply: (Double, RGBAColor) -> Void
    let onCancel: () -> Void

    @State private var degrees = 15.0
    @State private var fill: Color

    init(fill: RGBAColor, onApply: @escaping (Double, RGBAColor) -> Void, onCancel: @escaping () -> Void) {
        self.onApply = onApply
        self.onCancel = onCancel
        _fill = State(initialValue: color(fill))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rotate by Angle").font(.headline)
            Text("Positive angles turn the picture clockwise. The canvas grows to fit it.").foregroundStyle(.secondary)
            Form {
                HStack {
                    Slider(value: $degrees, in: -180...180, step: 0.5)
                    TextField("", value: $degrees, format: .number).frame(width: 64).multilineTextAlignment(.trailing)
                    Text("°")
                }
                ColorPicker("Corner color", selection: $fill, supportsOpacity: true)
            }
            DialogButtons(applyTitle: "Rotate", canApply: degrees != 0 && abs(degrees) <= 360,
                          onApply: { onApply(degrees, rgba(fill)) }, onCancel: onCancel)
        }
        .padding(20)
        .frame(width: 400)
    }
}
