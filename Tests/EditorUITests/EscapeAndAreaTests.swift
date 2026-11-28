import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

@MainActor
struct EscapeAndAreaTests {
    private func editor(inWindow: Bool = false) -> (EditorViewController, EditorDocument, NSWindow?) {
        let doc = EditorDocument(original: ColorPickingTests.twoColourImage(), title: "t")          // 400 x 200: orange | teal
        let controller = EditorViewController(document: doc, settings: nil)
        guard inWindow else { _ = controller.view; return (controller, doc, nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        return (controller, doc, window)
    }

    private let escape: UInt16 = 53, delete: UInt16 = 51

    // MARK: Esc leaves a tool

    @Test func escapeLeavesEveryToolOfTheRibbonThatCanBeLeft() {
        let leavable = ["pickColor", "fill", "pencil", "redactBrush", "hideText", "rectangle", "ellipse", "line", "arrow", "highlighter", "blur", "pixelate"]
        for id in leavable {
            let (controller, _, _) = editor()
            controller.selectTool(id: id)
            #expect(controller.activeToolID == id)
            controller.simulateKey(escape)
            #expect(controller.activeToolID == EditorToolRegistry.defaultToolID, "Esc did not leave \(id)")
        }
    }

    @Test func escapeFirstDeselectsAnObjectAndOnlyThenLeavesTheTool() {
        let (controller, doc, _) = editor()
        controller.selectTool(id: "rectangle")
        let box = Annotation(shape: RectangleShape(rect: CGRect(x: 20, y: 20, width: 80, height: 50)), style: EditorToolRegistry.rectangle.defaultStyle)
        doc.addAnnotation(box)                                                         // selected, as after drawing it
        #expect(!doc.selectedAnnotationIDs.isEmpty)
        controller.simulateKey(escape)
        #expect(doc.selectedAnnotationIDs.isEmpty && controller.activeToolID == "rectangle")        // first Esc: deselect
        controller.simulateKey(escape)
        #expect(controller.activeToolID == EditorToolRegistry.defaultToolID)                          // second Esc: leave
    }

    @Test func escapeInTheDefaultToolStillJustClearsTheSelection() {
        let (controller, doc, _) = editor()
        #expect(controller.activeToolID == EditorToolRegistry.defaultToolID)
        #expect(doc.selection != nil)                                                  // the whole picture starts selected
        controller.simulateKey(escape)
        #expect(doc.selection == nil && controller.activeToolID == EditorToolRegistry.defaultToolID)
    }

    @Test func escapeCancelsAStrokeInProgressBeforeLeavingTheTool() {
        let tool = PencilTool(); tool.shiftHeld = { false }
        let doc = EditorDocument(original: ColorPickingTests.twoColourImage(), title: "t")
        let context = ToolContext(document: doc, zoom: 2, style: EditorToolRegistry.pencil.defaultStyle)
        tool.mouseDown(at: CGPoint(x: 10, y: 10), context: context)
        tool.mouseDragged(to: CGPoint(x: 60, y: 40), context: context)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        #expect(tool.keyDown(event, context: context))                                // used: it cancelled the stroke
        #expect(tool.previewAnnotations.isEmpty)
        #expect(!tool.keyDown(event, context: context))                               // nothing left to cancel: the editor takes it
    }

    // MARK: Keyboard focus

    @Test func choosingAToolGivesTheCanvasKeyboardFocus() {
        let (controller, _, window) = editor(inWindow: true)
        defer { window?.close() }
        window?.makeFirstResponder(nil)                                                 // as after clicking a ribbon button
        #expect(!controller.canvasHasFocus)
        controller.selectTool(id: "pickColor")
        #expect(controller.canvasHasFocus)
    }

    @Test func escapeThroughTheResponderChainAlsoLeavesTheTool() {
        let (controller, _, _) = editor()
        controller.selectTool(id: "fill")
        controller.cancelOperation(nil)
        #expect(controller.activeToolID == EditorToolRegistry.defaultToolID)
    }

    // MARK: Delete and fill the selected area

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double)? {
        PixelSampler(image: image)?.color(x: x, y: y).map { ($0.red, $0.green, $0.blue, $0.alpha) }
    }

    @Test func deletingAnAreaMakesOnlyThatAreaTransparentAndUndoRestoresIt() throws {
        let (_, doc, _) = editor()
        doc.setSelection(.rect(CGRect(x: 50, y: 40, width: 100, height: 60)))
        #expect(doc.eraseSelection())
        let image = doc.workingImage.cgImage
        #expect(try #require(pixel(image, 100, 70)).a == 0)                             // inside: gone
        #expect(try #require(pixel(image, 10, 10)).a == 1)                              // outside: untouched
        #expect(try #require(pixel(image, 300, 100)).a == 1)
        #expect(doc.selection == .rect(CGRect(x: 50, y: 40, width: 100, height: 60)))   // still selected, ready to fill
        #expect(doc.undoNames.last == "Delete Area")
        doc.undo()
        #expect(try #require(pixel(doc.workingImage.cgImage, 100, 70)).a == 1)
    }

    @Test func fillingAnAreaPaintsItSolid() throws {
        let (_, doc, _) = editor()
        doc.setSelection(.rect(CGRect(x: 250, y: 20, width: 80, height: 80)))
        #expect(doc.fillSelection(with: RGBAColor(red: 1, green: 0, blue: 0)))
        let red = try #require(pixel(doc.workingImage.cgImage, 280, 60))
        #expect(red.r > 0.99 && red.g < 0.01 && red.b < 0.01 && red.a == 1)
        #expect(doc.undoNames.last == "Fill Area")
    }

    @Test func aFreehandAreaCanBeDeletedToo() throws {
        let (_, doc, _) = editor()
        let triangle = [CGPoint(x: 20, y: 150), CGPoint(x: 120, y: 150), CGPoint(x: 70, y: 60)]
        doc.setSelection(.freehand(triangle))
        #expect(doc.eraseSelection())
        #expect(try #require(pixel(doc.workingImage.cgImage, 70, 130)).a == 0)          // inside the triangle
        #expect(try #require(pixel(doc.workingImage.cgImage, 25, 70)).a == 1)           // beside it
    }

    @Test func theDeleteKeyErasesTheSelectedAreaAndTheBucketCanThenFillIt() async throws {
        let (controller, doc, _) = editor()
        doc.setSelection(.rect(CGRect(x: 50, y: 40, width: 100, height: 60)))
        controller.simulateKey(delete)
        #expect(try #require(pixel(doc.workingImage.cgImage, 100, 70)).a == 0)
        // Pick the colour, then the Paint Bucket fills the transparent hole (it is a region of its own).
        controller.pickedColor(RGBAColor(red: 0, green: 0, blue: 1))
        controller.simulateAction(.fillWithPicked)
        doc.clearSelection()
        let tool = FillTool()
        let context = ToolContext(document: doc, zoom: 2, style: controller.currentStyle)
        tool.mouseUp(at: CGPoint(x: 100, y: 70), context: context)
        let flattened = doc.flattenedImage().cgImage
        let hole = try #require(pixel(flattened, 100, 70))
        #expect(hole.b > 0.99 && hole.a == 1, "the hole was not filled with the picked colour: \(hole)")
        let outside = try #require(pixel(flattened, 10, 10))
        #expect(outside.r > 0.99)                                                       // the orange around it stays orange
    }

    @Test func theSelectionBarOffersDeleteAndFill() {
        let (controller, doc, _) = editor()
        doc.setSelection(.rect(CGRect(x: 10, y: 10, width: 50, height: 50)))
        controller.fillArea()                                                           // with no picked colour yet: the bucket's default
        #expect(doc.undoNames.last == "Fill Area")
        controller.eraseArea()
        #expect(doc.undoNames.last == "Delete Area")
    }
}
