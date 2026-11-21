import CoreGraphics
import CoreModels
import Foundation

/// One edit that can be applied and taken back. Every change to a document goes through a command,
/// which is what makes multi-level undo/redo work.
@MainActor
public protocol EditorCommand {
    var name: String { get }
    /// Returns false (leaving the document unchanged) if the command cannot be applied.
    func apply(to document: EditorDocument) -> Bool
    func revert(on document: EditorDocument)
}

/// Applies an `ImageOperation` (crop, resize, rotate, flip) to the picture. Annotations move with the
/// picture so they stay on the thing they point at; undo puts them back exactly.
public final class ApplyOperationCommand: EditorCommand {
    public let operation: ImageOperation
    public var name: String { operation.name }
    private var annotationsBefore: [Annotation] = []

    public init(_ operation: ImageOperation) { self.operation = operation }

    public func apply(to document: EditorDocument) -> Bool {
        let before = document.annotations
        let size = document.workingImage.cgImage
        guard document.appendOperation(operation) else { return false }
        annotationsBefore = before
        let transform = operation.annotationTransform(imageWidth: size.width, imageHeight: size.height)
        document.restoreAnnotations(before.map { $0.applying(transform) })
        return true
    }

    public func revert(on document: EditorDocument) {
        document.removeLastOperation()
        document.restoreAnnotations(annotationsBefore)
    }
}

