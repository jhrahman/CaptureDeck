import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

/// 60x40 picture: left half black, right half white (a hard vertical edge at x = 30).
private func edgePicture() -> CGImage {
    let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 30, y: 0, width: 30, height: 40))
    return ctx.makeImage()!
}

/// A 64x64 picture where every pixel has a different color, to see whether blocks become uniform.
private func noisePicture() -> CGImage {
    var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
    for y in 0..<64 { for x in 0..<64 {
        let i = (y * 64 + x) * 4
        bytes[i] = UInt8((x * 4) % 256); bytes[i + 1] = UInt8((y * 4) % 256); bytes[i + 2] = UInt8(((x + y) * 2) % 256)
    } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func gray(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Int(data[(y * w + x) * 4])
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

struct PixelEffectTests {
    private func style(_ strength: Double) -> AnnotationStyle { AnnotationStyle(strokeColor: .black, strength: strength) }

    @Test func blurSoftensAHardEdgeInsideTheRegionOnly() throws {
        let picture = edgePicture()
        let a = Annotation(shape: BlurShape(rect: CGRect(x: 10, y: 5, width: 40, height: 30)), style: style(6))
        let out = try #require(AnnotationRenderer.render([a], onto: picture))
        #expect(gray(picture, 28, 20) == 0 && gray(picture, 32, 20) == 255)              // a hard edge to begin with
        let left = gray(out, 28, 20), right = gray(out, 32, 20)
        #expect(left > 20 && left < 200, "left of the edge should be lighter than black: \(left)")
        #expect(right < 235 && right > 55, "right of the edge should be darker than white: \(right)")
        #expect(left < right, "the edge should still run dark to light: \(left) vs \(right)")
        #expect(gray(out, 5, 20) == 0 && gray(out, 55, 20) == 255)                        // outside the region: untouched
        #expect(gray(out, 28, 2) == 0 && gray(out, 32, 2) == 255)                         // above the region: untouched
    }

    @Test func blurDoesNotDarkenTheRegionEdgesWithTransparentPixels() throws {
        let a = Annotation(shape: BlurShape(rect: CGRect(x: 0, y: 0, width: 60, height: 40)), style: style(10))   // covers the whole picture
        let out = try #require(AnnotationRenderer.render([a], onto: edgePicture()))
        #expect(gray(out, 59, 20) > 200)                                                  // the far right stays white, not faded to transparent/black
        #expect(gray(out, 0, 20) < 30)
    }

    @Test func pixelateTurnsEachBlockIntoOneColor() throws {
        let picture = noisePicture()
        let a = Annotation(shape: PixelateShape(rect: CGRect(x: 0, y: 0, width: 64, height: 64)), style: style(16))
        let out = try #require(AnnotationRenderer.render([a], onto: picture))
        for (x, y) in [(2, 2), (7, 9), (13, 13)] {                                        // all inside the first 16x16 block
            #expect(rgb(out, x, y) == rgb(out, 2, 2), "pixel (\(x),\(y)) differs from the rest of its block")
        }
        #expect(rgb(picture, 2, 2) != rgb(picture, 13, 13))                               // the original was not uniform
        #expect(rgb(out, 2, 2) != rgb(out, 20, 2))                                        // neighbouring blocks differ
    }

    @Test func pixelateBlocksStartAtTheRegionCorner() throws {
        let region = CGRect(x: 8, y: 8, width: 32, height: 32)
        let out = try #require(AnnotationRenderer.render([Annotation(shape: PixelateShape(rect: region), style: style(16))], onto: noisePicture()))
        #expect(rgb(out, 8, 8) == rgb(out, 23, 23))                                       // the first block is 8...23
        #expect(rgb(out, 8, 8) != rgb(out, 24, 24))
    }

    @Test func regionsPartlyOutsideThePictureAreClipped() throws {
        let a = Annotation(shape: BlurShape(rect: CGRect(x: 40, y: 20, width: 100, height: 100)), style: style(5))
        #expect(AnnotationRenderer.render([a], onto: edgePicture()) != nil)
        let gone = Annotation(shape: BlurShape(rect: CGRect(x: 500, y: 500, width: 10, height: 10)), style: style(5))
        let out = try #require(AnnotationRenderer.render([gone], onto: edgePicture()))
        #expect(gray(out, 28, 20) == 0)
    }

    @Test func effectsWithoutAPictureDrawNothingAndDoNotCrash() {
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        AnnotationRenderer.draw([Annotation(shape: BlurShape(rect: CGRect(x: 0, y: 0, width: 5, height: 5)), style: .default)], in: ctx)
    }

    @Test func differentPicturesNeverShareCachedResults() throws {
        let region = CGRect(x: 0, y: 0, width: 60, height: 40)
        let first = try #require(PixelEffects.apply(.blur, to: edgePicture(), in: region, strength: 5))
        let inverted = { () -> CGImage in
            let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 30, y: 0, width: 30, height: 40))
            return ctx.makeImage()!
        }()
        let second = try #require(PixelEffects.apply(.blur, to: inverted, in: region, strength: 5))
        #expect(gray(first, 5, 20) < 30 && gray(second, 5, 20) > 225)                    // each result belongs to its own picture
    }

    @Test func strengthSurvivesSavingAndOldFilesGetADefault() throws {
        let style = AnnotationStyle(strokeColor: .black, strength: 33)
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded.strength == 33)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: Data(#"{}"#.utf8)).strength == 12)
        for shape: any AnnotationShape in [BlurShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4)), PixelateShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4))] {
            let a = Annotation(shape: shape, style: style)
            let loaded = Annotation(record: try JSONDecoder().decode(AnnotationRecord.self, from: JSONEncoder().encode(a.record())))
            #expect(!(loaded.shape is UnknownShape) && loaded.shape.shapeType == shape.shapeType)
        }
    }
}

