import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

@MainActor
struct SelectRectCropTests {
    private func makeDocument() -> EditorDocument {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")        // 1400 x 900
        doc.selectAll()
        return doc
    }

    private func context(_ doc: EditorDocument, crop: Bool = true, keep: Bool = true) -> ToolContext {
        var c = ToolContext(document: doc, zoom: 2, style: .default)       // zoom 2 = 1 image pixel is 1 screen point at 2x
        c.cropOnSelectionDrag = crop
        c.keepWholeImageSelected = keep
        return c
    }

    private func drag(_ tool: SelectRectTool, from a: CGPoint, to b: CGPoint, _ c: ToolContext) {
        tool.mouseDown(at: a, context: c)
        tool.mouseDragged(to: b, context: c)
        tool.mouseUp(at: b, context: c)
    }

    @Test func draggingACornerInwardCropsAtOnce() {
        let doc = makeDocument()
        let tool = SelectRectTool()
        drag(tool, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100), context(doc))      // the top-left corner
        #expect(doc.imageBounds.size == CGSize(width: 1200, height: 800))
        #expect(doc.undoNames.last == "Crop")
        doc.undo()
        #expect(doc.imageBounds.size == CGSize(width: 1400, height: 900))
    }

    @Test func everyEdgeAndCornerCropsFromItsOwnSide() {
        let cases: [(from: CGPoint, to: CGPoint, size: CGSize)] = [
            (CGPoint(x: 1400, y: 900), CGPoint(x: 1300, y: 800), CGSize(width: 1300, height: 800)),     // bottom-right
            (CGPoint(x: 700, y: 0), CGPoint(x: 700, y: 120), CGSize(width: 1400, height: 780)),        // top edge
            (CGPoint(x: 0, y: 450), CGPoint(x: 90, y: 450), CGSize(width: 1310, height: 900)),         // left edge
            (CGPoint(x: 1400, y: 450), CGPoint(x: 1000, y: 450), CGSize(width: 1000, height: 900)),    // right edge
        ]
        for item in cases {
            let doc = makeDocument()
            drag(SelectRectTool(), from: item.from, to: item.to, context(doc))
            #expect(doc.imageBounds.size == item.size, "from \\(item.from)")
        }
    }

    @Test func theWholePictureStaysSelectedSoTheNextSideCanBeTrimmed() {
        let doc = makeDocument()
        let tool = SelectRectTool()
        drag(tool, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100), context(doc))
        #expect(doc.selection == .rect(doc.imageBounds))
        drag(tool, from: CGPoint(x: 1200, y: 800), to: CGPoint(x: 1100, y: 700), context(doc))      // the new bottom-right corner
        #expect(doc.imageBounds.size == CGSize(width: 1100, height: 700))
    }

    @Test func withTheSettingOffAnEdgeDragOnlyResizesTheSelection() {
        let doc = makeDocument()
        drag(SelectRectTool(), from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100), context(doc, crop: false))
        #expect(doc.imageBounds.size == CGSize(width: 1400, height: 900))                           // not cropped
        #expect(doc.selection == .rect(CGRect(x: 200, y: 100, width: 1200, height: 800)))           // just a smaller selection
    }

    @Test func draggingInsideTheWholePictureDrawsANewSelectionInsteadOfCropping() {
        let doc = makeDocument()
        drag(SelectRectTool(), from: CGPoint(x: 300, y: 300), to: CGPoint(x: 600, y: 500), context(doc))
        #expect(doc.imageBounds.size == CGSize(width: 1400, height: 900))
        #expect(doc.selection == .rect(CGRect(x: 300, y: 300, width: 300, height: 200)))
    }

    @Test func aSmallerSelectionTheUserDrewIsNotCroppedWhenItsEdgeMoves() {
        let doc = makeDocument()
        let tool = SelectRectTool()
        drag(tool, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 600, y: 500), context(doc))
        drag(tool, from: CGPoint(x: 600, y: 500), to: CGPoint(x: 700, y: 560), context(doc))        // its bottom-right corner
        #expect(doc.imageBounds.size == CGSize(width: 1400, height: 900))
        #expect(doc.selection == .rect(CGRect(x: 300, y: 300, width: 400, height: 260)))
    }

    @Test func aPlainClickBringsBackTheWholePicture() {
        let doc = makeDocument()
        let tool = SelectRectTool()
        let c = context(doc)
        tool.mouseDown(at: CGPoint(x: 400, y: 400), context: c)
        tool.mouseUp(at: CGPoint(x: 400, y: 400), context: c)
        #expect(doc.selection == .rect(doc.imageBounds))
    }
}

@MainActor
struct OpensWithWholePictureSelectedTests {
    @Test func aNewPictureOpensFullySelectedWithTheRectangleSelectTool() {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        #expect(doc.selection == .rect(doc.imageBounds))
    }

    @Test func aBlankCanvasDoesNotStartSelected() {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "Untitled")
        doc.startsWithFullSelection = false
        _ = EditorViewController(document: doc, settings: nil).view
        #expect(doc.selection == nil)
    }
}

@MainActor
struct OpenedEditorSnapshotTests {
    @Test func freshlyOpenedPicture() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        try UXSnapshotTests.render(controller, width: 1100, height: 640, dark: true, name: "opened-whole-selected")
    }
}

