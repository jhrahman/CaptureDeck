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
        if labelled { drawMarkers(pieces, union: union, scale: scale, height: height, in: context) }
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

    /// A thin divider around every display plus a rounded badge ("Screen 1") in its top-left corner.
    private static func drawMarkers(_ pieces: [Piece], union: CGRect, scale: CGFloat, height: Int, in context: CGContext) {
        let numbers = numbering(pieces)
        for (index, piece) in pieces.enumerated() {
            let x = (piece.bounds.minX - union.minX) * scale
            let top = (piece.bounds.minY - union.minY) * scale
            let w = piece.bounds.width * scale, h = piece.bounds.height * scale
            let rect = CGRect(x: x, y: CGFloat(height) - top - h, width: w, height: h)

            // Divider: a crisp 2pt line just inside the display edge, light with a dark edge so it shows on anything.
            let line = max(2, 2 * scale)
            context.saveGState()
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            context.setLineWidth(line)
            context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.75))
            context.setLineWidth(line / 2)
            context.stroke(rect.insetBy(dx: line * 1.25, dy: line * 1.25))
            context.restoreGState()

            // Badge
            let fontSize = 15 * scale
            let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, fontSize, nil)
            let isMain = piece.bounds.origin == .zero
            let text = "Screen \(numbers[index])" + (isMain ? "  ·  Main" : "")
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]
            let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(ctLine, [])
            let padX = 12 * scale, padY = 7 * scale, margin = 16 * scale
            let badge = CGRect(x: rect.minX + margin, y: rect.maxY - margin - (bounds.height + padY * 2),
                               width: bounds.width + padX * 2, height: bounds.height + padY * 2)
            context.saveGState()
            let path = CGPath(roundedRect: badge, cornerWidth: badge.height / 2, cornerHeight: badge.height / 2, transform: nil)
            context.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 8 * scale, color: CGColor(gray: 0, alpha: 0.35))
            context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.88))
            context.addPath(path); context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.25)); context.setLineWidth(scale)
            context.addPath(path); context.strokePath()
            context.textPosition = CGPoint(x: badge.minX + padX - bounds.minX, y: badge.minY + padY - bounds.minY)
            CTLineDraw(ctLine, context)
            context.restoreGState()
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