struct SpotlightAndMagnifierTests {
    private func flat(_ w: Int, _ h: Int, _ c: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(c); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func spotlightDimsOutsideAndLeavesTheWindowBright() throws {
        let style = AnnotationStyle(strokeColor: .black, opacity: 0.6)
        let a = Annotation(shape: SpotlightShape(rect: CGRect(x: 30, y: 20, width: 40, height: 30)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: flat(100, 80, CGColor(gray: 1, alpha: 1))))
        #expect(gray(out, 50, 35) == 255)                                        // inside the window: untouched
        let dimmed = gray(out, 5, 5)
        #expect(dimmed > 80 && dimmed < 130, "outside should be ~40% bright: \(dimmed)")
        #expect(gray(out, 95, 75) == dimmed && gray(out, 5, 75) == dimmed)       // the whole outside is dimmed equally
    }

    @Test func aLargeCornerRadiusMakesAnOvalWindow() throws {
        let style = AnnotationStyle(strokeColor: .black, opacity: 1, cornerRadius: 500)
        let a = Annotation(shape: SpotlightShape(rect: CGRect(x: 20, y: 10, width: 60, height: 60)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: flat(100, 80, CGColor(gray: 1, alpha: 1))))
        #expect(gray(out, 50, 40) == 255)                                        // center of the window
        #expect(gray(out, 22, 12) == 0)                                          // a corner of the window's rectangle is outside the oval
    }

    @Test func magnifierEnlargesWhatIsUnderIt() throws {
        // A 3x3 red square at the middle of a white picture, magnified 4x: it should become about 12x12.
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 49, y: 49, width: 3, height: 3))
        let picture = ctx.makeImage()!
        let style = AnnotationStyle(strokeColor: .black, lineWidth: 0, strength: 4)
        let a = Annotation(shape: MagnifierShape(rect: CGRect(x: 30, y: 30, width: 40, height: 40)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: picture))
        // The 3-px square (x 49...52) is scaled 4x around the lens center (50): it now covers x 46...58.
        func isRed(_ p: [Int]) -> Bool { p[0] > 240 && p[1] < 40 && p[2] < 40 }       // smooth scaling softens the very edge
        #expect(isRed(rgb(out, 49, 50)) && isRed(rgb(out, 54, 50)) && isRed(rgb(out, 52, 45)))
        #expect(rgb(out, 43, 50) == [255, 255, 255] && rgb(out, 61, 50) == [255, 255, 255])   // beyond the enlarged square
        #expect(rgb(picture, 44, 50) == [255, 255, 255])                              // the original really was small
        #expect(rgb(out, 5, 5) == [255, 255, 255])                                    // outside the lens: unchanged
    }

    @Test func magnifierIsRoundAndHasABorder() throws {
        let style = AnnotationStyle(strokeColor: RGBAColor(red: 0, green: 0, blue: 1), lineWidth: 4, strength: 2)
        let a = Annotation(shape: MagnifierShape(rect: CGRect(x: 20, y: 20, width: 60, height: 60)), style: style)
        let out = try #require(AnnotationRenderer.render([a], onto: flat(100, 100, CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))))
        #expect(rgb(out, 50, 20) == [0, 0, 255])                                      // border at the top of the circle
        let background = flat(100, 100, CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        #expect(rgb(out, 22, 22) == rgb(background, 22, 22))                          // the rectangle's corner is outside the circle: untouched
        #expect(a.hitTest(CGPoint(x: 50, y: 50), tolerance: 0) && !a.hitTest(CGPoint(x: 21, y: 21), tolerance: 0))
    }

    @Test func bothSurviveSaving() throws {
        for shape: any AnnotationShape in [SpotlightShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4)), MagnifierShape(rect: CGRect(x: 1, y: 2, width: 3, height: 4))] {
            let loaded = Annotation(record: try JSONDecoder().decode(AnnotationRecord.self, from: JSONEncoder().encode(Annotation(shape: shape, style: .default).record())))
            #expect(!(loaded.shape is UnknownShape) && loaded.shape.shapeType == shape.shapeType)
        }
    }
}
