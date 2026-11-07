import CoreGraphics
import Testing
import CoreModels
@testable import CaptureEngine

private func makeImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

private actor RecordingGrabber: ScreenGrabber {
    private(set) var lastTarget: CaptureTarget?
    private(set) var lastIncludeCursor: Bool?
    var error: CaptureError?

    func setError(_ e: CaptureError?) { error = e }

    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        lastTarget = target
        lastIncludeCursor = includeCursor
        if let error { throw error }
        return CapturedImage(cgImage: makeImage(width: 200, height: 100), scale: 2)
    }
}

struct FullScreenCaptureModeTests {
    @Test func capturesDisplayFromProvider() async throws {
        let grabber = RecordingGrabber()
        let mode = FullScreenCaptureMode(displayProvider: { 42 })
        let result = try await mode.run(CaptureContext(grabber: grabber, includeCursor: true))

        guard case .image(let image) = result else { Issue.record("expected image"); return }
        #expect(image.pixelSize == CGSize(width: 200, height: 100))
        #expect(image.pointSize == CGSize(width: 100, height: 50))
        #expect(await grabber.lastTarget == .display(42))
        #expect(await grabber.lastIncludeCursor == true)
    }

    @Test func failsWhenNoDisplay() async {
        let mode = FullScreenCaptureMode(displayProvider: { nil })
        await #expect(throws: CaptureError.noDisplayAvailable) {
            _ = try await mode.run(CaptureContext(grabber: RecordingGrabber(), includeCursor: false))
        }
    }

    @Test func propagatesGrabberErrors() async {
        let grabber = RecordingGrabber()
        await grabber.setError(.permissionDenied)
        let mode = FullScreenCaptureMode(displayProvider: { 1 })
        await #expect(throws: CaptureError.permissionDenied) {
            _ = try await mode.run(CaptureContext(grabber: grabber, includeCursor: false))
        }
    }

    @Test func defaultShortcutIsCtrlShift1() {
        #expect(FullScreenCaptureMode().defaultShortcut == .digit(1, [.control, .shift]))
    }

    @Test func pixelDimensionsRoundAndClamp() {
        #expect(pixelDimensions(pointSize: CGSize(width: 1512, height: 982), scale: 2) == (3024, 1964))
        #expect(pixelDimensions(pointSize: CGSize(width: 10.4, height: 10.6), scale: 1) == (10, 11))
        #expect(pixelDimensions(pointSize: CGSize(width: 0, height: 0), scale: 2) == (1, 1))
    }
}
