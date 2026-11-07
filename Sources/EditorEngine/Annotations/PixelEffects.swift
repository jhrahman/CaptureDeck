import CoreGraphics
import CoreImage
import Foundation

/// Blur and pixelate a region of a picture. Used by the blur and pixelate annotations to hide sensitive information.
public enum PixelEffects {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public enum Kind: Hashable, Sendable { case blur, pixelate }

    /// The part of `rect` that lies inside the image, in whole pixels (origin top-left).
    static func region(_ rect: CGRect, in image: CGImage) -> CGRect? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (r.isNull || r.width < 1 || r.height < 1) ? nil : r
    }

    /// The processed pixels for `rect` (the result is exactly the rectangle `region(rect, in:)`).
    public static func apply(_ kind: Kind, to image: CGImage, in rect: CGRect, strength: Double) -> CGImage? {
        guard let r = region(rect, in: image) else { return nil }
        let key = Key(rect: r, kind: kind, strength: strength)
        if let cached = cache.value(for: key, picture: image) { return cached }

        let source = CIImage(cgImage: image)
        // Core Image's origin is bottom-left.
        let target = CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height)
        // Extending the edge pixels outward means blurring near the border of the region (or the picture) pulls in
        // real neighbouring pixels instead of transparent black.
        let extended = source.clampedToExtent()
        let processed: CIImage
        switch kind {
        case .blur:
            processed = extended.applyingGaussianBlur(sigma: max(strength, 0.1))
        case .pixelate:
            processed = extended.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(strength, 1),
                kCIInputCenterKey: CIVector(x: target.minX, y: target.minY),      // blocks start at the region's corner
            ])
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = context.createCGImage(processed.cropped(to: target), from: target, format: .RGBA8, colorSpace: space) else { return nil }
        cache.store(result, for: key, picture: image)
        return result
    }

    /// Draws the processed region into `context` (image pixel coordinates, y down).
    static func draw(_ kind: Kind, rect: CGRect, style: AnnotationStyle, backdrop: CGImage, in context: CGContext) {
        guard let r = region(rect, in: backdrop), let processed = apply(kind, to: backdrop, in: r, strength: style.strength) else { return }
        context.saveGState()
        context.translateBy(x: r.minX, y: r.maxY)          // our space is y-down; images draw y-up
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(processed, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        context.restoreGState()
    }

    // MARK: Cache

    /// Dragging or redrawing the canvas would otherwise recompute the same blur many times a second.
    /// The cache belongs to one picture at a time: it holds that picture strongly and empties itself the moment a
    /// different one arrives, so a result can never be shown for the wrong picture.
    private struct Key: Hashable {
        let rect: CGRect
        let kind: Kind
        let strength: Double
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var picture: CGImage?
        private var items: [Key: CGImage] = [:]
        private var order: [Key] = []
        private let limit = 24

        func value(for key: Key, picture: CGImage) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            guard self.picture === picture else { return nil }
            return items[key]
        }

        func store(_ value: CGImage, for key: Key, picture: CGImage) {
            lock.lock(); defer { lock.unlock() }
            if self.picture !== picture {
                self.picture = picture
                items = [:]
                order = []
            }
            items[key] = value
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > limit { items[order.removeFirst()] = nil }
        }
    }
    private static let cache = Cache()
}

// MARK: - Shapes

/// Blurs the picture inside the rectangle (to hide text or faces). Strength = blur radius in pixels.
public struct BlurShape: BackdropAnnotationShape, Codable, Equatable {
    public static let typeID = "blur"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }
    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage) {
        PixelEffects.draw(.blur, rect: rect, style: style, backdrop: backdrop, in: context)
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        let r = rect.applying(transform)
        return BlurShape(rect: CGRect(x: (r.minX * 1000).rounded() / 1000, y: (r.minY * 1000).rounded() / 1000,
                                      width: (r.width * 1000).rounded() / 1000, height: (r.height * 1000).rounded() / 1000))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

/// Replaces the picture inside the rectangle with large blocks. Strength = block size in pixels.
public struct PixelateShape: BackdropAnnotationShape, Codable, Equatable {
    public static let typeID = "pixelate"
    public var rect: CGRect

    public init(rect: CGRect) { self.rect = rect.standardized }
    public var geometryBounds: CGRect { rect }

    public func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage) {
        PixelEffects.draw(.pixelate, rect: rect, style: style, backdrop: backdrop, in: context)
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        let r = rect.applying(transform)
        return PixelateShape(rect: CGRect(x: (r.minX * 1000).rounded() / 1000, y: (r.minY * 1000).rounded() / 1000,
                                          width: (r.width * 1000).rounded() / 1000, height: (r.height * 1000).rounded() / 1000))
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
