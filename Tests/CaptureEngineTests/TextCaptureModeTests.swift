import CoreGraphics
import CoreModels
import Testing
@testable import CaptureEngine

private struct SolidGrabber: ScreenGrabber {
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        #expect(!includeCursor, "the pointer would cover the words being read")
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: context.makeImage()!, scale: 2)
    }
}

private struct BoxSelector: RegionSelecting {
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget {
        .rect(CGRect(x: 10, y: 20, width: 50, height: 30), display: 1)
    }
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget { throw CaptureError.cancelled }
}

struct TextCaptureModeTests {
    @Test func theSelectedAreaComesBackAsATextSourceNotAPicture() async throws {
        let mode = TextCaptureMode(selector: BoxSelector(), displaysProvider: { [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 150))] })
        let result = try await mode.run(CaptureContext(grabber: SolidGrabber(), includeCursor: true))
        guard case .textSource(let image) = result else { Issue.record("expected a text source"); return }
        #expect(image.cgImage.width == 100 && image.cgImage.height == 60)
        #expect(mode.defaultShortcut?.displayString == "⌃⇧T")
    }
}
