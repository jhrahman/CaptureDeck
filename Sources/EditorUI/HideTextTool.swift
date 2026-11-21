import AppKit
import EditorEngine

/// Hides text with a click. The picture's text is read once (on the Mac, with Vision), every word is outlined, the word under the
/// pointer lights up, and clicking it covers it. Dragging across several words covers them all, Option-click (or double-click)
/// takes the whole line, and "Hide All Text" does the lot. Everything is one undo step and stays editable until saved.
@MainActor
final class HideTextTool: OverlayTool {
    let descriptor = EditorToolRegistry.hideText
    var overlayChanged: (() -> Void)?

    private enum Detection { case none, reading, ready }
    private var detection = Detection.none
    private var detectedPicture: ObjectIdentifier?
    private var words: [DetectedWord] = []
    private var lineOf: [Int] = []                    // the line each word belongs to
    private var hovered: Int?
    private var touched: Set<Int> = []                // words swept over while the button is down
    private var pressing = false
    private var lastPoint = CGPoint.zero
    private var wholeLines = false

    var statusText: String {
        switch detection {
        case .none: return ""
        case .reading: return "Reading the text in the picture…"
        case .ready: return words.isEmpty ? "No text found in this picture" : "\(words.count) words found · click one, or drag across several"
        }
    }

    var barButton: (title: String, symbol: String)? { detection == .ready && !words.isEmpty ? ("Hide All Text", "text.viewfinder") : nil }

    // MARK: Reading the text

    /// Starts reading the text of the current picture, unless that has been done already.
    func prepare(context: ToolContext) {
        let picture = context.document.workingImage.cgImage
        let id = ObjectIdentifier(picture)
        guard detectedPicture != id else { return }
        detectedPicture = id
        detection = .reading
        words = []; lineOf = []; hovered = nil; touched = []
        overlayChanged?()
        Task.detached(priority: .userInitiated) {
            let found = TextDetector.words(in: picture)
            await MainActor.run { [weak self] in
                guard let self, self.detectedPicture == id else { return }       // the picture changed meanwhile (a crop): ignore
                self.words = found
                var lines: [CGRect] = []                                          // (CGRect is not Hashable before macOS 15)
                self.lineOf = found.map { word in
                    if let known = lines.lastIndex(of: word.lineRect) { return known }
                    lines.append(word.lineRect)
                    return lines.count - 1
                }
                self.detection = .ready
                self.overlayChanged?()
            }
        }
    }

    private func wordIndex(at point: CGPoint, context: ToolContext) -> Int? {
        let slop = context.imagePixels(forScreenPoints: 2)
        var best: (index: Int, area: CGFloat)?
        for (index, word) in words.enumerated() where word.rect.insetBy(dx: -slop, dy: -slop).contains(point) {
            let area = word.rect.width * word.rect.height
            if best == nil || area < best!.area { best = (index, area) }            // the smallest box wins where boxes overlap
        }
        return best?.index
    }

    // MARK: Pointer

    func cursor(at point: CGPoint, context: ToolContext) -> NSCursor {
        prepare(context: context)
        return wordIndex(at: point, context: context) != nil ? .pointingHand : .crosshair
    }

    func pointerMoved(to point: CGPoint, context: ToolContext) -> Bool {
        prepare(context: context)
        let now = wordIndex(at: point, context: context)
        guard now != hovered else { return false }
        hovered = now
        return true
    }

    func mouseDown(at point: CGPoint, context: ToolContext) {
        prepare(context: context)
        pressing = true
        lastPoint = point
        touched = []
        wholeLines = NSEvent.modifierFlags.contains(.option) || context.clickCount >= 2
        if let index = wordIndex(at: point, context: context) { touch(index) }
        overlayChanged?()
    }

    func mouseDragged(to point: CGPoint, context: ToolContext) {
        guard pressing else { return }
        // Sample along the way, so a quick sweep cannot skip a word between two mouse events.
        let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        let steps = max(1, Int(distance / max(context.imagePixels(forScreenPoints: 2), 1)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: lastPoint.x + (point.x - lastPoint.x) * t, y: lastPoint.y + (point.y - lastPoint.y) * t)
            if let index = wordIndex(at: sample, context: context) { touch(index) }
        }
        lastPoint = point
        hovered = wordIndex(at: point, context: context)
        overlayChanged?()
    }

