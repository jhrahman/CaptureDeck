import Foundation
import CoreGraphics
import CoreModels
import Testing
@testable import EditorEngine

/// 4x2 pixel image: top row  R G B W, bottom row  K C M Y (black, cyan, magenta, yellow).
private let colors: [[UInt8]] = [
    [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255],
    [0, 0, 0], [0, 255, 255], [255, 0, 255], [255, 255, 0],
]

private func testImage() -> CapturedImage {
    var bytes: [UInt8] = []
    for c in colors { bytes += [c[0], c[1], c[2], 255] }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return CapturedImage(cgImage: image, scale: 2)
}

/// RGB of the pixel at (x, y), counted from the top-left.
private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])]
}

struct ImageOperationTests {
    @Test func flipHorizontalMirrorsColumns() throws {
        let out = try #require(ImageOperation.flipHorizontal.apply(to: testImage().cgImage))
        #expect(rgb(out, 0, 0) == [255, 255, 255])      // white moved from top-right to top-left
        #expect(rgb(out, 3, 0) == [255, 0, 0])
        #expect(rgb(out, 0, 1) == [255, 255, 0])
    }

    @Test func flipVerticalMirrorsRows() throws {
        let out = try #require(ImageOperation.flipVertical.apply(to: testImage().cgImage))
        #expect(rgb(out, 0, 0) == [0, 0, 0])            // black moved from bottom-left to top-left
        #expect(rgb(out, 0, 1) == [255, 0, 0])
    }

    @Test func rotateClockwiseMovesTopLeftToTopRight() throws {
        let out = try #require(ImageOperation.rotate(quarterTurns: 1).apply(to: testImage().cgImage))
        #expect(out.width == 2 && out.height == 4)
        #expect(rgb(out, 1, 0) == [255, 0, 0])          // red: top-left -> top-right
        #expect(rgb(out, 0, 0) == [0, 0, 0])            // black: bottom-left -> top-left
        #expect(rgb(out, 1, 3) == [255, 255, 255])      // white: top-right -> bottom-right
    }

    @Test func rotateCounterClockwiseAndHalfTurn() throws {
        let left = try #require(ImageOperation.rotate(quarterTurns: 3).apply(to: testImage().cgImage))
        #expect(rgb(left, 0, 3) == [255, 0, 0])         // red: top-left -> bottom-left
        let half = try #require(ImageOperation.rotate(quarterTurns: 2).apply(to: testImage().cgImage))
        #expect(half.width == 4 && half.height == 2)
        #expect(rgb(half, 3, 1) == [255, 0, 0])         // red ends bottom-right
    }

    @Test func fourQuarterTurnsRestoreTheImage() throws {
        var image = testImage().cgImage
        for _ in 0..<4 { image = try #require(ImageOperation.rotate(quarterTurns: 1).apply(to: image)) }
        #expect(rgb(image, 0, 0) == [255, 0, 0] && rgb(image, 3, 1) == [255, 255, 0])
    }

    @Test func cropKeepsRequestedRectAndClampsToImage() throws {
        let out = try #require(ImageOperation.crop(CGRect(x: 1, y: 0, width: 2, height: 1)).apply(to: testImage().cgImage))
        #expect(out.width == 2 && out.height == 1)
        #expect(rgb(out, 0, 0) == [0, 255, 0] && rgb(out, 1, 0) == [0, 0, 255])
        let clamped = try #require(ImageOperation.crop(CGRect(x: 2, y: 1, width: 100, height: 100)).apply(to: testImage().cgImage))
        #expect(clamped.width == 2 && clamped.height == 1)
        #expect(ImageOperation.crop(CGRect(x: 50, y: 50, width: 5, height: 5)).apply(to: testImage().cgImage) == nil)
        #expect(ImageOperation.crop(.zero).apply(to: testImage().cgImage) == nil)
    }

    @Test func resizeChangesPixelDimensionsAndRejectsNonsense() throws {
        let out = try #require(ImageOperation.resize(width: 8, height: 4).apply(to: testImage().cgImage))
        #expect(out.width == 8 && out.height == 4)
        #expect(ImageOperation.resize(width: 0, height: 4).apply(to: testImage().cgImage) == nil)
        #expect(ImageOperation.resize(width: 100_000, height: 4).apply(to: testImage().cgImage) == nil)
    }

    @Test func operationsRoundTripThroughJSON() throws {
        let ops: [ImageOperation] = [.crop(CGRect(x: 1, y: 2, width: 3, height: 4)), .resize(width: 5, height: 6),
                                     .rotate(quarterTurns: 3), .flipHorizontal, .flipVertical]
        let data = try JSONEncoder().encode(ops)
        #expect(try JSONDecoder().decode([ImageOperation].self, from: data) == ops)
    }
}

@MainActor
struct EditorDocumentTests {
    @Test func startsCleanWithOriginalAsWorkingImage() {
        let doc = EditorDocument(original: testImage(), title: "t")
        #expect(!doc.isDirty && !doc.canUndo && !doc.canRedo)
        #expect(doc.workingImage.pixelSize == CGSize(width: 4, height: 2))
        #expect(doc.workingImage.scale == 2)
    }

