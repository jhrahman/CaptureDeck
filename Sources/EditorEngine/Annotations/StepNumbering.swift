import Foundation

/// Keeps step numbers (1, 2, 3) and step letters (A, B, C) gap-free.
///
/// A step's stored `number` is only its placement order: a stable sort key that never changes when other steps are
/// deleted, so undo, redo, saving and reopening need no special handling. What is shown is derived from it: each
/// step's rank among the steps of its own kind. Delete step 3 of 5 and the old 4 and 5 are drawn as 3 and 4;
/// undo the delete and everything is drawn as before. Numbers and letters are counted separately.
public enum StepNumbering {
    /// The same annotations, with every step's number replaced by its rank among steps of the same kind.
    /// Ties (duplicated steps) fall back to stacking order, so the result is deterministic.
    public static func resequenced(_ annotations: [Annotation]) -> [Annotation] {
        var order: [Bool: [(index: Int, key: Int)]] = [:]
        for (index, annotation) in annotations.enumerated() {
            if let step = annotation.shape as? StepShape { order[step.letters, default: []].append((index, step.number)) }
        }
        guard !order.isEmpty else { return annotations }
        var rank: [Int: Int] = [:]
        for (_, entries) in order {
            for (position, entry) in entries.sorted(by: { ($0.key, $0.index) < ($1.key, $1.index) }).enumerated() {
                rank[entry.index] = position + 1
            }
        }
        var result = annotations
        for (index, newNumber) in rank {
            guard var step = annotations[index].shape as? StepShape, step.number != newNumber else { continue }
            step.number = newNumber
            result[index] = Annotation(id: annotations[index].id, shape: step, style: annotations[index].style)
        }
        return result
    }
}
