import AppKit
import CoreGraphics
import CoreModels
import Foundation
import Testing
@testable import CaptureEngine

/// A pretend window onto a big page: scrolling moves the visible part, and the page ends.
private actor FakePage {
    let page: CGImage              // rows (vertical) or columns (horizontal) are unique
    let horizontal: Bool
    let view: Int                  // visible size along the scrolling direction
    var offset = 0
    init(length: Int, view: Int, horizontal: Bool, startAtEnd: Bool = false, startOffset: Int = 0) {
        self.view = view
        self.horizontal = horizontal
        var state: UInt64 = 99
        let thickness = 120
        let w = horizontal ? length : thickness, h = horizontal ? thickness : length
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<gray.count { state = state &* 6364136223846793005 &+ 1442695040888963407; gray[i] = UInt8((state >> 33) & 0xFF) }
        let provider = CGDataProvider(data: Data(gray) as CFData)!
        offset = startAtEnd ? length - view : startOffset
        page = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    func scroll(by amount: Int) {
        let length = horizontal ? page.width : page.height
        offset = min(max(offset + amount, 0), length - view)
    }
    func scrollToTop() { offset = 0 }
    func frame() -> CGImage {
        horizontal ? page.cropping(to: CGRect(x: offset, y: 0, width: view, height: page.height))!
                   : page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: view))!
    }
}

private struct PageGrabber: ScreenGrabber {
    let page: FakePage
    func capture(_ target: CaptureTarget, includeCursor: Bool) async throws -> CapturedImage {
        if case .display = target {          // the frozen snapshot behind the overlay
            let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return CapturedImage(cgImage: ctx.makeImage()!, scale: 1)
        }
        return CapturedImage(cgImage: await page.frame(), scale: 1)
    }
}

private struct PageDriver: ScrollDriving {
    let page: FakePage
    let scrollsVertically: Bool          // false: the pretend page ignores vertical scrolling (a wide, horizontal page)
    var acceptsWheel = true               // false: a page that ignores synthetic wheels but answers Page Down
    var acceptsKeys = true
    var gain = 1.0                        // how much further than asked the page really scrolls (acceleration)
    var invertedWheel = false             // true: the system flips synthetic wheel direction (natural scrolling)
    func scroll(_ axis: ScrollStitcher.Axis, method: ScrollMethod, points: Double, at point: CGPoint) async {
        if (method == .pageKey || method == .homeKey) && !acceptsKeys { return }
        if method == .homeKey { await page.scrollToTop(); return }
        let horizontalPage = await page.horizontal
        if method == .wheel && !acceptsWheel { return }
        guard (axis == .vertical) != horizontalPage else { return }
        let flips = method == .wheelReversed || (method == .wheel && invertedWheel)
        let reversedByMethod = method == .wheelReversed && invertedWheel
        await page.scroll(by: (flips && !reversedByMethod) || (method == .wheelReversed && !invertedWheel) ? -Int(points * gain) : Int(points * gain))
    }
}

private struct ClickSelector: RegionSelecting {
    func selectRegion(on snapshots: [DisplaySnapshot], kind: RegionSelectionKind) async throws -> CaptureTarget { throw CaptureError.cancelled }
    func pickTarget(on snapshots: [DisplaySnapshot], finder: any PickTargetFinder) async throws -> CaptureTarget { .window(1) }
}

/// Serialized: the "stop" request is a broadcast (the shortcut pressed again), so concurrent captures would all hear it.
@MainActor
@Suite(.serialized)
struct ScrollingCaptureModeTests {
    init() { ScrollTiming.scale = 0.2 }

