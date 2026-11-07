import CoreGraphics
import CoreModels

/// Shared by every mode that picks a rectangle on a frozen snapshot of the displays:
/// snapshot all displays, let the user choose, crop the snapshot.
enum SnapshotRegionCapture {
    static func run(
        _ context: CaptureContext,
        kind: RegionSelectionKind,
        selector: any RegionSelecting,
        displaysProvider: @Sendable () async -> [DisplayInfo]
    ) async throws -> CaptureResult {
        let displays = await displaysProvider()
        guard !displays.isEmpty else { throw CaptureError.noDisplayAvailable }

        // Snapshot every display (in parallel) so the overlay can freeze the screen and magnify it.
        let snapshots = try await withThrowingTaskGroup(of: DisplaySnapshot.self) { group in
            for display in displays {
                group.addTask {
                    let image = try await context.grabber.capture(.display(display.id), includeCursor: false)
                    return DisplaySnapshot(displayID: display.id, frame: display.frame, image: image)
                }
            }
            var result: [DisplaySnapshot] = []
            for try await snapshot in group { result.append(snapshot) }
            return result
        }

        let target = try await selector.selectRegion(on: snapshots, kind: kind)
        guard case .rect(let rect, let displayID) = target,
              let snapshot = snapshots.first(where: { $0.displayID == displayID }),
              let cropped = snapshot.image.cropped(toPointRect: rect) else {
            throw CaptureError.captureFailed("The selected region could not be captured.")
        }
        return .image(cropped)
    }
}

/// Drag out a rectangle on any display; the result is cropped from a snapshot taken
/// just before the overlay appeared, so it is exactly what the user saw.
public struct RegionCaptureMode: CaptureMode {
    public let id = "region"
    public let title = "Capture Region"
    public let defaultShortcut: KeyShortcut? = .digit(2, [.control, .shift])

    private let displaysProvider: @Sendable () async -> [DisplayInfo]
    private let selector: any RegionSelecting

    public init(
        selector: any RegionSelecting = RegionSelector(),
        displaysProvider: @escaping @Sendable () async -> [DisplayInfo] = DisplayLocator.allDisplays
    ) {
        self.selector = selector
        self.displaysProvider = displaysProvider
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        try await SnapshotRegionCapture.run(context, kind: .drag, selector: selector, displaysProvider: displaysProvider)
    }
}

/// A rectangle of a chosen pixel size follows the pointer; click to capture.
/// Right-click for preset sizes; Shift + arrows adjust the size one pixel at a time.
public struct FixedSizeCaptureMode: CaptureMode {
    public let id = "fixedSize"
    public let title = "Capture Fixed Size"
    public let defaultShortcut: KeyShortcut? = .digit(6, [.control, .shift])

    /// Standard sizes in pixels. A Settings screen will make this list editable.
    public static let defaultPresets: [CGSize] = [
        CGSize(width: 640, height: 480), CGSize(width: 800, height: 600), CGSize(width: 1024, height: 768),
        CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080),
    ]

    private let presets: [CGSize]
    private let displaysProvider: @Sendable () async -> [DisplayInfo]
    private let selector: any RegionSelecting

    public init(
        presets: [CGSize] = FixedSizeCaptureMode.defaultPresets,
        selector: any RegionSelecting = RegionSelector(),
        displaysProvider: @escaping @Sendable () async -> [DisplayInfo] = DisplayLocator.allDisplays
    ) {
        self.presets = presets
        self.selector = selector
        self.displaysProvider = displaysProvider
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        try await SnapshotRegionCapture.run(context, kind: .fixedSize(presets: presets), selector: selector, displaysProvider: displaysProvider)
    }
}
