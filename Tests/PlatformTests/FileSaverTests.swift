import CoreGraphics
import CoreModels
import Foundation
import ImageIO
import Testing
@testable import Platform

private func image(alpha: CGFloat = 1) -> CapturedImage {
    let ctx = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
    ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
    return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
}

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("capturedeck-tests-\(UUID().uuidString)")
}

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let date = Date(timeIntervalSince1970: 1_794_000_000)   // 2026-11-06 21:20:00 UTC

struct FilenameTemplateTests {
    @Test func replacesDateTokens() {
        let name = FilenameTemplate.render("Shot $Y-$M-$D at $h.$m.$s", date: date, calendar: utc)
        #expect(name == "Shot 2026-11-06 at 21.20.00")
    }

    @Test func sequenceIsPaddedToTheNumberOfHashes() {
        #expect(FilenameTemplate.render("img_####", date: date, sequence: 7, calendar: utc) == "img_0007")
        #expect(FilenameTemplate.render("a#b", date: date, sequence: 12, calendar: utc) == "a12b")
    }

    @Test func unknownTokensAndUnsafeCharactersAreHandled() {
        #expect(FilenameTemplate.render("a/b:c $Q", date: date, calendar: utc) == "a-b-c $Q")
        #expect(FilenameTemplate.render("", date: date, calendar: utc) == "Screenshot")
        #expect(FilenameTemplate.render("..hidden", date: date, calendar: utc) == "hidden")
        #expect(FilenameTemplate.render("price$", date: date, calendar: utc) == "price$")
    }
}

struct FileSaverTests {
    @Test func savesPngAtFullResolutionWithDpi() throws {
        let folder = tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = try FileSaver().save(image(), to: folder.appendingPathComponent("nested/dir"), template: "t $Y", format: .png, date: date)
        #expect(url.pathExtension == "png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 30 && decoded.height == 20)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyDPIWidth] as? Double) == 144)
    }

    @Test func neverOverwritesAndNumbersClashes() throws {
        let folder = tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let saver = FileSaver()
        let a = try saver.save(image(), to: folder, template: "same", format: .png, date: date)
        let b = try saver.save(image(), to: folder, template: "same", format: .png, date: date)
        let c = try saver.save(image(), to: folder, template: "same", format: .png, date: date)
        #expect([a, b, c].map(\.lastPathComponent) == ["same.png", "same 2.png", "same 3.png"])
    }

    @Test func sequenceTemplatesCountUp() throws {
        let folder = tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let names = try (0..<3).map { _ in
            try FileSaver().save(image(), to: folder, template: "cap_###", format: .jpeg, date: date).lastPathComponent
        }
        #expect(names == ["cap_001.jpg", "cap_002.jpg", "cap_003.jpg"])
    }

    @Test func jpegIsFlattenedOntoWhite() throws {
        let folder = tempFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = try FileSaver().save(image(alpha: 0), to: folder, template: "clear", format: .jpeg, date: date)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        #expect(px[0] > 240 && px[1] > 240 && px[2] > 240)    // transparent became white, not black
    }
}
