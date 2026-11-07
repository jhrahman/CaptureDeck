import CoreGraphics

/// An immutable captured bitmap plus its Retina scale (pixels per point).
/// `CGImage` is immutable, so sharing it across concurrency domains is safe.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Pixels per point of the source display (2.0 on Retina).
    public let scale: CGFloat

    public init(cgImage: CGImage, scale: CGFloat) {
        self.cgImage = cgImage
        self.scale = scale
    }

    public var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    public var pointSize: CGSize { CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale) }
}

/// What a capture mode produces. `.video` can be added when recording arrives.
public enum CaptureResult: Sendable {
    case image(CapturedImage)
}
