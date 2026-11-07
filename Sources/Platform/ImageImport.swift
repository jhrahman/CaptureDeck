import AppKit
import CoreModels
import ImageIO

/// Reads images from files and the pasteboard.
public enum ImageImport {
    /// Loads the first image in a file. The scale comes from the DPI metadata (144 dpi = 2x).
    public static func load(from url: URL) -> CapturedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return CapturedImage(cgImage: image, scale: scale(forDPI: dpi))
    }

    /// The image on a pasteboard (PNG or TIFF), if there is one.
    public static func image(from pasteboard: NSPasteboard = .general) -> CapturedImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
            return CapturedImage(cgImage: image, scale: scale(forDPI: dpi))
        }
        return nil
    }

    /// 72 dpi (or unknown) = 1x, 144 dpi = 2x. Clamped to a sane range.
    static func scale(forDPI dpi: Double) -> CGFloat {
        guard dpi >= 72 else { return 1 }
        return CGFloat(min(max((dpi / 72).rounded(), 1), 4))
    }
}
