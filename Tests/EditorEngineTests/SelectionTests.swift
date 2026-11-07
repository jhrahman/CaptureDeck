import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import EditorEngine

private let bounds = CGRect(x: 0, y: 0, width: 100, height: 60)

struct RectSelectionEditingTests {
    @Test func rectFromTwoPointsAnyDirectionSnapsToPixelsAndClamps() {
        #expect(RectSelectionEditing.rect(from: CGPoint(x: 10.4, y: 5.2), to: CGPoint(x: 30.6, y: 25.1), within: bounds)
                == CGRect(x: 10, y: 5, width: 21, height: 21))
        #expect(RectSelectionEditing.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 20, y: 10), within: bounds)
                == CGRect(x: 20, y: 10, width: 30, height: 40))
        #expect(RectSelectionEditing.rect(from: CGPoint(x: 90, y: 50), to: CGPoint(x: 500, y: 500), within: bounds)
                == CGRect(x: 90, y: 50, width: 10, height: 10))
        #expect(RectSelectionEditing.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10), within: bounds) == nil)
    }

    @Test func hitTestFindsCornersEdgesAndInside() {
        let r = CGRect(x: 20, y: 10, width: 40, height: 30)
        #expect(RectSelectionEditing.hitTest(rect: r, point: CGPoint(x: 20, y: 10), tolerance: 3) == .topLeft)
        #expect(RectSelectionEditing.hitTest(rect: r, point: CGPoint(x: 60, y: 40), tolerance: 3) == .bottomRight)
        #expect(RectSelectionEditing.hitTest(rect: r, point: CGPoint(x: 40, y: 11), tolerance: 3) == .top)
        #expect(RectSelectionEditing.hitTest(rect: r, point: CGPoint(x: 59, y: 25), tolerance: 3) == .right)
        #expect(RectSelectionEditing.hitTest(rect: r, point: CGPoint(x: 40, y: 25), tolerance: 3) == .move)
        #expect(RectSelectionEditing.hitTest(rect: r, point: CGPoint(x: 90, y: 55), tolerance: 3) == nil)
    }

    @Test func movingKeepsSizeAndStaysInsideTheImage() {
        let r = CGRect(x: 20, y: 10, width: 40, height: 30)
        #expect(RectSelectionEditing.dragged(r, handle: .move, by: CGSize(width: 5, height: -3), within: bounds)
                == CGRect(x: 25, y: 7, width: 40, height: 30))
        #expect(RectSelectionEditing.dragged(r, handle: .move, by: CGSize(width: 500, height: 500), within: bounds)
                == CGRect(x: 60, y: 30, width: 40, height: 30))
        #expect(RectSelectionEditing.dragged(r, handle: .move, by: CGSize(width: -500, height: -500), within: bounds)
                == CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    @Test func resizingMovesOnlyTheGrabbedEdges() {
        let r = CGRect(x: 20, y: 10, width: 40, height: 30)
        #expect(RectSelectionEditing.dragged(r, handle: .right, by: CGSize(width: 10, height: 99), within: bounds)
                == CGRect(x: 20, y: 10, width: 50, height: 30))
        #expect(RectSelectionEditing.dragged(r, handle: .topLeft, by: CGSize(width: -5, height: -4), within: bounds)
                == CGRect(x: 15, y: 6, width: 45, height: 34))
        #expect(RectSelectionEditing.dragged(r, handle: .bottom, by: CGSize(width: 0, height: 500), within: bounds)
                == CGRect(x: 20, y: 10, width: 40, height: 50))
    }

    @Test func draggingAnEdgePastTheOppositeEdgeFlips() {
        let r = CGRect(x: 20, y: 10, width: 40, height: 30)
        #expect(RectSelectionEditing.dragged(r, handle: .left, by: CGSize(width: 60, height: 0), within: bounds)
                == CGRect(x: 60, y: 10, width: 20, height: 30))
    }

    @Test func arrowKeysMoveAndShiftArrowsResize() {
        let r = CGRect(x: 20, y: 10, width: 40, height: 30)
        #expect(RectSelectionEditing.nudged(r, dx: 1, dy: 0, resize: false, within: bounds) == CGRect(x: 21, y: 10, width: 40, height: 30))
        #expect(RectSelectionEditing.nudged(r, dx: 5, dy: -5, resize: true, within: bounds) == CGRect(x: 20, y: 10, width: 45, height: 25))
        #expect(RectSelectionEditing.nudged(r, dx: -500, dy: 0, resize: true, within: bounds).width == 1)
    }
}

