import CoreGraphics
import CoreModels
import CoreText

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
    public static func compose(_ pieces: [Piece], labelled: Bool = false) -> CapturedImage? {
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return first.image }

        let union = pieces.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let scale = pieces.map(\.image.scale).max() ?? 1
        let width = Int((union.width * scale).rounded()), picturesHeight = Int((union.height * scale).rounded())
        // The labels go in their own strip under the pictures, so no screenshot pixel is covered.
        let strip = labelled ? Int((captionHeight * scale).rounded()) : 0
        let height = picturesHeight + strip
        guard width >= 1, picturesHeight >= 1, width <= 60_000, height <= 60_000 else { return nil }

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
            context.draw(piece.image.cgImage, in: CGRect(x: x, y: CGFloat(picturesHeight) - top - h + CGFloat(strip), width: w, height: h))
        }
        if labelled { drawCaptions(pieces, union: union, scale: scale, width: width, strip: strip, in: context) }
        guard let result = context.makeImage() else { return nil }
        return CapturedImage(cgImage: result, scale: scale)
    }

    /// Display numbers, left to right (then top to bottom), so "Screen 1" is the left-most one.
    static func numbering(_ pieces: [Piece]) -> [Int] {
        let order = pieces.indices.sorted {
            let a = pieces[$0].bounds, b = pieces[$1].bounds
            return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
        }
        var numbers = [Int](repeating: 0, count: pieces.count)
        for (rank, index) in order.enumerated() { numbers[index] = rank + 1 }
        return numbers
    }

    /// Height (points) of the caption strip added under the pictures when displays are labelled.
    static let captionHeight: CGFloat = 52

    /// The strip under the pictures: a slim accent bar under each display (so you can see which label belongs to which),
    /// and a "Screen 1" label centred beneath it.
    private static func drawCaptions(_ pieces: [Piece], union: CGRect, scale: CGFloat, width: Int, strip: Int, in context: CGContext) {
        let numbers = numbering(pieces)
        let stripRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(strip))
        context.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1))
        context.fill(stripRect)

        let order = pieces.indices.sorted { numbers[$0] < numbers[$1] }
        var nextFreeX: CGFloat = 0
        for index in order {
            let piece = pieces[index]
            let x = (piece.bounds.minX - union.minX) * scale
            let w = piece.bounds.width * scale

            // Accent bar along the top edge of the strip, exactly as wide as the display above it.
            let gap = 3 * scale
            context.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
            context.fill(CGRect(x: x + gap, y: CGFloat(strip) - 4 * scale, width: max(w - 2 * gap, 1), height: 4 * scale))

            let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, 15 * scale, nil)
            let isMain = piece.bounds.origin == .zero
            let text = "Screen \(numbers[index])" + (isMain ? "  ·  Main" : "")
            let attributed = CFAttributedStringCreate(nil, text as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.95),
            ] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            var left = x + (w - bounds.width) / 2
            left = max(left, nextFreeX)                         // keep labels of stacked displays apart
            nextFreeX = left + bounds.width + 24 * scale
            let baseline = (CGFloat(strip) - 4 * scale - bounds.height) / 2 - bounds.minY
            context.textPosition = CGPoint(x: left - bounds.minX, y: baseline)
            CTLineDraw(line, context)
        }
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
        guard let combined = DisplayComposer.compose(pieces, labelled: context.labelDisplays) else {
            throw CaptureError.captureFailed("The displays could not be combined into one picture.")
        }
        return .image(combined)       // not repeatable as one target, so it carries no source
    }
}
