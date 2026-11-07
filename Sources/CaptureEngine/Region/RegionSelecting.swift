import AppKit
import CoreModels

/// One display as it looked just before the selection overlay appeared.
public struct DisplaySnapshot: Sendable {
    public let displayID: CGDirectDisplayID
    /// Position of the display in AppKit's global screen coordinates (used to place the overlay window).
    public let frame: CGRect
    public let image: CapturedImage

    public init(displayID: CGDirectDisplayID, frame: CGRect, image: CapturedImage) {
        self.displayID = displayID
        self.frame = frame
        self.image = image
    }
}

public struct DisplayInfo: Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let frame: CGRect
    public init(id: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// Lets the user choose a region. Returns a target (not an image) so other features,
/// such as fixed-size capture or future recording, can reuse the same selection UI.
public protocol RegionSelecting: Sendable {
    /// Throws `CaptureError.cancelled` if the user backs out.
    func selectRegion(on snapshots: [DisplaySnapshot]) async throws -> CaptureTarget
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
                return DisplayInfo(id: number.uint32Value, frame: screen.frame)
            }
        }
    }
}
