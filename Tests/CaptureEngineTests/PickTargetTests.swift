import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import CaptureEngine

struct ObjectPickModelTests {
    private func rect(_ n: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: n, height: n) }
    private func list() -> [PickCandidate] {
        [PickCandidate(kind: .element, rect: rect(10)), PickCandidate(kind: .element, rect: rect(50)),
         PickCandidate(kind: .window(9), rect: rect(100))]
    }

    @Test func startsInnermostAndWalksOutwardsAndBack() {
        var m = ObjectPickModel()
        m.update(list())
        #expect(m.current?.rect == rect(10))
        m.selectParent(); #expect(m.current?.rect == rect(50))
        m.selectParent(); #expect(m.current?.kind == .window(9))
        m.selectParent(); #expect(m.current?.kind == .window(9))      // stops at the window
        m.selectChild(); m.selectChild(); m.selectChild()
        #expect(m.current?.rect == rect(10))                           // stops at the innermost
    }

    @Test func keepsChoiceWhilePointerStaysOverSameThingButResetsOnChange() {
        var m = ObjectPickModel()
        m.update(list())
        m.selectParent()
        m.update(list())                                               // pointer moved within the same element
        #expect(m.current?.rect == rect(50))
        m.update([PickCandidate(kind: .window(3), rect: rect(77))])    // moved onto something else
        #expect(m.current?.rect == rect(77))
    }

    @Test func emptyListHasNoCurrent() {
        var m = ObjectPickModel()
        m.update([])
        #expect(m.current == nil)
        m.selectParent(); m.selectChild()
        #expect(m.current == nil)
    }
}

struct WindowHitTesterTests {
    private func win(pid: Int32, layer: Int = 0, alpha: Double = 1, rect: CGRect, number: Int) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowNumber as String: number]
    }

    @Test func picksTopmostWindowUnderPointIgnoringOverlayMenusAndTinyWindows() {
        let list = [
            win(pid: 1, rect: CGRect(x: 0, y: 0, width: 2000, height: 1200), number: 1),          // our overlay (pid 1)
            win(pid: 5, layer: 101, rect: CGRect(x: 90, y: 90, width: 200, height: 200), number: 2), // menu layer
            win(pid: 6, rect: CGRect(x: 95, y: 95, width: 5, height: 5), number: 3),               // tiny
            win(pid: 7, rect: CGRect(x: 100, y: 100, width: 400, height: 300), number: 4),         // <- topmost real window
            win(pid: 8, rect: CGRect(x: 0, y: 0, width: 1000, height: 800), number: 5),            // behind it
        ]
        let hit = WindowHitTester.topWindow(at: CGPoint(x: 120, y: 120), in: list, excludingPID: 1)
        #expect(hit?.id == 4 && hit?.pid == 7)
        #expect(hit?.bounds == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(WindowHitTester.topWindow(at: CGPoint(x: 50, y: 50), in: list, excludingPID: 1)?.id == 5)
        #expect(WindowHitTester.topWindow(at: CGPoint(x: 5000, y: 5000), in: list, excludingPID: 1) == nil)
    }

    @Test func cleanChainDropsDuplicatesTinyAndWindowSizedRects() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let a = CGRect(x: 10, y: 10, width: 100, height: 40)
        let b = CGRect(x: 5, y: 5, width: 300, height: 200)
        let chain = WindowHitTester.cleanChain([a, a, CGRect(x: 1, y: 1, width: 1, height: 1), b, window], window: window)
        #expect(chain == [a, b])
    }
}

private struct FixedFinder: PickTargetFinder {
    func candidates(at globalPoint: CGPoint) -> [PickCandidate] { [] }
}

private struct PickStub: RegionSelecting {
    let target: CaptureTarget
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget { target }
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget { target }
}

private actor SeenTargets: ScreenGrabber {
    var targets: [CaptureTarget] = []
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        targets.append(target)
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CapturedImage(cgImage: ctx.makeImage()!, scale: 2)
    }
}

struct WindowObjectCaptureModeTests {
    private let display = DisplayInfo(id: 3, frame: CGRect(x: 0, y: 0, width: 100, height: 50))

    @Test func windowChoiceIsCapturedAsAWindow() async throws {
        let grabber = SeenTargets()
        let mode = WindowObjectCaptureMode(selector: PickStub(target: .window(42)), finder: FixedFinder(),
                                           displaysProvider: { [display] in [display] })
        _ = try await mode.run(CaptureContext(grabber: grabber, includeCursor: false))
        let targets = await grabber.targets
        #expect(targets.contains(.window(42)))
        #expect(targets.contains(.display(3)))     // the snapshot taken for the overlay
    }

    @Test func elementChoiceIsCroppedFromTheSnapshot() async throws {
        let grabber = SeenTargets()
        let mode = WindowObjectCaptureMode(
            selector: PickStub(target: .rect(CGRect(x: 10, y: 10, width: 20, height: 10), display: 3)),
            finder: FixedFinder(), displaysProvider: { [display] in [display] })
        let result = try await mode.run(CaptureContext(grabber: grabber, includeCursor: false))
        guard case .image(let image) = result else { Issue.record("expected image"); return }
        #expect(image.pixelSize == CGSize(width: 40, height: 20))
        #expect(await grabber.targets.allSatisfy { if case .window = $0 { false } else { true } })
    }

    @Test func metadata() {
        let mode = WindowObjectCaptureMode()
        #expect(mode.defaultShortcut == .digit(4, [.control, .shift]))
        #expect(mode.wantsAccessibility)
        #expect(!FullScreenCaptureMode().wantsAccessibility)
    }
}
