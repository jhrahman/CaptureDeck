import AppKit
import CoreModels
import ImageIO
import UniformTypeIdentifiers

public enum ClipboardError: Error, Equatable {
    case encodingFailed
    case writeFailed
}

/// Copies images to the pasteboard as PNG (lossless, keeps transparency) plus TIFF for older apps.
public struct ClipboardManager {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func copy(_ image: CapturedImage) throws {
        let png = try ImageEncoding.pngData(for: image)
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { throw ClipboardError.writeFailed }
        // TIFF is uncompressed (4 bytes per pixel), only for older apps. A very tall scrolling capture would be hundreds of
        // megabytes, which the pasteboard refuses, so it gets the PNG alone.
        if Self.fitsAsTIFF(image) { _ = pasteboard.setData(try ImageEncoding.tiffData(for: image), forType: .tiff) }
    }
}

extension ClipboardManager {
    /// Largest picture (in pixels) that is also offered as TIFF.
    static let maxTIFFPixels = 24_000_000

    static func fitsAsTIFF(_ image: CapturedImage) -> Bool {
        image.cgImage.width * image.cgImage.height <= maxTIFFPixels
    }
}

public enum ImageEncoding {
    /// Encodes with DPI metadata (72 x scale) so apps paste Retina captures at the right point size.
    public static func pngData(for image: CapturedImage) throws -> Data {
        try encode(image, type: UTType.png)
    }

    public static func tiffData(for image: CapturedImage) throws -> Data {
        try encode(image, type: UTType.tiff)
    }

    private static func encode(_ image: CapturedImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ClipboardError.encodingFailed
        }
        let dpi = 72 * image.scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image.cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClipboardError.encodingFailed }
        return data as Data
    }
}
