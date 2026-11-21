import CoreGraphics
import CoreModels
import Testing
@testable import EditorEngine

@MainActor
struct StepNumberingTests {
    private func step(_ n: Int, letters: Bool = false) -> Annotation {
        Annotation(shape: StepShape(center: .zero, radius: 10, number: n, letters: letters), style: .default)
    }
    private func labels(_ list: [Annotation]) -> [String] { StepNumbering.resequenced(list).compactMap { ($0.shape as? StepShape)?.label } }
    private func blankImage() -> CapturedImage {
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
    }

    @Test func deletingAStepClosesTheGap() {
        let without3 = (1...5).map { step($0) }.filter { ($0.shape as? StepShape)?.number != 3 }
        #expect(labels(without3) == ["1", "2", "3", "4"])
    }

    @Test func lettersAndNumbersAreCountedSeparately() {
        let list = [step(1), step(1, letters: true), step(2, letters: true), step(2)]
        #expect(labels(list) == ["1", "A", "B", "2"])
        let withoutLetterA = list.filter { !(($0.shape as? StepShape)?.letters == true && ($0.shape as? StepShape)?.number == 1) }
        #expect(labels(withoutLetterA) == ["1", "A", "2"])
    }

    @Test func deleteThenUndoRestoresOriginalLabels() {
        let doc = EditorDocument(original: blankImage(), title: "t")
        let all = (1...5).map { step($0) }
        for a in all { doc.addAnnotation(a) }
        #expect(doc.removeAnnotations(ids: [all[2].id]))
        #expect(labels(doc.annotations) == ["1", "2", "3", "4"])
        doc.undo()
        #expect(labels(doc.annotations) == ["1", "2", "3", "4", "5"])
    }

    @Test func orderFollowsPlacementNotStackingOrder() {
        #expect(labels([step(3), step(1), step(2)]) == ["3", "1", "2"])
    }

    @Test func otherAnnotationsAreUntouched() {
        let rect = Annotation(shape: RectangleShape(rect: CGRect(x: 0, y: 0, width: 5, height: 5)), style: .default)
        #expect(StepNumbering.resequenced([rect, step(4)]).first?.id == rect.id)
    }
}
