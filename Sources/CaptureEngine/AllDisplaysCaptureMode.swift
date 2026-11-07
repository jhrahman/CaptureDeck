import CoreGraphics
import CoreModels

/// Puts the pictures of several displays together into one image, laid out like the displays are on the desk.
public enum DisplayComposer {
    public struct Piece: Sendable {
        /// Where the display sits, in points (origin top-left of the main display).
        public let bounds: CGRect
        public let image: CapturedImage
        public init(bounds: CGRect, image: CapturedImage) {
            self.bounds = bounds
            self.image = image
        }
    }

    /// One image holding every display. It is sharp on the sharpest display (the highest scale); gaps between
    /// displays that do not touch are transparent. Returns nil if there is nothing to compose.
    public static func compose(_ pieces: [Piece]) -> CapturedImage? {
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return first.image }

        let union = pieces.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let scale = pieces.map(\.image.scale).max() ?? 1
        let width = Int((union.width * scale).rounded()), height = Int((union.height * scale).rounded())
        guard width >= 1, height >= 1, width <= 60_000, height <= 60_000 else { return nil }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        for piece in pieces {
            // The bitmap's origin is bottom-left; display positions are measured from the top-left.
            let x = (piece.bounds.minX - union.minX) * scale
            let top = (piece.bounds.minY - union.minY) * scale
            let w = piece.bounds.width * scale, h = piece.bounds.height * scale
            context.draw(piece.image.cgImage, in: CGRect(x: x, y: CGFloat(height) - top - h, width: w, height: h))
        }
        guard let result = context.makeImage() else { return nil }
        return CapturedImage(cgImage: result, scale: scale)
    }
}

/// Captures every connected display at once into a single picture.
public struct AllDisplaysCaptureMode: CaptureMode {
    public let id = "allDisplays"
    public let title = "Capture All Displays"
    public let defaultShortcut: KeyShortcut? = .digit(9, [.control, .shift])

    private let displaysProvider: @Sendable () async -> [DisplayInfo]

    public init(displaysProvider: @escaping @Sendable () async -> [DisplayInfo] = DisplayLocator.allDisplays) {
        self.displaysProvider = displaysProvider
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        let displays = await displaysProvider()
        guard !displays.isEmpty else { throw CaptureError.noDisplayAvailable }

        // Grab every display at (nearly) the same moment.
        let pieces = try await withThrowingTaskGroup(of: DisplayComposer.Piece.self) { group in
            for display in displays {
                group.addTask {
                    let image = try await context.grabber.capture(.display(display.id), includeCursor: context.includeCursor)
                    return DisplayComposer.Piece(bounds: display.globalBounds, image: image)
                }
            }
            var result: [DisplayComposer.Piece] = []
            for try await piece in group { result.append(piece) }
            return result
        }
        guard let combined = DisplayComposer.compose(pieces) else {
            throw CaptureError.captureFailed("The displays could not be combined into one picture.")
        }
        return .image(combined)       // not repeatable as one target, so it carries no source
    }
}
