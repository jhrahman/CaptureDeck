import DesignSystem
import SwiftUI

/// What the zoom control shows and does. The editor keeps `percent` up to date and supplies the actions.
@MainActor
final class ZoomModel: ObservableObject {
    @Published var percent: Double = 100
    /// Dragging the slider: zoom straight to this percentage (no easing, the hand is already steering).
    var onSlide: ((Double) -> Void)?
    /// The minus / plus buttons: one eased step.
    var onStep: ((_ zoomIn: Bool) -> Void)?
    var onFit: (() -> Void)?
    var onPercent: ((Double) -> Void)?
}

/// The zoom control in the bottom-left corner of the editor: zoom out, a slider, zoom in, and the current zoom as a menu with
/// presets. The slider is logarithmic, so every part of it changes the picture by the same proportion.
struct ZoomBar: View {
    @ObservedObject var model: ZoomModel

    static let sliderRange: ClosedRange<Double> = 5...800
    static let presets: [Double] = [25, 50, 100, 200, 400, 800]

    /// 0...1 along the slider for a zoom percentage, and back.
    static func position(forPercent percent: Double) -> Double {
        let lo = log(sliderRange.lowerBound), hi = log(sliderRange.upperBound)
        return min(max((log(max(percent, 0.0001)) - lo) / (hi - lo), 0), 1)
    }

    static func percent(forPosition position: Double) -> Double {
        let lo = log(sliderRange.lowerBound), hi = log(sliderRange.upperBound)
        return exp(lo + min(max(position, 0), 1) * (hi - lo))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { model.onStep?(false) } label: { Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
                .buttonStyle(.borderless).help("Zoom Out (⌘−)").accessibilityLabel("Zoom out")

            Slider(value: Binding(get: { Self.position(forPercent: model.percent) },
                                  set: { model.onSlide?(Self.percent(forPosition: $0)) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 112)
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(Int(model.percent.rounded())) percent")

            Button { model.onStep?(true) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
                .buttonStyle(.borderless).help("Zoom In (⌘+)").accessibilityLabel("Zoom in")

            Menu {
                Button("Fit to Window") { model.onFit?() }
                Divider()
                ForEach(Self.presets, id: \.self) { value in
                    Button("\(Int(value))%") { model.onPercent?(value) }
                }
            } label: {
                Text("\(Int(model.percent.rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a zoom level")
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Color(Glass.fill)))
        .overlay(Capsule().strokeBorder(Color(Glass.strongStroke)))
    }
}
