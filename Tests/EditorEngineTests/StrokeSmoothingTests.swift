import CoreGraphics
import Testing
@testable import EditorEngine

struct StrokeSmoothingTests {
    @Test func simplifyingKeepsTheShapeButDropsRedundantPoints() {
        let straight = (0...200).map { CGPoint(x: CGFloat($0), y: 0.1 * sin(CGFloat($0))) }          // a line with tiny noise
        let result = StrokeSmoothing.simplified(straight, tolerance: 0.6)
        #expect(result.count == 2)
        #expect(result.first == straight.first && result.last == straight.last)

        let corner = (0...50).map { CGPoint(x: CGFloat($0), y: 0) } + (1...50).map { CGPoint(x: 50, y: CGFloat($0)) }
        let bent = StrokeSmoothing.simplified(corner, tolerance: 0.6)
        #expect(bent.count == 3)                                                                       // start, the corner, the end
        #expect(bent[1] == CGPoint(x: 50, y: 0))
    }

    @Test func theStabilizerIgnoresJitterButFollowsRealMovement() {
        var steady = StrokeSmoothing.Stabilizer(start: .zero)
        let jittered = steady.filter(CGPoint(x: 1, y: 1), softness: 4)
        #expect(hypot(jittered.x, jittered.y) < 0.8)                       // a 1.4 px twitch moves the line well under that

        var quick = StrokeSmoothing.Stabilizer(start: .zero)
        let followed = quick.filter(CGPoint(x: 200, y: 0), softness: 4)
        #expect(followed.x > 190)                                          // a fast move is followed almost exactly
    }

    @Test func aStrokeWithAHundredPointsDrawsAsOneSmoothLine() throws {
        let points = (0..<100).map { CGPoint(x: 20 + CGFloat($0) * 2, y: 50 + 20 * sin(CGFloat($0) / 8)) }
        let ctx = CGContext(data: nil, width: 260, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        PencilShape(points: points).draw(in: ctx, style: AnnotationStyle(strokeColor: .black, lineWidth: 4))
        let image = try #require(ctx.makeImage())
        #expect(image.width == 260)
        #expect(PencilShape(points: points).geometryBounds.width > 190)
    }
}
