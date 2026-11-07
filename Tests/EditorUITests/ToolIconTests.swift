import AppKit
import CoreModels
import Testing
@testable import EditorUI

@MainActor
struct ToolIconTests {
    @Test func everyToolHasItsOwnColor() {
        let colors = EditorToolRegistry.descriptors.map(\.iconColor.hex)
        #expect(Set(colors).count == colors.count, "two tools share an icon color: \(colors)")
    }

    /// Average color of the (nearly) opaque pixels of an icon.
    private func averageColor(of image: NSImage) -> (r: Double, g: Double, b: Double)? {
        let size = 48
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 4, y: 4, width: size - 8, height: size - 8))
        NSGraphicsContext.restoreGraphicsState()

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in 0..<size {
            for x in 0..<size {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
        }
        return n > 0 ? (r / n, g / n, b / n) : nil
    }

    @Test func iconsAreDrawnInTheirOwnColorNotTheSystemTint() throws {
        for tool in EditorToolRegistry.descriptors {
            let icon = try #require(ToolIcons.image(for: tool, pointSize: 32), "no icon for \(tool.title)")
            #expect(!icon.isTemplate, "\(tool.title) icon would be re-tinted by the toolbar")
            let average = try #require(averageColor(of: icon), "\(tool.title) icon drew nothing")
            #expect(abs(average.r - tool.iconColor.red) < 0.06 && abs(average.g - tool.iconColor.green) < 0.06 && abs(average.b - tool.iconColor.blue) < 0.06,
                    "\(tool.title): icon color (\(average)) is not \(tool.iconColor.hex)")
        }
    }

    @Test func fallbackSymbolIsUsedWhenTheFirstIsMissing() {
        let icon = ToolIcons.image(symbols: ["this.symbol.does.not.exist", "circle"], color: .black, description: "x")
        #expect(icon != nil)
        #expect(ToolIcons.image(symbols: ["nope.nope"], color: .black, description: "x") == nil)
    }
}
