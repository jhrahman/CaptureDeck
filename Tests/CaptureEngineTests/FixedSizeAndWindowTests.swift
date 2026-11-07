import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import CaptureEngine

struct FixedSizeSelectionModelTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func rectIsCenteredOnPointerAndSizedInPixels() {
        var m = FixedSizeSelectionModel(bounds: bounds, scale: 2, sizePx: CGSize(width: 400, height: 200))
        #expect(m.selection == nil)                       // nothing until the pointer is seen
        m.move(to: CGPoint(x: 500, y: 300))
        #expect(m.selection == CGRect(x: 400, y: 250, width: 200, height: 100))   // 400x200 px = 200x100 pt
    }

    @Test func rectStaysInsideDisplayNearEdges() {
        var m = FixedSizeSelectionModel(bounds: bounds, scale: 1, sizePx: CGSize(width: 200, height: 100))
        m.move(to: CGPoint(x: 5, y: 5))
        #expect(m.selection == CGRect(x: 0, y: 0, width: 200, height: 100))
        m.move(to: CGPoint(x: 999, y: 599))
        #expect(m.selection == CGRect(x: 800, y: 500, width: 200, height: 100))
    }

    @Test func oversizedRequestIsLimitedToDisplay() {
        var m = FixedSizeSelectionModel(bounds: bounds, scale: 1, sizePx: CGSize(width: 5000, height: 5000))
        m.move(to: CGPoint(x: 500, y: 300))
        #expect(m.selection == bounds)
    }

    @Test func oddPixelSizesStayExactAndSnapToPixelGrid() throws {
        var m = FixedSizeSelectionModel(bounds: bounds, scale: 2, sizePx: CGSize(width: 801, height: 601))
        m.move(to: CGPoint(x: 500.3, y: 300.3))
        let r = try #require(m.selection)
        #expect(r.width * 2 == 801 && r.height * 2 == 601)
        #expect((r.minX * 2).truncatingRemainder(dividingBy: 1) == 0)   // origin on a whole pixel
        #expect((r.minY * 2).truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test func shiftArrowResizeAndNudge() {
        var m = FixedSizeSelectionModel(bounds: bounds, scale: 1, sizePx: CGSize(width: 100, height: 100))
        m.move(to: CGPoint(x: 500, y: 300))
        m.resize(dxPx: 5, dyPx: -10)
        #expect(m.sizePx == CGSize(width: 105, height: 90))
        m.resize(dxPx: -1000, dyPx: -1000)
        #expect(m.sizePx == CGSize(width: 1, height: 1))  // never below 1 px
        let before = m.selection
        m.nudge(dx: 10, dy: 0)
        #expect(m.selection?.minX == (before?.minX ?? 0) + 10)
    }
}

struct FixedSizeTextTests {
    @Test func parsesSingleSizes() {
        #expect(FixedSizeText.parse("800x600") == CGSize(width: 800, height: 600))
        #expect(FixedSizeText.parse(" 1280 × 720 ") == CGSize(width: 1280, height: 720))
        #expect(FixedSizeText.parse("garbage") == nil)
        #expect(FixedSizeText.parse("0x10") == nil)
        #expect(FixedSizeText.parse("99999x10") == nil)
    }

    @Test func parsesListsSkippingBadEntries() {
        let list = FixedSizeText.parseList("640x480, nope, 1280x720;1920x1080")
        #expect(list == [CGSize(width: 640, height: 480), CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080)])
        #expect(FixedSizeText.parseList("").isEmpty)
    }

    @Test func formatsRoundTrip() {
        let sizes = [CGSize(width: 640, height: 480), CGSize(width: 1280, height: 720)]
        #expect(FixedSizeText.format(sizes) == "640x480, 1280x720")
        #expect(FixedSizeText.parseList(FixedSizeText.format(sizes)) == sizes)
    }
}

private struct KindRecordingSelector: RegionSelecting {
    let box: KindBox
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget {
        await box.set(kind)
        throw CaptureError.cancelled
    }
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget {
        throw CaptureError.cancelled
    }
}
private actor KindBox { var kind: RegionSelectionKind?; func set(_ k: RegionSelectionKind) { kind = k } }

private struct FlatGrabber: ScreenGrabber {
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        let ctx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
    }
}

struct FixedSizeCaptureModeTests {
    @Test func passesFixedSizeKindAndPresetsToSelector() async {
        let box = KindBox()
        let presets = [CGSize(width: 10, height: 10)]
        let mode = FixedSizeCaptureMode(
            presets: { presets }, selector: KindRecordingSelector(box: box),
            displaysProvider: { [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 10))] })
        _ = try? await mode.run(CaptureContext(grabber: FlatGrabber(), includeCursor: false))
        #expect(await box.kind == .fixedSize(presets: presets))
    }

    @Test func defaultShortcutIsCtrlShift6() {
        #expect(FixedSizeCaptureMode().defaultShortcut == .digit(6, [.control, .shift]))
    }
}

private actor TargetRecorder: ScreenGrabber {
    var target: CaptureTarget?
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        self.target = target
        return try await FlatGrabber().capture(target, includeCursor: includeCursor)
    }
}

struct ActiveWindowTests {
    @Test func capturesWindowFromProvider() async throws {
        let grabber = TargetRecorder()
        let mode = ActiveWindowCaptureMode(windowProvider: { 99 })
        _ = try await mode.run(CaptureContext(grabber: grabber, includeCursor: false))
        #expect(await grabber.target == .window(99))
    }

    @Test func failsClearlyWhenNoWindow() async {
        let mode = ActiveWindowCaptureMode(windowProvider: { nil })
        await #expect(throws: CaptureError.self) {
            _ = try await mode.run(CaptureContext(grabber: FlatGrabber(), includeCursor: false))
        }
    }

    private func info(pid: Int32, layer: Int, alpha: Double = 1, w: Double = 800, h: Double = 600, number: Int) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: ["Width": w, "Height": h], kCGWindowNumber as String: number]
    }

    @Test func picksFrontmostNormalWindowOfTheApp() {
        let list = [
            info(pid: 5, layer: 25, number: 1),            // other app's menu bar item
            info(pid: 8, layer: 0, number: 2),             // different app
            info(pid: 7, layer: 0, w: 20, h: 20, number: 3), // tiny helper window
            info(pid: 7, layer: 8, number: 4),             // floating palette
            info(pid: 7, layer: 0, alpha: 0, number: 5),   // invisible
            info(pid: 7, layer: 0, number: 6),             // <- the one
            info(pid: 7, layer: 0, number: 7),             // behind it
        ]
        #expect(WindowLocator.pickWindow(from: list, ownerPID: 7) == 6)
        #expect(WindowLocator.pickWindow(from: list, ownerPID: 99) == nil)
    }
}
