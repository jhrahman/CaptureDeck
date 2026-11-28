import CoreGraphics
import Vision

/// A QR code or barcode found in a picture.
public struct DetectedCode: Sendable, Equatable {
    /// What the code holds, exactly as written in it. It may be a link: it is only ever shown and copied, never opened.
    public let payload: String
    /// Where it is, in image pixels with the origin at the top-left.
    public let rect: CGRect

    public init(payload: String, rect: CGRect) { (self.payload, self.rect) = (payload, rect) }
}

/// Reads the QR codes and barcodes in a picture, on the Mac.
public enum CodeReader {
    public static func codes(in image: CGImage) -> [DetectedCode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var found: [DetectedCode] = []
        for observation in observations {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { continue }
            let box = observation.boundingBox                          // normalised, origin at the bottom-left
            let code = DetectedCode(payload: payload,
                                    rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height))
            if !found.contains(where: { $0.payload == payload && $0.rect.intersects(code.rect) }) { found.append(code) }
        }
        return found.sorted { abs($0.rect.midY - $1.rect.midY) > 8 ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
    }

    /// The text read from a picture, with the contents of its codes after it, each on its own line.
    public static func combined(text: String, codes: [DetectedCode]) -> String {
        var parts = text.isEmpty ? [] : [text]
        var added: Set<String> = []
        for code in codes where !text.contains(code.payload) && added.insert(code.payload).inserted { parts.append(code.payload) }
        return parts.joined(separator: "\n")
    }
}
