import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

@MainActor
struct RedactToolsTests {
    /// A white "screenshot" with a few lines of large, clear text.
    static func textScreenshot() -> CapturedImage {
        let size = NSSize(width: 1000, height: 420)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let lines = ["Account 48151623 Secret", "Password hunter2 admin", "Email john@example.com"]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 40, y: size.height - 110 - CGFloat(i) * 120),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        return CapturedImage(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!, scale: 1)
    }

    /// Waits (without blocking the main actor, which the text reading needs) until `condition` holds.
    private func wait(_ seconds: TimeInterval = 20, until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func context(_ doc: EditorDocument, tool: EditorToolDescriptor) -> ToolContext {
        ToolContext(document: doc, zoom: 2, style: tool.defaultStyle)
    }

    // MARK: Registry

    @Test func bothToolsAreOnTheRibbonWithDistinctKeys() {
        let ids = EditorToolRegistry.descriptors.map(\.id)
        #expect(ids.contains("redactBrush") && ids.contains("hideText"))
        let keys = EditorToolRegistry.descriptors.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func theBrushOffersSizeModeStrengthAndCoverColour() {
        let props = EditorToolRegistry.redactBrush.styleProperties
        #expect(props.contains(.width) && props.contains(.redaction) && props.contains(.strength) && props.contains(.stroke))
        #expect(EditorToolRegistry.hideText.defaultStyle.redaction == .solid)      // the strongest hiding is the default for text
    }

    @Test func selectingABrushStrokeShowsItsOwnControls() {
        let (properties, _) = EditorToolRegistry.properties(forShapeTypes: ["redactBrush"])
        #expect(properties.contains(.redaction))
    }

    // MARK: Brush

    @Test func paintingWithTheBrushAddsAnUnselectedStroke() throws {
        let doc = EditorDocument(original: Self.textScreenshot(), title: "t")
        let tool = RedactBrushTool(); tool.shiftHeld = { false }
        let c = context(doc, tool: EditorToolRegistry.redactBrush)
        tool.mouseDown(at: CGPoint(x: 60, y: 100), context: c)
        for x in stride(from: 70, through: 500, by: 12) { tool.mouseDragged(to: CGPoint(x: CGFloat(x), y: 100 + CGFloat(x % 5)), context: c) }
        tool.mouseUp(at: CGPoint(x: 500, y: 102), context: c)
        let stroke = try #require(doc.annotations.last)
        #expect(stroke.shape is RedactBrushShape)
        #expect(stroke.style.redaction == .blur && stroke.style.lineWidth == 30)
        #expect(doc.selectedAnnotationIDs.isEmpty)
    }

    @Test func theBrushNeverPicksUpExistingObjects() {
        let tools = EditorToolRegistry.makeTools()
        #expect(!CanvasView.allowsGrabbing(from: tools.first { $0.descriptor.id == "redactBrush" }!))
        #expect(!CanvasView.allowsGrabbing(from: tools.first { $0.descriptor.id == "hideText" }!))
    }

    // MARK: Hide Text

    @Test func hideTextFindsTheWordsAndHidesOneWithAClick() async throws {
        let doc = EditorDocument(original: Self.textScreenshot(), title: "t")
        let tool = HideTextTool()
        let c = context(doc, tool: EditorToolRegistry.hideText)
        tool.prepare(context: c)
        #expect(tool.statusText.contains("Reading"))
        await wait { tool.barButton != nil }
        #expect(tool.barButton?.title == "Hide All Text", "status: \\(tool.statusText)")

        // Find where "Password" is by hovering over the middle line.
        var target: CGPoint?
        for x in stride(from: 40, to: 400, by: 10) where tool.pointerMoved(to: CGPoint(x: CGFloat(x), y: 180), context: c) { target = CGPoint(x: CGFloat(x), y: 180); break }
        let point = try #require(target, "no word under the pointer on the second line")
        tool.mouseDown(at: point, context: c)
        tool.mouseUp(at: point, context: c)
        #expect(doc.annotations.count == 1)
        let bar = try #require(doc.annotations.first)
        #expect(bar.shape is RedactBrushShape)
        #expect(bar.style.redaction == .solid)
        #expect(doc.undoNames.last == "Hide Text")
    }

    @Test func draggingAcrossWordsHidesThemAsOneStepAndHideAllCoversEverything() async throws {
        let doc = EditorDocument(original: Self.textScreenshot(), title: "t")
        let tool = HideTextTool()
        let c = context(doc, tool: EditorToolRegistry.hideText)
        tool.prepare(context: c)
        await wait { tool.barButton != nil }
        // Sweep along the whole first line.
        tool.mouseDown(at: CGPoint(x: 45, y: 100), context: c)
        for x in stride(from: 50, through: 900, by: 20) { tool.mouseDragged(to: CGPoint(x: CGFloat(x), y: 100), context: c) }
        tool.mouseUp(at: CGPoint(x: 900, y: 100), context: c)
        #expect(doc.annotations.count >= 1)
        let afterSweep = doc.annotations.count
        #expect(afterSweep <= 3)                                                   // neighbouring words share one bar
        tool.pressBarButton(context: c)
        #expect(doc.annotations.count > afterSweep)
        doc.undo()                                                                 // Hide All is one undo step
        #expect(doc.annotations.count == afterSweep)
    }

    @Test func aPictureWithoutTextSaysSo() async {
        let blank = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        blank.setFillColor(CGColor(gray: 1, alpha: 1)); blank.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let doc = EditorDocument(original: CapturedImage(cgImage: blank.makeImage()!, scale: 1), title: "t")
        let tool = HideTextTool()
        tool.prepare(context: context(doc, tool: EditorToolRegistry.hideText))
        await wait { tool.statusText.contains("No text") }
        #expect(tool.statusText.contains("No text"))
        #expect(tool.barButton == nil)
    }
}

@MainActor
struct RedactSnapshotTests {
    @Test func theToolReadyAndTheThreeWaysOfHiding() async throws {
        let doc = EditorDocument(original: RedactToolsTests.textScreenshot(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.hideText.id)
        try await Task.sleep(nanoseconds: 3_000_000_000)                           // the text is read in the background
        try UXSnapshotTests.render(controller, width: 1200, height: 700, dark: true, name: "hidetext-ready")

        for mode in RedactionMode.allCases {
            let document = EditorDocument(original: RedactToolsTests.textScreenshot(), title: "t")
            let tool = HideTextTool()
            var style = EditorToolRegistry.hideText.defaultStyle
            style.redaction = mode
            let context = ToolContext(document: document, zoom: 2, style: style)
            tool.prepare(context: context)
            for _ in 0..<100 where tool.barButton == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            tool.pressBarButton(context: context)                                  // Hide All Text
            let viewer = EditorViewController(document: document, settings: nil)
            _ = viewer.view
            viewer.selectTool(id: EditorToolRegistry.rectangleSelect.id)
            document.clearSelection()
            try UXSnapshotTests.render(viewer, width: 1200, height: 700, dark: true, name: "hidden-\(mode.rawValue)")
        }
    }
}
