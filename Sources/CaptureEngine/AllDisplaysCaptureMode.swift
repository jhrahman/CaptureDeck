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
    /// displays that do not touch are transparent. With `labelled`, the displays are instead set on a dark glass
    /// backdrop, apart from each other, with a "Screen 1" label under each. Returns nil if there is nothing to compose.
    public static func compose(_ pieces: [Piece], labelled: Bool = false) -> CapturedImage? {
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return first.image }
        if labelled { return composeFramed(pieces) }

        let union = pieces.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let scale = pieces.map(\.image.scale).max() ?? 1
        let width = Int((union.width * scale).rounded()), height = Int((union.height * scale).rounded())
        guard width >= 1, height >= 1, width <= 60_000, height <= 60_000 else { return nil }
        guard let context = makeContext(width: width, height: height) else { return nil }

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

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.interpolationQuality = .high
        return context
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

    // MARK: Glass backdrop layout (all in points)

    static let margin: CGFloat = 36
    static let columnGap: CGFloat = 36
    /// Room between rows (and under the bottom row) for the labels.
    static let rowGap: CGFloat = 84

    /// Which column (or row) each interval falls in: intervals that overlap share one.
    private static func groupIndex(_ ranges: [ClosedRange<CGFloat>]) -> [Int] {
        let order = ranges.indices.sorted { ranges[$0].lowerBound < ranges[$1].lowerBound }
        var result = [Int](repeating: 0, count: ranges.count)
        var group = 0, reach = -CGFloat.infinity
        for (n, i) in order.enumerated() {
            if n > 0, ranges[i].lowerBound >= reach - 0.5 { group += 1; reach = ranges[i].upperBound }
            else { reach = max(reach, ranges[i].upperBound) }
            result[i] = group
        }
        return result
    }

    /// Where each display goes on the backdrop, and how big the backdrop is. The layout of the desk is kept,
    /// with a gap added between neighbouring displays.
    static func framedLayout(_ pieces: [Piece]) -> (size: CGSize, frames: [CGRect]) {
        let union = pieces.dropFirst().reduce(pieces[0].bounds) { $0.union($1.bounds) }
        let columns = groupIndex(pieces.map { $0.bounds.minX...$0.bounds.maxX })
        let rows = groupIndex(pieces.map { $0.bounds.minY...$0.bounds.maxY })
        let frames = pieces.indices.map { i -> CGRect in
            CGRect(x: margin + pieces[i].bounds.minX - union.minX + CGFloat(columns[i]) * columnGap,
                   y: margin + pieces[i].bounds.minY - union.minY + CGFloat(rows[i]) * rowGap,
                   width: pieces[i].bounds.width, height: pieces[i].bounds.height)
        }
        let full = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        return (CGSize(width: full.maxX + margin, height: full.maxY + rowGap), frames)
    }

    private static func composeFramed(_ pieces: [Piece]) -> CapturedImage? {
        let scale = pieces.map(\.image.scale).max() ?? 1
        let layout = framedLayout(pieces)
        let width = Int((layout.size.width * scale).rounded()), height = Int((layout.size.height * scale).rounded())
        guard width >= 1, height >= 1, width <= 60_000, height <= 60_000 else { return nil }
        guard let context = makeContext(width: width, height: height) else { return nil }
        let numbers = numbering(pieces)
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

        // Backdrop: graphite, a little lighter towards the top-left, like the dark glass of a macOS panel.
        let backdrop = CGGradient(colorsSpace: rgb, colors: [
            CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1), CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])

        // Image space is top-left based; the bitmap is bottom-left based.
        func flipped(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale, y: CGFloat(height) - r.maxY * scale, width: r.width * scale, height: r.height * scale)
        }
        let corner = 12 * scale

        for (i, piece) in pieces.enumerated() {
            let rect = flipped(layout.frames[i])
            // Soft shadow under the display.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: 0.55))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)); context.fillPath()
            context.restoreGState()
            // The screenshot, with macOS-style rounded corners.
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)); context.clip()
            context.draw(piece.image.cgImage, in: rect)
            context.restoreGState()
            // A hairline glass edge just outside the picture.
            let edge = rect.insetBy(dx: -0.5 * scale, dy: -0.5 * scale)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.22)); context.setLineWidth(scale)
            context.addPath(CGPath(roundedRect: edge, cornerWidth: corner + 0.5 * scale, cornerHeight: corner + 0.5 * scale, transform: nil)); context.strokePath()

            drawLabel(number: numbers[i], isMain: piece.bounds.origin == .zero, under: rect, scale: scale, in: context)
        }
        guard let result = context.makeImage() else { return nil }
        return CapturedImage(cgImage: result, scale: scale)
    }

    /// A frosted pill with a blue dot and "Screen 1", centred under a display.
    private static func drawLabel(number: Int, isMain: Bool, under display: CGRect, scale: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, 15 * scale, nil)
        let text = "Screen \(number)" + (isMain ? "  ·  Main" : "")
        let attributed = CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.92),
        ] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let textBounds = CTLineGetBoundsWithOptions(line, [])
        let dot = 8 * scale, padX = 16 * scale, gapDot = 10 * scale
        let pillW = padX * 2 + dot + gapDot + textBounds.width, pillH = 34 * scale
        let pill = CGRect(x: display.midX - pillW / 2, y: display.minY - 20 * scale - pillH, width: pillW, height: pillH)
        let path = CGPath(roundedRect: pill, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
        context.setFillColor(CGColor(gray: 1, alpha: 0.10)); context.addPath(path); context.fillPath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.20)); context.setLineWidth(scale); context.addPath(path); context.strokePath()
        context.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: pill.minX + padX, y: pill.midY - dot / 2, width: dot, height: dot))
        context.textPosition = CGPoint(x: pill.minX + padX + dot + gapDot - textBounds.minX, y: pill.midY - textBounds.height / 2 - textBounds.minY)
        CTLineDraw(line, context)
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
