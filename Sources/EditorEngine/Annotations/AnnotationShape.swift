import CoreGraphics
import Foundation

/// The geometry and drawing of one kind of annotation (rectangle, arrow, text, ...).
///
/// To add a new kind: write a type that conforms to this protocol and add it to
/// `AnnotationRegistry.decoders`. Nothing else in the engine needs to change: drawing, hit-testing,
/// moving, resizing, undo and saving all work through this protocol.
///
/// Coordinates are image pixels with the origin at the top-left (y grows downward).
public protocol AnnotationShape: Sendable {
    /// Stable name stored in saved files. Never change one.
    static var typeID: String { get }
    var shapeType: String { get }

    /// Tight bounds of the geometry (without the stroke width). Used for selection handles.
    var geometryBounds: CGRect { get }

    /// Draws with `style`. The renderer has already set up the coordinate system and whole-object opacity.
    func draw(in context: CGContext, style: AnnotationStyle)

    /// `tolerance` is extra reach in image pixels (so thin lines are easy to click).
    func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool

    /// The shape after a move / scale / rotate of the picture or of the object itself.
    func applying(_ transform: CGAffineTransform) -> any AnnotationShape

    /// JSON for saving.
    func payload() throws -> Data

    /// Extra drag handles beyond the eight around the bounds (a speech bubble's tail tip). Image pixels.
    var extraHandles: [CGPoint] { get }
    /// The shape after dragging extra handle `index` to `point`.
    func movingHandle(_ index: Int, to point: CGPoint) -> any AnnotationShape
}

public extension AnnotationShape {
    var shapeType: String { Self.typeID }
    var extraHandles: [CGPoint] { [] }
    func movingHandle(_ index: Int, to point: CGPoint) -> any AnnotationShape { self }
}

/// A shape that works on the picture underneath it (blur, pixelate, spotlight, magnifier), so it needs to see it.
/// `backdrop` is the original picture, in the same pixel coordinates as the shape.
public protocol BackdropAnnotationShape: AnnotationShape {
    func draw(in context: CGContext, style: AnnotationStyle, backdrop: CGImage)
}

public extension BackdropAnnotationShape {
    /// Without a backdrop there is nothing to work on.
    func draw(in context: CGContext, style: AnnotationStyle) {}
}

/// An annotation on the picture: a shape plus how it looks.
public struct Annotation: Identifiable, Sendable {
    public let id: UUID
    public var shape: any AnnotationShape
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), shape: any AnnotationShape, style: AnnotationStyle) {
        self.id = id
        self.shape = shape
        self.style = style
    }

    public var bounds: CGRect { shape.geometryBounds }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        shape.hitTest(point, style: style, tolerance: tolerance)
    }

    public func applying(_ transform: CGAffineTransform) -> Annotation {
        Annotation(id: id, shape: shape.applying(transform), style: style)
    }

    /// True if both look exactly the same (same kind of shape, same geometry, same style).
    func looksSame(as other: Annotation) -> Bool {
        style == other.style && shape.shapeType == other.shape.shapeType && (try? shape.payload()) == (try? other.shape.payload())
    }

    /// Same object, new copy (a fresh id), moved by `offset`.
    public func duplicated(offset: CGSize) -> Annotation {
        Annotation(shape: shape.applying(CGAffineTransform(translationX: offset.width, y: offset.height)), style: style)
    }
}

/// How an annotation is stored in a saved file.
public struct AnnotationRecord: Codable, Sendable {
    public let id: UUID
    public let type: String
    public let style: AnnotationStyle
    public let payload: Data
}

public extension Annotation {
    func record() throws -> AnnotationRecord {
        AnnotationRecord(id: id, type: shape.shapeType, style: style, payload: try shape.payload())
    }

    init(record: AnnotationRecord) {
        self.init(id: record.id, shape: AnnotationRegistry.shape(typeID: record.type, payload: record.payload), style: record.style)
    }
}

/// Maps saved type names back to shapes.
public enum AnnotationRegistry {
    typealias Decoder = @Sendable (Data) throws -> any AnnotationShape

    /// Every known shape type. Add new shapes here.
    static let decoders: [String: Decoder] = [
        RectangleShape.typeID: { try JSONDecoder().decode(RectangleShape.self, from: $0) },
        EllipseShape.typeID: { try JSONDecoder().decode(EllipseShape.self, from: $0) },
        LineShape.typeID: { try JSONDecoder().decode(LineShape.self, from: $0) },
        PencilShape.typeID: { try JSONDecoder().decode(PencilShape.self, from: $0) },
        HighlighterShape.typeID: { try JSONDecoder().decode(HighlighterShape.self, from: $0) },
        BlurShape.typeID: { try JSONDecoder().decode(BlurShape.self, from: $0) },
        PixelateShape.typeID: { try JSONDecoder().decode(PixelateShape.self, from: $0) },
        FillShape.typeID: { try JSONDecoder().decode(FillShape.self, from: $0) },
        SpotlightShape.typeID: { try JSONDecoder().decode(SpotlightShape.self, from: $0) },
        MagnifierShape.typeID: { try JSONDecoder().decode(MagnifierShape.self, from: $0) },
        TextShape.typeID: { try JSONDecoder().decode(TextShape.self, from: $0) },
        CalloutShape.typeID: { try JSONDecoder().decode(CalloutShape.self, from: $0) },
        StepShape.typeID: { try JSONDecoder().decode(StepShape.self, from: $0) },
    ]

    /// Unknown or damaged types are kept untouched (as `UnknownShape`), so a file saved by a newer
    /// version is never destroyed by an older one.
    public static func shape(typeID: String, payload: Data) -> any AnnotationShape {
        if let decode = decoders[typeID], let shape = try? decode(payload) { return shape }
        return UnknownShape(storedType: typeID, storedPayload: payload)
    }
}

/// Placeholder for a shape type this version does not know. It is not drawn, but it is saved back unchanged.
public struct UnknownShape: AnnotationShape {
    public static let typeID = "unknown"
    public let storedType: String
    public let storedPayload: Data

    public var shapeType: String { storedType }
    public var geometryBounds: CGRect { .zero }
    public func draw(in context: CGContext, style: AnnotationStyle) {}
    public func hitTest(_ point: CGPoint, style: AnnotationStyle, tolerance: CGFloat) -> Bool { false }
    public func applying(_ transform: CGAffineTransform) -> any AnnotationShape { self }
    public func payload() throws -> Data { storedPayload }
}
