import AppKit
import CoreModels
import EditorEngine
import Testing
@testable import EditorUI

/// Draws the real editor offscreen for UX review. Set UX_PNG_DIR=/some/folder to keep the pictures.
@MainActor
struct UXSnapshotTests {
    static func sampleImage() -> CapturedImage {
        let ctx = CGContext(data: nil, width: 1400, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 900))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 820, width: 1400, height: 80))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 120, y: 200, width: 700, height: 500))
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
    }

    static func render(_ controller: EditorViewController, width: CGFloat, height: CGFloat, dark: Bool, name: String) throws {
        let view = controller.view
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.viewDidLayout()
        view.layoutSubtreeIfNeeded()
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        for _ in 0..<3 {                                   // SwiftUI settles over a few passes (bar height follows its content)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            if let warm = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: warm) }
        }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["UX_PNG_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @Test func arrowJustDrawn() throws {
        let doc = EditorDocument(original: Self.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        let arrow = EditorToolRegistry.arrow
        controller.selectTool(id: arrow.id)
        let a = Annotation(shape: LineShape(start: CGPoint(x: 300, y: 400), end: CGPoint(x: 700, y: 300)), style: EditorToolRegistry.arrow.defaultStyle)
        doc.addAnnotation(a)
        try Self.render(controller, width: 1100, height: 760, dark: true, name: "arrow-selected-dark")
        try Self.render(controller, width: 1100, height: 760, dark: false, name: "arrow-selected-light")
        try Self.render(controller, width: 760, height: 600, dark: true, name: "arrow-selected-narrow")
    }

    @Test func otherToolsBars() throws {
        let cases: [(String, EditorToolDescriptor, any AnnotationShape)] = [
            ("text", EditorToolRegistry.text, TextShape(rect: CGRect(x: 300, y: 300, width: 300, height: 60), text: "Click here")),
            ("rect", EditorToolRegistry.rectangle, RectangleShape(rect: CGRect(x: 300, y: 300, width: 300, height: 150))),
            ("bubble", EditorToolRegistry.callout, CalloutShape(rect: CGRect(x: 300, y: 300, width: 260, height: 90), text: "Look", tip: CGPoint(x: 220, y: 480), oval: false)),
            ("blur", EditorToolRegistry.blur, BlurShape(rect: CGRect(x: 300, y: 300, width: 260, height: 90))),
        ]
        for (name, tool, shape) in cases {
            let doc = EditorDocument(original: Self.sampleImage(), title: "t")
            let controller = EditorViewController(document: doc, settings: nil)
            _ = controller.view
            controller.selectTool(id: tool.id)
            doc.addAnnotation(Annotation(shape: shape, style: tool.defaultStyle))
            try Self.render(controller, width: 1100, height: 520, dark: true, name: "bar-\(name)")
            try Self.render(controller, width: 760, height: 520, dark: true, name: "bar-\(name)-narrow")
        }
    }

    @Test func areaSelectionBar() throws {
        let doc = EditorDocument(original: Self.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.rectangleSelect.id)
        try Self.render(controller, width: 1100, height: 520, dark: true, name: "area-empty")
        doc.setSelection(.rect(CGRect(x: 200, y: 200, width: 400, height: 250)))
        try Self.render(controller, width: 1100, height: 520, dark: true, name: "area-selected")
    }
}

@MainActor
struct DirectManipulationTests {
    private func context(_ doc: EditorDocument) -> ToolContext {
        ToolContext(document: doc, zoom: 1, style: EditorToolRegistry.arrow.defaultStyle, host: nil)
    }

    @Test func lineDefaultsToFive() {
        #expect(EditorToolRegistry.line.defaultStyle.lineWidth == 5)
        #expect(EditorToolRegistry.arrow.defaultStyle.lineWidth == 5)
        #expect(EditorToolRegistry.doubleArrow.defaultStyle.lineWidth == 5)
    }

    @Test func deselectedObjectsAreGrabbedFromDrawingTools() {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let arrow = Annotation(shape: LineShape(start: CGPoint(x: 300, y: 400), end: CGPoint(x: 700, y: 300)), style: EditorToolRegistry.arrow.defaultStyle)
        let rect = Annotation(shape: RectangleShape(rect: CGRect(x: 200, y: 500, width: 200, height: 100)), style: EditorToolRegistry.rectangle.defaultStyle)
        let blur = Annotation(shape: BlurShape(rect: CGRect(x: 900, y: 500, width: 200, height: 100)), style: EditorToolRegistry.blur.defaultStyle)
        for a in [arrow, rect, blur] { doc.addAnnotation(a) }
        doc.clearAnnotationSelection()
        let pointer = PointerTool()
        let ctx = context(doc)
        let onArrow = CGPoint(x: 500, y: 350), onRectEdge = CGPoint(x: 200, y: 550), empty = CGPoint(x: 1200, y: 100), onBlur = CGPoint(x: 1000, y: 550)
        #expect(pointer.grabs(onArrow, context: ctx))
        #expect(pointer.grabs(onRectEdge, context: ctx))
        #expect(!pointer.grabs(empty, context: ctx))
        #expect(!pointer.grabs(onBlur, context: ctx))          // effects stay drawable-over
        #expect(pointer.grabs(CGPoint(x: 900, y: 550), context: ctx))   // ...but can be grabbed by their edge
        doc.selectAnnotations([blur.id])
        #expect(pointer.grabs(onBlur, context: ctx))           // ...and anywhere inside once selected
        doc.clearAnnotationSelection()
        #expect(pointer.cursor(at: onArrow, context: ctx) == NSCursor.openHand)
        // Click selects it, dragging moves it.
        pointer.mouseDown(at: onArrow, context: ctx)
        #expect(doc.selectedAnnotationIDs == [arrow.id])
        pointer.mouseDragged(to: CGPoint(x: 520, y: 380), context: ctx)
        pointer.mouseUp(at: CGPoint(x: 520, y: 380), context: ctx)
        let moved = doc.annotations.first { $0.id == arrow.id }?.shape as? LineShape
        #expect(moved?.start == CGPoint(x: 320, y: 430))
        // Clicking empty space deselects.
        pointer.mouseDown(at: empty, context: ctx); pointer.mouseUp(at: empty, context: ctx)
        #expect(doc.selectedAnnotationIDs.isEmpty)
    }

    @Test func ribbonIconsAreTemplates() throws {
        for tool in EditorToolRegistry.descriptors {
            let image = try #require(ToolIcons.image(for: tool))
            #expect(image.isTemplate)
        }
    }
}

@MainActor
struct DeselectTests {
    @Test func pressingEmptySpaceWithADrawingToolDeselects() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        controller.selectTool(id: EditorToolRegistry.rectangle.id)
        let line = Annotation(shape: LineShape(start: CGPoint(x: 300, y: 400), end: CGPoint(x: 700, y: 300)), style: EditorToolRegistry.arrow.defaultStyle)
        doc.addAnnotation(line)
        #expect(doc.selectedAnnotationIDs == [line.id])
        let canvas = try #require(controller.view.firstDescendant(ofType: CanvasView.self))
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        canvas.mouseDown(with: try #require(down))
        #expect(doc.selectedAnnotationIDs.isEmpty)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for sub in subviews { if let found = sub.firstDescendant(ofType: type) { return found } }
        return nil
    }
}
