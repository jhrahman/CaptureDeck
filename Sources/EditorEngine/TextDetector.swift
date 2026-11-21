import CoreGraphics
import Foundation
import Vision

/// A word found in a picture.
public struct DetectedWord: Sendable, Equatable {
    public let text: String
    /// Where the word is, in image pixels with the origin at the top-left.
    public let rect: CGRect
    /// The whole line the word belongs to.
    public let lineRect: CGRect
}

/// Finds the text in a picture (on the Mac, with Apple's Vision framework: nothing leaves the computer), so it can be hidden
/// with a click instead of by painting over it.
public enum TextDetector {
    /// Very tall pictures (a scrolling capture) are read in slices, because Vision works best on pictures of normal size.
    private static let sliceHeight = 3600
    private static let sliceOverlap = 200

    /// Reads all the words in `image`. Slow (a moment for a screenshot): call it off the main thread.
    public static func words(in image: CGImage) -> [DetectedWord] {
        var found: [DetectedWord] = []
        var top = 0
        while top < image.height {
            let height = min(sliceHeight, image.height - top)
            if let slice = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)) {
                for word in read(slice, offsetY: CGFloat(top)) where !found.contains(where: { duplicate($0, word) }) { found.append(word) }
            }
            if top + height >= image.height { break }
            top += height - sliceOverlap
        }
        return found.sorted { lhs, rhs in
            abs(lhs.lineRect.midY - rhs.lineRect.midY) > 4 ? lhs.lineRect.midY < rhs.lineRect.midY : lhs.rect.minX < rhs.rect.minX
        }
    }

    private static func duplicate(_ a: DetectedWord, _ b: DetectedWord) -> Bool {
        guard a.text == b.text else { return false }
        let overlap = a.rect.intersection(b.rect)
        return !overlap.isNull && overlap.width * overlap.height > 0.5 * min(a.rect.width * a.rect.height, b.rect.width * b.rect.height)
    }

    private static func read(_ image: CGImage, offsetY: CGFloat) -> [DetectedWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false                         // screens hold names, codes and numbers, not prose
        request.minimumTextHeight = min(max(8 / Float(image.height), 0.001), 0.03)    // small interface text counts
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }

        let width = CGFloat(image.width), height = CGFloat(image.height)
        func toImage(_ box: CGRect) -> CGRect {                        // Vision: normalised, origin at the bottom-left
            CGRect(x: box.minX * width, y: (1 - box.maxY) * height + offsetY, width: box.width * width, height: box.height * height)
        }

        var words: [DetectedWord] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = toImage(observation.boundingBox)
            let string = candidate.string
            var index = string.startIndex
            while index < string.endIndex {
                if string[index].isWhitespace { index = string.index(after: index); continue }
                var end = index
                while end < string.endIndex, !string[end].isWhitespace { end = string.index(after: end) }
                let range = index..<end
                if let box = try? candidate.boundingBox(for: range) {
                    words.append(DetectedWord(text: String(string[range]), rect: toImage(box.boundingBox), lineRect: line))
                }
                index = end
            }
        }
        return words
    }
}
