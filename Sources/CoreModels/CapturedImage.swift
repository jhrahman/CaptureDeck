import CoreGraphics

/// An immutable captured bitmap plus its Retina scale (pixels per point).
/// `CGImage` is immutable, so sharing it across concurrency domains is safe.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Pixels per point of the source display (2.0 on Retina).
    public let scale: CGFloat
    /// What was captured, when it can be captured again ("repeat last capture").
    public let source: CaptureTarget?

    public init(cgImage: CGImage, scale: CGFloat, source: CaptureTarget? = nil) {
        self.cgImage = cgImage
        self.scale = scale
        self.source = source
    }

    public func withSource(_ source: CaptureTarget?) -> CapturedImage {
        CapturedImage(cgImage: cgImage, scale: scale, source: source)
    }

    public var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    public var pointSize: CGSize { CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale) }
}

/// What a capture mode produces. `.video` can be added when recording arrives.
public enum CaptureResult: Sendable {
    case image(CapturedImage)
}

public extension CapturedImage {
    /// A pixel-exact copy of `pointRect` (display points, origin top-left), clamped to the image.
    /// Draws into a new bitmap so the result does not keep the whole source image alive in memory.
    func cropped(toPointRect pointRect: CGRect) -> CapturedImage? {
        crop(pointRect: pointRect, polygon: nil)
    }

    /// The polygon's bounding box with everything outside the polygon transparent.
    func cropped(toPolygon points: [CGPoint]) -> CapturedImage? {
        guard points.count >= 3 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return crop(pointRect: box, polygon: points)
    }

    private func crop(pointRect: CGRect, polygon: [CGPoint]?) -> CapturedImage? {
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let pixelRect = CGRect(
            x: (pointRect.minX * scale).rounded(.down),
            y: (pointRect.minY * scale).rounded(.down),
            width: (pointRect.width * scale).rounded(.up),
            height: (pointRect.height * scale).rounded(.up)
        ).intersection(bounds)
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        let width = Int(pixelRect.width), height = Int(pixelRect.height)
        let sourceSpace = cgImage.colorSpace
        let space = (sourceSpace?.model == .rgb ? sourceSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .none
        if let polygon {
            // Clip to the outline. Bitmap origin is bottom-left; polygon points are top-left based.
            let mapped = polygon.map {
                CGPoint(x: $0.x * scale - pixelRect.minX, y: pixelRect.maxY - $0.y * scale)
            }
            context.addLines(between: mapped)
            context.closePath()
            context.clip()
        }
        // CGContext origin is bottom-left; pixelRect origin is top-left.
        context.draw(cgImage, in: CGRect(
            x: -pixelRect.minX,
            y: -(bounds.height - pixelRect.maxY),
            width: bounds.width,
            height: bounds.height
        ))
        guard let result = context.makeImage() else { return nil }
        return CapturedImage(cgImage: result, scale: scale)
    }
}
