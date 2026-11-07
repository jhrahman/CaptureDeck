import CoreGraphics
import CoreModels

public enum DashStyle: String, Codable, Sendable, CaseIterable {
    case solid, dashed, dotted

    func pattern(lineWidth: CGFloat) -> [CGFloat] {
        let w = max(lineWidth, 1)
        switch self {
        case .solid: return []
        case .dashed: return [3 * w, 2 * w]
        case .dotted: return [w, 1.6 * w]
        }
    }
}

public enum ArrowHeadStyle: String, Codable, Sendable, CaseIterable {
    case none, open, filled
}

/// How an annotation looks. Sizes are in image pixels.
public struct AnnotationStyle: Equatable, Sendable, Codable {
    public var strokeColor: RGBAColor
    /// Alpha 0 means "no fill".
    public var fillColor: RGBAColor
    public var lineWidth: Double
    /// Whole-object opacity, 0...1.
    public var opacity: Double
    public var dash: DashStyle
    /// Rounded corners (rectangles only).
    public var cornerRadius: Double

    public init(strokeColor: RGBAColor, fillColor: RGBAColor = .clear, lineWidth: Double = 4, opacity: Double = 1,
                dash: DashStyle = .solid, cornerRadius: Double = 0) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = Self.clampWidth(lineWidth)
        self.opacity = min(max(opacity, 0), 1)
        self.dash = dash
        self.cornerRadius = max(0, cornerRadius.isNaN ? 0 : min(cornerRadius, 1000))
    }

    public static let defaultStroke = RGBAColor(hex: "#FF3B30FF") ?? .black
    public static let `default` = AnnotationStyle(strokeColor: defaultStroke)

    public static func clampWidth(_ w: Double) -> Double { w.isNaN ? 4 : min(max(w, 0), 200) }

    // Missing fields (from older or newer files) fall back to the defaults instead of failing to load.
    private enum CodingKeys: String, CodingKey { case strokeColor, fillColor, lineWidth, opacity, dash, cornerRadius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            strokeColor: try c.decodeIfPresent(RGBAColor.self, forKey: .strokeColor) ?? Self.defaultStroke,
            fillColor: try c.decodeIfPresent(RGBAColor.self, forKey: .fillColor) ?? .clear,
            lineWidth: try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 4,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            dash: try c.decodeIfPresent(DashStyle.self, forKey: .dash) ?? .solid,
            cornerRadius: try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0)
    }
}
