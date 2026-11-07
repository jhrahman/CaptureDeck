import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

/// 2x2 image: top row red, green; bottom row blue, white.
private func quad() -> CGImage {
    let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return data[i..<i + 4].map(Int.init)
}

struct RGBAColorTests {
    @Test func parsesHexWithAndWithoutAlpha() {
        #expect(RGBAColor(hex: "#FF8000")?.hex == "#FF8000FF")
        #expect(RGBAColor(hex: "ff800080")?.hex == "#FF800080")
        #expect(RGBAColor(hex: "#12345") == nil)
        #expect(RGBAColor(hex: "zzzzzz") == nil)
        #expect(RGBAColor.clear.hex == "#00000000")
    }

    @Test func clampsOutOfRangeComponents() {
        let c = RGBAColor(red: 2, green: -1, blue: .nan, alpha: 5)
        #expect(c == RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
    }
}

struct CanvasSizeTests {
    private let white = RGBAColor.white

    @Test func expandingWithTopLeftAnchorKeepsPictureAtTopLeft() throws {
        let out = try #require(ImageOperation.canvasSize(width: 4, height: 4, anchor: .topLeft, fill: .black).apply(to: quad()))
        #expect(out.width == 4 && out.height == 4)
        #expect(rgba(out, 0, 0) == [255, 0, 0, 255])        // red still top-left
        #expect(rgba(out, 3, 3) == [0, 0, 0, 255])          // new area is the fill
    }

    @Test func centerAndBottomRightAnchors() throws {
        let center = try #require(ImageOperation.canvasSize(width: 4, height: 4, anchor: .center, fill: .black).apply(to: quad()))
        #expect(rgba(center, 1, 1) == [255, 0, 0, 255] && rgba(center, 0, 0) == [0, 0, 0, 255])
        let corner = try #require(ImageOperation.canvasSize(width: 4, height: 4, anchor: .bottomRight, fill: .black).apply(to: quad()))
        #expect(rgba(corner, 2, 2) == [255, 0, 0, 255] && rgba(corner, 3, 3) == [255, 255, 255, 255])
    }

    @Test func transparentFillStaysTransparent() throws {
        let out = try #require(ImageOperation.canvasSize(width: 3, height: 2, anchor: .left, fill: .clear).apply(to: quad()))
        #expect(rgba(out, 2, 0)[3] == 0)
        #expect(rgba(out, 0, 0) == [255, 0, 0, 255])
    }

    @Test func shrinkingCropsAccordingToAnchor() throws {
        let out = try #require(ImageOperation.canvasSize(width: 1, height: 1, anchor: .bottomRight, fill: white).apply(to: quad()))
        #expect(out.width == 1 && rgba(out, 0, 0) == [255, 255, 255, 255])    // the white (bottom-right) pixel
    }

    @Test func rejectsInvalidSizes() {
        #expect(ImageOperation.canvasSize(width: 0, height: 5, anchor: .center, fill: white).apply(to: quad()) == nil)
        #expect(ImageOperation.canvasSize(width: 40_000, height: 5, anchor: .center, fill: white).apply(to: quad()) == nil)
    }
}

struct ArbitraryRotationTests {
    @Test func ninetyDegreesSwapsDimensionsLikeAQuarterTurn() throws {
        let wide = try #require(ImageOperation.canvasSize(width: 6, height: 2, anchor: .topLeft, fill: .white).apply(to: quad()))
        let out = try #require(ImageOperation.rotateByAngle(degrees: 90, fill: .black).apply(to: wide))
        #expect(out.width == 2 && out.height == 6)
    }

    @Test func fortyFiveDegreesGrowsTheCanvasAndFillsTheCorners() throws {
        let big = try #require(ImageOperation.resize(width: 20, height: 20).apply(to: quad()))
        let out = try #require(ImageOperation.rotateByAngle(degrees: 45, fill: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)).apply(to: big))
        #expect(out.width == 29 && out.height == 29)                    // 20 * (cos45 + sin45) = 28.28 -> 29
        #expect(rgba(out, 0, 0) == [0, 0, 0, 255])                       // corner is background
        #expect(rgba(out, 14, 14)[3] == 255 && rgba(out, 14, 14) != [0, 0, 0, 255])   // center is picture
    }

    @Test func zeroDegreesKeepsTheSize() throws {
        let out = try #require(ImageOperation.rotateByAngle(degrees: 0, fill: .white).apply(to: quad()))
        #expect(out.width == 2 && out.height == 2 && rgba(out, 0, 0) == [255, 0, 0, 255])
    }

    @Test func namesAreReadable() {
        #expect(ImageOperation.rotateByAngle(degrees: 15, fill: .white).name == "Rotate 15°")
        #expect(ImageOperation.rotateByAngle(degrees: 7.5, fill: .white).name == "Rotate 7.5°")
        #expect(ImageOperation.canvasSize(width: 1, height: 1, anchor: .center, fill: .white).name == "Canvas Size")
    }

    @Test func newOperationsRoundTripThroughJSON() throws {
        let ops: [ImageOperation] = [.canvasSize(width: 5, height: 6, anchor: .bottom, fill: RGBAColor(hex: "#11223344")!),
                                     .rotateByAngle(degrees: -12.5, fill: .clear)]
        let data = try JSONEncoder().encode(ops)
        #expect(try JSONDecoder().decode([ImageOperation].self, from: data) == ops)
    }
}

struct ResizeMathTests {
    @Test func percentScalesBothSides() {
        #expect(ResizeMath.size(from: (1000, 600), percent: 50) == (500, 300))
        #expect(ResizeMath.size(from: (1000, 600), percent: 200) == (2000, 1200))
        #expect(ResizeMath.size(from: (3, 3), percent: 10) == (1, 1))              // never below 1
    }

    @Test func keepingProportionsFollowsTheOtherSide() {
        #expect(ResizeMath.height(forWidth: 500, keepingProportionsOf: (1000, 600)) == 300)
        #expect(ResizeMath.width(forHeight: 150, keepingProportionsOf: (1000, 600)) == 250)
        #expect(ResizeMath.height(forWidth: 1, keepingProportionsOf: (1000, 1)) == 1)
    }

    @Test func validity() {
        #expect(ResizeMath.isValid(width: 1, height: 30_000))
        #expect(!ResizeMath.isValid(width: 0, height: 5))
        #expect(!ResizeMath.isValid(width: 30_001, height: 5))
    }
}
