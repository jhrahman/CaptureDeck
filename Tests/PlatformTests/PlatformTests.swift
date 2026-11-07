import AppKit
import ServiceManagement
import Carbon.HIToolbox
import CoreModels
import ImageIO
import Testing
@testable import Platform

private func makeImage(width: Int, height: Int, scale: CGFloat) -> CapturedImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return CapturedImage(cgImage: ctx.makeImage()!, scale: scale)
}

@MainActor
struct ClipboardTests {
    @Test func copiesPngAndTiffPreservingSizeAndAlpha() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("capturedeck.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        try ClipboardManager(pasteboard: board).copy(makeImage(width: 300, height: 200, scale: 2))

        let png = try #require(board.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 300 && decoded.height == 200)
        #expect(decoded.alphaInfo != .none && decoded.alphaInfo != .noneSkipLast)

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyDPIWidth] as? Double) == 144)

        #expect(board.data(forType: .tiff) != nil)
    }
}

@MainActor
struct HotkeyTests {
    @Test func carbonModifierMapping() {
        let all = HotkeyManager.carbonModifiers([.command, .option, .control, .shift])
        #expect(all == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(HotkeyManager.carbonModifiers([]) == 0)
    }

    @Test func registersAndRejectsDuplicateCombination() throws {
        // Obscure combination so it does not collide with real apps during tests.
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_F19), modifiers: [.control, .option, .shift, .command], keyLabel: "F19")
        let first = HotkeyManager()
        let second = HotkeyManager()
        try first.register(name: "a", shortcut: shortcut) {}
        #expect(throws: HotkeyError.alreadyInUse) {
            try second.register(name: "b", shortcut: shortcut) {}
        }
        first.unregister(name: "a")
        try second.register(name: "b", shortcut: shortcut) {}  // free again
    }
}

struct ImageImportTests {
    @Test func dpiMapsToScale() {
        #expect(ImageImport.scale(forDPI: 72) == 1)
        #expect(ImageImport.scale(forDPI: 144) == 2)
        #expect(ImageImport.scale(forDPI: 216) == 3)
        #expect(ImageImport.scale(forDPI: 0) == 1)
        #expect(ImageImport.scale(forDPI: 9999) == 4)
    }

    @Test func formatFromExtension() {
        #expect(ImageFileFormat(fileExtension: "PNG") == .png)
        #expect(ImageFileFormat(fileExtension: "jpeg") == .jpeg)
        #expect(ImageFileFormat(fileExtension: "tif") == .tiff)
        #expect(ImageFileFormat(fileExtension: "webp") == nil)
    }

    @Test func savedFileLoadsBackWithSameSizeAndScale() throws {
        let ctx = CGContext(data: nil, width: 50, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let original = CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileSaver().write(original, to: url, format: .png)
        let loaded = try #require(ImageImport.load(from: url))
        #expect(loaded.pixelSize == CGSize(width: 50, height: 30))
        #expect(loaded.scale == 2)
    }
}

struct LoginItemTests {
    @Test func systemStatusesMapToOurs() {
        #expect(LoginItem.status(from: .enabled) == .enabled)
        #expect(LoginItem.status(from: .notRegistered) == .disabled)
        #expect(LoginItem.status(from: .requiresApproval) == .requiresApproval)
        #expect(LoginItem.status(from: .notFound) == .unavailable)
    }

    @Test func explanationsOnlyForCasesThatNeedOne() {
        #expect(LoginItem.explanation(for: .enabled) == nil && LoginItem.explanation(for: .disabled) == nil)
        #expect(LoginItem.explanation(for: .requiresApproval)?.contains("Login Items") == true)
        #expect(LoginItem.explanation(for: .unavailable) != nil)
    }
}
