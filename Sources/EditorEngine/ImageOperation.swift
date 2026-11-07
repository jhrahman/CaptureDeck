import CoreGraphics

/// A change to the picture itself (as opposed to annotations drawn on top of it).
/// The document keeps the original image untouched and a list of these; the working image is derived.
public enum ImageOperation: Sendable, Equatable, Codable {
    /// Keep this rectangle (pixels, origin top-left).
    case crop(CGRect)
    case resize(width: Int, height: Int)
    /// Clockwise quarter turns (1 = 90°, 2 = 180°, 3 = 270°).
    case rotate(quarterTurns: Int)
    case flipHorizontal
    case flipVertical

    public var name: String {
        switch self {
        case .crop: "Crop"
        case .resize: "Resize"
        case .rotate(let q): q % 4 == 3 ? "Rotate Left" : (q % 4 == 1 ? "Rotate Right" : "Rotate 180°")
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }

    /// Returns the transformed image, or nil if the operation does not make sense for this image
    /// (empty crop, zero size, absurdly large result).
    public func apply(to image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        switch self {
        case .crop(let rect):
            let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
            guard let ctx = Self.context(width: Int(r.width), height: Int(r.height), like: image) else { return nil }
            ctx.draw(image, in: CGRect(x: -r.minX, y: -(CGFloat(h) - r.maxY), width: CGFloat(w), height: CGFloat(h)))
            return ctx.makeImage()

        case .resize(let nw, let nh):
            guard nw >= 1, nh >= 1, nw <= 30_000, nh <= 30_000 else { return nil }
            guard let ctx = Self.context(width: nw, height: nh, like: image) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            return ctx.makeImage()

        case .rotate(let turns):
            let q = ((turns % 4) + 4) % 4
            if q == 0 { return image }
            let (nw, nh) = q % 2 == 1 ? (h, w) : (w, h)
            guard let ctx = Self.context(width: nw, height: nh, like: image) else { return nil }
            ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
            ctx.rotate(by: -CGFloat(q) * .pi / 2)          // clockwise on screen = negative in CG's y-up space
            ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
            return ctx.makeImage()

        case .flipHorizontal:
            guard let ctx = Self.context(width: w, height: h, like: image) else { return nil }
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()

        case .flipVertical:
            guard let ctx = Self.context(width: w, height: h, like: image) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
    }

    /// An empty 8-bit RGBA bitmap in the source image's color space (sRGB if that is not RGB).
    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let source = image.colorSpace
        let space = (source?.model == .rgb ? source : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .none
        return ctx
    }
}
