import AppKit
import CoreModels
import EditorEngine

/// How the editor reads text, as chosen in Settings.
public struct TextReadingSetting {
    public static let language = "editor.ocr.language"
    public static let correctsSpelling = "editor.ocr.correctSpelling"
    public static let keepsLineBreaks = "editor.ocr.keepLineBreaks"
}

/// A picture exactly as the user sees it, with everything drawn on it, and a way to tell when that has changed.
///
/// Text must be read from this and never from the picture underneath: whatever was covered up or blurred has to stay unread.
struct VisiblePicture: Equatable {
    private struct Item: Equatable {
        let id: UUID
        let shape: Data
        let style: AnnotationStyle
    }

    private let base: ObjectIdentifier
    private let items: [Item]
    let options: TextReadingOptions

    @MainActor
    init(_ document: EditorDocument, options: TextReadingOptions) {
        base = ObjectIdentifier(document.workingImage.cgImage)
        items = document.annotations.map { Item(id: $0.id, shape: (try? $0.shape.payload()) ?? Data(), style: $0.style) }
        self.options = options
    }

    /// The words in `image`, or only those whose middle lies inside `area`. Slow: call off the main thread.
    nonisolated static func words(in image: CGImage, area: EditorSelection?, options: TextReadingOptions) -> [DetectedWord] {
        guard let area else { return TextDetector.words(in: image, options: options) }
        // Reading just the area is quicker and, for small areas, more accurate.
        let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box = area.bounds.integral.intersection(whole)
        guard box.width >= 4, box.height >= 4, let cropped = image.cropping(to: box) else { return [] }
        let found = TextDetector.words(in: cropped, options: options).map {
            DetectedWord(text: $0.text, rect: $0.rect.offsetBy(dx: box.minX, dy: box.minY), lineRect: $0.lineRect.offsetBy(dx: box.minX, dy: box.minY))
        }
        guard case .freehand(let points) = area, points.count > 2 else { return found }
        let outline = CGMutablePath()
        outline.addLines(between: points)
        outline.closeSubpath()
        return found.filter { outline.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
    }
}

/// Copies text out of the picture (optical character recognition, done on the Mac with Apple's Vision framework). Every line
/// found is outlined: click a line to copy it, or drag a box to copy just what is inside. The bar copies everything, or shows
/// it for editing. Nothing in the picture is changed.
@MainActor
final class ExtractTextTool: OverlayTool {
    let descriptor = EditorToolRegistry.extractText
    var overlayChanged: (() -> Void)?

    private enum Reading { case none, reading, ready }
    private var state = Reading.none
    private var shown: VisiblePicture?
    private(set) var words: [DetectedWord] = []
    private(set) var codes: [DetectedCode] = []
    private var lines: [CGRect] = []
    private var hovered: Int?
    private var anchor: CGPoint?
    private var box: CGRect?
    private var task: Task<Void, Never>?

    var statusText: String {
        switch state {
        case .none: ""
        case .reading: "Reading the text in the picture…"
        case .ready: words.isEmpty && codes.isEmpty ? "No text or codes found in this picture"
            : codes.isEmpty ? "Click a line to copy it, or drag a box around the text you want"
            : "Click a line or a code to copy it, or drag a box around what you want"
        }
    }

    /// The whole picture's text, once read, followed by what its QR codes and barcodes hold.
    func allText(keepsLineBreaks: Bool) -> String { CodeReader.combined(text: TextLayout.text(from: words, keepsLineBreaks: keepsLineBreaks), codes: codes) }
    var hasText: Bool { state == .ready && !(words.isEmpty && codes.isEmpty) }
    var isReady: Bool { state == .ready }

    // MARK: Reading

