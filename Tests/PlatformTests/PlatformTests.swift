import AppKit
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
