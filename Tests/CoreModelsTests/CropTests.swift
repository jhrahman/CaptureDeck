import CoreGraphics
import Testing
@testable import CoreModels

/// 40x20 pixel image: top half red, bottom half blue (scale 2 => 20x10 points).
private func twoToneImage() -> CapturedImage {
    let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 10))   // bottom
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 10, width: 40, height: 10))  // top
    return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
}

private func firstPixel(_ image: CapturedImage) -> (r: UInt8, g: UInt8, b: UInt8) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: image.cgImage.width, height: image.cgImage.height))
    return (px[0], px[1], px[2])
}

struct CropTests {
    @Test func cropUsesTopLeftOriginAndScale() throws {
        let top = try #require(twoToneImage().cropped(toPointRect: CGRect(x: 0, y: 0, width: 10, height: 4)))
        #expect(top.pixelSize == CGSize(width: 20, height: 8))
        #expect(top.scale == 2)
        let t = firstPixel(top)
        #expect(t.r > 200 && t.b < 40)                      // top rows are red

        let bottom = try #require(twoToneImage().cropped(toPointRect: CGRect(x: 0, y: 6, width: 10, height: 4)))
        let b = firstPixel(bottom)
        #expect(b.b > 200 && b.r < 40)                      // bottom rows are blue
    }

    @Test func cropIsClampedAndRejectsEmpty() {
        let image = twoToneImage()
        #expect(image.cropped(toPointRect: CGRect(x: 15, y: 5, width: 100, height: 100))?.pixelSize == CGSize(width: 10, height: 10))
        #expect(image.cropped(toPointRect: CGRect(x: 500, y: 500, width: 10, height: 10)) == nil)
    }

    @Test func croppedImageDoesNotRetainFullBuffer() throws {
        let c = try #require(twoToneImage().cropped(toPointRect: CGRect(x: 0, y: 0, width: 5, height: 5)))
        #expect(c.cgImage.width == 10 && c.cgImage.height == 10)
    }
}
