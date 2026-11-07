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

/// Applies an `ImageOperation` (crop, resize, rotate, flip) to the picture.
public struct ApplyOperationCommand: EditorCommand {
    public let operation: ImageOperation
    public var name: String { operation.name }
    public init(_ operation: ImageOperation) { self.operation = operation }

    public func apply(to document: EditorDocument) -> Bool { document.appendOperation(operation) }
    public func revert(on document: EditorDocument) { document.removeLastOperation() }
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

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoNames.last }
    public var redoName: String? { redoNames.last }
    public var isDirty: Bool { savedDepth != undoStack.count }

    /// The picture as it should be exported. (Annotations will be rendered in here later.)
    public func flattenedImage() -> CapturedImage { workingImage }

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
        undoNames = undoStack.map(\.name)
        redoNames = redoStack.map(\.name)
    }

    // MARK: Used by commands

    func appendOperation(_ operation: ImageOperation) -> Bool {
        guard let image = operation.apply(to: workingImage.cgImage) else { return false }
        operations.append(operation)
        workingImage = CapturedImage(cgImage: image, scale: workingImage.scale)
        return true
    }

    func removeLastOperation() {
        guard !operations.isEmpty else { return }
        operations.removeLast()
        // Replay from the untouched original.
        var image = original.cgImage
        for operation in operations {
            guard let next = operation.apply(to: image) else { break }
            image = next
        }
        workingImage = CapturedImage(cgImage: image, scale: original.scale)
    }
}
