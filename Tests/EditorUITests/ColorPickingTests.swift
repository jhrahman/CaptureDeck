import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

@MainActor
private final class FakeHost: ToolHost {
    var picked: [RGBAColor] = []
    func editText(annotationID: UUID?, rect: CGRect, text: String, style: AnnotationStyle, kind: TextEditKind) {}
    func pickedColor(_ color: RGBAColor) { picked.append(color) }
}

@MainActor
struct ColorPickingTests {
    /// Left half a known orange, right half a known teal.
    static func twoColourImage() -> CapturedImage {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
    }

    private func wait(_ seconds: TimeInterval = 10, until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 30_000_000) }
    }

    // MARK: Registry

    @Test func theEyedropperIsOnTheRibbonJustBeforeThePaintBucket() {
        let ids = EditorToolRegistry.descriptors.map(\.id)
        let pick = try? #require(ids.firstIndex(of: "pickColor"))
        #expect(pick != nil && ids[(pick ?? 0) + 1] == "fill")
        let keys = EditorToolRegistry.descriptors.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    // MARK: Loupe geometry

    @Test func theLoupeStaysInsideThePictureAndSwapsSidesAtTheEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let middle = ColorLoupe.area(around: CGPoint(x: 300, y: 200), unit: 1, bounds: bounds)
        #expect(middle.minX > 300 && middle.minY > 200)                                // lower right of the pointer
        let corner = ColorLoupe.area(around: CGPoint(x: 990, y: 590), unit: 1, bounds: bounds)
        #expect(corner.maxX <= 990 + 8 && corner.maxY <= 590 + 8)                      // moved to the upper left instead
        let topLeft = ColorLoupe.area(around: CGPoint(x: 2, y: 2), unit: 1, bounds: bounds)
        #expect(topLeft.minX >= -8 && topLeft.minY >= -8)
    }

    // MARK: Eyedropper tool

    @Test func hoveringShowsTheColourAndClickingPicksIt() async throws {
        let doc = EditorDocument(original: Self.twoColourImage(), title: "t")
        let tool = EyedropperTool()
        let host = FakeHost()
        let context = ToolContext(document: doc, zoom: 2, style: .default, host: host)
        tool.prepare(context: context)
        await wait { _ = tool.pointerMoved(to: CGPoint(x: 50, y: 50), context: context); return tool.statusText.contains("#FF8000") }
        #expect(tool.statusText.contains("#FF8000"), "status: \(tool.statusText)")
        #expect(tool.overlayRect != nil)

        _ = tool.pointerMoved(to: CGPoint(x: 300, y: 100), context: context)
        #expect(tool.statusText.contains("#0099") )
        tool.mouseDown(at: CGPoint(x: 300, y: 100), context: context)
        tool.mouseDragged(to: CGPoint(x: 250, y: 100), context: context)              // slide to another pixel before letting go
        tool.mouseUp(at: CGPoint(x: 250, y: 100), context: context)
        let picked = try #require(host.picked.last)
        #expect(abs(picked.red - 0) < 0.01 && abs(picked.green - 0.6) < 0.01 && abs(picked.blue - 0.6) < 0.01)
        #expect(host.picked.count == 1)
    }

    @Test func pickingOutsideThePictureDoesNothing() async {
        let doc = EditorDocument(original: Self.twoColourImage(), title: "t")
        let tool = EyedropperTool()
        let host = FakeHost()
        let context = ToolContext(document: doc, zoom: 2, style: .default, host: host)
        tool.prepare(context: context)
        await wait { _ = tool.pointerMoved(to: CGPoint(x: 10, y: 10), context: context); return !tool.statusText.contains("Click any") }
        tool.mouseUp(at: CGPoint(x: -20, y: 10), context: context)
        #expect(host.picked.isEmpty)
    }

    // MARK: Editor wiring

    @Test func pickingWithTheEyedropperSetsTheBucketColourAndSwitchesToIt() {
        let doc = EditorDocument(original: Self.twoColourImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.pickColor.id)
        #expect(controller.activeToolID == "pickColor")
        controller.pickedColor(RGBAColor(red: 0.2, green: 0.4, blue: 0.6))
        #expect(controller.activeToolID == "fill")
        #expect(abs(controller.currentStyle.strokeColor.green - 0.4) < 0.001)
    }

    @Test func optionPickingSetsTheActiveToolsOwnColourWithoutSwitching() {
        let doc = EditorDocument(original: Self.twoColourImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.pencil.id)
        controller.simulateOptionPick(RGBAColor(red: 1, green: 0.5, blue: 0))
        #expect(controller.activeToolID == "pencil")
        #expect(abs(controller.optionsStyle.strokeColor.red - 1) < 0.001 && abs(controller.optionsStyle.strokeColor.green - 0.5) < 0.001)
    }

    // MARK: Paint bucket preview

    @Test func thePaintBucketPreviewsTheRegionUnderThePointer() async {
        let doc = EditorDocument(original: Self.twoColourImage(), title: "t")
        let tool = FillTool()
        var changed = 0
        tool.overlayChanged = { changed += 1 }
        let context = ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.fill.defaultStyle)
        _ = tool.pointerMoved(to: CGPoint(x: 50, y: 50), context: context)
        await wait { changed > 0 }
        #expect(changed == 1)                                                           // the region arrived and the canvas was told
        let again = tool.pointerMoved(to: CGPoint(x: 120, y: 80), context: context)    // still the same orange region
        #expect(!again)                                                                  // no new work, no flicker
        #expect(changed == 1)
    }

    @Test func clickingFillsWithoutSelectingSoTheNextClickIsFree() {
        let doc = EditorDocument(original: Self.twoColourImage(), title: "t")
        let tool = FillTool()
        let context = ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.fill.defaultStyle)
        tool.mouseUp(at: CGPoint(x: 50, y: 50), context: context)
        tool.mouseUp(at: CGPoint(x: 300, y: 50), context: context)
        #expect(doc.annotations.count == 2)
        #expect(doc.selectedAnnotationIDs.isEmpty)
    }
}

@MainActor
struct ColorPickingSnapshotTests {
    @Test func loupeAndFillPreview() async throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.pickColor.id)
        try await Task.sleep(nanoseconds: 600_000_000)                                  // the pixels are unpacked in the background
        controller.simulatePointer(at: CGPoint(x: 480, y: 112))                          // just under the blue header, near its edge
        try UXSnapshotTests.render(controller, width: 1100, height: 640, dark: true, name: "eyedropper-loupe")

        controller.selectTool(id: EditorToolRegistry.fill.id)
        controller.simulatePointer(at: CGPoint(x: 400, y: 400))                          // inside the white box
        try await Task.sleep(nanoseconds: 700_000_000)                                  // the region is found in the background
        try UXSnapshotTests.render(controller, width: 1100, height: 640, dark: true, name: "bucket-preview")
    }
}
