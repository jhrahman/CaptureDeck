import CoreGraphics
import CoreModels
import Testing
@testable import CaptureEngine

private struct StubSelector: RegionSelecting {
    let outcome: Result<CaptureTarget, CaptureError>
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget { try outcome.get() }
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget { try outcome.get() }
}

private struct SolidGrabber: ScreenGrabber {
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)   // 100x50 points
    }
}

struct RegionCaptureModeTests {
    private let display = DisplayInfo(id: 7, frame: CGRect(x: 0, y: 0, width: 100, height: 50))

    @Test func cropsSelectedRectFromSnapshotAtRetinaScale() async throws {
        let mode = RegionCaptureMode(
            selector: StubSelector(outcome: .success(.rect(CGRect(x: 10, y: 20, width: 30, height: 20), display: 7))),
            displaysProvider: { [display] in [display] })
        let result = try await mode.run(CaptureContext(grabber: SolidGrabber(), includeCursor: false))
        guard case .image(let image) = result else { Issue.record("expected image"); return }
        #expect(image.pixelSize == CGSize(width: 60, height: 40))
        #expect(image.scale == 2)
    }

    @Test func cancellationPropagates() async {
        let mode = RegionCaptureMode(
            selector: StubSelector(outcome: .failure(.cancelled)),
            displaysProvider: { [display] in [display] })
        await #expect(throws: CaptureError.cancelled) {
            _ = try await mode.run(CaptureContext(grabber: SolidGrabber(), includeCursor: false))
        }
    }

    @Test func failsWithoutDisplays() async {
        let mode = RegionCaptureMode(selector: StubSelector(outcome: .failure(.cancelled)), displaysProvider: { [] })
        await #expect(throws: CaptureError.noDisplayAvailable) {
            _ = try await mode.run(CaptureContext(grabber: SolidGrabber(), includeCursor: false))
        }
    }

    @Test func defaultShortcutIsCtrlShift2() {
        #expect(RegionCaptureMode().defaultShortcut == .digit(2, [.control, .shift]))
    }
}
