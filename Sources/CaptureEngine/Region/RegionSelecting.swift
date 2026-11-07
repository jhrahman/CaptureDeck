import AppKit
import CoreModels

/// One display as it looked just before the selection overlay appeared.
public struct DisplaySnapshot: Sendable {
    public let displayID: CGDirectDisplayID
    /// Position of the display in AppKit's global screen coordinates (used to place the overlay window).
    public let frame: CGRect
    /// The display's rectangle in global coordinates with the origin at the top-left of the primary
    /// display (the coordinate space of window lists and the Accessibility API).
    public let globalBounds: CGRect
    public let image: CapturedImage

    public init(displayID: CGDirectDisplayID, frame: CGRect, globalBounds: CGRect? = nil, image: CapturedImage) {
        self.displayID = displayID
        self.frame = frame
        self.globalBounds = globalBounds ?? CGRect(origin: .zero, size: frame.size)
        self.image = image
    }
}

public struct DisplayInfo: Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let frame: CGRect
    public let globalBounds: CGRect
    public init(id: CGDirectDisplayID, frame: CGRect, globalBounds: CGRect? = nil) {
        self.id = id
        self.frame = frame
        self.globalBounds = globalBounds ?? CGRect(origin: .zero, size: frame.size)
    }
}

/// How the user chooses a region.
public enum RegionSelectionKind: Sendable, Equatable {
    /// Drag out any rectangle.
    case drag
    /// A rectangle of a fixed pixel size follows the pointer; click to capture.
    /// `presets` appear in a right-click menu.
    case fixedSize(presets: [CGSize])
    /// Draw any outline; the result is its bounding box with the outside transparent.
    case freehand
}

/// Lets the user choose a region. Returns a target (not an image) so other features,
/// such as future recording, can reuse the same selection UI.
public protocol RegionSelecting: Sendable {
    /// Throws `CaptureError.cancelled` if the user backs out.
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget

    /// Hover to highlight a window or element, click to choose. Returns `.window` for a whole window
    /// or `.rect` (display points) for an element. Throws `CaptureError.cancelled` on Esc.
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget
}

/// Settings-driven behavior of the selection overlay. Read fresh each time an overlay opens,
/// so changes in Settings apply to the next capture.
public struct OverlayOptions: Sendable {
    /// How dark the area outside the selection is (0 = not dimmed).
    public var dimAlpha: CGFloat
    public var showMagnifier: Bool
    /// Magnification of the loupe (4, 8, 12...).
    public var magnifierZoom: Int
    /// Fixed-size mode: the size to start with, and where to report changes so it is remembered.
    public var lastFixedSize: CGSize?
    public var onFixedSizeChanged: (@MainActor @Sendable (CGSize) -> Void)?

    public init(dimAlpha: CGFloat = 0.4, showMagnifier: Bool = true, magnifierZoom: Int = 8,
                lastFixedSize: CGSize? = nil, onFixedSizeChanged: (@MainActor @Sendable (CGSize) -> Void)? = nil) {
        self.dimAlpha = min(max(dimAlpha, 0), 0.9)
        self.showMagnifier = showMagnifier
        self.magnifierZoom = max(2, magnifierZoom)
        self.lastFixedSize = lastFixedSize
        self.onFixedSizeChanged = onFixedSizeChanged
    }
}

public struct OverlayStyle: @unchecked Sendable {
    public var accent: NSColor
    public init(accent: NSColor = .white) { self.accent = accent }
}

public extension DisplayLocator {
    @Sendable static func allDisplays() async -> [DisplayInfo] {
        await MainActor.run {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let id = number.uint32Value
                return DisplayInfo(id: id, frame: screen.frame, globalBounds: CGDisplayBounds(id))
            }
        }
    }
}
