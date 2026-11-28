import AppKit

/// How big the floating controls are.
public enum ControlsSize: String, CaseIterable, Sendable {
    /// Time, Pause and Stop.
    case mini
    /// Every control as an icon.
    case compact
    /// Every control, with names.
    case regular

    public var title: String {
        switch self {
        case .mini: "Mini – time, pause and stop"
        case .compact: "Compact – all controls as icons"
        case .regular: "Large – with button names"
        }
    }
}

/// Where the floating controls sit.
public enum ControlsPosition: String, CaseIterable, Sendable {
    case bottomLeft, bottomCenter, bottomRight, topLeft, topCenter, topRight, custom

    public var title: String {
        switch self {
        case .bottomLeft: "Bottom left, beside the Dock"
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right, beside the Dock"
        case .topLeft: "Top left"
        case .topCenter: "Top center"
        case .topRight: "Top right"
        case .custom: "Where I last dragged them"
        }
    }

    /// The panel's lower-left corner, in Cocoa screen coordinates.
    ///
    /// `dock` is the Dock's frame if it is known. In the two bottom corners the controls sit in the Dock's own row when
    /// there is room beside it, and otherwise just above it.
    public func origin(for size: NSSize, screen: NSRect, visible: NSRect, dock: NSRect?, custom: NSPoint? = nil, margin: CGFloat = 10) -> NSPoint {
        let left = visible.minX + margin, right = visible.maxX - size.width - margin
        let center = visible.midX - size.width / 2
        let bottom = visible.minY + margin, top = visible.maxY - size.height - margin

        // The Dock along the bottom of this screen, if there is one.
        let row = dock.flatMap { $0.width > $0.height && $0.intersects(screen) && $0.midY < screen.midY ? $0 : nil }
        func besideDock(x: CGFloat, gap: CGFloat) -> NSPoint? {
            guard let row, gap >= size.width + 2 * 6 else { return nil }
            return NSPoint(x: x, y: max(screen.minY + 4, row.midY - size.height / 2))
        }

        switch self {
        case .bottomLeft:
            return besideDock(x: screen.minX + 6, gap: (row?.minX ?? 0) - screen.minX) ?? NSPoint(x: left, y: bottom)
        case .bottomRight:
            return besideDock(x: screen.maxX - size.width - 6, gap: screen.maxX - (row?.maxX ?? 0)) ?? NSPoint(x: right, y: bottom)
        case .bottomCenter: return NSPoint(x: center, y: bottom)
        case .topLeft: return NSPoint(x: left, y: top)
        case .topCenter: return NSPoint(x: center, y: top)
        case .topRight: return NSPoint(x: right, y: top)
        case .custom:
            guard let custom else { return ControlsPosition.bottomLeft.origin(for: size, screen: screen, visible: visible, dock: dock, margin: margin) }
            // Kept on screen even if the display it was on has changed.
            return NSPoint(x: min(max(custom.x, screen.minX), screen.maxX - size.width), y: min(max(custom.y, screen.minY), screen.maxY - size.height))
        }
    }
}

public struct ControlsStyle: Equatable, Sendable {
    public var size: ControlsSize
    public var position: ControlsPosition
    public var opacity: Double
    public var showsFileSize: Bool
    /// Discard and Start over ask for a second click.
    public var confirmsDiscard: Bool

    public init(size: ControlsSize = .compact, position: ControlsPosition = .bottomLeft, opacity: Double = 1, showsFileSize: Bool = true,
                confirmsDiscard: Bool = true) {
        (self.size, self.position, self.opacity, self.showsFileSize) = (size, position, opacity, showsFileSize)
        self.confirmsDiscard = confirmsDiscard
    }
}