@MainActor
struct PencilToolTests {
    private func context(_ doc: EditorDocument) -> ToolContext { ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.pencil.defaultStyle) }

    private func stroke(_ tool: PencilTool, _ points: [CGPoint], _ c: ToolContext) {
        tool.mouseDown(at: points[0], context: c)
        for p in points.dropFirst() { tool.mouseDragged(to: p, context: c) }
        tool.mouseUp(at: points.last!, context: c)
    }

    @Test func aWigglyHandDrawnLineIsStoredAsFewPoints() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let tool = PencilTool()
        tool.shiftHeld = { false }
        let raw = (0...300).map { CGPoint(x: 100 + CGFloat($0), y: 200 + CGFloat(($0 % 2 == 0) ? 0.4 : -0.4)) }   // a straight line with hand jitter
        stroke(tool, raw, context(doc))
        let shape = try #require(doc.annotations.last?.shape as? PencilShape)
        #expect(shape.points.count < 12)
        #expect(abs(shape.points.last!.x - 400) < 1)                          // it ends exactly where the pointer was let go
        #expect(doc.undoNames.last == "Add Drawing")
    }

    @Test func holdingShiftDrawsAStraightLineSnappedToFortyFiveDegrees() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let tool = PencilTool()
        tool.shiftHeld = { true }
        stroke(tool, [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 135), CGPoint(x: 300, y: 112)], context(doc))
        let shape = try #require(doc.annotations.last?.shape as? PencilShape)
        #expect(shape.points.count == 2)
        #expect(shape.points[0] == CGPoint(x: 100, y: 100))
        #expect(abs(shape.points[1].y - 100) < 0.01)                          // a nearly horizontal drag snaps to horizontal
    }

    @Test func aSingleClickMakesADot() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let tool = PencilTool()
        tool.shiftHeld = { false }
        tool.mouseDown(at: CGPoint(x: 50, y: 50), context: context(doc))
        tool.mouseUp(at: CGPoint(x: 50, y: 50), context: context(doc))
        #expect((doc.annotations.last?.shape as? PencilShape)?.points.count == 1)
    }

    @Test func thePreviewShowsTheStrokeWhileDrawingAndNothingAfter() {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let tool = PencilTool()
        tool.shiftHeld = { false }
        let c = context(doc)
        tool.mouseDown(at: CGPoint(x: 10, y: 10), context: c)
        tool.mouseDragged(to: CGPoint(x: 60, y: 40), context: c)
        #expect(tool.previewAnnotations.count == 1)
        tool.mouseUp(at: CGPoint(x: 60, y: 40), context: c)
        #expect(tool.previewAnnotations.isEmpty)
    }

    @Test func theCursorIsARoundBrushAsBigAsTheLine() {
        let small = BrushCursor.cursor(diameter: 5)
        let big = BrushCursor.cursor(diameter: 40)
        #expect(big.image.size.width > small.image.size.width)
        #expect(BrushCursor.cursor(diameter: 40) === big)                    // cached
    }
}

@MainActor
struct PencilSnapshotTests {
    @Test func shakyStrokeComesOutSmooth() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.pencil.id)
        let tool = PencilTool(); tool.shiftHeld = { false }
        let c = ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.pencil.defaultStyle)
        // A circle-ish loop drawn with a shaky hand: a deterministic wobble of about 2 px on every sample.
        var raw: [CGPoint] = []
        for i in 0...220 {
            let t = CGFloat(i) / 220 * 2 * .pi * 1.1
            let wobble = CGFloat((i * 37) % 5) - 2
            raw.append(CGPoint(x: 600 + 230 * cos(t) + wobble, y: 450 + 160 * sin(t) - wobble))
        }
        tool.mouseDown(at: raw[0], context: c)
        for p in raw.dropFirst() { tool.mouseDragged(to: p, context: c) }
        tool.mouseUp(at: raw.last!, context: c)
        try UXSnapshotTests.render(controller, width: 1100, height: 640, dark: true, name: "pencil-smooth")
    }
}

@MainActor
struct PencilIsAlwaysFreehandTests {
    @Test func aFinishedStrokeIsNotSelected() {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let tool = PencilTool(); tool.shiftHeld = { false }
        let c = ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.pencil.defaultStyle)
        tool.mouseDown(at: CGPoint(x: 100, y: 100), context: c)
        tool.mouseDragged(to: CGPoint(x: 200, y: 160), context: c)
        tool.mouseUp(at: CGPoint(x: 220, y: 170), context: c)
        #expect(doc.annotations.count == 1)
        #expect(doc.selectedAnnotationIDs.isEmpty)               // no handle box, no "Selected" bar
    }

    @Test func manyStrokesInARowAreAllKeptAndNoneAreSelected() {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let tool = PencilTool(); tool.shiftHeld = { false }
        let c = ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.pencil.defaultStyle)
        for i in 0..<5 {
            let y = CGFloat(100 + i * 20)
            tool.mouseDown(at: CGPoint(x: 100, y: y), context: c)          // each stroke starts right beside the previous one
            tool.mouseDragged(to: CGPoint(x: 300, y: y + 10), context: c)
            tool.mouseUp(at: CGPoint(x: 300, y: y + 10), context: c)
        }
        #expect(doc.annotations.count == 5)
        #expect(doc.selectedAnnotationIDs.isEmpty)
    }

    @Test func onlyThePencilNeverPicksUpExistingObjects() {
        let tools = EditorToolRegistry.makeTools()
        func tool(_ id: String) -> any EditorTool { tools.first { $0.descriptor.id == id }! }
        #expect(!CanvasView.allowsGrabbing(from: tool("pencil")))
        #expect(CanvasView.allowsGrabbing(from: tool("arrow")))
        #expect(CanvasView.allowsGrabbing(from: tool("rectangle")))
        #expect(!CanvasView.allowsGrabbing(from: tool("selectRect")))        // not a drawing tool at all
    }
}

