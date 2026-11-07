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

@MainActor
struct BubbleToolTests {
    private func makeDocument() -> (EditorDocument, Annotation) {
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let doc = EditorDocument(original: CapturedImage(cgImage: ctx.makeImage()!, scale: 2), title: "t")
        let bubble = Annotation(shape: CalloutShape(rect: CGRect(x: 100, y: 50, width: 200, height: 80), text: "Look here", tip: CGPoint(x: 150, y: 220)),
                                style: EditorToolRegistry.callout.defaultStyle)
        doc.addAnnotation(bubble)
        return (doc, bubble)
    }

    private func drag(_ doc: EditorDocument, from a: CGPoint, to b: CGPoint) {
        let tool = PointerTool()
        let ctx = ToolContext(document: doc, zoom: 1, style: .default)
        tool.mouseDown(at: a, context: ctx)
        for i in 1...6 { tool.mouseDragged(to: CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 6, y: a.y + (b.y - a.y) * CGFloat(i) / 6), context: ctx) }
        tool.mouseUp(at: b, context: ctx)
    }

    @Test func draggingTheTailTipAimsTheTailWithoutMovingTheBubble() throws {
        let (doc, _) = makeDocument()
        drag(doc, from: CGPoint(x: 150, y: 220), to: CGPoint(x: 400, y: 300))
        let bubble = try #require(doc.annotations[0].shape as? CalloutShape)
        #expect(bubble.tip == CGPoint(x: 400, y: 300) && bubble.rect == CGRect(x: 100, y: 50, width: 200, height: 80))
        #expect(doc.undoNames.last == "Move Tail")
        doc.undo()
        #expect((doc.annotations[0].shape as? CalloutShape)?.tip == CGPoint(x: 150, y: 220))
    }

    @Test func draggingTheBodyStillMovesTheWholeBubble() throws {
        let (doc, _) = makeDocument()
        drag(doc, from: CGPoint(x: 200, y: 90), to: CGPoint(x: 240, y: 110))          // inside the body, not on a handle
        let bubble = try #require(doc.annotations[0].shape as? CalloutShape)
        #expect(bubble.rect.origin == CGPoint(x: 140, y: 70) && bubble.tip == CGPoint(x: 190, y: 240))
    }

    @Test func bubbleToolsAreRegisteredWithTheRightProperties() {
        let callout = EditorToolRegistry.callout, oval = EditorToolRegistry.ovalCallout
        #expect(callout.styleProperties.contains(.textColor) && callout.styleProperties.contains(.cornerRadius))
        #expect(oval.styleProperties.contains(.textColor) && !oval.styleProperties.contains(.cornerRadius))
        #expect(callout.propertyTitles[.fill] == "Bubble" && callout.propertyTitles[.textColor] == "Text")
        #expect(EditorToolRegistry.descriptors.contains(callout) && EditorToolRegistry.descriptors.contains(oval))
    }

    @Test func aSelectedBubbleOffersBubbleProperties() {
        let result = EditorToolRegistry.properties(forShapeTypes: ["callout"])
        #expect(result.properties.contains(.textColor) && result.properties.contains(.fontSize) && result.properties.contains(.fill))
        #expect(result.titles[.fill] == "Bubble")
    }

    @Test func newBubblesUseTheToolsDefaultLookWithDarkTextOnLightFill() {
        let style = EditorToolRegistry.callout.defaultStyle
        #expect(style.fillColor.alpha == 1 && style.textColor == AnnotationStyle.defaultTextColor && style.lineWidth > 0)
    }
}