    func mouseUp(at point: CGPoint, context: ToolContext) {
        defer { pressing = false; touched = []; overlayChanged?() }
        guard pressing, !touched.isEmpty else { return }
        hide(touched, context: context)
    }

    private func touch(_ index: Int) {
        if wholeLines {
            let line = lineOf[index]
            for other in words.indices where lineOf[other] == line { touched.insert(other) }
        } else {
            touched.insert(index)
        }
    }

    func keyDown(_ event: NSEvent, context: ToolContext) -> Bool {
        guard event.keyCode == 53 else { return false }                              // Esc: forget the sweep in progress
        if pressing { pressing = false; touched = []; overlayChanged?(); return true }
        return dismissSelection(context.document)
    }

    func deactivate() { pressing = false; touched = []; hovered = nil }

    // MARK: Hiding

    func pressBarButton(context: ToolContext) { hide(Set(words.indices), context: context) }

    /// Covers the words as one undoable step. Neighbouring words of a line are covered by one bar.
    private func hide(_ indices: Set<Int>, context: ToolContext) {
        var runs: [[Int]] = []
        for index in indices.sorted() {
            if let last = runs.last?.last, lineOf[last] == lineOf[index], index == last + 1 { runs[runs.count - 1].append(index) } else { runs.append([index]) }
        }
        let annotations = runs.map { run -> Annotation in
            let box = run.map { words[$0].rect }.reduce(words[run[0]].rect) { $0.union($1) }
            var style = context.style
            // Blur and pixelation must be strong relative to the TEXT: a block that hides small interface text leaves big headings
            // readable. So the strength grows with the word's height; the slider sets the minimum.
            style.strength = min(max(style.strength, box.height * 0.5), 200)
            let thickness = max(box.height * 1.3 + 2, 8)
            // The bar's ends are round, so its end points sit just inside the text: close enough that the round caps also cover the
            // corners of the first and last letters.
            let inset = box.height * 0.25
            let left = box.minX + inset, right = box.maxX - inset
            if right - left < 1 {                                                    // a very short word: one round dab
                style.lineWidth = max(thickness, box.width + 6)
                return Annotation(shape: RedactBrushShape(points: [CGPoint(x: box.midX, y: box.midY)]), style: style)
            }
            style.lineWidth = thickness
            return Annotation(shape: RedactBrushShape(points: [CGPoint(x: left, y: box.midY), CGPoint(x: right, y: box.midY)]), style: style)
        }
        context.document.clearAnnotationSelection()
        context.document.addAnnotations(annotations, name: "Hide Text")
        hovered = nil
    }

    // MARK: Overlay

    func drawOverlay(in context: CGContext, unit: CGFloat) {
        guard detection == .ready else { return }
        context.saveGState()
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        for (index, word) in words.enumerated() {
            let rect = word.rect.insetBy(dx: -1.5 * unit, dy: -1.5 * unit)
            let path = CGPath(roundedRect: rect, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil)
            if touched.contains(index) {
                context.setFillColor(NSColor.systemRed.withAlphaComponent(0.35).cgColor)
                context.setStrokeColor(NSColor.systemRed.cgColor)
                context.setLineWidth(1.5 * unit)
                context.addPath(path); context.drawPath(using: .fillStroke)
            } else if index == hovered {
                context.setFillColor(accent.withAlphaComponent(0.28).cgColor)
                context.setStrokeColor(accent.cgColor)
                context.setLineWidth(1.5 * unit)
                context.addPath(path); context.drawPath(using: .fillStroke)
            } else {
                context.setStrokeColor(accent.withAlphaComponent(0.4).cgColor)
                context.setLineWidth(unit)
                context.addPath(path); context.strokePath()
            }
        }
        context.restoreGState()
    }
}
