import AppKit
import CoreGraphics
import Testing
@testable import EditorEngine

struct RedactionTests {
    /// A white picture with a high-contrast checker pattern (so blur and pixelation visibly change it) in the middle.
    private func checkerImage(width: Int = 300, height: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 20, to: 280, by: 4) { for y in stride(from: 40, to: 160, by: 4) where ((x / 4) + (y / 4)) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: 4, height: 4)) } }
        return ctx.makeImage()!
    }

    private func render(_ shape: RedactBrushShape, style: AnnotationStyle, over image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)          // annotations use top-left coordinates
            shape.draw(in: ctx, style: style, backdrop: image)
        }
        return pixels
    }

    private func pixel(_ data: [UInt8], _ x: Int, _ y: Int, width: Int = 300) -> Int { Int(data[(y * width + x) * 4]) }   // red channel

    @Test func theBrushOnlyChangesWhatItPaintsOver() {
        let image = checkerImage()
        let original = render(RedactBrushShape(points: []), style: .default, over: image)
        var style = AnnotationStyle(strokeColor: .black, lineWidth: 30)
        style.redaction = .blur; style.strength = 12
        let shape = RedactBrushShape(points: [CGPoint(x: 60, y: 100), CGPoint(x: 140, y: 100)])
        let painted = render(shape, style: style, over: image)
        var changedInside = 0, changedOutside = 0
        for y in 0..<200 { for x in 0..<300 where pixel(painted, x, y) != pixel(original, x, y) {
            if abs(y - 100) <= 15 && x >= 45 && x <= 155 { changedInside += 1 } else { changedOutside += 1 }
        } }
        #expect(changedInside > 500)
        #expect(changedOutside == 0)                                       // nothing outside the stroke is touched
    }

    @Test func solidCoversCompletely() {
        let image = checkerImage()
        var style = AnnotationStyle(strokeColor: RGBAColorFixtures.black, lineWidth: 40)
        style.redaction = .solid
        let painted = render(RedactBrushShape(points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)]), style: style, over: image)
        for x in stride(from: 100, through: 200, by: 7) { for y in [90, 100, 110] { #expect(pixel(painted, x, y) == 0, "(\\(x), \\(y)) should be covered") } }
    }

    @Test func pixelationReplacesDetailWithBlocks() {
        let image = checkerImage()
        var style = AnnotationStyle(strokeColor: .black, lineWidth: 60)
        style.redaction = .pixelate; style.strength = 24
        let painted = render(RedactBrushShape(points: [CGPoint(x: 150, y: 100)]), style: style, over: image)       // a single dab
        // Inside a 24 px block the colour is uniform, so neighbouring pixels agree.
        let a = pixel(painted, 150, 100), b = pixel(painted, 152, 100), c = pixel(painted, 150, 102)
        #expect(a == b && a == c)
    }

    @Test func theBrushRoundTripsThroughSavedFiles() throws {
        var style = AnnotationStyle(strokeColor: .black, lineWidth: 22)
        style.redaction = .pixelate
        let annotation = Annotation(shape: RedactBrushShape(points: [CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 40)]), style: style)
        let record = try annotation.record()
        let restored = Annotation(record: record)
        #expect((restored.shape as? RedactBrushShape)?.points == [CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 40)])
        #expect(restored.style.redaction == .pixelate)
    }

    @Test func oldFilesWithoutARedactionModeStillLoad() throws {
        let json = #"{"strokeColor":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":3}"#.data(using: .utf8)!
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: json)
        #expect(style.redaction == .blur)
    }
}

private enum RGBAColorFixtures { static let black = AnnotationStyle(strokeColor: .black).strokeColor }

struct TextDetectionTests {
    /// Renders words in a large, clear font on white.
    private func textImage(_ lines: [String]) -> CGImage {
        let size = NSSize(width: 900, height: 120 * CGFloat(lines.count) + 40)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 30, y: size.height - 110 - CGFloat(i) * 120),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    @Test func wordsAreFoundWithTheirPositions() {
        let image = textImage(["Account 48151623", "Password Secret"])
        let words = TextDetector.words(in: image)
        let texts = words.map(\.text)
        #expect(texts.contains("Account"), "found: \\(texts)")
        #expect(texts.contains { $0.contains("4815") })
        #expect(texts.contains("Secret"))
        // Positions are in image pixels from the top-left: the first line is above the second.
        let account = words.first { $0.text == "Account" }
        let secret = words.first { $0.text == "Secret" }
        if let account, let secret { #expect(account.rect.midY < secret.rect.midY) }
        for word in words { #expect(CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(word.rect.insetBy(dx: 1, dy: 1))) }
    }

    @Test func aBlankPictureHasNoText() {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(TextDetector.words(in: ctx.makeImage()!).isEmpty)
    }
}
