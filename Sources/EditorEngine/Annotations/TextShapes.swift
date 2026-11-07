import CoreGraphics
import CoreText
import Foundation

/// The fonts offered in the font menu and in Settings (common macOS fonts).
public enum TextFonts {
    public static let common = ["Helvetica Neue", "Arial", "Georgia", "Times New Roman", "Verdana", "Trebuchet MS",
                                "Courier New", "Menlo", "Impact", "Marker Felt"]
}

/// Lays out and draws text with CoreText, so what the editor shows is exactly what is exported.
public enum TextRenderer {
    /// Space between a text box's edge and its text, in image pixels.
    public static let padding: CGFloat = 6

    static func font(for style: AnnotationStyle) -> CTFont {
        let size = CGFloat(style.fontSize)
        var font = CTFontCreateWithName(style.fontName as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.boldTrait) }
        if style.italic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = styled }
        return font
    }

    private static func attributedString(_ text: String, style: AnnotationStyle) -> CFAttributedString {
        var alignment: CTTextAlignment = .left
        switch style.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let paragraph = withUnsafePointer(to: &alignment) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font(for: style),
            kCTForegroundColorAttributeName: style.strokeColor.cgColor,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }

    /// The size the text needs when wrapped to `width` (the text area, without padding).
    public static func suggestedSize(of text: String, style: AnnotationStyle, width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(attributedString(text.isEmpty ? " " : text, style: style))
        return CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
    }

    /// Draws `text` inside `rect` (image pixels, y down). Text is clipped to the rectangle.
    public static func draw(_ text: String, in rect: CGRect, style: AnnotationStyle, verticallyCentered: Bool, in context: CGContext) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let setter = CTFramesetterCreateWithAttributedString(attributedString(text, style: style))
        let used = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let top = verticallyCentered ? max(0, (rect.height - used.height) / 2) : 0

        context.saveGState()
        context.clip(to: rect)
        // CoreText draws y-up: flip around the rectangle so the text is upright in our y-down space.
        context.translateBy(x: rect.minX, y: rect.minY + top)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -used.height)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: used.height), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        context.restoreGState()
    }
}

// MARK: - Text box

/// A box of text. The text color is the style's `strokeColor`, the background its `fillColor`,
/// and a border (if `lineWidth` > 0) is drawn in the stroke color.
public struct TextShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "text"
    public var rect: CGRect
    public var text: String

    public init(rect: CGRect, text: String) {
        self.rect = rect.standardized
        self.text = text
    }

    public var geometryBounds: CGRect { rect }

    /// The box tall enough for all the text at the given width.
    public static func fittingRect(origin: CGPoint, width: CGFloat, text: String, style: AnnotationStyle) -> CGRect {
        let size = TextRenderer.suggestedSize(of: text, style: style, width: width - 2 * TextRenderer.padding)
        return CGRect(x: origin.x, y: origin.y, width: width, height: ceil(size.height) + 2 * TextRenderer.padding)
    }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        if style.fillColor.alpha > 0 {
            context.setFillColor(style.fillColor.cgColor)
            context.fill(rect)
        }
        TextRenderer.draw(text, in: rect.insetBy(dx: TextRenderer.padding, dy: TextRenderer.padding), style: style, verticallyCentered: false, in: context)
        if style.lineWidth > 0, style.strokeColor.alpha > 0 {
            context.applyStroke(style)
            context.stroke(rect)
        }
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        let moved = rect.applying(transform)
        return TextShape(rect: CGRect(x: (moved.minX * 1000).rounded() / 1000, y: (moved.minY * 1000).rounded() / 1000,
                                      width: (moved.width * 1000).rounded() / 1000, height: (moved.height * 1000).rounded() / 1000), text: text)
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}

// MARK: - Step number / letter

/// A numbered (1, 2, 3…) or lettered (A, B, C…) circle, for "step 1, step 2" screenshots.
/// The circle is the style's `fillColor`; the number is drawn in its `strokeColor`.
public struct StepShape: AnnotationShape, Codable, Equatable {
    public static let typeID = "step"
    public var center: CGPoint
    public var radius: CGFloat
    public var number: Int
    public var letters: Bool

    public init(center: CGPoint, radius: CGFloat, number: Int, letters: Bool = false) {
        self.center = center
        self.radius = max(radius, 2)
        self.number = max(number, 1)
        self.letters = letters
    }

    public var geometryBounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }

    /// 1 → "A", 26 → "Z", 27 → "AA".
    public static func letterLabel(_ number: Int) -> String {
        var n = max(number, 1), result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(UInt8(65 + n % 26))) + result
            n /= 26
        }
        return result
    }

    public var label: String { letters ? Self.letterLabel(number) : String(number) }

    public func draw(in context: CGContext, style: AnnotationStyle) {
        let circle = geometryBounds
        let fill = style.fillColor.alpha > 0 ? style.fillColor : AnnotationStyle.defaultStroke
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: circle)
        if style.lineWidth > 0 {
            context.applyStroke(style)
            context.strokeEllipse(in: circle)
        }
        var textStyle = style
        textStyle.fontSize = Double(radius) * (label.count > 1 ? 0.95 : 1.15)
        textStyle.bold = true
        textStyle.alignment = .center
        TextRenderer.draw(label, in: circle, style: textStyle, verticallyCentered: true, in: context)
    }

    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
    }

    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape {
        let box = geometryBounds.applying(transform)
        let tidy: (CGFloat) -> CGFloat = { ($0 * 1000).rounded() / 1000 }
        return StepShape(center: CGPoint(x: tidy(box.midX), y: tidy(box.midY)), radius: tidy(min(box.width, box.height) / 2),
                         number: number, letters: letters)
    }

    public func payload() throws -> Data { try AnnotationJSON.encode(self) }
}
