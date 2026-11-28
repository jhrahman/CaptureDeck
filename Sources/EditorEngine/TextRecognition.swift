import CoreGraphics
import Foundation
import Vision

/// How the text in a picture is read.
public struct TextReadingOptions: Sendable, Equatable {
    /// A language identifier such as "de-DE"; nil lets the Mac work out the language itself.
    public var language: String?
    /// Fixes likely misreadings using the language's dictionary. Helps ordinary writing; spoils code, names and numbers.
    public var correctsSpelling: Bool

    public init(language: String? = nil, correctsSpelling: Bool = false) {
        self.language = language
        self.correctsSpelling = correctsSpelling
    }

    /// The languages this version of macOS can read, as identifiers.
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }
}

/// Puts words found in a picture back together as text, in reading order: top to bottom, and left to right within a line.
///
/// Pictures with several columns side by side are read straight across; select one column to copy it by itself.
public enum TextLayout {
    private struct Piece {
        var text: String
        var rect: CGRect
    }

    public static func text(from words: [DetectedWord], keepsLineBreaks: Bool = true) -> String {
        // The words of each line Vision found, left to right.
        var lines: [(rect: CGRect, words: [DetectedWord])] = []
        for word in words {
            if let index = lines.lastIndex(where: { $0.rect == word.lineRect }) {
                lines[index].words.append(word)
            } else {
                lines.append((word.lineRect, [word]))
            }
        }
        let pieces = lines.map { line -> Piece in
            let ordered = line.words.sorted { $0.rect.minX < $1.rect.minX }
            let box = ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) }
            return Piece(text: ordered.map(\.text).joined(separator: " "), rect: box)
        }.sorted { $0.rect.midY < $1.rect.midY }

        // Lines level with each other (a label and its value, cells of a table) become one row.
        var rows: [[Piece]] = []
        for piece in pieces {
            if let first = rows.last?.first, abs(piece.rect.midY - first.rect.midY) < min(piece.rect.height, first.rect.height) * 0.5 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        let joined = rows.map { row -> Piece in
            let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
            var text = ordered[0].text
            for (before, piece) in zip(ordered, ordered.dropFirst()) {
                // A wide gap is a column of a table or a form, kept apart with a tab.
                text += (piece.rect.minX - before.rect.maxX > piece.rect.height * 2 ? "\t" : " ") + piece.text
            }
            return Piece(text: text, rect: ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) })
        }

        // A paragraph ends at a gap that is clear in itself and clearly bigger than the usual space between these lines, so
        // that a widely spaced list is not broken apart. With only one gap there is nothing to compare, so it must be wide.
        let gaps = zip(joined, joined.dropFirst()).map { max(0, $1.rect.minY - $0.rect.maxY) }.sorted()
        let usual = gaps.count > 1 ? gaps[(gaps.count - 1) / 2] : nil
        func startsParagraph(_ row: Piece, after above: Piece) -> Bool {
            let height = min(row.rect.height, above.rect.height), gap = row.rect.minY - above.rect.maxY
            guard let usual else { return gap > height * 1.5 }
            return gap > max(height * 0.9, usual * 1.6)
        }

        var result = ""
        var previous: Piece?
        for row in joined {
            guard let above = previous else {
                result = row.text
                previous = row
                continue
            }
            if startsParagraph(row, after: above) {
                result += "\n\n" + row.text                                   // a clear gap: a new paragraph
            } else if keepsLineBreaks {
                result += "\n" + row.text
            } else if result.hasSuffix("-"), result.dropLast().last?.isLetter == true, row.text.first?.isLowercase == true {
                result = String(result.dropLast()) + row.text                 // a word split across two lines
            } else {
                result += " " + row.text
            }
            previous = row
        }
        return result
    }

    /// "1 word", "24 words".
    public static func wordCount(_ text: String) -> String {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return "\(count) \(count == 1 ? "word" : "words")"
    }
}
