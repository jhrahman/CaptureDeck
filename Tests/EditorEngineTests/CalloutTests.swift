import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

private let yellow = RGBAColor(hex: "#FFFF00")!
private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)

private func canvas(_ w: Int = 200, _ h: Int = 200) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])]
}

struct CalloutGeometryTests {
    private let body = CGRect(x: 50, y: 20, width: 100, height: 60)

    @Test func tailRunsFromTheBodyToTheTipBelow() throws {
        let t = try #require(CalloutShape.tail(rect: body, oval: false, tip: CGPoint(x: 100, y: 160)))
        #expect(t.count == 3 && t[2] == CGPoint(x: 100, y: 160))
        #expect(abs(t[0].y - t[1].y) < 0.001)                                 // base is horizontal for a tip straight below
        #expect(t[0].y < 160 && t[0].y > body.midY)                            // base sits on the lower part of the body
        #expect(abs((t[0].x + t[1].x) / 2 - 100) < 0.001)                      // centered under the body
    }

    @Test func tailPointsTowardAnyDirection() throws {
        let left = try #require(CalloutShape.tail(rect: body, oval: false, tip: CGPoint(x: -40, y: 50)))
        #expect(left[0].x > left[2].x && abs(left[0].x - left[1].x) < 0.001)   // base is vertical on the left side
        let diagonal = try #require(CalloutShape.tail(rect: body, oval: true, tip: CGPoint(x: 220, y: 150)))
        #expect(diagonal[2] == CGPoint(x: 220, y: 150))
    }

    @Test func noTailWhenTheTipIsInsideTheBody() {
        #expect(CalloutShape.tail(rect: body, oval: false, tip: CGPoint(x: 100, y: 50)) == nil)
        #expect(CalloutShape.tail(rect: body, oval: true, tip: CGPoint(x: 100, y: 50)) == nil)
        #expect(CalloutShape.tail(rect: body, oval: false, tip: CGPoint(x: 100, y: 50)) == nil)
    }

    @Test func ovalBodiesLeaveTheCornersOpen() {
        // A point near the rectangle's corner is inside the rectangle but outside the oval, so a tip there needs a tail.
        let corner = CGPoint(x: 52, y: 22)
        #expect(CalloutShape.tail(rect: body, oval: false, tip: corner) == nil)
        #expect(CalloutShape.tail(rect: body, oval: true, tip: corner) != nil)
    }

    @Test func ovalFittingRectIsTallerThanTheRoundedOne() {
        let style = AnnotationStyle(strokeColor: .black, fontName: "Helvetica", fontSize: 24)
        let rounded = CalloutShape.fittingRect(origin: .zero, width: 200, text: "Click here", style: style, oval: false)
        let oval = CalloutShape.fittingRect(origin: .zero, width: 200, text: "Click here", style: style, oval: true)
        #expect(oval.height > rounded.height && rounded.height >= 40)
    }
}

struct CalloutRenderingTests {
    private func render(oval: Bool, tip: CGPoint, style: AnnotationStyle? = nil) throws -> CGImage {
        let s = style ?? AnnotationStyle(strokeColor: red, fillColor: yellow, lineWidth: 4, cornerRadius: 12, textColor: blue)
        let a = Annotation(shape: CalloutShape(rect: CGRect(x: 40, y: 20, width: 120, height: 60), text: " ", tip: tip, oval: oval), style: s)
        return try #require(AnnotationRenderer.render([a], onto: canvas()))
    }

    @Test func bodyAndTailAreFilledAndOutlined() throws {
        let out = try render(oval: false, tip: CGPoint(x: 100, y: 150))
        #expect(rgb(out, 100, 50) == [255, 255, 0])                // inside the body: bubble color
        #expect(rgb(out, 100, 100) == [255, 255, 0])               // inside the tail (away from the narrow tip)
        #expect(rgb(out, 100, 20) == [255, 0, 0])                  // outline on the body's top edge
        #expect(rgb(out, 30, 130) == [255, 255, 255])              // beside the tail: untouched
        #expect(rgb(out, 100, 175) == [255, 255, 255])             // beyond the tip: untouched
    }

    @Test func noTailIsDrawnWhenTheTipIsInside() throws {
        let out = try render(oval: false, tip: CGPoint(x: 100, y: 50))
        #expect(rgb(out, 100, 130) == [255, 255, 255])
    }

    @Test func ovalBodyIsRoundWithRoundedCornersCutOff() throws {
        let out = try render(oval: true, tip: CGPoint(x: 100, y: 150))
        #expect(rgb(out, 100, 50) == [255, 255, 0])
        #expect(rgb(out, 42, 22) == [255, 255, 255])               // the rectangle's corner is outside the oval
    }

