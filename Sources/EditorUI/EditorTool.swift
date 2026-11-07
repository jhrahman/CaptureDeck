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
    /// Lets a tool ask the editor for things only the editor can do (like opening the text editor).
    var host: (any ToolHost)?
    /// 1 for a single click, 2 for a double-click.
    var clickCount = 1

    /// A distance measured in screen points, expressed in image pixels.
    func imagePixels(forScreenPoints points: CGFloat) -> CGFloat { points / max(zoom, 0.0001) * (NSScreen.main?.backingScaleFactor ?? 2) }
}

/// What the inline text editor is editing.
enum TextEditKind {
    case plain
    /// A speech bubble. `tip` is where its tail points; nil lets the editor choose a default below the box.
    case callout(oval: Bool, tip: CGPoint?)
}

@MainActor
protocol ToolHost: AnyObject {
    /// Opens the inline text editor over `rect` (image pixels). `annotationID` is set when editing existing text.
    func editText(annotationID: UUID?, rect: CGRect, text: String, style: AnnotationStyle, kind: TextEditKind)
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
    case fontName, fontSize, bold, italic, alignment
    /// Blur radius, pixel block size, or magnifier zoom.
    case strength
    /// Magnifier zoom (stored as the style's strength).
    case zoom
    /// Text color inside bubbles.
    case textColor
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
    /// Names for properties where "Color" / "Fill" would be unclear (a step's circle and number, a text's background).
    public let propertyTitles: [StyleProperty: String]
    /// Color of the tool's icon in the toolbar and menus, so tools are easy to tell apart at a glance.
    public let iconColor: RGBAColor

