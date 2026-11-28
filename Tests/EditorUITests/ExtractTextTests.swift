import AppKit
import CoreImage
import CoreModels
import EditorEngine
import PDFKit
import Testing
@testable import EditorUI

@MainActor
private final class TextHost: ToolHost {
    var texts: [String] = []
    func editText(annotationID: UUID?, rect: CGRect, text: String, style: AnnotationStyle, kind: TextEditKind) {}
    func pickedColor(_ color: RGBAColor) {}
    func recognizedText(_ text: String) { texts.append(text) }
}

@MainActor
struct ExtractTextTests {
    /// Two lines of ordinary text, and a "secret" on a line of its own.
    private func picture() -> CapturedImage {
        let context = CGContext(data: nil, width: 900, height: 420, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 420))
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: 0, y: 420)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (text, y) in [("Meeting notes for Tuesday", 40), ("Bring the printed agenda", 100), ("Password swordfish 98431", 260)] {
            (text as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return CapturedImage(cgImage: context.makeImage()!, scale: 1)
    }

    private func editor(_ doc: EditorDocument) -> (EditorViewController, NSPasteboard) {
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        let board = NSPasteboard.withUniqueName()
        controller.colorPasteboard = board
        return (controller, board)
    }

    private func ready(_ tool: ExtractTextTool, _ context: ToolContext) async {
        tool.prepare(context: context)
        let end = Date().addingTimeInterval(60)                       // generous: a full test run keeps the main actor busy
        while !tool.isReady, Date() < end { try? await Task.sleep(nanoseconds: 40_000_000) }
    }

    private func cover(_ doc: EditorDocument) {
        var style = EditorToolRegistry.redactBrush.defaultStyle
        style.redaction = .solid
        style.strokeColor = .black
        style.lineWidth = 64
        doc.addAnnotation(Annotation(shape: RedactBrushShape(points: [CGPoint(x: 50, y: 280), CGPoint(x: 700, y: 280)]), style: style))
    }

    @Test func theToolIsOnTheRibbonWithItsOwnKey() {
        let keys = EditorToolRegistry.descriptors.map(\.key)
        #expect(EditorToolRegistry.extractText.key == "j" && Set(keys).count == keys.count)
        #expect(EditorToolRegistry.descriptors.contains { $0.id == "extractText" })
    }

    @Test func clickingALineCopiesItAndABoxCopiesWhatIsInside() async throws {
        let doc = EditorDocument(original: picture(), title: "t")
        let tool = ExtractTextTool(), host = TextHost()
        let context = ToolContext(document: doc, zoom: 2, style: .default, host: host)
        await ready(tool, context)
        let agenda = try #require(tool.words.first { $0.text == "agenda" })
        let spot = CGPoint(x: agenda.rect.midX, y: agenda.rect.midY)
        tool.mouseDown(at: spot, context: context)
        tool.mouseUp(at: spot, context: context)
        #expect(host.texts.last == "Bring the printed agenda")

        tool.mouseDown(at: CGPoint(x: 10, y: 20), context: context)
        tool.mouseDragged(to: CGPoint(x: 890, y: 170), context: context)
        tool.mouseUp(at: CGPoint(x: 890, y: 170), context: context)
        #expect(host.texts.last == "Meeting notes for Tuesday\nBring the printed agenda", "\(host.texts.last ?? "")")

        tool.mouseDown(at: CGPoint(x: 850, y: 400), context: context)               // empty space
        tool.mouseUp(at: CGPoint(x: 850, y: 400), context: context)
        #expect(host.texts.count == 2)
        #expect(doc.annotations.isEmpty)                                             // the picture is never changed
    }

    /// The privacy rule: what has been covered up is never read, by the tool, by Copy Text or into a PDF.
    @Test func coveredTextIsNeverRead() async throws {
        let doc = EditorDocument(original: picture(), title: "t")
        let (controller, board) = editor(doc)
        defer { board.releaseGlobally() }
        let before = await controller.readText()
        #expect(before.contains("swordfish"), "the secret must be readable before it is covered: \(before)")

        cover(doc)
        let text = await controller.readText()
        #expect(text.contains("Meeting notes") && !text.lowercased().contains("swordfish") && !text.contains("98431"), "\(text)")

        let tool = ExtractTextTool()
        let context = ToolContext(document: doc, zoom: 2, style: .default)
        await ready(tool, context)
        let all = tool.allText(keepsLineBreaks: true)
        #expect(!all.lowercased().contains("swordfish") && !all.contains("98431"), "\(all)")

        let data = try #require(await controller.searchablePDF())
        let pdf = try #require(PDFDocument(data: data)?.string)
        #expect(pdf.contains("Meeting") && !pdf.lowercased().contains("swordfish") && !pdf.contains("98431"), "\(pdf)")
    }

    @Test func theToolReadsAgainAfterThePictureChanges() async {
        let doc = EditorDocument(original: picture(), title: "t")
        let tool = ExtractTextTool()
        let context = ToolContext(document: doc, zoom: 2, style: .default)
        await ready(tool, context)
        #expect(tool.allText(keepsLineBreaks: true).contains("swordfish"))
        cover(doc)
        await ready(tool, context)
        #expect(tool.hasText && !tool.allText(keepsLineBreaks: true).contains("swordfish"))
    }

    @Test func aSelectedAreaGivesOnlyItsText() async {
        let doc = EditorDocument(original: picture(), title: "t")
        let (controller, board) = editor(doc)
        defer { board.releaseGlobally() }
        doc.setSelection(.rect(CGRect(x: 0, y: 80, width: 900, height: 80)))
        #expect(await controller.readText() == "Bring the printed agenda")
        // A freehand outline: a triangle around the first line only.
        doc.setSelection(.freehand([CGPoint(x: 0, y: 0), CGPoint(x: 900, y: 0), CGPoint(x: 900, y: 90), CGPoint(x: 0, y: 90)]))
        #expect(await controller.readText() == "Meeting notes for Tuesday")
    }

    @Test func copyingNothingLeavesTheClipboardAlone() {
        let (controller, board) = editor(EditorDocument(original: picture(), title: "t"))
        defer { board.releaseGlobally() }
        controller.copyText("hello there")
        #expect(board.string(forType: .string) == "hello there")
        controller.copyText("")
        #expect(board.string(forType: .string) == "hello there")
    }

    @Test func theTextSheetAnswersEditingShortcuts() throws {
        let window = TextSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "select all of this"
        window.contentView = view
        window.makeFirstResponder(view)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(window.performKeyEquivalent(with: event))
        #expect(view.selectedRange() == NSRange(location: 0, length: 18))
    }

    @Test func theBarsRender() async throws {
        let doc = EditorDocument(original: picture(), title: "t")
        let (controller, board) = editor(doc)
        defer { board.releaseGlobally() }
        controller.selectTool(id: EditorToolRegistry.extractText.id)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try UXSnapshotTests.render(controller, width: 1100, height: 560, dark: true, name: "ocr-tool")
        controller.selectTool(id: EditorToolRegistry.rectangleSelect.id)
        doc.setSelection(.rect(CGRect(x: 30, y: 30, width: 520, height: 130)))
        try UXSnapshotTests.render(controller, width: 1100, height: 560, dark: true, name: "ocr-area-bar")
        try UXSnapshotTests.render(controller, width: 760, height: 480, dark: true, name: "ocr-area-bar-narrow")
    }
}