/// An open image being edited. The original capture is never modified: the working image is derived
/// from it by replaying `operations`, and history is a stack of commands.
@MainActor
public final class EditorDocument: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    public let original: CapturedImage

    @Published public var title: String
    /// Where this image was last saved to or opened from.
    @Published public var fileURL: URL?
    @Published public private(set) var operations: [ImageOperation] = []
    @Published public private(set) var workingImage: CapturedImage
    @Published public private(set) var undoNames: [String] = []
    @Published public private(set) var redoNames: [String] = []
    /// The selected area, in working-image pixels. Selection is not part of the undo history.
    @Published public private(set) var selection: EditorSelection?
    /// Shapes drawn on the picture, bottom to top.
    @Published public private(set) var annotations: [Annotation] = []
    /// The annotations currently selected (in the order they were selected).
    @Published public private(set) var selectedAnnotationIDs: [UUID] = []

    private var undoStack: [any EditorCommand] = []
    private var redoStack: [any EditorCommand] = []
    /// History depth at the last save; nil once the saved state is no longer reachable.
    private var savedDepth: Int? = 0

    public init(original: CapturedImage, title: String, fileURL: URL? = nil) {
        self.original = original
        self.workingImage = original.withSource(nil)
        self.title = title
        self.fileURL = fileURL
    }

    /// Whether the editor should start with the whole picture selected (not wanted for a blank canvas).
    public var startsWithFullSelection = true

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoNames.last }
    public var redoName: String? { redoNames.last }
    public var isDirty: Bool { savedDepth != undoStack.count }

    /// The picture as it should be exported, with the annotations drawn in.
    public func flattenedImage() -> CapturedImage {
        guard !annotations.isEmpty, let image = AnnotationRenderer.render(annotations, onto: workingImage.cgImage) else { return workingImage }
        return CapturedImage(cgImage: image, scale: workingImage.scale)
    }

    // MARK: History

    @discardableResult
    public func perform(_ command: any EditorCommand) -> Bool {
        guard command.apply(to: self) else { return false }
        if let saved = savedDepth, saved > undoStack.count { savedDepth = nil }   // saved state was in the discarded redo branch
        undoStack.append(command)
        redoStack.removeAll()
        publishHistory()
        return true
    }

    @discardableResult
    public func apply(_ operation: ImageOperation) -> Bool { perform(ApplyOperationCommand(operation)) }

    public func undo() {
        guard let command = undoStack.popLast() else { return }
        command.revert(on: self)
        redoStack.append(command)
        publishHistory()
    }

    public func redo() {
        guard let command = redoStack.popLast() else { return }
        if command.apply(to: self) {
            undoStack.append(command)
        } else {
            redoStack.removeAll()    // cannot be re-applied; drop the branch rather than corrupt state
        }
        publishHistory()
    }

    public func markSaved() { savedDepth = undoStack.count }

    private func publishHistory() {
        pruneAnnotationSelection()
        undoNames = undoStack.map(\.name)
        redoNames = redoStack.map(\.name)
    }

    // MARK: Annotations

    public var selectedAnnotations: [Annotation] {
        selectedAnnotationIDs.compactMap { id in annotations.first { $0.id == id } }
    }

    /// The rectangle around all selected annotations.
    public var selectedAnnotationBounds: CGRect? {
        let boxes = selectedAnnotations.map(\.bounds)
        guard var union = boxes.first else { return nil }
        for box in boxes.dropFirst() { union = union.union(box) }
        return union
    }

    public func annotation(withID id: UUID) -> Annotation? { annotations.first { $0.id == id } }

    /// The topmost annotation under `point` (image pixels).
    public func annotation(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    public func selectAnnotations(_ ids: [UUID]) {
        let existing = Set(annotations.map(\.id))
        selectedAnnotationIDs = ids.filter { existing.contains($0) }
    }

    public func clearAnnotationSelection() { selectedAnnotationIDs = [] }

    @discardableResult
    public func addAnnotation(_ annotation: Annotation, select: Bool = true) -> Bool {
        guard perform(AddAnnotationsCommand([annotation])) else { return false }
        if select { selectedAnnotationIDs = [annotation.id] }
        return true
    }

    /// Adds several annotations as ONE undoable step (hiding every word of a page, say, is a single Undo).
    @discardableResult
    public func addAnnotations(_ annotations: [Annotation], name: String? = nil) -> Bool {
        guard !annotations.isEmpty else { return false }
        return perform(AddAnnotationsCommand(annotations, name: name))
    }

    /// Replaces annotations (same ids) with new versions as one undoable step: restyle, move, resize.
    @discardableResult
    public func updateAnnotations(_ updated: [Annotation], name: String) -> Bool {
        let old = updated.compactMap { annotation(withID: $0.id) }
        guard old.count == updated.count, !updated.isEmpty else { return false }
        return perform(ReplaceAnnotationsCommand(name: name, old: old, new: updated))
    }

    /// Shows a change while the mouse is still dragging, without touching the undo history.
    public func previewAnnotations(_ updated: [Annotation]) { replaceAnnotations(updated) }

    /// Ends a drag: records `original` -> current as one undoable step.
    @discardableResult
    public func commitAnnotationEdit(from original: [Annotation], name: String) -> Bool {
        let current = original.compactMap { annotation(withID: $0.id) }
        guard current.count == original.count, !original.isEmpty else { return false }
        // A click or a drag that ended where it started changes nothing, so it must not become an undo step.
        guard zip(original, current).contains(where: { !$0.looksSame(as: $1) }) else { return false }
        return perform(ReplaceAnnotationsCommand(name: name, old: original, new: current))
    }

    @discardableResult
    public func removeAnnotations(ids: [UUID]) -> Bool {
        let present = ids.filter { id in annotations.contains { $0.id == id } }
        guard !present.isEmpty else { return false }
        return perform(RemoveAnnotationsCommand(ids: present))
    }

    @discardableResult
    public func deleteSelectedAnnotations() -> Bool { removeAnnotations(ids: selectedAnnotationIDs) }

    /// Copies the given annotations, slightly offset, on top. The copies become the selection.
    @discardableResult
    public func duplicateAnnotations(ids: [UUID], offset: CGSize = CGSize(width: 12, height: 12)) -> [UUID] {
        let copies = ids.compactMap { annotation(withID: $0)?.duplicated(offset: offset) }
        guard !copies.isEmpty, perform(AddAnnotationsCommand(copies, name: "Duplicate")) else { return [] }
        selectedAnnotationIDs = copies.map(\.id)
        return selectedAnnotationIDs
    }

    public enum ZOrder { case toFront, toBack }

    @discardableResult
    public func reorderAnnotations(ids: [UUID], _ order: ZOrder) -> Bool {
        let moving = annotations.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return false }
        let others = annotations.filter { !ids.contains($0.id) }
        let after = (order == .toFront ? others + moving : moving + others).map(\.id)
        guard after != annotations.map(\.id) else { return false }
        return perform(ReorderAnnotationsCommand(before: annotations.map(\.id), after: after, name: order == .toFront ? "Bring to Front" : "Send to Back"))
    }

    // Used by commands (and image operations).

    func insertAnnotations(_ items: [(index: Int, annotation: Annotation)]) {
        var list = annotations
        for item in items.sorted(by: { $0.index < $1.index }) { list.insert(item.annotation, at: min(item.index, list.count)) }
        annotations = list
    }

    func removeAnnotations(withIDs ids: Set<UUID>) {
        annotations.removeAll { ids.contains($0.id) }
        pruneAnnotationSelection()
    }

    /// Swaps in new versions of existing annotations (matched by id).
    func replaceAnnotations(_ updated: [Annotation]) {
        var list = annotations
        for new in updated {
            if let index = list.firstIndex(where: { $0.id == new.id }) { list[index] = new }
        }
        annotations = list
    }

    func restoreAnnotations(_ all: [Annotation]) {
        annotations = all
        pruneAnnotationSelection()
    }

    func setAnnotationOrder(_ ids: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })
        annotations = ids.compactMap { byID[$0] }
    }

    private func pruneAnnotationSelection() {
        let existing = Set(annotations.map(\.id))
        let kept = selectedAnnotationIDs.filter { existing.contains($0) }
        if kept != selectedAnnotationIDs { selectedAnnotationIDs = kept }
    }

    // MARK: Selection

    public var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: workingImage.cgImage.width, height: workingImage.cgImage.height)
    }

    /// Sets the selection, clamped to the image. Empty selections clear it.
    public func setSelection(_ new: EditorSelection?) {
        switch new {
        case .rect(let r)?:
            let clamped = r.intersection(imageBounds)
            selection = (clamped.isNull || clamped.width < 1 || clamped.height < 1) ? nil : .rect(clamped)
        case .freehand(let points)?:
            let b = imageBounds
            let clamped = points.map { CGPoint(x: min(max($0.x, b.minX), b.maxX), y: min(max($0.y, b.minY), b.maxY)) }
            selection = clamped.count >= 3 ? .freehand(clamped) : nil
        case nil:
            selection = nil
        }
    }

    public func selectAll() { setSelection(.rect(imageBounds)) }
    public func clearSelection() { selection = nil }

    /// The selected pixels (annotations included) as their own image; freehand selections are transparent outside the outline.
    public func selectionImage() -> CapturedImage? {
        let picture = flattenedImage()
        switch selection {
        case .rect(let r)?: return picture.cropped(toPixelRect: r)
        case .freehand(let points)?: return picture.cropped(toPixelPolygon: points)
        case nil: return nil
        }
    }

    /// Crops the picture to the selection's bounding box (an undoable operation).
    @discardableResult
    public func cropToSelection() -> Bool {
        guard let selection else { return false }
        return apply(.crop(selection.bounds.integral))
    }

    /// Erases the selected area: those pixels become transparent (undoable). The selection stays, so the area can be filled next.
    @discardableResult
    public func eraseSelection() -> Bool {
        switch selection {
        case .rect(let rect)?: return apply(.clearArea(rect.integral))
        case .freehand(let points)?: return apply(.clearPolygon(points))
        case nil: return false
        }
    }

    /// Paints the selected area with a solid colour (undoable).
    @discardableResult
    public func fillSelection(with color: RGBAColor) -> Bool {
        switch selection {
        case .rect(let rect)?: return apply(.fillArea(rect.integral, color))
        case .freehand(let points)?: return apply(.fillPolygon(points, color))
        case nil: return false
        }
    }

    // MARK: Used by commands

    func appendOperation(_ operation: ImageOperation) -> Bool {
        guard let image = operation.apply(to: workingImage.cgImage) else { return false }
        operations.append(operation)
        workingImage = CapturedImage(cgImage: image, scale: workingImage.scale)
        if operation.changesShape { selection = nil }          // the picture changed shape; the old selection no longer applies
        return true
    }

    func removeLastOperation() {
        guard !operations.isEmpty else { return }
        let removed = operations.removeLast()
        // Replay from the untouched original.
        var image = original.cgImage
        for operation in operations {
            guard let next = operation.apply(to: image) else { break }
            image = next
        }
        workingImage = CapturedImage(cgImage: image, scale: original.scale)
        if removed.changesShape { selection = nil }
    }
}
