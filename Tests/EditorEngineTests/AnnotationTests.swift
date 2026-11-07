import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)

private func blank(_ w: Int = 40, _ h: Int = 30, color: RGBAColor = .white) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// RGBA of the pixel at (x, y), counted from the top-left.
private func px(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return data[i..<i + 4].map(Int.init)
}

private func solid(_ c: RGBAColor, width: Double = 4) -> AnnotationStyle { AnnotationStyle(strokeColor: c, lineWidth: width) }

struct AnnotationRenderingTests {
    @Test func filledRectangleUsesTopLeftCoordinates() throws {
        let style = AnnotationStyle(strokeColor: red, fillColor: red, lineWidth: 0)
        let a = Annotation(shape: RectangleShape(rect: CGRect(x: 5, y: 2, width: 10, height: 6)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: blank()))
        #expect(px(out, 8, 4) == [255, 0, 0, 255])        // inside, near the top
        #expect(px(out, 8, 25) == [255, 255, 255, 255])   // far below: untouched (proves y is not flipped)
        #expect(px(out, 20, 4) == [255, 255, 255, 255])
    }

    @Test func cornerRadiusRoundsTheCorners() throws {
        let style = AnnotationStyle(strokeColor: red, fillColor: red, lineWidth: 0, cornerRadius: 10)
        let a = Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 40, height: 30)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: blank()))
        #expect(px(out, 0, 0) == [255, 255, 255, 255])            // the very corner is cut off
        #expect(px(out, 20, 15) == [255, 0, 0, 255])
    }

    @Test func unfilledRectangleOnlyDrawsTheOutline() throws {
        let a = Annotation(shape: RectangleShape(rect: CGRect(x: 4, y: 4, width: 30, height: 20)), style: solid(blue, width: 2))
        let out = try #require(AnnotationRenderer.render([a], onto: blank()))
        #expect(px(out, 19, 4) == [0, 0, 255, 255])       // on the top edge
        #expect(px(out, 19, 14) == [255, 255, 255, 255])  // the inside stays clear
    }

    @Test func opacityBlendsWithThePicture() throws {
        let style = AnnotationStyle(strokeColor: red, fillColor: red, lineWidth: 0, opacity: 0.5)
        let a = Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 40, height: 30)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: blank()))
        let p = px(out, 20, 15)
        #expect(p[0] == 255 && p[1] > 100 && p[1] < 150 && p[2] == p[1])    // roughly half red over white
    }

    @Test func overlappingShapesDrawInOrder() throws {
        let top = Annotation(shape: RectangleShape(rect: CGRect(x: 10, y: 10, width: 10, height: 10)),
                             style: AnnotationStyle(strokeColor: blue, fillColor: blue, lineWidth: 0))
        let bottom = Annotation(shape: RectangleShape(rect: CGRect(x: 5, y: 5, width: 20, height: 20)),
                                style: AnnotationStyle(strokeColor: red, fillColor: red, lineWidth: 0))
        let out = try #require(AnnotationRenderer.render([bottom, top], onto: blank()))
        #expect(px(out, 15, 15) == [0, 0, 255, 255] && px(out, 7, 7) == [255, 0, 0, 255])
    }

    @Test func highlighterKeepsDarkTextVisible() throws {
        let yellow = RGBAColor(hex: "#FFFF00")!
        let image = blank(color: .black)
        let a = Annotation(shape: HighlighterShape(rect: CGRect(x: 0, y: 0, width: 40, height: 30)), style: AnnotationStyle(strokeColor: yellow))
        let out = try #require(AnnotationRenderer.render([a], onto: image))
        #expect(px(out, 10, 10) == [0, 0, 0, 255])                           // multiply: black stays black
        let onWhite = try #require(AnnotationRenderer.render([a], onto: blank()))
        #expect(px(onWhite, 10, 10) == [255, 255, 0, 255])                   // white becomes the marker color
    }

    @Test func arrowDrawsALineAndAHead() throws {
        let a = Annotation(shape: LineShape(start: CGPoint(x: 4, y: 15), end: CGPoint(x: 36, y: 15), endHead: .filled), style: solid(red, width: 2))
        let out = try #require(AnnotationRenderer.render([a], onto: blank()))
        #expect(px(out, 15, 15) == [255, 0, 0, 255])                          // the shaft
        #expect(px(out, 32, 13) == [255, 0, 0, 255])                          // inside the arrowhead, above the shaft
        #expect(px(out, 4, 25) == [255, 255, 255, 255])
    }

    @Test func noAnnotationsReturnsTheSamePicture() {
        let image = blank()
        #expect(AnnotationRenderer.render([], onto: image) === image)
    }
}

