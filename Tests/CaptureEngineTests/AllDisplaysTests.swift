import CoreGraphics
import CoreModels
import Testing
@testable import CaptureEngine

private func solid(_ w: Int, _ h: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, scale: CGFloat) -> CapturedImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return CapturedImage(cgImage: ctx.makeImage()!, scale: scale)
}

private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return data[i..<i + 4].map(Int.init)
}

struct DisplayComposerTests {
    @Test func sideBySideDisplaysAreLaidOutLeftAndRight() throws {
        // A laptop (1470x956 pt, left of the main display) and an external 1920x1080 display, tops aligned.
        let left = DisplayComposer.Piece(bounds: CGRect(x: -100, y: 0, width: 100, height: 60), image: solid(200, 120, 1, 0, 0, scale: 2))
        let right = DisplayComposer.Piece(bounds: CGRect(x: 0, y: 0, width: 160, height: 90), image: solid(320, 180, 0, 0, 1, scale: 2))
        let out = try #require(DisplayComposer.compose([left, right]))
        #expect(out.pixelSize == CGSize(width: 520, height: 180) && out.scale == 2)    // 260 x 90 pt
        #expect(rgba(out.cgImage, 50, 30) == [255, 0, 0, 255])                          // left display, red
        #expect(rgba(out.cgImage, 400, 30) == [0, 0, 255, 255])                         // right display, blue
        #expect(rgba(out.cgImage, 100, 150)[3] == 0)                                    // below the shorter left display: empty
        #expect(rgba(out.cgImage, 199, 10) == [255, 0, 0, 255] && rgba(out.cgImage, 201, 10) == [0, 0, 255, 255])   // they meet at x = 200
    }

    @Test func aDisplayAboveAnotherIsPlacedAboveIt() throws {
        let top = DisplayComposer.Piece(bounds: CGRect(x: 0, y: -50, width: 100, height: 50), image: solid(100, 50, 0, 1, 0, scale: 1))
        let bottom = DisplayComposer.Piece(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), image: solid(100, 50, 1, 0, 0, scale: 1))
        let out = try #require(DisplayComposer.compose([bottom, top]))                  // order given does not matter
        #expect(out.pixelSize == CGSize(width: 100, height: 100))
        #expect(rgba(out.cgImage, 50, 20) == [0, 255, 0, 255])                          // top display is at the top
        #expect(rgba(out.cgImage, 50, 80) == [255, 0, 0, 255])
    }

    @Test func mixedResolutionsUseTheSharpestScale() throws {
        let retina = DisplayComposer.Piece(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), image: solid(200, 100, 1, 0, 0, scale: 2))
        let normal = DisplayComposer.Piece(bounds: CGRect(x: 100, y: 0, width: 100, height: 50), image: solid(100, 50, 0, 0, 1, scale: 1))
        let out = try #require(DisplayComposer.compose([retina, normal]))
        #expect(out.scale == 2 && out.pixelSize == CGSize(width: 400, height: 100))     // the 1x display is enlarged to fit
        #expect(rgba(out.cgImage, 300, 50) == [0, 0, 255, 255])
    }

    @Test func oneDisplayIsReturnedUnchangedAndNothingGivesNil() throws {
        let image = solid(50, 40, 1, 1, 0, scale: 2)
        let one = try #require(DisplayComposer.compose([.init(bounds: CGRect(x: 0, y: 0, width: 25, height: 20), image: image)]))
        #expect(one.pixelSize == image.pixelSize)
        #expect(DisplayComposer.compose([]) == nil)
    }
}

private struct PerDisplayGrabber: ScreenGrabber {
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        guard case .display(let id) = target else { throw CaptureError.noDisplayAvailable }
        return solid(100, 50, id == 1 ? 1 : 0, 0, id == 1 ? 0 : 1, scale: 1)
    }
}

