import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)
private let green = RGBAColor(red: 0, green: 1, blue: 0)
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])]
}

/// 60x40 white picture with a black rectangle outline (x 10...49, y 8...31, 2 px thick) and a black dot outside it.
private func picture() -> CGImage {
    let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
    ctx.setStrokeColor(CGColor(colorSpace: srgb, components: [0, 0, 0, 1])!); ctx.setLineWidth(2)
    ctx.stroke(CGRect(x: 11, y: 9, width: 38, height: 22))                              // the outline (y-up coordinates)
    return ctx.makeImage()!
}

private func style(_ color: RGBAColor, tolerance: Double = 10) -> AnnotationStyle { AnnotationStyle(strokeColor: color, strength: tolerance) }

struct PaintBucketTests {
    @Test func fillsOnlyTheEnclosedArea() throws {
        let out = try #require(AnnotationRenderer.render([Annotation(shape: FillShape(seed: CGPoint(x: 30, y: 20)), style: style(red))], onto: picture()))
        #expect(rgb(out, 30, 20) == [255, 0, 0])                // inside the outline: filled
        #expect(rgb(out, 14, 12) == [255, 0, 0])                // near the inside corner
        #expect(rgb(out, 3, 3) == [255, 255, 255])              // outside the outline: untouched
        #expect(rgb(out, 58, 38) == [255, 255, 255])
        let edge = rgb(out, 10, 20)
        #expect(edge[0] < 80 && edge[1] < 80 && edge[2] < 80, "the black outline must stay: \(edge)")
    }

    @Test func fillingTheOutsideDoesNotLeakInside() throws {
        let out = try #require(AnnotationRenderer.render([Annotation(shape: FillShape(seed: CGPoint(x: 3, y: 3)), style: style(blue))], onto: picture()))
        #expect(rgb(out, 3, 3) == [0, 0, 255] && rgb(out, 58, 38) == [0, 0, 255])
        #expect(rgb(out, 30, 20) == [255, 255, 255])            // the enclosed area is separate: still white
    }

    @Test func clickingTheOutlineFillsTheOutline() throws {
        let out = try #require(AnnotationRenderer.render([Annotation(shape: FillShape(seed: CGPoint(x: 10, y: 20)), style: style(green))], onto: picture()))
        #expect(rgb(out, 10, 20) == [0, 255, 0])
        #expect(rgb(out, 30, 20) == [255, 255, 255])
    }

    @Test func toleranceDecidesHowSimilarColorsAreIncluded() throws {
        // Left half pure white, right half light grey (230). A tight tolerance stops at the change, a loose one crosses it.
        let ctx = CGContext(data: nil, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [0.9, 0.9, 0.9, 1])!); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 10))
        let graded = ctx.makeImage()!
        let tight = try #require(AnnotationRenderer.render([Annotation(shape: FillShape(seed: CGPoint(x: 5, y: 5)), style: style(red, tolerance: 3))], onto: graded))
        #expect(rgb(tight, 5, 5) == [255, 0, 0] && rgb(tight, 30, 5) != [255, 0, 0])
        let loose = try #require(AnnotationRenderer.render([Annotation(shape: FillShape(seed: CGPoint(x: 5, y: 5)), style: style(red, tolerance: 30))], onto: graded))
        #expect(rgb(loose, 30, 5) == [255, 0, 0])
    }

    @Test func aSeedOutsideThePictureDoesNothing() throws {
        let original = picture()
        let out = try #require(AnnotationRenderer.render([Annotation(shape: FillShape(seed: CGPoint(x: 500, y: 500)), style: style(red))], onto: original))
        #expect(rgb(out, 30, 20) == [255, 255, 255])
    }

    @Test func fillIsAnEditableObjectNotAChangeToThePicture() async {
        await MainActor.run {
            let d = EditorDocument(original: CapturedImage(cgImage: picture(), scale: 1), title: "t")
            d.addAnnotation(Annotation(shape: FillShape(seed: CGPoint(x: 30, y: 20)), style: style(red)))
            #expect(rgb(d.flattenedImage().cgImage, 30, 20) == [255, 0, 0])
            #expect(rgb(d.workingImage.cgImage, 30, 20) == [255, 255, 255])             // the picture itself is untouched
            #expect(d.undoName == "Add Fill")
            d.undo()
            #expect(rgb(d.flattenedImage().cgImage, 30, 20) == [255, 255, 255])
        }
    }

    @Test func movingASeedReFillsADifferentArea() throws {
        let moved = FillShape(seed: CGPoint(x: 30, y: 20)).applying(CGAffineTransform(translationX: -27, y: -17))
        let out = try #require(AnnotationRenderer.render([Annotation(shape: moved, style: style(red))], onto: picture()))
        #expect(rgb(out, 3, 3) == [255, 0, 0] && rgb(out, 30, 20) == [255, 255, 255])
    }

    @Test func savingKeepsTheSeed() throws {
        let a = Annotation(shape: FillShape(seed: CGPoint(x: 12.5, y: 7)), style: style(red, tolerance: 33))
        let loaded = Annotation(record: try JSONDecoder().decode(AnnotationRecord.self, from: JSONEncoder().encode(a.record())))
        #expect((loaded.shape as? FillShape)?.seed == CGPoint(x: 12.5, y: 7) && loaded.style.strength == 33)
    }
}

