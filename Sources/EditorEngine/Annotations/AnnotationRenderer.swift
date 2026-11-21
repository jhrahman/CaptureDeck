import CoreGraphics
import CoreModels

/// Draws annotations, in order, onto a bitmap or into a view's context.
public enum AnnotationRenderer {
    /// Draws into a context whose coordinates are already image pixels with the origin at the top-left
    /// (a flipped view context, or one set up by `render`).
    /// `backdrop` is the picture under the annotations; effects like blur read from it.
    public static func draw(_ annotations: [Annotation], in context: CGContext, backdrop: CGImage? = nil) {
        func drawOne(_ annotation: Annotation) {
            if let effect = annotation.shape as? any BackdropAnnotationShape {
                if let backdrop { effect.draw(in: context, style: annotation.style, backdrop: backdrop) }
            } else {
                annotation.shape.draw(in: context, style: annotation.style)
            }
        }
        for annotation in StepNumbering.resequenced(annotations) {
            context.saveGState()
            if annotation.style.opacity < 1 {
                context.setAlpha(CGFloat(annotation.style.opacity))
                context.beginTransparencyLayer(auxiliaryInfo: nil)     // stroke and fill fade together
                drawOne(annotation)
                context.endTransparencyLayer()
            } else {
                drawOne(annotation)
            }
            context.restoreGState()
        }
    }

    /// The picture with the annotations burned in. Returns the picture itself if there are none.
    public static func render(_ annotations: [Annotation], onto image: CGImage) -> CGImage? {
        guard !annotations.isEmpty else { return image }
        let w = image.width, h = image.height
        let source = image.colorSpace
        let space = (source?.model == .rgb ? source : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.translateBy(x: 0, y: CGFloat(h))        // from here on: top-left origin, y down
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, backdrop: image)
        return context.makeImage()
    }
}
