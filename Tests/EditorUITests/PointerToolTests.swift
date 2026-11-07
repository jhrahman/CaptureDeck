import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

@MainActor
struct PointerToolTests {
    private func makeDocument() -> (EditorDocument, Annotation) {
        let ctx = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let doc = EditorDocument(original: CapturedImage(cgImage: ctx.makeImage()!, scale: 2), title: "t")
        let rect = Annotation(shape: RectangleShape(rect: CGRect(x: 200, y: 150, width: 400, height: 300)), style: .default)
        doc.addAnnotation(rect)
        return (doc, rect)
    }

    private func context(_ doc: EditorDocument) -> ToolContext { ToolContext(document: doc, zoom: 1, style: .default) }

    private func drag(_ tool: PointerTool, _ doc: EditorDocument, from a: CGPoint, to b: CGPoint) {
        let ctx = context(doc)
        tool.mouseDown(at: a, context: ctx)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            tool.mouseDragged(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), context: ctx)
        }
        tool.mouseUp(at: b, context: ctx)
    }

    @Test func draggingTheOutlineMovesTheObjectAsOneUndoStep() {
        let (doc, _) = makeDocument()
        // (200, 300) is on the left outline but not on a handle square, so it moves the object.
        drag(PointerTool(), doc, from: CGPoint(x: 200, y: 300 + 40), to: CGPoint(x: 300, y: 350 + 40))
        #expect(doc.annotations[0].bounds == CGRect(x: 300, y: 200, width: 400, height: 300))
        #expect(doc.undoNames == ["Add Rectangle", "Move"])
        doc.undo()
        #expect(doc.annotations[0].bounds == CGRect(x: 200, y: 150, width: 400, height: 300))
    }

    @Test func draggingTheBottomRightHandleResizesBothDirections() {
        let (doc, _) = makeDocument()
        drag(PointerTool(), doc, from: CGPoint(x: 600, y: 450), to: CGPoint(x: 700, y: 500))
        #expect(doc.annotations[0].bounds == CGRect(x: 200, y: 150, width: 500, height: 350))
        #expect(doc.undoNames.last == "Resize")
    }

    @Test func draggingEachHandleMovesOnlyItsEdges() {
        let cases: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x: 200, y: 150), CGPoint(x: 180, y: 130), CGRect(x: 180, y: 130, width: 420, height: 320)),   // top-left
            (CGPoint(x: 400, y: 150), CGPoint(x: 400, y: 100), CGRect(x: 200, y: 100, width: 400, height: 350)),   // top
            (CGPoint(x: 600, y: 300), CGPoint(x: 650, y: 300), CGRect(x: 200, y: 150, width: 450, height: 300)),   // right
            (CGPoint(x: 400, y: 450), CGPoint(x: 400, y: 480), CGRect(x: 200, y: 150, width: 400, height: 330)),   // bottom
        ]
        for (from, to, expected) in cases {
            let (doc, _) = makeDocument()
            drag(PointerTool(), doc, from: from, to: to)
            #expect(doc.annotations[0].bounds == expected)
        }
    }

    @Test func clickingEmptySpaceDeselects() {
        let (doc, _) = makeDocument()
        let tool = PointerTool()
        tool.mouseDown(at: CGPoint(x: 900, y: 550), context: context(doc))
        tool.mouseUp(at: CGPoint(x: 900, y: 550), context: context(doc))
        #expect(doc.selectedAnnotationIDs.isEmpty)
    }

    @Test func clickingAnObjectSelectsIt() {
        let (doc, rect) = makeDocument()
        doc.clearAnnotationSelection()
        let tool = PointerTool()
        tool.mouseDown(at: CGPoint(x: 400, y: 150), context: context(doc))     // on the top edge
        tool.mouseUp(at: CGPoint(x: 400, y: 150), context: context(doc))
        #expect(doc.selectedAnnotationIDs == [rect.id])
        #expect(doc.undoNames == ["Add Rectangle"])                              // a plain click is not an edit
    }
}