struct AllDisplaysModeTests {
    @Test func capturesEveryDisplayIntoOnePicture() async throws {
        let displays = [DisplayInfo(id: 1, frame: .zero, globalBounds: CGRect(x: 0, y: 0, width: 100, height: 50)),
                        DisplayInfo(id: 2, frame: .zero, globalBounds: CGRect(x: 100, y: 0, width: 100, height: 50))]
        let result = try await AllDisplaysCaptureMode(displaysProvider: { displays }).run(CaptureContext(grabber: PerDisplayGrabber(), includeCursor: false))
        guard case .image(let image) = result else { Issue.record("expected an image"); return }
        #expect(image.pixelSize == CGSize(width: 200, height: 50))
        #expect(rgba(image.cgImage, 50, 25) == [255, 0, 0, 255] && rgba(image.cgImage, 150, 25) == [0, 0, 255, 255])
    }

    @Test func failsWithoutDisplaysAndKeepsItsShortcut() async {
        await #expect(throws: CaptureError.noDisplayAvailable) {
            _ = try await AllDisplaysCaptureMode(displaysProvider: { [] }).run(CaptureContext(grabber: PerDisplayGrabber(), includeCursor: false))
        }
        #expect(AllDisplaysCaptureMode().defaultShortcut == .digit(9, [.control, .shift]))
    }
}

@Suite struct DisplayLabelTests {
    private let left = DisplayComposer.Piece(bounds: CGRect(x: -100, y: 0, width: 100, height: 60), image: solid(200, 120, 1, 0, 0, scale: 2))
    private let right = DisplayComposer.Piece(bounds: CGRect(x: 0, y: 0, width: 160, height: 90), image: solid(320, 180, 0, 0, 1, scale: 2))

    @Test func labelsAreLeftToRight() {
        #expect(DisplayComposer.numbering([right, left]) == [2, 1])
    }

    @Test func displaysSitApartOnAnOpaqueBackdropAndKeepTheirPixels() throws {
        let layout = DisplayComposer.framedLayout([left, right])
        #expect(layout.frames[1].minX - layout.frames[0].maxX == DisplayComposer.columnGap)     // a real gap between them
        #expect(layout.frames[0].size == left.bounds.size && layout.frames[1].size == right.bounds.size)
        let out = try #require(DisplayComposer.compose([left, right], labelled: true))
        #expect(out.pixelSize == CGSize(width: layout.size.width * 2, height: layout.size.height * 2))
        // Display interiors are untouched (the centre is clear of the rounded corners).
        for (i, expected) in [[255, 0, 0, 255], [0, 0, 255, 255]].enumerated() {
            let f = layout.frames[i]
            #expect(rgba(out.cgImage, Int(f.midX * 2), Int(f.midY * 2)) == expected)
            #expect(rgba(out.cgImage, Int(f.minX * 2) + 40, Int(f.minY * 2) + 40) == expected)
        }
        // Backdrop is opaque everywhere, including the gap and the label area.
        #expect(rgba(out.cgImage, 2, 2)[3] == 255)
        let gapX = Int((layout.frames[0].maxX + DisplayComposer.columnGap / 2) * 2)
        #expect(rgba(out.cgImage, gapX, 60)[3] == 255)
        #expect(rgba(out.cgImage, gapX, 60) != [255, 0, 0, 255] && rgba(out.cgImage, gapX, 60) != [0, 0, 255, 255])
    }

    @Test func stackedDisplaysGetRoomForTheirLabels() {
        let top = DisplayComposer.Piece(bounds: CGRect(x: 0, y: -50, width: 100, height: 50), image: solid(100, 50, 0, 1, 0, scale: 1))
        let bottom = DisplayComposer.Piece(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), image: solid(100, 50, 1, 0, 0, scale: 1))
        let layout = DisplayComposer.framedLayout([top, bottom])
        #expect(layout.frames[1].minY - layout.frames[0].maxY == DisplayComposer.rowGap)
        #expect(layout.frames[0].minX == layout.frames[1].minX)                                  // still one column
    }
}
