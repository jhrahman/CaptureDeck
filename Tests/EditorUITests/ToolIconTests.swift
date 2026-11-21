import AppKit
import SwiftUI
import CoreModels
import Testing
@testable import EditorUI

@MainActor
struct ToolIconTests {
    @Test func iconsAreGenericTemplatesTintedBySystem() throws {
        for tool in EditorToolRegistry.descriptors {
            let icon = try #require(ToolIcons.image(for: tool, pointSize: 32), "no icon for \(tool.title)")
            #expect(icon.isTemplate, "\(tool.title) icon should be a plain template icon")
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

    @Test func theRibbonIsMonochrome() throws {
        for dark in [true, false] {
            let rep = try renderRibbon(dark: dark)
            if let path = ProcessInfo.processInfo.environment["RIBBON_PNG"], let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: dark ? "-dark.png" : "-light.png")))
            }
            // The selected tool's highlight is blue, so only count strongly colored pixels outside that button.
            var colored = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where x < 420 || x > 560 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                if s > 0.55 && b > 0.5 { colored += 1 }
            } }
            #expect(colored < 15, "\(dark ? "dark" : "light") ribbon has \(colored) strongly colored pixels")
        }
    }
}