    init(id: String, title: String, symbol: String, key: String, kind: Kind = .pixelSelection,
         styleProperties: [StyleProperty] = [], defaultStyle: AnnotationStyle = .default, iconColor: String = "#8E9AAF",
         propertyTitles: [StyleProperty: String] = [:]) {
        self.propertyTitles = propertyTitles
        self.iconColor = RGBAColor(hex: iconColor) ?? .black
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
        styleProperties: StyleProperty.allCases, iconColor: "#5B9DFF")
    public static let rectangleSelect = EditorToolDescriptor(id: "selectRect", title: "Rectangle Select", symbol: "rectangle.dashed", key: "s", iconColor: "#30B0C7")
    public static let freehandSelect = EditorToolDescriptor(id: "selectFreehand", title: "Freehand Select", symbol: "lasso", key: "f", iconColor: "#AF7BFF")
    public static let rectangle = EditorToolDescriptor(
        id: "rectangle", title: "Rectangle", symbol: "rectangle", key: "r", kind: .draw, styleProperties: outline, iconColor: "#FF5A4F")
    public static let roundedRectangle = EditorToolDescriptor(
        id: "roundedRectangle", title: "Rounded Rectangle", symbol: "rectangle.roundedtop", key: "u", kind: .draw,
        styleProperties: outline + [.cornerRadius], defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, cornerRadius: 24), iconColor: "#FF9F0A")
    public static let ellipse = EditorToolDescriptor(
        id: "ellipse", title: "Ellipse", symbol: "circle", key: "o", kind: .draw, styleProperties: outline, iconColor: "#34C759")
    public static let line = EditorToolDescriptor(
        id: "line", title: "Line", symbol: "line.diagonal", key: "l", kind: .draw, styleProperties: [.stroke, .width, .opacity, .dash], iconColor: "#64D2FF")
    public static let arrow = EditorToolDescriptor(
        id: "arrow", title: "Arrow", symbol: "arrow.up.right", key: "a", kind: .draw, styleProperties: [.stroke, .width, .opacity, .dash],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 5), iconColor: "#FF375F")
    public static let doubleArrow = EditorToolDescriptor(
        id: "doubleArrow", title: "Double Arrow", symbol: "arrow.left.and.right", key: "d", kind: .draw,
        styleProperties: [.stroke, .width, .opacity, .dash], defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 5),
        iconColor: "#BF5AF2")
    public static let pencil = EditorToolDescriptor(
        id: "pencil", title: "Pencil", symbol: "pencil", key: "p", kind: .draw, styleProperties: [.stroke, .width, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 5), iconColor: "#D9A441")
    public static let highlighter = EditorToolDescriptor(
        id: "highlighter", title: "Highlighter", symbol: "highlighter", key: "h", kind: .draw, styleProperties: [.stroke, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: marker, lineWidth: 0, opacity: 0.6), iconColor: "#F2E94E")

    private static let white = RGBAColor.white
    public static let text = EditorToolDescriptor(
        id: "text", title: "Text", symbol: "textformat", key: "t", kind: .draw,
        styleProperties: [.stroke, .fill, .width, .fontName, .fontSize, .bold, .italic, .alignment, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 0, fontSize: 32),
        iconColor: "#0A84FF", propertyTitles: [.stroke: "Text", .fill: "Background", .width: "Border"])
    private static let bubbleProperties: [StyleProperty] = [.fill, .stroke, .width, .textColor, .fontName, .fontSize, .bold, .italic, .alignment]
    private static let bubbleStyle = AnnotationStyle(
        strokeColor: AnnotationStyle.defaultStroke, fillColor: RGBAColor(hex: "#FFF7B2FF") ?? .white, lineWidth: 3,
        cornerRadius: 20, fontSize: 28)
    private static let bubbleTitles: [StyleProperty: String] = [.fill: "Bubble", .stroke: "Border", .width: "Border width", .textColor: "Text"]
    public static let callout = EditorToolDescriptor(
        id: "callout", title: "Speech Bubble", symbol: "text.bubble", key: "c", kind: .draw,
        styleProperties: bubbleProperties + [.cornerRadius, .opacity], defaultStyle: bubbleStyle,
        iconColor: "#E879F9", propertyTitles: bubbleTitles.merging([.cornerRadius: "Corners"]) { a, _ in a })
    public static let ovalCallout = EditorToolDescriptor(
        id: "ovalCallout", title: "Oval Bubble", symbol: "bubble.left", key: "q", kind: .draw,
        styleProperties: bubbleProperties + [.opacity], defaultStyle: bubbleStyle,
        iconColor: "#818CF8", propertyTitles: bubbleTitles)
    public static let step = EditorToolDescriptor(
        id: "step", title: "Step Number", symbol: "1.circle", key: "n", kind: .draw,
        styleProperties: [.fill, .stroke, .fontSize, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: white, fillColor: AnnotationStyle.defaultStroke, lineWidth: 0, fontSize: 28),
        iconColor: "#FF453A", propertyTitles: [.fill: "Circle", .stroke: "Number", .fontSize: "Size"])
    public static let stepLetter = EditorToolDescriptor(
        id: "stepLetter", title: "Step Letter", symbol: "a.circle", key: "k", kind: .draw,
        styleProperties: [.fill, .stroke, .fontSize, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: white, fillColor: RGBAColor(hex: "#0A84FFFF") ?? .black, lineWidth: 0, fontSize: 28),
        iconColor: "#5E5CE6", propertyTitles: [.fill: "Circle", .stroke: "Letter", .fontSize: "Size"])

    public static let blur = EditorToolDescriptor(
        id: "blur", title: "Blur", symbol: "drop.fill", key: "b", kind: .draw, styleProperties: [.strength],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, strength: 12),
        iconColor: "#2DD4BF", propertyTitles: [.strength: "Blur"])
    public static let pixelate = EditorToolDescriptor(
        id: "pixelate", title: "Pixelate", symbol: "square.grid.3x3.fill", key: "x", kind: .draw, styleProperties: [.strength],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, strength: 14),
        iconColor: "#A3E635", propertyTitles: [.strength: "Block size"])

    /// The ribbon's sections, left to right. Every tool appears in exactly one.
    public static let groups: [[EditorToolDescriptor]] = [
        [pointer],
        [rectangleSelect, freehandSelect],
        [rectangle, roundedRectangle, ellipse],
        [line, arrow, doubleArrow, pencil],
        [text, callout, ovalCallout, step, stepLetter],
        [highlighter, blur, pixelate, spotlight, magnifier],
    ]

    /// Which tool draws each kind of shape, so selecting a shape can show that tool's properties and names.
    static let toolForShapeType: [String: EditorToolDescriptor] = [
        "rectangle": rectangle, "ellipse": ellipse, "line": line, "pencil": pencil, "highlighter": highlighter,
        "text": text, "callout": callout, "step": step, "blur": blur, "pixelate": pixelate, "spotlight": spotlight, "magnifier": magnifier,
    ]

    /// The properties that make sense for the selected shapes (the union, in the usual order) and their names.
    static func properties(forShapeTypes types: Set<String>) -> (properties: [StyleProperty], titles: [StyleProperty: String]) {
        let tools = types.compactMap { toolForShapeType[$0] }
        var offered = Set(tools.flatMap(\.styleProperties))
        if types.contains("rectangle") { offered.insert(.cornerRadius) }                      // rounded rectangles are rectangles
        let ordered = StyleProperty.allCases.filter { offered.contains($0) }
        // A single kind of shape keeps its tool's own names; mixed selections use the plain ones.
        let titles = tools.count == 1 && types.count == 1 ? tools[0].propertyTitles : [:]
        return (ordered, titles)
    }

    public static let spotlight = EditorToolDescriptor(
        id: "spotlight", title: "Spotlight", symbol: "viewfinder.circle", key: "g", kind: .draw,
        styleProperties: [.stroke, .opacity, .cornerRadius],
        defaultStyle: AnnotationStyle(strokeColor: .black, opacity: 0.6, cornerRadius: 0),
        iconColor: "#94A3B8", propertyTitles: [.stroke: "Dim color", .opacity: "Dimming", .cornerRadius: "Rounding"])
    public static let magnifier = EditorToolDescriptor(
        id: "magnifier", title: "Magnifier", symbol: "plus.magnifyingglass", key: "m", kind: .draw,
        styleProperties: [.stroke, .width, .zoom, .opacity],
        defaultStyle: AnnotationStyle(strokeColor: AnnotationStyle.defaultStroke, lineWidth: 4, strength: 2),
        iconColor: "#0EA5E9", propertyTitles: [.stroke: "Border"])

    /// Every tool, in ribbon order. (Derived from `groups`, so the ribbon, the Tools menu and Tab-cycling always agree.)
    public static let descriptors: [EditorToolDescriptor] = groups.flatMap { $0 }
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
            TextTool(),
            CalloutTool(callout, oval: false),
            CalloutTool(ovalCallout, oval: true),
            StepTool(step, letters: false),
            StepTool(stepLetter, letters: true),
            ShapeDragTool(highlighter) { a, b, square in HighlighterShape(rect: ShapeDragTool.rect(a, b, square: square)) },
            ShapeDragTool(blur) { a, b, _ in BlurShape(rect: ShapeDragTool.rect(a, b, square: false)) },
            ShapeDragTool(pixelate) { a, b, _ in PixelateShape(rect: ShapeDragTool.rect(a, b, square: false)) },
            ShapeDragTool(spotlight) { a, b, square in SpotlightShape(rect: ShapeDragTool.rect(a, b, square: square)) },
            ShapeDragTool(magnifier) { a, b, square in MagnifierShape(rect: ShapeDragTool.rect(a, b, square: square)) },
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
            case .fontName: style.fontName = settings.string(key)
            case .fontSize: style.fontSize = Double(settings.int(key))
            case .bold: style.bold = settings.bool(key)
            case .italic: style.italic = settings.bool(key)
            case .alignment: style.alignment = TextAlignment(rawValue: settings.string(key)) ?? style.alignment
            case .strength, .zoom: style.strength = Double(settings.int(key))
            case .textColor: style.textColor = RGBAColor(hex: settings.string(key)) ?? style.textColor
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
            case .fontName: settings.set(style.fontName, for: key)
            case .fontSize: settings.set(Int(style.fontSize.rounded()), for: key)
            case .bold: settings.set(style.bold, for: key)
            case .italic: settings.set(style.italic, for: key)
            case .alignment: settings.set(style.alignment.rawValue, for: key)
            case .strength, .zoom: settings.set(Int(style.strength.rounded()), for: key)
            case .textColor: settings.set(style.textColor.hex, for: key)
            }
        }
    }
}
