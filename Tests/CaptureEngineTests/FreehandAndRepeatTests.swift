import CoreGraphics
import CoreModels
import Testing
@testable import CaptureEngine

struct FreehandSelectionModelTests {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)

    @Test func collectsPointsSkipsJitterAndClampsToDisplay() {
        var m = FreehandSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 10, y: 10))
        m.add(CGPoint(x: 10.3, y: 10.2))         // under 1 pt away: ignored
        m.add(CGPoint(x: 100, y: 10))
        m.add(CGPoint(x: 9999, y: 9999))         // clamped to the corner
        #expect(m.points == [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10), CGPoint(x: 500, y: 300)])
        #expect(m.boundingRect == CGRect(x: 10, y: 10, width: 490, height: 290))
    }

    @Test func endReturnsOutlineWhenLargeEnough() {
        var m = FreehandSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 10, y: 10))
        m.add(CGPoint(x: 60, y: 10))
        m.add(CGPoint(x: 60, y: 60))
        #expect(m.end(at: CGPoint(x: 10, y: 60))?.count == 4)
        #expect(m.phase == .idle)
        #expect(m.points.isEmpty)
    }

    @Test func tinyOrStraightScribblesAreRejected() {
        var m = FreehandSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 10, y: 10))
        #expect(m.end(at: CGPoint(x: 10, y: 10)) == nil)          // a click
        m.begin(at: CGPoint(x: 10, y: 10))
        m.add(CGPoint(x: 50, y: 10)); m.add(CGPoint(x: 90, y: 10))
        #expect(m.confirm() == nil)                                // a straight line has no area (height 0)
    }

    @Test func resetClears() {
        var m = FreehandSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 1, y: 1)); m.add(CGPoint(x: 20, y: 20))
        m.reset()
        #expect(m.points.isEmpty && m.boundingRect == nil && m.confirm() == nil)
    }
}

private struct OutlineStub: RegionSelecting {
    let target: CaptureTarget
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget { target }
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget { target }
}

private actor Grabs: ScreenGrabber {
    var targets: [CaptureTarget] = []
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        targets.append(target)
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
    }
}

struct FreehandCaptureModeTests {
    private let display = DisplayInfo(id: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 50))

    @Test func producesMaskedBoundingBoxAndRemembersOutline() async throws {
        let outline = [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 25, y: 30)]
        let mode = FreehandCaptureMode(selector: OutlineStub(target: .polygon(outline, display: 2)),
                                       displaysProvider: { [display] in [display] })
        let result = try await mode.run(CaptureContext(grabber: Grabs(), includeCursor: false))
        guard case .image(let image) = result else { Issue.record("expected image"); return }
        #expect(image.pixelSize == CGSize(width: 60, height: 40))        // 30 x 20 pt at 2x
        #expect(image.source == .polygon(outline, display: 2))
    }

    @Test func shortcut() { #expect(FreehandCaptureMode().defaultShortcut == .digit(5, [.control, .shift])) }
}

struct RepeatLastTests {
    @Test func repeatsStoredTargetLive() async throws {
        let store = LastCaptureStore()
        store.target = .window(77)
        let grabs = Grabs()
        let result = try await RepeatLastCaptureMode(store: store).run(CaptureContext(grabber: grabs, includeCursor: false))
        #expect(await grabs.targets == [.window(77)])
        guard case .image(let image) = result else { Issue.record("expected image"); return }
        #expect(image.source == .window(77))                               // stays repeatable
    }

    @Test func explainsWhenThereIsNothingToRepeat() async {
        await #expect(throws: CaptureError.self) {
            _ = try await RepeatLastCaptureMode(store: LastCaptureStore()).run(CaptureContext(grabber: Grabs(), includeCursor: false))
        }
    }

    @Test func regionAndFullScreenResultsRecordTheirSource() async throws {
        let display = DisplayInfo(id: 9, frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        let rect = CGRect(x: 5, y: 5, width: 20, height: 10)
        let region = RegionCaptureMode(selector: OutlineStub(target: .rect(rect, display: 9)), displaysProvider: { [display] in [display] })
        guard case .image(let a) = try await region.run(CaptureContext(grabber: Grabs(), includeCursor: false)) else { return }
        #expect(a.source == .rect(rect, display: 9))
        guard case .image(let b) = try await FullScreenCaptureMode(displayProvider: { 9 }).run(CaptureContext(grabber: Grabs(), includeCursor: false)) else { return }
        #expect(b.source == .display(9))
    }
}
