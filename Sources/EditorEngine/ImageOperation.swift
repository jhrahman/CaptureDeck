import CoreGraphics
import CoreModels

/// Where the existing picture sits when the canvas is resized.
public enum CanvasAnchor: String, Sendable, Codable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    /// Horizontal and vertical position as fractions (0 = left/top, 1 = right/bottom).
    public var fractions: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }
}

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
    /// Makes the canvas a new size (pixels). The picture stays where `anchor` says; new area is `fill`.
    case canvasSize(width: Int, height: Int, anchor: CanvasAnchor, fill: RGBAColor)
    /// Rotates clockwise by any angle; the canvas grows to hold the result and the corners are `fill`.
    case rotateByAngle(degrees: Double, fill: RGBAColor)

    public var name: String {
        switch self {
        case .crop: "Crop"
        case .resize: "Resize"
        case .rotate(let q): q % 4 == 3 ? "Rotate Left" : (q % 4 == 1 ? "Rotate Right" : "Rotate 180°")
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        case .canvasSize: "Canvas Size"
        case .rotateByAngle(let degrees, _): "Rotate \(Self.format(degrees))°"
        }
    }

    private static func format(_ degrees: Double) -> String {
        degrees == degrees.rounded() ? String(Int(degrees)) : String(format: "%.1f", degrees)
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

        case .canvasSize(let nw, let nh, let anchor, let fill):
            guard nw >= 1, nh >= 1, nw <= 30_000, nh <= 30_000 else { return nil }
            guard let ctx = Self.context(width: nw, height: nh, like: image) else { return nil }
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
            let f = anchor.fractions
            let left = (CGFloat(nw - w) * f.x).rounded()
            let top = (CGFloat(nh - h) * f.y).rounded()
            ctx.draw(image, in: CGRect(x: left, y: CGFloat(nh) - top - CGFloat(h), width: CGFloat(w), height: CGFloat(h)))
            return ctx.makeImage()

        case .rotateByAngle(let degrees, let fill):
            let radians = degrees * .pi / 180
            let c = abs(cos(radians)), sn = abs(sin(radians))
            // The small tolerance stops floating-point noise (2.0000000000000004) from adding a pixel at 90°.
            let nw = Int((Double(w) * c + Double(h) * sn - 1e-9).rounded(.up))
            let nh = Int((Double(w) * sn + Double(h) * c - 1e-9).rounded(.up))
            guard nw >= 1, nh >= 1, nw <= 30_000, nh <= 30_000 else { return nil }
            guard let ctx = Self.context(width: nw, height: nh, like: image) else { return nil }
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
            ctx.interpolationQuality = .high
            ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
            ctx.rotate(by: -CGFloat(radians))                 // clockwise on screen = negative in CG's y-up space
            ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
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
