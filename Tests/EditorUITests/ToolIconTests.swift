import AppKit
import SwiftUI
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

@MainActor
struct ToolRibbonTests {
    @Test func everyToolIsInExactlyOneRibbonSection() {
        let grouped = EditorToolRegistry.groups.flatMap { $0 }.map(\.id)
        #expect(Set(grouped).count == grouped.count, "a tool appears twice in the ribbon")
        #expect(Set(grouped) == Set(EditorToolRegistry.descriptors.map(\.id)), "a tool is missing from the ribbon")
    }

    @Test func ribbonOrderMatchesTheToolListOrder() {
        #expect(EditorToolRegistry.groups.flatMap { $0 }.map(\.id) == EditorToolRegistry.descriptors.map(\.id))
    }

    @Test func toolInstancesFollowTheRibbonOrder() {
        #expect(EditorToolRegistry.makeTools().map { $0.descriptor.id } == EditorToolRegistry.descriptors.map(\.id))
    }

    @Test func toolKeysAreUnique() {
        let keys = EditorToolRegistry.descriptors.map(\.key)
        #expect(Set(keys).count == keys.count, "two tools share a shortcut key: \(keys)")
    }
}

@MainActor
struct ToolRibbonRenderingTests {
    /// Draws the real ribbon view offscreen. Set RIBBON_PNG=/path/file.png to keep a picture of it.
    private func renderRibbon(dark: Bool) throws -> NSBitmapImageRep {
        let model = ToolRibbonModel()
        model.selectedID = EditorToolRegistry.ellipse.id
        let host = NSHostingView(rootView: ToolRibbonView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 42)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    @Test func theRibbonShowsManyDistinctIconColors() throws {
        for dark in [true, false] {
            let rep = try renderRibbon(dark: dark)
            if let path = ProcessInfo.processInfo.environment["RIBBON_PNG"], let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: dark ? "-dark.png" : "-light.png")))
            }
            // Count how many different hues of strongly colored pixels appear (12 hue buckets).
            var buckets = [Int](repeating: 0, count: 12)
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                if s > 0.55 && b > 0.5 { buckets[min(Int(h * 12), 11)] += 1 }
            } }
            let populated = buckets.filter { $0 >= 15 }.count
            #expect(populated >= 7, "\(dark ? "dark" : "light") ribbon shows only \(populated) icon hues: \(buckets)")
        }
    }
}
