import CoreGraphics
import CoreModels
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFileFormat: String, CaseIterable, Sendable {
    case png, jpeg, tiff

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }
}

public enum FileSaveError: Error, Equatable {
    case cannotCreateFolder
    case encodingFailed
    case writeFailed
}

/// Saves captures to disk with a filename template. Never overwrites an existing file.
public struct FileSaver: Sendable {
    public init() {}

    @discardableResult
    public func save(
        _ image: CapturedImage,
        to folder: URL,
        template: String,
        format: ImageFileFormat,
        jpegQuality: Double = 0.9,
        date: Date = Date()
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw FileSaveError.cannotCreateFolder
        }
        let data = try ImageEncoding.data(for: image, format: format, jpegQuality: jpegQuality)
        let url = availableURL(in: folder, template: template, ext: format.fileExtension, date: date)
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            throw FileSaveError.writeFailed
        }
        return url
    }

    /// With `#` in the template the sequence counts up to the first free name;
    /// otherwise " 2", " 3", ... is appended on a clash.
    func availableURL(in folder: URL, template: String, ext: String, date: Date) -> URL {
        let fm = FileManager.default
        func url(_ name: String) -> URL { folder.appendingPathComponent(name).appendingPathExtension(ext) }
        if FilenameTemplate.hasSequence(template) {
            var n = 1
            while fm.fileExists(atPath: url(FilenameTemplate.render(template, date: date, sequence: n)).path) { n += 1 }
            return url(FilenameTemplate.render(template, date: date, sequence: n))
        }
        let base = FilenameTemplate.render(template, date: date)
        var candidate = url(base)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = url("\(base) \(n)")
            n += 1
        }
        return candidate
    }
}

extension ImageEncoding {
    /// Encodes for a file. JPEG has no transparency, so it is flattened onto white first.
    static func data(for image: CapturedImage, format: ImageFileFormat, jpegQuality: Double) throws -> Data {
        var cgImage = image.cgImage
        if format == .jpeg, let flattened = flattenedOnWhite(cgImage) { cgImage = flattened }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw FileSaveError.encodingFailed
        }
        let dpi = 72 * image.scale
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileSaveError.encodingFailed }
        return data as Data
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