    private func run(length: Int, view: Int, horizontal: Bool, wheel: Bool = true, inverted: Bool = false, gain: Double = 1, startAtEnd: Bool = false, startOffset: Int = 0) async throws -> CapturedImage {
        let page = FakePage(length: length, view: view, horizontal: horizontal, startAtEnd: startAtEnd, startOffset: startOffset)
        let bounds = horizontal ? CGRect(x: 0, y: 0, width: view, height: 120) : CGRect(x: 0, y: 0, width: 120, height: view)
        let mode = ScrollingCaptureMode(
            selector: ClickSelector(),
            displaysProvider: { [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20))] },
            driver: PageDriver(page: page, scrollsVertically: !horizontal, acceptsWheel: wheel, gain: gain, invertedWheel: inverted), requiresAccessibility: false, activatesTarget: false, usesEventTap: false, boundsProvider: { _ in bounds })
        guard case .image(let image) = try await mode.run(CaptureContext(grabber: PageGrabber(page: page), includeCursor: false)) else {
            throw CaptureError.cancelled
        }
        return image
    }

    @Test func scrollsDownAndCapturesTheWholePage() async throws {
        let image = try await run(length: 1100, view: 400, horizontal: false)
        #expect(image.cgImage.width == 120 && image.cgImage.height == 1100)
    }

    @Test func switchesToHorizontalWhenThePageOnlyScrollsSideways() async throws {
        let image = try await run(length: 1100, view: 400, horizontal: true)
        #expect(image.cgImage.width == 1100 && image.cgImage.height == 120)
    }

    @Test func fallsBackToPageDownWhenTheWheelDoesNothing() async throws {
        let image = try await run(length: 1100, view: 400, horizontal: false, wheel: false)
        #expect(image.cgImage.width == 120 && image.cgImage.height == 1100)
    }

    private func stuckMode(_ page: FakePage, height: Int) -> ScrollingCaptureMode {
        ScrollingCaptureMode(
            selector: ClickSelector(),
            displaysProvider: { [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20))] },
            driver: PageDriver(page: page, scrollsVertically: true, acceptsWheel: false, acceptsKeys: false),
            requiresAccessibility: false, activatesTarget: false, usesEventTap: false,
            boundsProvider: { _ in CGRect(x: 0, y: 0, width: 120, height: CGFloat(height)) })
    }

    private func requestStop(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            NotificationCenter.default.post(name: Notification.Name.scrollingCaptureStopRequested, object: nil)
        }
    }

    /// The reported YouTube bug: a stop request during start-up probing was ignored until probing failed.
    @Test func aStopRequestIsHonouredEvenWhileProbing() async throws {
        let page = FakePage(length: 300, view: 300, horizontal: false)          // cannot be scrolled by us
        requestStop(after: 0.6)
        let started = Date()
        guard case .image(let image) = try await stuckMode(page, height: 300).run(CaptureContext(grabber: PageGrabber(page: page), includeCursor: false)) else { return }
        #expect(Date().timeIntervalSince(started) < 2.0, "stopping took too long")
        #expect(image.cgImage.height == 300)                                     // the one picture that was taken
    }

    @Test func followsTheUsersOwnScrollingWhenAutoScrollCannotMoveTheWindow() async throws {
        let page = FakePage(length: 900, view: 400, horizontal: false)
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)                    // after the automatic attempts gave up
            for _ in 0..<4 { await page.scroll(by: 150); try? await Task.sleep(nanoseconds: 900_000_000) }
            await MainActor.run { NotificationCenter.default.post(name: Notification.Name.scrollingCaptureStopRequested, object: nil) }
        }
        guard case .image(let image) = try await stuckMode(page, height: 400).run(CaptureContext(grabber: PageGrabber(page: page), includeCursor: false)) else { return }
        #expect(image.cgImage.height == 900)                                     // all of it, as the user scrolled down to the end
    }

    @Test func triesTheOppositeWheelDirectionWhenTheSystemFlipsIt() async throws {
        let image = try await run(length: 1100, view: 400, horizontal: false, inverted: true)
        #expect(image.cgImage.width == 120 && image.cgImage.height == 1100)
    }

    @Test func copesWithAppsThatScrollFurtherThanAsked() async throws {
        let image = try await run(length: 2400, view: 400, horizontal: false, gain: 3.0)
        #expect(image.cgImage.width == 120 && image.cgImage.height == 2400)
    }

    @Test func capturesFromWhereTheUserIsEvenAtTheEndOfThePage() async throws {
        let image = try await run(length: 1100, view: 400, horizontal: false, startAtEnd: true)
        // The user was on the last screen: that is what is captured (plus, at most, a little above it from finding the direction).
        #expect(image.cgImage.width == 120)
        #expect(image.cgImage.height >= 400 && image.cgImage.height <= 400 + 160)
    }

    @Test func startsWhereTheUserWasAndRunsToTheEnd() async throws {
        for inverted in [false, true] {                                         // whichever way the system flips the wheel
            let image = try await run(length: 1500, view: 400, horizontal: false, inverted: inverted, gain: 2.0, startOffset: 600)
            // From row 600 to the end is 900 rows; finding the direction may add a little above the starting point.
            #expect(image.cgImage.height >= 900 && image.cgImage.height <= 900 + 200, "inverted=\(inverted): \(image.cgImage.height)")
        }
    }

    @Test func aWrongRememberedDirectionIsCorrectedFromTheFirstScroll() async throws {
        UserDefaults.standard.set("wheel", forKey: "scrolling.towardEnd.vertical")           // wrong for an inverted system
        let image = try await run(length: 1100, view: 400, horizontal: false, inverted: true, startOffset: 300)
        #expect(image.cgImage.height >= 800 && image.cgImage.height <= 800 + 160)
        #expect(UserDefaults.standard.string(forKey: "scrolling.towardEnd.vertical") == "wheelReversed")   // and remembered
    }
}


