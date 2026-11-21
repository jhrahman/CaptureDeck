import Foundation
import CoreGraphics
import Testing
@testable import CaptureEngine

struct ScrollStitcherTests {
    /// A tall picture whose every row is different (so alignment is unambiguous).
    private static func page(width: Int = 120, height: Int, seed: UInt64 = 7) -> [[UInt8]] {
        var state = seed
        return (0..<height).map { _ in
            (0..<width).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8((state >> 33) & 0xFF)
            }
        }
    }

    private static func image(_ rows: [[UInt8]]) -> CGImage {
        let w = rows[0].count, h = rows.count
        var gray = rows.flatMap { $0 }
        let provider = CGDataProvider(data: Data(bytes: &gray, count: gray.count) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func rows(of image: CGImage) -> [[UInt8]] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (0..<h).map { Array(pixels[$0 * w..<($0 + 1) * w]) }
    }

    private func closeEnough(_ a: [[UInt8]], _ b: [[UInt8]]) -> Bool {
        guard a.count == b.count else { return false }
        let bad = zip(a, b).filter { x, y in zip(x, y).contains { abs(Int($0) - Int($1)) > 3 } }.count
        return bad <= a.count / 100
    }

    @Test func stitchesScrolledFramesIntoTheOriginalPage() {
        let page = Self.page(height: 1500)
        var stitcher = ScrollStitcher()
        for offset in [0, 240, 480, 720, 960, 1100] {          // the last step is shorter: the end of the page
            let frame = Self.image(Array(page[offset..<offset + 400]))
            let result = stitcher.append(frame, expectedShift: 240)
            #expect(result != .unmatched && result != .noChange)
        }
        let stitched = try! #require(stitcher.result())
        #expect(stitched.height == 1500)
        #expect(closeEnough(Self.rows(of: stitched), page))
    }

    @Test func reportsTheEndWhenNothingMoves() {
        let page = Self.page(height: 600)
        var stitcher = ScrollStitcher()
        let frame = Self.image(Array(page[200..<600]))
        _ = stitcher.append(frame, expectedShift: 240)
        #expect(stitcher.append(frame, expectedShift: 240) == .noChange)
        #expect(stitcher.totalHeight == 400)
    }

    @Test func keepsAStickyHeaderAndFooterOnce() {
        let header = Self.page(height: 40, seed: 11), footer = Self.page(height: 30, seed: 13)
        let content = Self.page(height: 1500, seed: 17)
        func frame(_ offset: Int) -> CGImage { Self.image(header + Array(content[offset..<offset + 330]) + footer) }
        var stitcher = ScrollStitcher()
        for offset in [0, 200, 400, 600, 800, 1000, 1170] { _ = stitcher.append(frame(offset), expectedShift: 200) }
        let stitched = try! #require(stitcher.result())
        #expect(stitched.height == 40 + 1500 + 30)
        #expect(closeEnough(Self.rows(of: stitched), header + content + footer))
    }

    @Test func refusesFramesThatDoNotLineUp() {
        var stitcher = ScrollStitcher()
        _ = stitcher.append(Self.image(Self.page(height: 400, seed: 1)), expectedShift: 200)
        #expect(stitcher.append(Self.image(Self.page(height: 400, seed: 2)), expectedShift: 200) == .unmatched)
    }

    @Test func stitchesHorizontalScrollingToo() throws {
        let page = Self.page(height: 1200)                      // rows of this page become columns below
        var stitcher = ScrollStitcher(axis: .horizontal)
        for offset in [0, 240, 480, 720, 800] {
            let tall = Self.image(Array(page[offset..<offset + 400]))
            let wide = try #require(tall.rotatedQuarterTurn(clockwise: false))      // a 400-wide, 120-high frame
            #expect(wide.width == 400 && wide.height == 120)
            let result = stitcher.append(wide, expectedShift: 240)
            #expect(result != .unmatched && result != .noChange)
        }
        let stitched = try #require(stitcher.result())
        #expect(stitched.width == 1200 && stitched.height == 120)
        let back = try #require(stitched.rotatedQuarterTurn(clockwise: true))
        #expect(closeEnough(Self.rows(of: back), page))
    }

    /// Like Facebook or YouTube: fixed panels left and right, only the middle column scrolls.
    @Test func ignoresFixedSidePanels() {
        let left = Self.page(width: 40, height: 400, seed: 21), right = Self.page(width: 40, height: 400, seed: 23)
        let middle = Self.page(width: 120, height: 1500, seed: 29)
        func frame(_ offset: Int) -> CGImage {
            let rows = (0..<400).map { left[$0] + middle[offset + $0] + right[$0] }
            return Self.image(rows)
        }
        var stitcher = ScrollStitcher()
        for offset in [0, 240, 480, 720, 960, 1100] {
            let result = stitcher.append(frame(offset), expectedShift: 240)
            #expect(result != .unmatched && result != .noChange)
        }
        let stitched = try! #require(stitcher.result())
        #expect(stitched.height == 1500)
        // The scrolling column (the middle 120 pixels) must be the original page, whatever the panels look like.
        let got = Self.rows(of: stitched).map { Array($0[40..<160]) }
        #expect(closeEnough(got, middle))
    }

    /// Every frame ends in its own rounded corners: only the very last frame's may remain in the result.
    @Test func dropsEachFramesBottomEdgeAtSeams() {
        let content = Self.page(height: 1000, seed: 31)
        func frame(_ offset: Int, seed: UInt64) -> CGImage { Self.image(Array(content[offset..<offset + 388]) + Self.page(height: 12, seed: seed)) }
        var stitcher = ScrollStitcher()
        for (n, offset) in [0, 200, 400, 612].enumerated() { _ = stitcher.append(frame(offset, seed: UInt64(100 + n)), expectedShift: 200, bottomMargin: 12) }
        let stitched = try! #require(stitcher.result())
        #expect(stitched.height == 1000 + 12)                    // all the content, plus the last frame's own bottom edge
        #expect(closeEnough(Array(Self.rows(of: stitched)[0..<1000]), content))
    }

    /// A playing video: one block of the picture changes every frame, scrolling or not.
    private func withVideo(_ rows: [[UInt8]], seed: UInt64) -> [[UInt8]] {
        var result = rows
        let video = Self.page(width: rows[0].count, height: 30, seed: seed)
        for i in 0..<30 { result[120 + i] = video[i] }
        return result
    }

    @Test func liveContentDoesNotBreakTheJoin() {
        let page = Self.page(height: 1500, seed: 41)
        var stitcher = ScrollStitcher()
        for (n, offset) in [0, 150, 300, 450, 600, 750, 900, 1050, 1100].enumerated() {
            let result = stitcher.append(Self.image(withVideo(Array(page[offset..<offset + 400]), seed: UInt64(500 + n))), expectedShift: 150)
            #expect(result != .unmatched && result != .noChange)
        }
        #expect(stitcher.result()?.height == 1500)
    }

    @Test func aChangingVideoAloneIsNotAScroll() {
        let page = Self.page(height: 600, seed: 43)
        var stitcher = ScrollStitcher()
        _ = stitcher.append(Self.image(withVideo(Array(page[0..<400]), seed: 1)), expectedShift: 240)
        #expect(stitcher.append(Self.image(withVideo(Array(page[0..<400]), seed: 2)), expectedShift: 240) == .noChange)
    }

    /// Text-like content: thin lines of detail separated by blank rows (easy to match falsely at a wrong shift).
    private static func textPage(height: Int, seed: UInt64) -> [[UInt8]] {
        let base = page(width: 120, height: height, seed: seed)
        return base.enumerated().map { index, row in index % 20 < 8 ? row : [UInt8](repeating: 250, count: row.count) }
    }

    @Test func directionIsDecidedByTheBetterOfBothAlignments() {
        let page = Self.textPage(height: 1500, seed: 51)
        let upper = Self.image(Array(page[200..<600])), lower = Self.image(Array(page[380..<780]))
        guard case .forward(let shift, _) = ScrollStitcher.motion(from: upper, to: lower, axis: .vertical, expected: 160) else {
            Issue.record("scrolling toward the end was not recognised"); return
        }
        #expect(shift == 180)
        guard case .backward(let back, _) = ScrollStitcher.motion(from: lower, to: upper, axis: .vertical, expected: 160) else {
            Issue.record("scrolling back was not recognised"); return
        }
        #expect(back == 180)
        #expect(ScrollStitcher.motion(from: upper, to: upper, axis: .vertical, expected: 160) == .still)
    }

    /// A mostly blank page: scrolling moves all the text, yet nearly every row is blank both before and after.
    @Test func aScrollOnABlankPageIsNotMistakenForNoMovement() {
        let page = Self.textPage(height: 1500, seed: 61)
        let before = Self.image(Array(page[300..<700])), after = Self.image(Array(page[360..<760]))      // scrolled by 60 rows
        #expect(ScrollStitcher.framesDiffer(before, after))
        guard case .forward = ScrollStitcher.motion(from: before, to: after, axis: .vertical, expected: 60) else {
            Issue.record("the scroll was not recognised as movement"); return
        }
    }

    /// A lazily loaded page: placeholders where content has not arrived yet. The later frame has the real content.
    @Test func laterFramesReplaceContentThatWasStillLoading() {
        let page = Self.page(height: 1400, seed: 71)
        let placeholder = [UInt8](repeating: 90, count: 120)
        func frame(_ offset: Int, loadingRows: Range<Int>) -> CGImage {
            var rows = Array(page[offset..<offset + 400])
            for i in loadingRows { rows[i] = placeholder }
            return Self.image(rows)
        }
        var stitcher = ScrollStitcher()
        _ = stitcher.append(frame(0, loadingRows: 330..<400), expectedShift: 250)       // bottom of the first frame still loading
        _ = stitcher.append(frame(250, loadingRows: 0..<0), expectedShift: 250)
        _ = stitcher.append(frame(500, loadingRows: 0..<0), expectedShift: 250)
        let stitched = try! #require(stitcher.result())
        #expect(stitched.height == 900)
        #expect(closeEnough(Array(Self.rows(of: stitched)[0..<900]), Array(page[0..<900])))        // no placeholder survives
    }

    /// The reported YouTube case: the previous frame's lower half was placeholders, so the next one cannot match it until the
    /// previous one is retaken after loading.
    @Test func aFrameTakenWhileLoadingCanBeRetakenAndThenJoined() {
        let page = Self.page(height: 1400, seed: 81)
        let placeholder = [UInt8](repeating: 90, count: 120)
        var loading = Array(page[0..<400])
        for i in 120..<400 { loading[i] = placeholder }                 // everything below the top 30% was still loading
        var stitcher = ScrollStitcher()
        _ = stitcher.append(Self.image(loading), expectedShift: 250)
        let next = Self.image(Array(page[250..<650]))
        let firstTry = stitcher.append(next, expectedShift: 250)
        #expect(firstTry == .unmatched)                                              // cannot join to placeholders
        let retaken = stitcher.refreshLast(Self.image(Array(page[0..<400])))
        #expect(retaken)                                                              // the same place, now loaded
        guard case .appended = stitcher.append(next, expectedShift: 250) else { Issue.record("still does not join"); return }
        #expect(closeEnough(Array(Self.rows(of: stitcher.result()!)[0..<650]), Array(page[0..<650])))
        let elsewhere = stitcher.refreshLast(Self.image(Array(page[700..<1100])))
        #expect(!elsewhere)                                                           // a different place is refused
    }

    /// A sticky bar that is not perfectly still: some of its rows change with the page behind it. It must still be kept
    /// once, at the top, and never reappear at a seam.
    @Test func aNotQuiteStillStickyBarIsNotRepeatedAtSeams() {
        let header = Self.page(height: 80, seed: 91)
        let content = Self.page(height: 1500, seed: 93)
        func frame(_ offset: Int, _ n: Int) -> CGImage {
            var bar = header
            for i in stride(from: 3, to: 80, by: 7) { bar[i] = Self.page(width: 120, height: 1, seed: UInt64(1000 + n * 100 + i))[0] }   // every 7th row differs
            return Self.image(bar + Array(content[offset..<offset + 320]))
        }
        var stitcher = ScrollStitcher()
        for (n, offset) in [0, 200, 400, 600, 800, 1000, 1180].enumerated() { _ = stitcher.append(frame(offset, n), expectedShift: 200) }
        let stitched = try! #require(stitcher.result())
        #expect(stitched.height == 80 + 1500)
        let rows = Self.rows(of: stitched)
        #expect(closeEnough(Array(rows[80..<1580]), content), "the page content must run on without any bar repeated")
    }
}
