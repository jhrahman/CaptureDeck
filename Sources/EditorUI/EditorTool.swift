import AppKit
import CoreModels
import EditorEngine
import Settings

/// What a tool needs to know about the editor while handling an event.
struct ToolContext {
    let document: EditorDocument
    /// Device pixels per image pixel (the zoom). Used to keep handles a constant size on screen.
    let zoom: CGFloat
    /// The look new shapes get from the active tool (from Settings, or the properties bar).
    let style: AnnotationStyle

    /// A distance measured in screen points, expressed in image pixels.
    func imagePixels(forScreenPoints points: CGFloat) -> CGFloat { points / max(zoom, 0.0001) * (NSScreen.main?.backingScaleFactor ?? 2) }
}

/// A tool the user can pick. Tools are added by registering them in `EditorToolRegistry`; the toolbar, the Tools menu,
/// the single-key shortcuts, the properties bar, the default-tool setting and each tool's style settings are all
/// generated from that list.
@MainActor
protocol EditorTool: AnyObject {
    var descriptor: EditorToolDescriptor { get }
    /// Shapes being drawn right now (shown until the mouse is released).
    var previewAnnotations: [Annotation] { get }
    /// Points are in image pixels, origin top-left.
    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor
    func mouseDown(at point: CGPoint, context: ToolContext)
    func mouseDragged(to point: CGPoint, context: ToolContext)
    func mouseUp(at point: CGPoint, context: ToolContext)
    /// Return true if the key was used.
    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool
    /// Called when another tool is chosen.
    func deactivate()
}

extension EditorTool {
    var previewAnnotations: [Annotation] { [] }
}

/// A look setting the properties bar can show for a tool.
public enum StyleProperty: String, Sendable, CaseIterable {
    case stroke, fill, width, opacity, dash, cornerRadius
}

public struct EditorToolDescriptor: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable { case pixelSelection, object, draw }

    public let id: String
    public let title: String
    public let symbol: String
    /// Single key that switches to this tool while the canvas has focus.
    public let key: String
    public let kind: Kind
    /// Which look settings this tool has (shown in the properties bar and in Settings).
    public let styleProperties: [StyleProperty]
    /// What new shapes look like until the user changes it.
    public let defaultStyle: AnnotationStyle

    init(id: String, title: String, symbol: String, key: String, kind: Kind = .pixelSelection,
         styleProperties: [StyleProperty] = [], defaultStyle: AnnotationStyle = .default) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.key = key
        self.kind = kind
        self.styleProperties = styleProperties
        self.defaultStyle = defaultStyle
    }
}

public enum EditorToolRegistry {
    private static let outline: [StyleProperty] = [.stroke, .fill, .width, .opacity, .dash]
    private static let marker = RGBAColor(hex: "#FFE600FF") ?? .white