struct FreehandPathTests {
    @Test func skipsJitterClampsAndRejectsTinyShapes() {
        var path = FreehandPath(start: CGPoint(x: 10, y: 10), within: bounds)
        path.append(CGPoint(x: 10.3, y: 10.2))     // under 1 px away
        path.append(CGPoint(x: 40, y: 10))
        path.append(CGPoint(x: 500, y: 500))       // clamped to the corner
        #expect(path.points == [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 100, y: 60)])
        #expect(path.finished()?.count == 3)

        var line = FreehandPath(start: CGPoint(x: 5, y: 5), within: bounds)
        line.append(CGPoint(x: 30, y: 5)); line.append(CGPoint(x: 60, y: 5))
        #expect(line.finished() == nil)            // a straight line selects nothing
        #expect(FreehandPath(start: .zero, within: bounds).finished() == nil)
    }
}

/// 8x4 image, scale 1: left half red, right half blue.
private func halves() -> CapturedImage {
    let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
    return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
}

@MainActor
struct DocumentSelectionTests {
    @Test func selectionIsClampedAndEmptyOnesClear() {
        let doc = EditorDocument(original: halves(), title: "t")
        doc.setSelection(.rect(CGRect(x: 6, y: 1, width: 100, height: 100)))
        #expect(doc.selection == .rect(CGRect(x: 6, y: 1, width: 2, height: 3)))
        doc.setSelection(.rect(CGRect(x: 50, y: 50, width: 5, height: 5)))
        #expect(doc.selection == nil)
        doc.selectAll()
        #expect(doc.selection == .rect(CGRect(x: 0, y: 0, width: 8, height: 4)))
        doc.clearSelection()
        #expect(doc.selection == nil)
    }

    @Test func selectionImageCropsExactPixelsAndKeepsScale() throws {
        let doc = EditorDocument(original: halves(), title: "t")
        doc.setSelection(.rect(CGRect(x: 3, y: 0, width: 2, height: 4)))     // straddles red | blue
        let image = try #require(doc.selectionImage())
        #expect(image.pixelSize == CGSize(width: 2, height: 4) && image.scale == 2)
    }

    @Test func freehandSelectionIsTransparentOutsideTheOutline() throws {
        let doc = EditorDocument(original: halves(), title: "t")
        doc.setSelection(.freehand([CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 0, y: 4)]))   // top-left triangle
        let image = try #require(doc.selectionImage())
        #expect(image.pixelSize == CGSize(width: 8, height: 4))
        var px = [UInt8](repeating: 0, count: 8 * 4 * 4)
        let ctx = CGContext(data: &px, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 4))
        #expect(px[(0 * 8 + 1) * 4 + 3] == 255)        // top-left area kept
        #expect(px[(3 * 8 + 7) * 4 + 3] == 0)          // bottom-right corner cleared
    }

    @Test func cropToSelectionIsUndoableAndClearsTheSelection() {
        let doc = EditorDocument(original: halves(), title: "t")
        doc.setSelection(.rect(CGRect(x: 4, y: 0, width: 4, height: 4)))
        #expect(doc.cropToSelection())
        #expect(doc.workingImage.pixelSize == CGSize(width: 4, height: 4))
        #expect(doc.selection == nil && doc.undoName == "Crop")
        doc.undo()
        #expect(doc.workingImage.pixelSize == CGSize(width: 8, height: 4))
        #expect(!doc.cropToSelection())                 // nothing selected
    }

    @Test func editingThePictureClearsTheSelection() {
        let doc = EditorDocument(original: halves(), title: "t")
        doc.selectAll()
        doc.apply(.flipHorizontal)
        #expect(doc.selection == nil)
        doc.selectAll(); doc.undo()
        #expect(doc.selection == nil)
    }

    @Test func selectionDoesNotAffectDirtyState() {
        let doc = EditorDocument(original: halves(), title: "t")
        doc.selectAll()
        #expect(!doc.isDirty && !doc.canUndo)
    }
}
