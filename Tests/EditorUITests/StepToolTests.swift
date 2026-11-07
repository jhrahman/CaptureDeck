import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

@MainActor
struct StepToolTests {
    private func makeDocument() -> EditorDocument {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorDocument(original: CapturedImage(cgImage: ctx.makeImage()!, scale: 1), title: "t")
    }

    private func place(_ tool: StepTool, _ doc: EditorDocument, at p: CGPoint) {
        let context = ToolContext(document: doc, zoom: 1, style: tool.descriptor.defaultStyle)
        tool.mouseDown(at: p, context: context)
        tool.mouseUp(at: p, context: context)
    }

    private func labels(_ doc: EditorDocument) -> [String] { doc.annotations.compactMap { ($0.shape as? StepShape)?.label } }

    @Test func numbersCountUpAsYouClick() {
        let doc = makeDocument(), tool = StepTool(EditorToolRegistry.step, letters: false)
        for x in [50, 100, 150] { place(tool, doc, at: CGPoint(x: x, y: 50)) }
        #expect(labels(doc) == ["1", "2", "3"])
    }

    @Test func deletingTheLastStepFreesItsNumber() {
        let doc = makeDocument(), tool = StepTool(EditorToolRegistry.step, letters: false)
        for x in [50, 100, 150] { place(tool, doc, at: CGPoint(x: x, y: 50)) }
        doc.deleteSelectedAnnotations()                        // the newest (3) is selected
        place(tool, doc, at: CGPoint(x: 200, y: 50))
        #expect(labels(doc) == ["1", "2", "3"])
    }

    @Test func lettersAndNumbersCountSeparately() {
        let doc = makeDocument()
        let numbers = StepTool(EditorToolRegistry.step, letters: false), letters = StepTool(EditorToolRegistry.stepLetter, letters: true)
        place(numbers, doc, at: CGPoint(x: 50, y: 50)); place(letters, doc, at: CGPoint(x: 100, y: 50))
        place(numbers, doc, at: CGPoint(x: 150, y: 50)); place(letters, doc, at: CGPoint(x: 200, y: 50))
        #expect(labels(doc) == ["1", "A", "2", "B"])
    }

    @Test func stepSizeFollowsTheSizeSetting() {
        let doc = makeDocument(), tool = StepTool(EditorToolRegistry.step, letters: false)
        var style = tool.descriptor.defaultStyle; style.fontSize = 50
        let context = ToolContext(document: doc, zoom: 1, style: style)
        tool.mouseDown(at: CGPoint(x: 100, y: 100), context: context)
        tool.mouseUp(at: CGPoint(x: 100, y: 100), context: context)
        #expect((doc.annotations[0].shape as? StepShape)?.radius == 45)
        #expect(doc.annotations[0].style.fillColor == tool.descriptor.defaultStyle.fillColor)
    }

    @Test func everyDrawingToolHasSettingsForEachOfItsProperties() {
        // Guards the "every tool is configurable" rule: a tool property with no stored default would be hard-coded.
        for tool in EditorToolRegistry.descriptors where tool.kind == .draw {
            #expect(!tool.styleProperties.isEmpty, "\(tool.title) has no editable properties")
            let ids = tool.styleProperties.map { ToolStyleSetting.id(tool, $0) }
            #expect(Set(ids).count == ids.count)
        }
    }
}