struct AnnotationHitTestingTests {
    @Test func unfilledRectangleIsOnlyHitOnItsOutline() {
        let s = RectangleShape(rect: CGRect(x: 10, y: 10, width: 40, height: 30))
        let style = solid(red, width: 4)
        #expect(s.hitTest(CGPoint(x: 10, y: 25), style: style, tolerance: 2))
        #expect(!s.hitTest(CGPoint(x: 30, y: 25), style: style, tolerance: 2))
        #expect(!s.hitTest(CGPoint(x: 80, y: 80), style: style, tolerance: 2))
        #expect(s.hitTest(CGPoint(x: 30, y: 25), style: AnnotationStyle(strokeColor: red, fillColor: blue), tolerance: 2))
    }

    @Test func ellipseOutlineAndFill() {
        let s = EllipseShape(rect: CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(s.hitTest(CGPoint(x: 0, y: 10), style: solid(red), tolerance: 2))
        #expect(!s.hitTest(CGPoint(x: 20, y: 10), style: solid(red), tolerance: 2))
        #expect(s.hitTest(CGPoint(x: 20, y: 10), style: AnnotationStyle(strokeColor: red, fillColor: red), tolerance: 0))
        #expect(!s.hitTest(CGPoint(x: 1, y: 1), style: AnnotationStyle(strokeColor: red, fillColor: red), tolerance: 0))   // corner is outside the ellipse
    }

    @Test func linesAndPencilUseDistanceToTheStroke() {
        let line = LineShape(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        #expect(line.hitTest(CGPoint(x: 50, y: 3), style: solid(red, width: 2), tolerance: 4))
        #expect(!line.hitTest(CGPoint(x: 50, y: 20), style: solid(red, width: 2), tolerance: 4))
        let pencil = PencilShape(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0)])
        #expect(pencil.hitTest(CGPoint(x: 5, y: 5), style: solid(red, width: 2), tolerance: 2))
        #expect(!pencil.hitTest(CGPoint(x: 10, y: 0), style: solid(red, width: 2), tolerance: 2))
    }

    @Test func topmostAnnotationWinsInTheDocument() async throws {
        await MainActor.run {
            let doc = EditorDocument(original: CapturedImage(cgImage: blank(), scale: 1), title: "t")
            let style = AnnotationStyle(strokeColor: red, fillColor: red)
            let a = Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 30, height: 30)), style: style)
            let b = Annotation(shape: RectangleShape(rect: CGRect(x: 10, y: 10, width: 30, height: 30)), style: style)
            doc.addAnnotation(a); doc.addAnnotation(b)
            #expect(doc.annotation(at: CGPoint(x: 15, y: 15), tolerance: 1)?.id == b.id)
            #expect(doc.annotation(at: CGPoint(x: 5, y: 5), tolerance: 1)?.id == a.id)
            #expect(doc.annotation(at: CGPoint(x: 38, y: 5), tolerance: 1) == nil)
        }
    }
}