@MainActor
struct ScrollCaptureSessionTests {
    private func session() -> ScrollCaptureSession {
        let primary = NSScreen.screens.first?.frame.height ?? 1000
        let session = ScrollCaptureSession(bounds: CGRect(x: 100, y: 100, width: 400, height: 300))   // global coordinates, top-left origin
        session.armed = true
        _ = primary
        return session
    }
    private var inside: NSPoint { NSPoint(x: 300, y: (NSScreen.screens.first?.frame.height ?? 1000) - 250) }

    @Test func aClickOnTheWindowFinishes() {
        let s = session()
        s.handle(.leftMouseDown, keyCode: 0, location: inside)
        #expect(s.reason == .done)
    }
    @Test func aClickElsewhereIsIgnored() {
        let s = session()
        s.handle(.leftMouseDown, keyCode: 0, location: NSPoint(x: 5000, y: 5000))
        #expect(s.reason == nil)
    }
    @Test func returnFinishesAndEscapeCancels() {
        let done = session(); done.handle(.keyDown, keyCode: 36, location: .zero); #expect(done.reason == .done)
        let cancelled = session(); cancelled.handle(.keyDown, keyCode: 53, location: .zero); #expect(cancelled.reason == .cancelled)
    }
    @Test func nothingCountsBeforeItIsArmed() {
        let s = session(); s.armed = false
        s.handle(.leftMouseDown, keyCode: 0, location: inside)
        #expect(s.reason == nil)
    }
}


struct ScrollGlideTests {
    @Test func framesAddUpToExactlyTheDistance() {
        for speed in ScrollSpeed.allCases {
            for points in [7.0, 120, 613, -613] {
                #expect(ScrollGlide.deltas(points: points, speed: speed).reduce(0, +) == Int32(points), "\(speed) \(points)")
            }
        }
    }

    @Test func slowerSpeedsTakeMoreAndSmallerFrames() {
        let all = ScrollSpeed.allCases.map { ScrollGlide.deltas(points: 600, speed: $0) }      // slowest first
        for (slower, faster) in zip(all, all.dropFirst()) {
            #expect(slower.count > faster.count)
            #expect(slower.max()! <= faster.max()!)
        }
    }

    @Test func aGlideEasesInAndOutAndNeverRunsBackwards() {
        let deltas = ScrollGlide.deltas(points: 600, speed: .medium)
        #expect(deltas.allSatisfy { $0 >= 0 })
        #expect(deltas.first! < deltas[deltas.count / 2] && deltas.last! < deltas[deltas.count / 2])
    }
}

struct HUDHitTestingTests {
    private let panel = CGRect(x: 770, y: 45, width: 380, height: 64)
    private let done = CGRect(x: 310, y: 18, width: 56, height: 28), cancel = CGRect(x: 236, y: 18, width: 62, height: 28)

    @Test func theButtonsAreFoundByTheirPositionOnTheScreen() {
        #expect(HUDHitTesting.action(at: CGPoint(x: 770 + 330, y: 45 + 30), panel: panel, done: done, cancel: cancel) == .finish)
        #expect(HUDHitTesting.action(at: CGPoint(x: 770 + 260, y: 45 + 30), panel: panel, done: done, cancel: cancel) == .cancel)
    }

    @Test func otherPlacesAreNotButtons() {
        #expect(HUDHitTesting.action(at: CGPoint(x: 770 + 100, y: 45 + 30), panel: panel, done: done, cancel: cancel) == nil)   // the text
        #expect(HUDHitTesting.action(at: CGPoint(x: 100, y: 100), panel: panel, done: done, cancel: cancel) == nil)             // outside
        #expect(HUDHitTesting.action(at: CGPoint(x: 770 + 330, y: 45 + 30), panel: panel, done: .zero, cancel: .zero) == nil)    // not laid out yet
    }
}
