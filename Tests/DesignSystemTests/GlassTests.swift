import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct GlassTests {
    private func rgba(_ color: NSColor, _ name: NSAppearance.Name) -> [CGFloat] {
        var result: [CGFloat] = []
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            result = [c.redComponent, c.alphaComponent]
        }
        return result
    }

    @Test func hairlinesAreLightOnDarkGlassAndDarkOnLightGlass() {
        #expect(rgba(Glass.stroke, .darkAqua)[0] == 1)
        #expect(rgba(Glass.stroke, .aqua)[0] == 0)
        #expect(rgba(Glass.stroke, .darkAqua)[1] > 0 && rgba(Glass.stroke, .darkAqua)[1] < 0.3)
        #expect(rgba(Glass.strongStroke, .aqua)[1] > rgba(Glass.stroke, .aqua)[1])
    }
}
