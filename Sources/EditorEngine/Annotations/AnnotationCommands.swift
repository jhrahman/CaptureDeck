import Foundation

/// Adds annotations on top.
@MainActor
final class AddAnnotationsCommand: EditorCommand {
    let name: String
    private let annotations: [Annotation]

    init(_ annotations: [Annotation], name: String? = nil) {
        self.annotations = annotations
        self.name = name ?? (annotations.count == 1 ? "Add \(Self.title(of: annotations[0]))" : "Add Annotations")
    }

    private static func title(of annotation: Annotation) -> String {
        switch annotation.shape.shapeType {
        case "rectangle": "Rectangle"
        case "ellipse": "Ellipse"
        case "line": "Line"
        case "pencil": "Drawing"
        case "highlighter": "Highlight"
        default: "Annotation"
        }
    }

    func apply(to document: EditorDocument) -> Bool {
        let existing = Set(document.annotations.map(\.id))
        let fresh = annotations.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        let start = document.annotations.count
        document.insertAnnotations(fresh.enumerated().map { (start + $0.offset, $0.element) })
        return true
    }

    func revert(on document: EditorDocument) {
        document.removeAnnotations(withIDs: Set(annotations.map(\.id)))
    }
}

/// Removes annotations, remembering where each one was so undo puts it back in the same place.
@MainActor
final class RemoveAnnotationsCommand: EditorCommand {
    let name = "Delete"
    private let ids: [UUID]
    private var removed: [(index: Int, annotation: Annotation)] = []

    init(ids: [UUID]) { self.ids = ids }

    func apply(to document: EditorDocument) -> Bool {
        removed = document.annotations.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) }
        guard !removed.isEmpty else { return false }
        document.removeAnnotations(withIDs: Set(ids))
        return true
    }

    func revert(on document: EditorDocument) {
        document.insertAnnotations(removed)
        document.selectAnnotations(removed.map(\.annotation.id))        // undoing a delete brings the selection back too
    }
}

/// Replaces annotations with new versions: move, resize, restyle.
@MainActor
final class ReplaceAnnotationsCommand: EditorCommand {
    let name: String
    private let old: [Annotation]
    private let new: [Annotation]

    init(name: String, old: [Annotation], new: [Annotation]) {
        self.name = name
        self.old = old
        self.new = new
    }

    func apply(to document: EditorDocument) -> Bool {
        document.replaceAnnotations(new)
        return true
    }

    func revert(on document: EditorDocument) { document.replaceAnnotations(old) }
}

/// Changes the stacking order.
@MainActor
final class ReorderAnnotationsCommand: EditorCommand {
    let name: String
    private let before: [UUID]
    private let after: [UUID]

    init(before: [UUID], after: [UUID], name: String) {
        self.before = before
        self.after = after
        self.name = name
    }

    func apply(to document: EditorDocument) -> Bool {
        document.setAnnotationOrder(after)
        return true
    }

    func revert(on document: EditorDocument) { document.setAnnotationOrder(before) }
}