struct AnnotationPersistenceTests {
    @Test func everyShapeRoundTripsThroughRecords() throws {
        let shapes: [any AnnotationShape] = [
            RectangleShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
            EllipseShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
            LineShape(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 3, y: 4), startHead: .open, endHead: .filled),
            PencilShape(points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3)]),
            HighlighterShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
        ]
        for shape in shapes {
            let original = Annotation(shape: shape, style: AnnotationStyle(strokeColor: blue, fillColor: red, lineWidth: 7, opacity: 0.5, dash: .dashed, cornerRadius: 6))
            let data = try JSONEncoder().encode(original.record())
            let loaded = Annotation(record: try JSONDecoder().decode(AnnotationRecord.self, from: data))
            #expect(loaded.id == original.id && loaded.style == original.style)
            #expect(loaded.shape.shapeType == shape.shapeType && loaded.bounds == original.bounds)
            #expect(try loaded.shape.payload() == original.shape.payload())
        }
    }

    @Test func unknownShapeTypesSurviveUntouched() throws {
        let payload = Data(#"{"future":"stuff","n":42}"#.utf8)
        let record = AnnotationRecord(id: UUID(), type: "hologram", style: .default, payload: payload)
        let loaded = Annotation(record: record)
        #expect(loaded.shape is UnknownShape)
        let resaved = try loaded.record()
        #expect(resaved.type == "hologram" && resaved.payload == payload)
        #expect(loaded.applying(CGAffineTransform(translationX: 5, y: 5)).shape is UnknownShape)    // moving it does not destroy it
    }

    @Test func damagedPayloadOfAKnownTypeIsKeptToo() throws {
        let bad = Data("not json".utf8)
        let loaded = Annotation(record: AnnotationRecord(id: UUID(), type: "rectangle", style: .default, payload: bad))
        #expect(loaded.shape is UnknownShape)
        #expect(try loaded.record().payload == bad)
    }

    @Test func styleWithMissingFieldsGetsDefaults() throws {
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: Data(#"{"lineWidth": 9}"#.utf8))
        #expect(style.lineWidth == 9 && style.opacity == 1 && style.dash == .solid && style.fillColor.alpha == 0)
    }
}

@MainActor
struct AnnotationDocumentTests {
    private func doc() -> EditorDocument { EditorDocument(original: CapturedImage(cgImage: blank(), scale: 1), title: "t") }
    private func rect(_ x: CGFloat) -> Annotation {
        Annotation(shape: RectangleShape(rect: CGRect(x: x, y: 5, width: 10, height: 10)), style: solid(red))
    }

    @Test func addUndoRedo() {
        let d = doc(); let a = rect(0)
        #expect(d.addAnnotation(a))
        #expect(d.annotations.count == 1 && d.selectedAnnotationIDs == [a.id] && d.isDirty && d.undoName == "Add Rectangle")
        d.undo()
        #expect(d.annotations.isEmpty && d.selectedAnnotationIDs.isEmpty && !d.isDirty)
        d.redo()
        #expect(d.annotations.map(\.id) == [a.id])
    }

    @Test func deleteRestoresAtTheSamePlace() {
        let d = doc(); let a = rect(0), b = rect(10), c = rect(20)
        [a, b, c].forEach { d.addAnnotation($0) }
        d.selectAnnotations([b.id])
        #expect(d.deleteSelectedAnnotations())
        #expect(d.annotations.map(\.id) == [a.id, c.id] && d.selectedAnnotationIDs.isEmpty)
        d.undo()
        #expect(d.annotations.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func dragMoveIsOneUndoStep() throws {
        let d = doc(); let a = rect(0)
        d.addAnnotation(a)
        let original = d.annotations
        for dx in stride(from: 1.0, through: 10.0, by: 1.0) {       // many live updates while dragging
            d.previewAnnotations([a.applying(CGAffineTransform(translationX: dx, y: 0))])
        }
        #expect(d.undoNames == ["Add Rectangle"])                    // nothing recorded yet
        #expect(d.commitAnnotationEdit(from: original, name: "Move"))
        #expect(d.undoNames == ["Add Rectangle", "Move"] && d.annotations[0].bounds.minX == 10)
        d.undo()
        #expect(d.annotations[0].bounds.minX == 0)
        d.redo()
        #expect(d.annotations[0].bounds.minX == 10)
    }

    @Test func restyleKeepsGeometry() {
        let d = doc(); let a = rect(3)
        d.addAnnotation(a)
        var changed = a; changed.style.strokeColor = blue; changed.style.lineWidth = 9
        #expect(d.updateAnnotations([changed], name: "Change Style"))
        #expect(d.annotations[0].style.lineWidth == 9 && d.annotations[0].bounds.minX == 3)
        d.undo()
        #expect(d.annotations[0].style.lineWidth == 4)
    }

    @Test func zOrderAndUndo() {
        let d = doc(); let a = rect(0), b = rect(10), c = rect(20)
        [a, b, c].forEach { d.addAnnotation($0) }
        #expect(d.reorderAnnotations(ids: [a.id], .toFront))
        #expect(d.annotations.map(\.id) == [b.id, c.id, a.id])
        #expect(d.reorderAnnotations(ids: [c.id], .toBack))
        #expect(d.annotations.map(\.id) == [c.id, b.id, a.id])
        #expect(!d.reorderAnnotations(ids: [c.id], .toBack))        // already there
        d.undo(); d.undo()
        #expect(d.annotations.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func duplicateCreatesOffsetCopiesAndSelectsThem() {
        let d = doc(); let a = rect(0)
        d.addAnnotation(a)
        let copies = d.duplicateAnnotations(ids: [a.id], offset: CGSize(width: 7, height: 3))
        #expect(copies.count == 1 && copies[0] != a.id && d.annotations.count == 2)
        #expect(d.annotation(withID: copies[0])?.bounds == CGRect(x: 7, y: 8, width: 10, height: 10))
        #expect(d.selectedAnnotationIDs == copies)
        d.undo()
        #expect(d.annotations.count == 1)
    }

    @Test func flattenedImageIncludesAnnotationsButWorkingImageDoesNot() throws {
        let d = doc()
        d.addAnnotation(Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 40, height: 30)),
                                   style: AnnotationStyle(strokeColor: red, fillColor: red, lineWidth: 0)))
        #expect(px(d.flattenedImage().cgImage, 20, 15) == [255, 0, 0, 255])
        #expect(px(d.workingImage.cgImage, 20, 15) == [255, 255, 255, 255])      // the picture itself is untouched
    }

    @Test func annotationsFollowImageOperationsAndUndoRestoresThem() throws {
        let d = doc()                                                            // 40 x 30
        d.addAnnotation(Annotation(shape: RectangleShape(rect: CGRect(x: 4, y: 6, width: 10, height: 8)), style: solid(red)))
        let bounds = { d.annotations[0].bounds }

        d.apply(.flipHorizontal);   #expect(bounds() == CGRect(x: 26, y: 6, width: 10, height: 8))
        d.undo();                   #expect(bounds() == CGRect(x: 4, y: 6, width: 10, height: 8))
        d.apply(.flipVertical);     #expect(bounds() == CGRect(x: 4, y: 16, width: 10, height: 8))
        d.undo()
        d.apply(.rotate(quarterTurns: 1)); #expect(bounds() == CGRect(x: 16, y: 4, width: 8, height: 10))   // 90° clockwise
        d.undo()
        d.apply(.rotate(quarterTurns: 3)); #expect(bounds() == CGRect(x: 6, y: 26, width: 8, height: 10))
        d.undo()
        d.apply(.crop(CGRect(x: 2, y: 2, width: 20, height: 20))); #expect(bounds() == CGRect(x: 2, y: 4, width: 10, height: 8))
        d.undo()
        d.apply(.resize(width: 80, height: 60)); #expect(bounds() == CGRect(x: 8, y: 12, width: 20, height: 16))
        d.undo()
        d.apply(.canvasSize(width: 60, height: 50, anchor: .center, fill: .white)); #expect(bounds() == CGRect(x: 14, y: 16, width: 10, height: 8))
        d.undo()
        #expect(bounds() == CGRect(x: 4, y: 6, width: 10, height: 8))
    }

    @Test func rotatingByAnAngleKeepsTheAnnotationOnTheSamePixels() throws {
        let d = doc()                                                            // 40 x 30
        d.addAnnotation(Annotation(shape: LineShape(start: CGPoint(x: 20, y: 15), end: CGPoint(x: 20, y: 15)), style: solid(red)))
        d.apply(.rotateByAngle(degrees: 45, fill: .white))
        let size = d.workingImage.pixelSize
        let line = try #require(d.annotations[0].shape as? LineShape)
        #expect(abs(line.start.x - size.width / 2) < 0.01 && abs(line.start.y - size.height / 2) < 0.01)   // the center stays the center
    }
}

@MainActor
struct AnnotationSelectionHistoryTests {
    @Test func undoingADeleteSelectsTheRestoredObject() {
        let d = EditorDocument(original: CapturedImage(cgImage: blank(), scale: 1), title: "t")
        let a = Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: solid(red))
        d.addAnnotation(a)
        d.deleteSelectedAnnotations()
        #expect(d.selectedAnnotationIDs.isEmpty)
        d.undo()
        #expect(d.selectedAnnotationIDs == [a.id])
    }

    @Test func movingNowhereRecordsNothing() {
        let d = EditorDocument(original: CapturedImage(cgImage: blank(), scale: 1), title: "t")
        let a = Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 10, height: 10)), style: solid(red))
        d.addAnnotation(a)
        #expect(!d.commitAnnotationEdit(from: [a], name: "Move"))
        #expect(d.undoNames == ["Add Rectangle"])
    }
}
