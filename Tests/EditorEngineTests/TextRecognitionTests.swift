import AppKit
import CoreImage
import CoreModels
import PDFKit
import Testing
@testable import EditorEngine

/// A made-up picture with text drawn at known places (origin top-left, like image pixels).
@MainActor
enum TextPicture {
    static func make(_ items: [(String, CGPoint)], size: CGSize = CGSize(width: 900, height: 420), fontSize: CGFloat = 32) -> CGImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (text, point) in items {
            (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func qr(_ payload: String, at origin: CGPoint = CGPoint(x: 60, y: 60), size: CGSize = CGSize(width: 600, height: 420)) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rendered = CIContext().createCGImage(code, from: code.extent)!
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(rendered, in: CGRect(x: origin.x, y: size.height - origin.y - CGFloat(rendered.height),
                                          width: CGFloat(rendered.width), height: CGFloat(rendered.height)))
        return context.makeImage()!
    }
}

/// Words placed by hand, to check how text is put together without reading any picture.
struct TextLayoutTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat = 20) -> [DetectedWord] {
        let parts = text.split(separator: " ").map(String.init)
        let box = CGRect(x: x, y: y, width: CGFloat(text.count) * 10, height: height)
        var left = x
        return parts.map { part in
            defer { left += CGFloat(part.count + 1) * 10 }
            return DetectedWord(text: part, rect: CGRect(x: left, y: y, width: CGFloat(part.count) * 10, height: height), lineRect: box)
        }
    }

    @Test func linesReadTopToBottomWhateverOrderTheyArriveIn() {
        let words = line("third line", x: 10, y: 60) + line("first line", x: 10, y: 0) + line("second line", x: 10, y: 30)
        #expect(TextLayout.text(from: words) == "first line\nsecond line\nthird line")
    }

    @Test func anEvenlyWideSpacedListIsNotBrokenApart() {
        let words = (0..<4).flatMap { line("item \($0)", x: 10, y: CGFloat($0) * 48) } + line("After the list", x: 10, y: 260)
        #expect(TextLayout.text(from: words) == "item 0\nitem 1\nitem 2\nitem 3\n\nAfter the list")
    }

    @Test func aClearGapStartsAParagraph() {
        let words = line("Title", x: 10, y: 0) + line("Body text", x: 10, y: 70)
        #expect(TextLayout.text(from: words) == "Title\n\nBody text")
    }

    @Test func piecesLevelWithEachOtherShareARowAndWideGapsBecomeTabs() {
        let words = line("$48,290", x: 400, y: 2) + line("Total", x: 10, y: 0)
        #expect(TextLayout.text(from: words) == "Total\t$48,290")
    }

    @Test func withoutLineBreaksAParagraphIsJoinedAndSplitWordsAreMended() {
        let words = line("This is a para-", x: 10, y: 0) + line("graph of text", x: 10, y: 24) + line("that goes on", x: 10, y: 48)
            + line("Another one", x: 10, y: 130)
        #expect(TextLayout.text(from: words, keepsLineBreaks: false) == "This is a paragraph of text that goes on\n\nAnother one")
    }

    @Test func emptyAndCounting() {
        #expect(TextLayout.text(from: []) == "")
        #expect(TextLayout.wordCount("one") == "1 word")
        #expect(TextLayout.wordCount("one two\nthree\tfour") == "4 words")
    }

    @Test func codesFollowTheTextOnceEach() {
        let codes = [DetectedCode(payload: "https://example.com", rect: .zero), DetectedCode(payload: "https://example.com", rect: .zero),
                     DetectedCode(payload: "visible", rect: .zero)]
        #expect(CodeReader.combined(text: "visible words", codes: codes) == "visible words\nhttps://example.com")
        #expect(CodeReader.combined(text: "", codes: [codes[0]]) == "https://example.com")
    }
}

@MainActor
struct TextReadingTests {
    @Test func aPictureIsReadInOrder() {
        let image = TextPicture.make([("Quarterly revenue report", CGPoint(x: 40, y: 40)), ("Orders shipped yesterday", CGPoint(x: 40, y: 90))])
        let text = TextLayout.text(from: TextDetector.words(in: image))
        #expect(text == "Quarterly revenue report\nOrders shipped yesterday", "\(text)")
    }

    /// A very tall scrolling capture is read in slices; a line on a slice's edge must appear once, and whole.
    @Test func aTallPictureReadsEveryLineExactlyOnce() {
        let items = (0..<64).map { ("Entry number \(100 + $0) is listed here", CGPoint(x: 40, y: CGFloat($0) * 118 + 20)) }
        let image = TextPicture.make(items, size: CGSize(width: 900, height: 7600))
        let text = TextLayout.text(from: TextDetector.words(in: image))
        for number in 100..<164 {
            #expect(text.components(separatedBy: "number \(number) ").count == 2, "entry \(number) not read exactly once")
        }
    }

    @Test func theLanguageListIsOfferedAndAChosenLanguageIsUsed() {
        let languages = TextReadingOptions.supportedLanguages()
        #expect(languages.contains("en-US") && languages.count > 3)
        let image = TextPicture.make([("Plain English words", CGPoint(x: 40, y: 40))])
        #expect(TextLayout.text(from: TextDetector.words(in: image, options: TextReadingOptions(language: "en-US", correctsSpelling: true)))
            == "Plain English words")
    }

    @Test func aQRCodeIsReadWithItsPlace() throws {
        let image = TextPicture.qr("https://example.com/capturedeck?id=42")
        let code = try #require(CodeReader.codes(in: image).first)
        #expect(code.payload == "https://example.com/capturedeck?id=42")
        #expect(code.rect.minX > 40 && code.rect.minX < 120 && code.rect.minY > 40 && code.rect.minY < 120, "\(code.rect)")
        #expect(CodeReader.codes(in: TextPicture.make([("no codes here", CGPoint(x: 40, y: 40))])).isEmpty)
    }

    // MARK: Searchable PDF

    @Test func theSearchablePDFHoldsTheTextWhereThePictureShowsIt() throws {
        let image = TextPicture.make([("Invoice total amount", CGPoint(x: 40, y: 40)), ("Payment due Friday", CGPoint(x: 40, y: 200))])
        let words = TextDetector.words(in: image)
        let data = try #require(SearchablePDF.data(image: image, words: words, scale: 2))
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 450, height: 210))          // a 2x capture: half the pixels
        let text = try #require(page.string)
        #expect(text.contains("Invoice total amount") && text.contains("Payment due Friday"), "\(text)")
        let found = try #require(document.findString("total", withOptions: .caseInsensitive).first)
        let shown = try #require(words.first { $0.text == "total" }).rect
        let box = found.bounds(for: page)
        #expect(abs(box.midX - shown.midX / 2) < 6 && abs(box.midY - (210 - shown.midY / 2)) < 8, "\(box) vs \(shown)")
    }

    @Test func aVeryLongCaptureStillFitsAPDFPage() throws {
        let image = TextPicture.make([("Top", CGPoint(x: 20, y: 20))], size: CGSize(width: 800, height: 30_000))
        let data = try #require(SearchablePDF.data(image: image, words: [], scale: 1))
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).height <= 14_400)
    }
}
