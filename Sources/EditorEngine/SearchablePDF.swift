import CoreGraphics
import CoreText
import Foundation

/// A PDF that looks exactly like the picture, with the recognized text laid invisibly over it, so it can be searched,
/// selected and copied in any PDF reader.
public enum SearchablePDF {
    /// - Parameters:
    ///   - image: the picture as the user sees it. Whatever is covered in it stays covered, and unread, in the PDF.
    ///   - words: the words read from that same picture.
    ///   - scale: pixels per point of the capture, so a Retina picture makes a normal-sized page.
    public static func data(image: CGImage, words: [DetectedWord], scale: CGFloat) -> Data? {
        let factor = 1 / max(scale, 1)
        var page = CGRect(x: 0, y: 0, width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        // PDF pages may be at most 14400 points on a side; a very long scrolling capture is shrunk to fit.
        let shrink = min(1, 14_400 / max(page.width, page.height))
        page.size = CGSize(width: page.width * shrink, height: page.height * shrink)
        let points = factor * shrink

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextCreator: "CaptureDeck"] as CFDictionary) else { return nil }
        context.beginPDFPage(nil)
        context.draw(image, in: page)
        context.setTextDrawingMode(.invisible)
        let ordered = words.sorted { abs($0.lineRect.midY - $1.lineRect.midY) > 4 ? $0.lineRect.midY < $1.lineRect.midY : $0.rect.minX < $1.rect.minX }
        for (index, word) in ordered.enumerated() {
            let box = CGRect(x: word.rect.minX * points, y: page.height - word.rect.maxY * points,       // PDF: origin bottom-left
                             width: word.rect.width * points, height: word.rect.height * points)
            guard box.width > 0.5, box.height > 0.5 else { continue }
            // A space after every word but a line's last, so copied text does not run together.
            let sameLineFollows = index + 1 < ordered.count && ordered[index + 1].lineRect == word.lineRect
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.82, nil)
            func line(_ text: String) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ]))
            }
            let natural = CTLineGetTypographicBounds(line(word.text), nil, nil, nil)
            guard natural > 0 else { continue }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
            context.scaleBy(x: box.width / CGFloat(natural), y: 1)               // exactly as wide as the word in the picture
            context.textPosition = .zero
            CTLineDraw(line(sameLineFollows ? word.text + " " : word.text), context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
