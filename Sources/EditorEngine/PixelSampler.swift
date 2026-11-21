import CoreGraphics
import CoreModels
import Foundation

/// Reads exact pixel colours from a picture, for the eyedropper and its magnifier. The picture is unpacked once into plain bytes
/// (the first read takes a moment on a large picture), so every later read is instant, however fast the pointer moves.
public final class PixelSampler: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let pixels: [UInt8]?                    // RGBA, not premultiplied, top row first; nil for huge pictures
    private let image: CGImage

    /// Pictures with more pixels than this are not unpacked (a very tall scrolling capture would take hundreds of megabytes);
    /// they are read through a small crop around each requested pixel instead.
    nonisolated(unsafe) static var unpackLimit = 40_000_000

    public init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        self.image = image
        width = w; height = h
        let unpackIt = w * h <= Self.unpackLimit
        pixels = unpackIt ? Self.unpack(image) : nil
        if pixels == nil, unpackIt { return nil }
    }

    private static func unpack(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Undo the premultiplication, so a half-transparent pixel reports its real colour.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            if a > 0, a < 255 {
                for c in 0..<3 { bytes[i + c] = UInt8(min(255, (Int(bytes[i + c]) * 255 + a / 2) / a)) }
            }
        }
        return bytes
    }

    /// The colour of the pixel at (`x`, `y`) (image pixels, top-left origin), or nil outside the picture.
    public func color(x: Int, y: Int) -> RGBAColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        guard let pixels else {
            // A huge picture: unpack just this pixel.
            guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)), let one = Self.unpack(crop) else { return nil }
            return RGBAColor(red: Double(one[0]) / 255, green: Double(one[1]) / 255, blue: Double(one[2]) / 255, alpha: Double(one[3]) / 255)
        }
        let i = (y * width + x) * 4
        return RGBAColor(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255, alpha: Double(pixels[i + 3]) / 255)
    }

    public func color(at point: CGPoint) -> RGBAColor? { color(x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down))) }

    /// The square of pixels around `center`, `radius` pixels each way (a magnifier shows these), row by row from the top.
    /// Pixels outside the picture are nil.
    public func patch(around center: CGPoint, radius: Int) -> [[RGBAColor?]] {
        let cx = Int(center.x.rounded(.down)), cy = Int(center.y.rounded(.down))
        if pixels == nil {                                                       // one crop for the whole patch, not one per pixel
            let area = CGRect(x: cx - radius, y: cy - radius, width: 2 * radius + 1, height: 2 * radius + 1)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if let crop = image.cropping(to: area), let small = PixelSampler(image: crop) {
                return (-radius...radius).map { dy in (-radius...radius).map { dx in
                    small.color(x: cx + dx - Int(area.minX), y: cy + dy - Int(area.minY))
                } }
            }
        }
        return (-radius...radius).map { dy in (-radius...radius).map { dx in color(x: cx + dx, y: cy + dy) } }
    }

    // MARK: Shared

    /// The sampler for a picture, kept for as long as that picture is in use.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var current: (image: CGImage, sampler: PixelSampler)?

    public static func shared(for image: CGImage) -> PixelSampler? {
        lock.lock(); defer { lock.unlock() }
        if let current, current.image === image { return current.sampler }
        guard let sampler = PixelSampler(image: image) else { return nil }
        current = (image, sampler)
        return sampler
    }
}

/// The area a paint bucket would fill, found without drawing anything: used for the live preview under the pointer.
public enum FillRegion {
    /// A mask the size of the picture (0 = inside the region, 255 = outside), or nil if `seed` is outside it.
    /// `tolerance` is a percentage, the same scale as the paint bucket's Tolerance setting.
    public static func mask(in image: CGImage, seed: CGPoint, tolerance: Double) -> CGImage? {
        FloodFill.mask(in: image, seed: seed, tolerance: Int((tolerance * 2.55).rounded()))
    }

    /// Whether `point` lies inside a mask made by `mask(in:seed:tolerance:)`.
    public static func contains(_ mask: CGImage, point: CGPoint) -> Bool {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < mask.width, y < mask.height, let data = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        return bytes[y * mask.bytesPerRow + x] == 0
    }
}
