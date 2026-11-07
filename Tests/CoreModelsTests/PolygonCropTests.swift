import CoreGraphics
import Testing
@testable import CoreModels

private func redImage() -> CapturedImage {
    let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)   // 20 x 10 points
}

/// RGBA of the pixel at (x, y), counted from the top-left.
private func pixel(_ image: CapturedImage, _ x: Int, _ y: Int) -> (r: UInt8, a: UInt8) {
    let w = image.cgImage.width, h = image.cgImage.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return (data[i], data[i + 3])
}

struct PolygonCropTests {
    @Test func triangleKeepsInsideAndClearsOutside() throws {
        // Triangle covering the top-left half of the 20x10 pt image.
        let result = try #require(redImage().cropped(toPolygon: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 0, y: 10)]))
        #expect(result.pixelSize == CGSize(width: 40, height: 20))
        #expect(pixel(result, 3, 2).a == 255)          // inside (near top-left)
        #expect(pixel(result, 36, 17).a == 0)          // outside (near bottom-right)
        #expect(pixel(result, 3, 2).r > 200)
    }

    @Test func resultIsBoundingBoxOnly() throws {
        let result = try #require(redImage().cropped(toPolygon: [CGPoint(x: 5, y: 2), CGPoint(x: 15, y: 2), CGPoint(x: 10, y: 8)]))
        #expect(result.pixelSize == CGSize(width: 20, height: 12))      // 10 x 6 pt at 2x
        #expect(pixel(result, 10, 1).a == 255)         // top middle is inside the triangle
        #expect(pixel(result, 0, 11).a == 0)           // bottom-left corner is outside it
    }

    @Test func rejectsDegenerateInput() {
        #expect(redImage().cropped(toPolygon: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]) == nil)
        #expect(redImage().cropped(toPolygon: [CGPoint(x: 900, y: 900), CGPoint(x: 950, y: 900), CGPoint(x: 900, y: 950)]) == nil)
    }

    @Test func sourceIsCarriedOnlyWhenSet() {
        let image = redImage()
        #expect(image.source == nil)
        #expect(image.withSource(.display(4)).source == .display(4))
        #expect(image.cropped(toPointRect: CGRect(x: 0, y: 0, width: 5, height: 5))?.source == nil)
    }
}
