import CoreGraphics
import Testing
@testable import EditorEngine

struct PixelSamplerTests {
    /// 40 x 20: left half red, right half blue, one green pixel at (5, 3), a 50% transparent pixel at (30, 10).
    private func image() -> CGImage {
        let w = 40, h = 20
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 5, y: h - 1 - 3, width: 1, height: 1))     // y is bottom-up here
        return ctx.makeImage()!
    }

    @Test func readsExactColoursFromTheTopLeftOrigin() throws {
        let sampler = try #require(PixelSampler(image: image()))
        #expect(sampler.color(x: 2, y: 2)?.hex.hasPrefix("#FF0000") == true)
        #expect(sampler.color(x: 30, y: 15)?.hex.hasPrefix("#0000FF") == true)
        #expect(sampler.color(x: 5, y: 3)?.hex.hasPrefix("#00FF00") == true)             // y counts from the top
        #expect(sampler.color(x: 5, y: 4)?.hex.hasPrefix("#FF0000") == true)
        #expect(sampler.color(x: -1, y: 0) == nil && sampler.color(x: 40, y: 0) == nil && sampler.color(x: 0, y: 20) == nil)
        #expect(sampler.color(at: CGPoint(x: 5.9, y: 3.2))?.hex.hasPrefix("#00FF00") == true)
    }

    @Test func aPatchHasTheRightShapeAndMarksWhatIsOutside() throws {
        let sampler = try #require(PixelSampler(image: image()))
        let patch = sampler.patch(around: CGPoint(x: 1, y: 1), radius: 3)
        #expect(patch.count == 7 && patch.allSatisfy { $0.count == 7 })
        #expect(patch[3][3]?.hex.hasPrefix("#FF0000") == true)                          // the centre
        #expect(patch[0][0] == nil)                                                    // two pixels above and left of the picture
    }

    @Test func aVeryLargePictureIsReadWithoutBeingUnpacked() throws {
        let saved = PixelSampler.unpackLimit
        PixelSampler.unpackLimit = 100                                                  // pretend 40 x 20 is "huge"
        defer { PixelSampler.unpackLimit = saved }
        let sampler = try #require(PixelSampler(image: image()))
        #expect(sampler.color(x: 30, y: 15)?.hex.hasPrefix("#0000FF") == true)
        #expect(sampler.color(x: 5, y: 3)?.hex.hasPrefix("#00FF00") == true)
        let patch = sampler.patch(around: CGPoint(x: 20, y: 10), radius: 2)             // across the red / blue edge
        #expect(patch[2][0]?.hex.hasPrefix("#FF0000") == true && patch[2][4]?.hex.hasPrefix("#0000FF") == true)
        #expect(patch[2][2]?.hex.hasPrefix("#0000FF") == true)
    }

    @Test func theFillRegionMatchesWhatTheBucketWouldFill() throws {
        let picture = image()
        let mask = try #require(FillRegion.mask(in: picture, seed: CGPoint(x: 2, y: 2), tolerance: 10))
        #expect(FillRegion.contains(mask, point: CGPoint(x: 10, y: 10)))                // inside the red half
        #expect(!FillRegion.contains(mask, point: CGPoint(x: 30, y: 10)))               // the blue half is a different region
        #expect(!FillRegion.contains(mask, point: CGPoint(x: 5, y: 3)))                 // the green pixel is not part of it
        #expect(!FillRegion.contains(mask, point: CGPoint(x: -3, y: 3)))                // outside the picture
    }
}