    @Test func textIsDrawnInTheTextColorNotTheOutlineColor() throws {
        let style = AnnotationStyle(strokeColor: red, fillColor: yellow, lineWidth: 0, fontName: "Helvetica", fontSize: 40, bold: true, alignment: .center, textColor: blue)
        let a = Annotation(shape: CalloutShape(rect: CGRect(x: 20, y: 20, width: 160, height: 80), text: "W", tip: CGPoint(x: 100, y: 100)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: canvas()))
        var blueInk = 0, redInk = 0
        for y in 25..<95 { for x in 30..<170 {
            let p = rgb(out, x, y)
            if p[2] > 200 && p[0] < 60 && p[1] < 60 { blueInk += 1 }
            if p[0] > 200 && p[1] < 60 && p[2] < 60 { redInk += 1 }
        } }
        #expect(blueInk > 100, "the text should be drawn in textColor")
        #expect(redInk == 0, "the outline color must not leak into the text")
    }
}

struct CalloutInteractionTests {
    private let shape = CalloutShape(rect: CGRect(x: 50, y: 20, width: 100, height: 60), text: "hi", tip: CGPoint(x: 100, y: 160))
    private let style = AnnotationStyle(strokeColor: red, fillColor: yellow, lineWidth: 4)

    @Test func hitTestCoversTheBodyAndTheTailButNotTheGaps() {
        #expect(shape.hitTest(CGPoint(x: 100, y: 50), style: style, tolerance: 2))      // body
        #expect(shape.hitTest(CGPoint(x: 100, y: 120), style: style, tolerance: 2))     // tail
        #expect(!shape.hitTest(CGPoint(x: 20, y: 120), style: style, tolerance: 2))     // beside the tail
        #expect(!shape.hitTest(CGPoint(x: 100, y: 190), style: style, tolerance: 2))    // beyond the tip
    }

    @Test func theTipIsADragHandleThatOnlyMovesTheTip() throws {
        #expect(shape.extraHandles == [CGPoint(x: 100, y: 160)])
        let moved = try #require(shape.movingHandle(0, to: CGPoint(x: 300, y: 40)) as? CalloutShape)
        #expect(moved.tip == CGPoint(x: 300, y: 40) && moved.rect == shape.rect && moved.text == "hi")
        let ignored = try #require(shape.movingHandle(5, to: CGPoint(x: 1, y: 1)) as? CalloutShape)
        #expect(ignored == shape)
        #expect(RectangleShape(rect: .zero).extraHandles.isEmpty)                         // other shapes have none
    }

    @Test func selectionBoundsIncludeTheTail() {
        #expect(shape.geometryBounds == CGRect(x: 50, y: 20, width: 100, height: 140))
    }

    @Test func resizingScalesBodyAndTailTogether() throws {
        let scaled = try #require(shape.applying(CGAffineTransform(scaleX: 2, y: 2)) as? CalloutShape)
        #expect(scaled.rect == CGRect(x: 100, y: 40, width: 200, height: 120) && scaled.tip == CGPoint(x: 200, y: 320))
    }

    @Test func savingKeepsEverythingIncludingTheTextColor() throws {
        let style = AnnotationStyle(strokeColor: red, fillColor: yellow, fontName: "Courier", fontSize: 30, textColor: blue)
        let original = Annotation(shape: CalloutShape(rect: CGRect(x: 1, y: 2, width: 30, height: 40), text: "héllo 你好", tip: CGPoint(x: 9, y: 99), oval: true), style: style)
        let loaded = Annotation(record: try JSONDecoder().decode(AnnotationRecord.self, from: JSONEncoder().encode(original.record())))
        #expect(loaded.style == style && loaded.style.textColor == blue)
        let c = try #require(loaded.shape as? CalloutShape)
        #expect(c.text == "héllo 你好" && c.oval && c.tip == CGPoint(x: 9, y: 99))
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: Data("{}".utf8)).textColor == AnnotationStyle.defaultTextColor)
    }

    @Test func theTipSurvivesImageOperations() async throws {
        await MainActor.run {
            let doc = EditorDocument(original: CapturedImage(cgImage: canvas(200, 100), scale: 1), title: "t")
            doc.addAnnotation(Annotation(shape: CalloutShape(rect: CGRect(x: 10, y: 10, width: 50, height: 30), text: "x", tip: CGPoint(x: 30, y: 80)), style: style))
            doc.apply(.flipHorizontal)
            let c = doc.annotations[0].shape as? CalloutShape
            #expect(c?.tip == CGPoint(x: 170, y: 80) && c?.rect == CGRect(x: 140, y: 10, width: 50, height: 30))
            doc.undo()
            #expect((doc.annotations[0].shape as? CalloutShape)?.tip == CGPoint(x: 30, y: 80))
        }
    }
}