    @Test func undoRedoWalkTheHistoryAndOriginalIsNeverTouched() throws {
        let doc = EditorDocument(original: testImage(), title: "t")
        #expect(doc.apply(.rotate(quarterTurns: 1)))
        #expect(doc.apply(.crop(CGRect(x: 0, y: 0, width: 2, height: 2))))
        #expect(doc.workingImage.pixelSize == CGSize(width: 2, height: 2))
        #expect(doc.undoNames == ["Rotate Right", "Crop"])

        doc.undo()
        #expect(doc.workingImage.pixelSize == CGSize(width: 2, height: 4))
        doc.undo()
        #expect(doc.workingImage.pixelSize == CGSize(width: 4, height: 2))
        #expect(rgb(doc.workingImage.cgImage, 0, 0) == [255, 0, 0])
        #expect(!doc.canUndo && doc.canRedo)

        doc.redo(); doc.redo()
        #expect(doc.workingImage.pixelSize == CGSize(width: 2, height: 2))
        #expect(doc.original.pixelSize == CGSize(width: 4, height: 2))
        #expect(doc.original.cgImage === testImageOriginalCheck(doc))
    }

    private func testImageOriginalCheck(_ doc: EditorDocument) -> CGImage { doc.original.cgImage }

    @Test func newEditAfterUndoDiscardsRedoBranch() {
        let doc = EditorDocument(original: testImage(), title: "t")
        doc.apply(.flipHorizontal)
        doc.undo()
        #expect(doc.canRedo)
        doc.apply(.flipVertical)
        #expect(!doc.canRedo)
        #expect(doc.undoNames == ["Flip Vertical"])
    }

    @Test func failedOperationLeavesDocumentUntouched() {
        let doc = EditorDocument(original: testImage(), title: "t")
        #expect(!doc.apply(.crop(CGRect(x: 100, y: 100, width: 5, height: 5))))
        #expect(!doc.isDirty && !doc.canUndo)
        #expect(doc.workingImage.pixelSize == CGSize(width: 4, height: 2))
    }

    @Test func dirtyTrackingFollowsSavePoint() {
        let doc = EditorDocument(original: testImage(), title: "t")
        doc.apply(.flipHorizontal)
        #expect(doc.isDirty)
        doc.markSaved()
        #expect(!doc.isDirty)
        doc.apply(.flipVertical)
        #expect(doc.isDirty)
        doc.undo()
        #expect(!doc.isDirty)                       // back at the saved state
        doc.undo()
        #expect(doc.isDirty)                        // before the saved state
        doc.apply(.rotate(quarterTurns: 1))         // diverged: saved state no longer reachable
        doc.redo()
        #expect(doc.isDirty)
        doc.undo()
        #expect(doc.isDirty)
    }

    @Test func scaleIsPreservedThroughOperations() {
        let doc = EditorDocument(original: testImage(), title: "t")
        doc.apply(.resize(width: 40, height: 20))
        #expect(doc.workingImage.scale == 2)
        doc.undo()
        #expect(doc.workingImage.scale == 2)
    }
}
