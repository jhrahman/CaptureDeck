import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

private let black = RGBAColor.black
private let white = RGBAColor.white
private let red = RGBAColor(red: 1, green: 0, blue: 0)

private func blank(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// Number of dark pixels inside a region (top-left origin).
private func darkPixels(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> Int {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var count = 0
    for py in y { for px in x where data[(py * w + px) * 4] < 100 && data[(py * w + px) * 4 + 3] > 0 { count += 1 } }
    return count
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

struct TextRenderingTests {
    private var big: AnnotationStyle { AnnotationStyle(strokeColor: black, lineWidth: 0, fontName: "Helvetica", fontSize: 150, bold: true) }

    @Test func textIsUprightAndInsideItsBox() throws {
        // A bold "T": crossbar across the top, stem down the middle. Upside-down text would swap top and bottom.
        let a = Annotation(shape: TextShape(rect: CGRect(x: 10, y: 10, width: 180, height: 180), text: "T"), style: big)
        let out = try #require(AnnotationRenderer.render([a], onto: blank(200, 200)))
        let topLeft = darkPixels(out, x: 20..<45, y: 25..<70)        // under the left end of the crossbar
        let bottomLeft = darkPixels(out, x: 20..<45, y: 130..<185)   // left of the stem: nothing there for a T
        #expect(topLeft > 100, "no crossbar at the top (text upside down?)")
        #expect(bottomLeft == 0)
        #expect(darkPixels(out, x: 0..<10, y: 0..<200) == 0)         // nothing outside the box
    }

    @Test func alignmentMovesTheText() throws {
        func inkColumns(_ alignment: TextAlignment) throws -> (left: Int, right: Int) {
            var style = big; style.alignment = alignment; style.fontSize = 60
            let a = Annotation(shape: TextShape(rect: CGRect(x: 0, y: 0, width: 300, height: 100), text: "I"), style: style)
            let out = try #require(AnnotationRenderer.render([a], onto: blank(300, 100)))
            return (darkPixels(out, x: 0..<100, y: 0..<100), darkPixels(out, x: 200..<300, y: 0..<100))
        }
        let left = try inkColumns(.left), right = try inkColumns(.right)
        #expect(left.left > 0 && left.right == 0)
        #expect(right.right > 0 && right.left == 0)
    }

    @Test func backgroundAndBorderAreDrawn() throws {
        let style = AnnotationStyle(strokeColor: red, fillColor: RGBAColor(hex: "#FFFF00")!, lineWidth: 4, fontSize: 20)
        let a = Annotation(shape: TextShape(rect: CGRect(x: 10, y: 10, width: 100, height: 40), text: " "), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: blank(130, 70)))
        #expect(rgb(out, 60, 30) == [255, 255, 0])        // yellow background
        #expect(rgb(out, 60, 10) == [255, 0, 0])         // red border on the top edge
    }

    @Test func longTextWrapsAndTheBoxGrowsToFit() {
        let style = AnnotationStyle(strokeColor: black, fontName: "Helvetica", fontSize: 20)
        let short = TextShape.fittingRect(origin: .zero, width: 400, text: "Hello", style: style)
        let long = TextShape.fittingRect(origin: .zero, width: 120, text: String(repeating: "word ", count: 30), style: style)
        #expect(long.height > short.height * 3)
        #expect(long.width == 120)
        let twoLines = TextShape.fittingRect(origin: .zero, width: 400, text: "one\ntwo", style: style)
        #expect(twoLines.height - short.height > 20)          // one more line of text
    }

    @Test func fontTraitsChangeTheMeasuredWidth() {
        func width(_ bold: Bool) -> CGFloat {
            TextRenderer.suggestedSize(of: "Wide Text Sample", style: AnnotationStyle(strokeColor: black, fontName: "Helvetica", fontSize: 40, bold: bold), width: 2000).width
        }
        #expect(width(true) > width(false))
    }
}

struct StepShapeTests {
    @Test func lettersFollowTheAlphabetThenDouble() {
        #expect(StepShape.letterLabel(1) == "A")
        #expect(StepShape.letterLabel(26) == "Z")
        #expect(StepShape.letterLabel(27) == "AA")
        #expect(StepShape.letterLabel(52) == "AZ")
        #expect(StepShape.letterLabel(53) == "BA")
        #expect(StepShape.letterLabel(0) == "A")        // never empty
    }

    @Test func labelFollowsTheKind() {
        #expect(StepShape(center: .zero, radius: 20, number: 7).label == "7")
        #expect(StepShape(center: .zero, radius: 20, number: 3, letters: true).label == "C")
    }

    @Test func drawsAColoredCircleWithTheNumberInside() throws {
        let style = AnnotationStyle(strokeColor: white, fillColor: red, lineWidth: 0)
        let a = Annotation(shape: StepShape(center: CGPoint(x: 50, y: 50), radius: 40, number: 1), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: blank(100, 100)))
        #expect(rgb(out, 20, 50) == [255, 0, 0])          // inside the circle, left of the number
        #expect(rgb(out, 3, 3) == [255, 255, 255])        // outside the circle
        #expect(rgb(out, 50, 20) == [255, 0, 0])
    }

    @Test func hitTestAndResizeKeepItCircular() {
        let s = StepShape(center: CGPoint(x: 50, y: 50), radius: 20, number: 1)
        #expect(s.hitTest(CGPoint(x: 60, y: 50), style: .default, tolerance: 0))
        #expect(!s.hitTest(CGPoint(x: 90, y: 50), style: .default, tolerance: 2))
        let bigger = s.applying(CGAffineTransform(scaleX: 2, y: 2)) as? StepShape
        #expect(bigger?.radius == 40 && bigger?.center == CGPoint(x: 100, y: 100) && bigger?.number == 1)
    }

    @Test func textAndStepShapesSurviveSaving() throws {
        let style = AnnotationStyle(strokeColor: black, fillColor: red, fontName: "Courier", fontSize: 33, bold: true, italic: true, alignment: .center)
        for shape: any AnnotationShape in [TextShape(rect: CGRect(x: 1, y: 2, width: 30, height: 40), text: "héllo\nwörld 你好"),
                                           StepShape(center: CGPoint(x: 5, y: 6), radius: 12, number: 9, letters: true)] {
            let original = Annotation(shape: shape, style: style)
            let loaded = Annotation(record: try JSONDecoder().decode(AnnotationRecord.self, from: JSONEncoder().encode(original.record())))
            #expect(loaded.style == style)
            #expect(try loaded.shape.payload() == original.shape.payload())
            #expect(!(loaded.shape is UnknownShape))
        }
    }

    @Test func oldStyleFilesWithoutFontFieldsStillLoad() throws {
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: Data(#"{"lineWidth": 3, "opacity": 0.5}"#.utf8))
        #expect(style.fontSize == 28 && style.fontName == "Helvetica Neue" && !style.bold && style.alignment == .left)
    }
}