struct ArrowDesignTests {
    private func ink(_ style: AnnotationStyle, in rect: CGRect) throws -> Int {
        let ctx = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let a = Annotation(shape: LineShape(start: CGPoint(x: 10, y: 30), end: CGPoint(x: 100, y: 30)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: ctx.makeImage()!))
        var n = 0
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) where rgb(out, x, y)[1] < 100 { n += 1 } }
        return n
    }

    private func base(_ end: ArrowHeadStyle, start: ArrowHeadStyle = .none, width: Double = 3) -> AnnotationStyle {
        AnnotationStyle(strokeColor: red, lineWidth: width, startHead: start, endHead: end)
    }

    @Test func everyHeadDesignDrawsSomethingAtTheTipThatPlainLinesDoNot() throws {
        let tip = CGRect(x: 84, y: 14, width: 22, height: 32)                    // around the end of the line, above and below it
        let plain = try ink(base(.none), in: tip)
        for head in [ArrowHeadStyle.open, .filled, .diamond, .dot, .bar] {
            #expect(try ink(base(head), in: tip) > plain + 8, "\(head) added nothing at the tip")
        }
    }

    @Test func solidHeadsAreFullerThanOpenOnes() throws {
        let tip = CGRect(x: 84, y: 14, width: 22, height: 32)
        #expect(try ink(base(.filled), in: tip) > (try ink(base(.open), in: tip)))
    }

    @Test func headsAppearOnTheChosenEndsOnly() throws {
        let start = CGRect(x: 4, y: 14, width: 22, height: 32), end = CGRect(x: 84, y: 14, width: 22, height: 32)
        let tailOnly = base(.none, start: .filled)
        let plainStart = try ink(base(.none), in: start), plainEnd = try ink(base(.none), in: end)
        #expect(try ink(tailOnly, in: start) > plainStart + 8)
        #expect(try ink(tailOnly, in: end) <= plainEnd + 2)                       // nothing extra at the other end
        let both = base(.dot, start: .dot)
        #expect(try ink(both, in: start) > plainStart + 8 && (try ink(both, in: end)) > plainEnd + 8)
    }

    @Test func thickerLinesGetBiggerHeads() throws {
        let tip = CGRect(x: 70, y: 0, width: 50, height: 60)
        #expect(try ink(base(.filled, width: 12), in: tip) > (try ink(base(.filled, width: 3), in: tip)) * 2)
    }

    @Test func headsSurviveSavingAndOldFilesDefaultToNone() throws {
        let style = base(.diamond, start: .bar)
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded.endHead == .diamond && decoded.startHead == .bar)
        let old = try JSONDecoder().decode(AnnotationStyle.self, from: Data("{}".utf8))
        #expect(old.endHead == .none && old.startHead == .none)
    }
}
