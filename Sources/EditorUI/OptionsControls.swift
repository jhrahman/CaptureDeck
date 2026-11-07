import AppKit
import CoreModels
import EditorEngine
import SwiftUI

/// A colour button that opens a palette of ready colours (one click), with the full colour panel one step further.
struct ColorSwatchButton: View {
    @Binding var color: RGBAColor
    var allowsClear: Bool
    var help: String
    @State private var open = false

    static let palette: [RGBAColor] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#0A84FF", "#5E5CE6", "#BF5AF2",
        "#FF2D92", "#A2845E", "#000000", "#3A3A3C", "#8E8E93", "#C7C7CC", "#FFFFFF", "#FFF200",
    ].compactMap { RGBAColor(hex: $0) }

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.5).opacity(0.25))
                if color.alpha > 0 {
                    RoundedRectangle(cornerRadius: 4).fill(swiftUIColor(color)).padding(3)
                } else {
                    Image(systemName: "nosign").foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help).accessibilityLabel(help)
        .popover(isPresented: $open, arrowEdge: .bottom) { palettePanel }
    }

    private var palettePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 8), spacing: 6) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        var picked = swatch
                        if color.alpha > 0 && color.alpha < 1 { picked.alpha = color.alpha }      // keep the current transparency
                        color = picked
                    } label: {
                        RoundedRectangle(cornerRadius: 5).fill(swiftUIColor(swatch))
                            .frame(width: 24, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(isCurrent(swatch) ? 0.9 : 0.25), lineWidth: isCurrent(swatch) ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.hex)
                }
            }
            HStack(spacing: 8) {
                Text("Custom").font(.caption).foregroundStyle(.secondary)
                ColorPicker("Custom color", selection: Binding(get: { swiftUIColor(color) }, set: { color = rgba($0) }), supportsOpacity: true)
                    .labelsHidden()
                Spacer()
                if allowsClear {
                    Button("No fill") { color = .clear; open = false }.controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    private func isCurrent(_ swatch: RGBAColor) -> Bool {
        abs(color.red - swatch.red) < 0.01 && abs(color.green - swatch.green) < 0.01 && abs(color.blue - swatch.blue) < 0.01 && color.alpha > 0
    }
}

/// Chooses an arrow's head or tail from small pictures of each design.
struct HeadPickerButton: View {
    var current: ArrowHeadStyle
    var atStart: Bool
    var color: RGBAColor
    var set: (ArrowHeadStyle) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                HeadGlyph(kind: current, atStart: atStart, color: swiftUIColor(color))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.5).opacity(0.2)))
        }
        .buttonStyle(.plain)
        .help(atStart ? "Tail: \(current.title)" : "Head: \(current.title)")
        .accessibilityLabel(atStart ? "Tail style, \(current.title)" : "Head style, \(current.title)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 4) {
                ForEach(ArrowHeadStyle.allCases, id: \.self) { kind in
                    Button { set(kind); open = false } label: {
                        HStack(spacing: 10) {
                            HeadGlyph(kind: kind, atStart: atStart, color: .primary)
                            Text(kind.title).font(.system(size: 12))
                            Spacer(minLength: 0)
                            if kind == current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                        }
                        .padding(.horizontal, 8).frame(width: 170, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(kind == current ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }
}

/// A short line with the given end design, drawn the way the canvas draws it.
struct HeadGlyph: View {
    var kind: ArrowHeadStyle
    var atStart: Bool
    var color: Color

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            let left = CGPoint(x: 2, y: y), right = CGPoint(x: size.width - 2, y: y)
            let tip = atStart ? left : right, tail = atStart ? right : left
            var line = Path(); line.move(to: left); line.addLine(to: right)
            context.stroke(line, with: .color(color), lineWidth: 1.6)
            let dir: CGFloat = tip.x > tail.x ? 1 : -1
            func p(_ along: CGFloat, _ across: CGFloat) -> CGPoint { CGPoint(x: tip.x - dir * along, y: tip.y + across) }
            var head = Path()
            switch kind {
            case .none: break
            case .open:
                head.move(to: p(6, -4)); head.addLine(to: tip); head.addLine(to: p(6, 4))
                context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            case .filled:
                head.move(to: tip); head.addLine(to: p(7, -4)); head.addLine(to: p(7, 4)); head.closeSubpath()
                context.fill(head, with: .color(color))
            case .diamond:
                head.move(to: tip); head.addLine(to: p(4, -3.5)); head.addLine(to: p(8, 0)); head.addLine(to: p(4, 3.5)); head.closeSubpath()
                context.fill(head, with: .color(color))
            case .dot:
                context.fill(Path(ellipseIn: CGRect(x: p(3, 0).x - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(color))
            case .bar:
                head.move(to: p(0, -5)); head.addLine(to: p(0, 5))
                context.stroke(head, with: .color(color), lineWidth: 2)
            }
        }
        .frame(width: 40, height: 14)
    }
}