    public static let pointer = EditorToolDescriptor(
        id: "pointer", title: "Select Object", symbol: "cursorarrow", key: "v", kind: .object,
        styleProperties: StyleProperty.allCases)
    public static let rectangleSelect = EditorToolDescriptor(id: "selectRect", title: "Rectangle Select", symbol: "rectangle.dashed", key: "s")
    public static let freehandSelect = EditorToolDescriptor(id: "selectFreehand", title: "Freehand Select", symbol: "lasso", key: "f")
    public static let rectangle = EditorToolDescriptor(
        id: "rectangle", title: "Rectangle", symbol: "rectangle", key: "r", kind: .draw, styleProperties: outline)
    public static let roundedRectangle = EditorToolDescriptor(
        id: "roundedRectangle", title: "Rounded Rectangle", symbol: "rectangle.roundedtop", key: "u", kind: .draw,
        styleProperties: outline + [.cornerRadius], defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, cornerRadius: 24))
    public static let ellipse = EditorToolDescriptor(
        id: "ellipse", title: "Ellipse", symbol: "circle", key: "o", kind: .draw, styleProperties: outline)
    public static let line = EditorToolDescriptor(
        id: "line", title: "Line", symbol: "line.diagonal", key: "l", kind: .draw, styleProperties: [.stroke, .width, .opacity, .dash])
    public static let arrow = EditorToolDescriptor(
        id: "arrow", title: "Arrow", symbol: "arrow.up.right", key: "a", kind: .draw, styleProperties: [.stroke, .width, .opacity, .dash],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 5))
    public static let doubleArrow = EditorToolDescriptor(
        id: "doubleArrow", title: "Double Arrow", symbol: "arrow.left.and.right", key: "d", kind: .draw,
        styleProperties: [.stroke, .width, .opacity, .dash], defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 5))
    public static let pencil = EditorToolDescriptor(
        id: "pencil", title: "Pencil", symbol: "pencil", key: "p", kind: .draw, styleProperties: [.stroke, .width, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 5))
    public static let highlighter = EditorToolDescriptor(
        id: "highlighter", title: "Highlighter", symbol: "highlighter", key: "h", kind: .draw, styleProperties: [.stroke, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: marker, lineWidth: 0, opacity: 0.6))

    /// Every tool, in toolbar order.
    public static let descriptors: [EditorToolDescriptor] = [
        pointer, rectangleSelect, freehandSelect, rectangle, roundedRectangle, ellipse, line, arrow, doubleArrow, pencil, highlighter,
    ]
    public static var defaultToolID: String { rectangleSelect.id }

    @MainActor
    static func makeTools() -> [any EditorTool] {
        [
            PointerTool(),
            SelectRectTool(),
            SelectFreehandTool(),
            ShapeDragTool(rectangle) { a, b, square in RectangleShape(rect: ShapeDragTool.rect(a, b, square: square)) },
            ShapeDragTool(roundedRectangle) { a, b, square in RectangleShape(rect: ShapeDragTool.rect(a, b, square: square)) },
            ShapeDragTool(ellipse) { a, b, circle in EllipseShape(rect: ShapeDragTool.rect(a, b, square: circle)) },
            ShapeDragTool(line) { a, b, snap in LineShape(start: a, end: ShapeDragTool.end(a, b, snap: snap)) },
            ShapeDragTool(arrow) { a, b, snap in LineShape(start: a, end: ShapeDragTool.end(a, b, snap: snap), endHead: .filled) },
            ShapeDragTool(doubleArrow) { a, b, snap in LineShape(start: a, end: ShapeDragTool.end(a, b, snap: snap), startHead: .filled, endHead: .filled) },
            PencilTool(),
            ShapeDragTool(highlighter) { a, b, square in HighlighterShape(rect: ShapeDragTool.rect(a, b, square: square)) },
        ]
    }
}

/// Where each tool's remembered look lives in Settings. Setting ids are generated from the tool list.
public enum ToolStyleSetting {
    public static func id(_ tool: EditorToolDescriptor, _ property: StyleProperty) -> String { "editor.tool.\(tool.id).\(property.rawValue)" }

    @MainActor
    static func style(for tool: EditorToolDescriptor, settings: SettingsStore?) -> AnnotationStyle {
        var style = tool.defaultStyle
        guard let settings else { return style }
        for property in tool.styleProperties {
            let key = id(tool, property)
            switch property {
            case .stroke: style.strokeColor = RGBAColor(hex: settings.string(key)) ?? style.strokeColor
            case .fill: style.fillColor = RGBAColor(hex: settings.string(key)) ?? style.fillColor
            case .width: style.lineWidth = AnnotationStyle.clampWidth(Double(settings.int(key)))
            case .opacity: style.opacity = min(max(settings.double(key), 0), 1)
            case .dash: style.dash = DashStyle(rawValue: settings.string(key)) ?? style.dash
            case .cornerRadius: style.cornerRadius = Double(settings.int(key))
            }
        }
        return style
    }

    @MainActor
    static func save(_ style: AnnotationStyle, for tool: EditorToolDescriptor, settings: SettingsStore?) {
        guard let settings, tool.kind == .draw else { return }
        for property in tool.styleProperties {
            let key = id(tool, property)
            switch property {
            case .stroke: settings.set(style.strokeColor.hex, for: key)
            case .fill: settings.set(style.fillColor.hex, for: key)
            case .width: settings.set(Int(style.lineWidth.rounded()), for: key)
            case .opacity: settings.set(style.opacity, for: key)
            case .dash: settings.set(style.dash.rawValue, for: key)
            case .cornerRadius: settings.set(Int(style.cornerRadius.rounded()), for: key)
            }
        }
    }
}
