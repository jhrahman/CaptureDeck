import CoreGraphics
import CoreModels

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

        let target = try await selector.selectRegion(on: snapshots)
        guard case .rect(let rect, let displayID) = target,
              let snapshot = snapshots.first(where: { $0.displayID == displayID }),
              let cropped = snapshot.image.cropped(toPointRect: rect) else {
            throw CaptureError.captureFailed("The selected region could not be captured.")
        }
        return .image(cropped)
    }
}