    /// Reads the picture as it looks now, unless that has been done already.
    func prepare(context: ToolContext) {
        let picture = VisiblePicture(context.document, options: context.textOptions)
        guard picture != shown else { return }
        shown = picture
        state = .reading
        words = []; codes = []; lines = []; hovered = nil; box = nil; anchor = nil
        overlayChanged?()
        task?.cancel()
        let image = context.document.flattenedImage().cgImage
        let options = context.textOptions
        task = Task.detached(priority: .userInitiated) {
            let found = VisiblePicture.words(in: image, area: nil, options: options)
            let foundCodes = CodeReader.codes(in: image)
            await MainActor.run { [weak self] in
                guard let self, self.shown == picture else { return }           // the picture changed meanwhile: ignore
                self.words = found
                self.codes = foundCodes
                var rects: [CGRect] = []
                for word in found where !rects.contains(word.lineRect) { rects.append(word.lineRect) }
                self.lines = rects
                self.state = .ready
                self.overlayChanged?()
            }
        }
    }

    private func line(at point: CGPoint, context: ToolContext) -> Int? {
        let slop = context.imagePixels(forScreenPoints: 2)
        return lines.indices.filter { lines[$0].insetBy(dx: -slop, dy: -slop).contains(point) }
            .min { lines[$0].width * lines[$0].height < lines[$1].width * lines[$1].height }
    }

    private func code(at point: CGPoint) -> DetectedCode? { codes.first { $0.rect.contains(point) } }

    // MARK: Pointer

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        prepare(context: context)
        return code(at: point) != nil || line(at: point, context: context) != nil ? .pointingHand : .crosshair
    }

    func pointerMoved(to point: CGPoint, context: ToolContext) -> Bool {
        prepare(context: context)
        let now = line(at: point, context: context)
        guard now != hovered else { return false }
        hovered = now
        return true
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        prepare(context: context)
        anchor = point
        box = nil
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard let anchor else { return }
        let rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        let slop = context.imagePixels(forScreenPoints: 4)
        box = rect.width > slop || rect.height > slop ? rect : nil              // a shaky click is still a click
        overlayChanged?()
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { anchor = nil; box = nil; overlayChanged?() }
        guard let start = anchor, state == .ready else { return }
        let chosen: [DetectedWord]
        var chosenCodes: [DetectedCode] = []
        if let box {
            chosen = words.filter { box.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            chosenCodes = codes.filter { box.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        } else if let code = code(at: start) {
            context.host?.recognizedText(code.payload)
            return
        } else if let index = line(at: start, context: context) {
            chosen = words.filter { $0.lineRect == lines[index] }
        } else {
            return
        }
        context.host?.recognizedText(CodeReader.combined(text: TextLayout.text(from: chosen, keepsLineBreaks: context.keepsLineBreaks), codes: chosenCodes))
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }
        if anchor != nil { anchor = nil; box = nil; overlayChanged?(); return true }
        return dismissSelection(context.document)
    }

    func deactivate() { anchor = nil; box = nil; hovered = nil }

    // MARK: Overlay

    func drawOverlay(in context: CGContext, unit: CGFloat) {
        guard state == .ready else { return }
        context.saveGState()
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        context.setLineWidth(unit)
        for (index, line) in lines.enumerated() {
            let path = CGPath(roundedRect: line.insetBy(dx: -2 * unit, dy: -2 * unit), cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil)
            let inBox = box.map { area in words.contains { $0.lineRect == line && area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) } } ?? false
            context.setStrokeColor(accent.withAlphaComponent(index == hovered ? 1 : 0.45).cgColor)
            context.setFillColor(accent.withAlphaComponent(index == hovered && box == nil ? 0.22 : 0).cgColor)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            guard inBox, let area = box else { continue }
            context.setFillColor(accent.withAlphaComponent(0.3).cgColor)        // exactly the words the box will copy
            for word in words where word.lineRect == line && area.contains(CGPoint(x: word.rect.midX, y: word.rect.midY)) { context.fill(word.rect) }
        }
        for code in codes {                                                       // QR codes and barcodes, in their own color
            context.setStrokeColor(NSColor.systemOrange.cgColor)
            context.setLineWidth(2 * unit)
            context.stroke(code.rect.insetBy(dx: -3 * unit, dy: -3 * unit))
        }
        if let box {
            context.setStrokeColor(accent.cgColor)
            context.setLineDash(phase: 0, lengths: [5 * unit, 3 * unit])
            context.stroke(box)
        }
        context.restoreGState()
    }
}
