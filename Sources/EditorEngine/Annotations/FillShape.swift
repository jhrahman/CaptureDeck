import CoreGraphics
import Foundation

/// Finds the area a paint bucket would fill: the connected pixels that are close in color to the one clicked.
enum FloodFill {
    /// Returns a mask the size of the picture: 0 where the fill goes, 255 everywhere else (that is what
    /// `CGImage` masks expect: 0 paints). Nil if the seed is outside the picture.
    static func mask(in image: CGImage, seed: CGPoint, tolerance: Int) -> CGImage? {
        let w = image.width, h = image.height
        let sx = Int(seed.x.rounded(.down)), sy = Int(seed.y.rounded(.down))
        guard sx >= 0, sy >= 0, sx < w, sy < h else { return nil }

        // The picture as plain RGBA bytes, top row first.
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let base = (sy * w + sx) * 4
        let target = (pixels[base], pixels[base + 1], pixels[base + 2], pixels[base + 3])
        let limit = max(0, min(tolerance, 255))
        func matches(_ i: Int) -> Bool {
            abs(Int(pixels[i]) - Int(target.0)) <= limit && abs(Int(pixels[i + 1]) - Int(target.1)) <= limit
                && abs(Int(pixels[i + 2]) - Int(target.2)) <= limit && abs(Int(pixels[i + 3]) - Int(target.3)) <= limit
        }

        var filled = [Bool](repeating: false, count: w * h)
        var stack = [(Int, Int)]()
        stack.append((sx, sy))
        // Scanline fill: take a row span at a time, then look above and below it.
        while let (x0, y) = stack.popLast() {
            if filled[y * w + x0] || !matches((y * w + x0) * 4) { continue }
            var left = x0, right = x0
            while left > 0, !filled[y * w + left - 1], matches((y * w + left - 1) * 4) { left -= 1 }
            while right < w - 1, !filled[y * w + right + 1], matches((y * w + right + 1) * 4) { right += 1 }
            for x in left...right { filled[y * w + x] = true }
            for ny in [y - 1, y + 1] where ny >= 0 && ny < h {
                var x = left
                while x <= right {
                    if !filled[ny * w + x], matches((ny * w + x) * 4) {
                        stack.append((x, ny))
                        while x <= right, !filled[ny * w + x], matches((ny * w + x) * 4) { x += 1 }   // one seed per run
                    } else {
                        x += 1
                    }
                }
            }
        }

        let bytes = filled.map { $0 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       provider: provider, decode: nil, shouldInterpolate: false)
    }

    // One picture at a time, like the blur cache: clicking and redrawing must not redo the work, but a result must
    // never be shown for a different picture.
    private final class Cache: @unchecked Sendable {
        struct Key: Hashable { let x: Int; let y: Int; let tolerance: Int }
        private let lock = NSLock()
        private var picture: CGImage?
        private var items: [Key: CGImage?] = [:]

        func fetch(_ key: Key, picture: CGImage, make: () -> CGImage?) -> CGImage? {
            lock.lock()
            if self.picture !== picture { self.picture = picture; items = [:] }
            if let hit = items[key] { lock.unlock(); return hit }
            lock.unlock()
            let made = make()
            lock.lock(); defer { lock.unlock() }
            if self.picture === picture {
                if items.count > 24 { items = [:] }
                items[key] = made
            }
            return made
        }
    }
    private static let cache = Cache()

    static func cachedMask(in image: CGImage, seed: CGPoint, tolerance: Int) -> CGImage? {
        cache.fetch(.init(x: Int(seed.x.rounded(.down)), y: Int(seed.y.rounded(.down)), tolerance: tolerance), picture: image) {
            mask(in: image, seed: seed, tolerance: tolerance)
        }
    }
}

/// A paint-bucket fill: every pixel connected to `seed` that is close in color to it gets the fill color
/// (the style's `strokeColor`). The style's `strength` is the tolerance, as a percentage. The fill is worked out from
/// the original picture, so it stays editable (move the seed, change the color or tolerance, or undo it).
public struct FillShape: BackdropAnnotationShape, Codable, Equatable {
    public static let typeID = "fill"
    public var seed: CGPoint

    public init(seed: CGPoint) { self.seed = seed }

    /// Whether a fill in this style makes its region transparent. (Its opacity setting does not apply then.)
    public static func erases(_ style: AnnotationStyle) -> Bool { style.strokeColor.alpha == 0 }

    /// A small square around the seed, so the fill can be clicked, selected and deleted.
    public var geometryBounds: CGRect { CGRect(x: seed.x - 6, y: seed.y - 6, width: 12, height: 12) }

    public func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage) {
        let tolerance = Int((style.strength * 2.55).rounded())
        guard let mask = FloodFill.cachedMask(in: backdrop, seed: seed, tolerance: tolerance) else { return }
        let w = CGFloat(backdrop.width), h = CGFloat(backdrop.height)
        context.saveGState()
        context.translateBy(x: 0, y: h)                         // our space is y-down; masks and images are y-up
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask)
        if Self.erases(style) {                                 // a transparent fill removes the region
            context.setBlendMode(.clear)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
        } else {
            context.setFillColor(style.strokeColor.cgColor)
        }
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.restoreGState()
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        hypot(point.x - seed.x, point.y - seed.y) <= 10 + tolerance
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        let p = seed.applying(transform)
        return FillShape(seed: CGPoint(x: (p.x * 1000).rounded() / 1000, y: (p.y * 1000).rounded() / 1000))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
