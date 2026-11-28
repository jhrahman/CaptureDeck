import CoreModels

/// Copies text straight from the screen: drag a box, and what is inside is read (the app does the reading and the copying).
/// Nothing is saved as a picture.
public struct TextCaptureMode: CaptureMode {
    public let id = "captureText"
    public let title = "Capture Text (OCR)"
    public let defaultShortcut: KeyShortcut? = KeyShortcut(keyCode: 0x11, modifiers: [.control, .shift], keyLabel: "T")

    private let selector: any RegionSelecting
    private let displaysProvider: @Sendable () async -> [DisplayInfo]

    public init(selector: any RegionSelecting = RegionSelector(),
                displaysProvider: @escaping @Sendable () async -> [DisplayInfo] = DisplayLocator.allDisplays) {
        self.selector = selector
        self.displaysProvider = displaysProvider
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        // The mouse pointer would sit on top of the very words being read.
        let clean = CaptureContext(grabber: context.grabber, includeCursor: false, labelDisplays: false)
        guard case .image(let image) = try await SnapshotRegionCapture.run(clean, kind: .drag, selector: selector, displaysProvider: displaysProvider) else {
            throw CaptureError.cancelled
        }
        return .textSource(image)
    }
}
