import CoreGraphics
import Foundation

/// A compact fingerprint of a picture: one row of coarse brightness samples per pixel row. Comparing fingerprints is
/// far cheaper than comparing pixels, and tolerant of tiny rendering noise.
public struct ScrollSignature: Sendable {
    static let columns = 48
    let rows: Int
    let cols: Int
    private let data: [UInt8]
    /// Brightest minus darkest sample of each row: near 0 means a blank (featureless) row.
    private let contrast: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w >= 8, h >= 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let cols = min(Self.columns, w)
        var data = [UInt8](repeating: 0, count: h * cols)
        var contrast = [UInt8](repeating: 0, count: h)
        for y in 0..<h {
            var lo = 255, hi = 0
            for c in 0..<cols {
                let x0 = c * w / cols, x1 = max((c + 1) * w / cols, x0 + 1)
                var sum = 0
                for x in x0..<x1 { sum += Int(pixels[y * w + x]) }
                let value = sum / (x1 - x0)
                data[y * cols + c] = UInt8(value)
                lo = min(lo, value); hi = max(hi, value)
            }
            contrast[y] = UInt8(hi - lo)
        }
        self.rows = h; self.cols = cols; self.data = data; self.contrast = contrast
    }

    /// True when row `i` here looks the same as row `j` of `other`.
    func rowMatches(_ i: Int, _ other: ScrollSignature, _ j: Int) -> Bool {
        guard cols == other.cols else { return false }
        var difference = 0
        let a = i * cols, b = j * other.cols
        for c in 0..<cols { difference += abs(Int(data[a + c]) - Int(other.data[b + c])) }
        return difference <= cols * 3
    }

    func hasContent(row: Int) -> Bool { contrast[row] > 10 }

    /// Share of columns (0...1) where this row agrees with row `j` of `other` within `tolerance` brightness levels.
    func columnAgreement(_ i: Int, _ other: ScrollSignature, _ j: Int, tolerance: Int, mask: [Bool]?) -> Double {
        var agree = 0, used = 0
        let a = i * cols, b = j * other.cols
        for c in 0..<cols where mask?[c] ?? true {
            used += 1
            if abs(Int(data[a + c]) - Int(other.data[b + c])) <= tolerance { agree += 1 }
        }
        return used == 0 ? 0 : Double(agree) / Double(used)
    }

    /// Like `rowMatches`, but only looks at the columns in `mask` (the part of the picture that actually scrolls).
    func rowMatches(_ i: Int, _ other: ScrollSignature, _ j: Int, mask: [Bool], active: Int) -> Bool {
        guard cols == other.cols, mask.count == cols else { return false }
        // A column the scroll boundary cuts through mixes fixed and moving pixels, so a few columns may disagree.
        var bad = 0
        let allowed = active / 12
        let a = i * cols, b = j * other.cols
        for c in 0..<cols where mask[c] && abs(Int(data[a + c]) - Int(other.data[b + c])) > 6 {
            bad += 1
            if bad > allowed { return false }
        }
        return true
    }

    /// Whether this row is "about the same" as row `j` of `other` at the same position, with a loose tolerance: a fixed bar that
    /// is slightly translucent (its colour shifts a little as the page scrolls behind it) still counts as fixed.
    func rowLooselyMatches(_ i: Int, _ other: ScrollSignature, _ j: Int, mask: [Bool]?, active: Int) -> Bool {
        guard cols == other.cols else { return false }
        var bad = 0
        let used = mask == nil ? cols : active
        let allowed = used / 6
        let a = i * cols, b = j * other.cols
        for c in 0..<cols where mask?[c] ?? true && abs(Int(data[a + c]) - Int(other.data[b + c])) > 18 {
            bad += 1
            if bad > allowed { return false }
        }
        return true
    }

    /// Whether the scrolling columns of this row have any detail (a blank row proves nothing when aligning).
    func hasContent(row: Int, mask: [Bool]) -> Bool {
        var lo = 255, hi = 0
        for c in 0..<cols where mask[c] {
            let v = Int(data[row * cols + c])
            lo = min(lo, v); hi = max(hi, v)
        }
        return hi - lo > 10
    }

    /// Which columns scroll. A column that looks the same at the same position in both frames is fixed (a side panel,
    /// a sticky sidebar) and must not be used to line the frames up. Nil if nothing is fixed.
    func scrollingColumns(comparedWith other: ScrollSignature) -> (mask: [Bool], active: Int)? {
        guard rows == other.rows, cols == other.cols else { return nil }
        var mask = [Bool](repeating: true, count: cols)
        var active = cols
        for c in 0..<cols {
            var same = 0
            for y in 0..<rows where abs(Int(data[y * cols + c]) - Int(other.data[y * cols + c])) <= 3 { same += 1 }
            if Double(same) / Double(rows) >= 0.85 { mask[c] = false; active -= 1 }
        }
        guard active < cols else { return nil }
        // Columns touching a fixed column are partly fixed too: leave them out.
        let original = mask
        for c in 0..<cols where original[c] {
            if (c > 0 && !original[c - 1]) || (c + 1 < cols && !original[c + 1]) { mask[c] = false; active -= 1 }
        }
        // Enough scrolling columns are needed to trust a match; otherwise compare everything.
        return active >= 4 ? (mask, active) : nil
    }

    /// Whether the rows in `range` look the same as in `other`, allowing the picture to sit up to `maxDrift` rows off.
    func sameUpperPart(as other: ScrollSignature, rows range: Range<Int>, maxDrift: Int) -> Bool {
        guard rows == other.rows else { return false }
        for drift in 0...maxDrift {
            for sign in (drift == 0 ? [0] : [-1, 1]) {
                let d = drift * sign
                var detail = 0, same = 0
                for y in range where y + d >= 0 && y + d < rows && (hasContent(row: y) || other.hasContent(row: y + d)) {
                    detail += 1
                    if rowLooselyMatches(y, other, y + d, mask: nil, active: 0) { same += 1 }
                }
                if detail >= 8, Double(same) / Double(detail) >= 0.9 { return true }
            }
        }
        return false
    }

    /// Like `similarity`, but counting only rows that carry detail in either picture. On a mostly blank page (a white
    /// document with lines of text) nearly every row is blank both before and after a scroll, so plain similarity says
    /// "unchanged" even when all the text moved; the rows with detail tell the truth.
    func contentSimilarity(to other: ScrollSignature, rows range: Range<Int>? = nil) -> Double {
        guard rows == other.rows else { return 0 }
        var detail = 0, same = 0
        for y in (range ?? 0..<rows) where hasContent(row: y) || other.hasContent(row: y) {
            detail += 1
            if rowMatches(y, other, y) { same += 1 }
        }
        return detail >= 8 ? Double(same) / Double(detail) : (range == nil ? similarity(to: other) : 1)
    }

    /// Fraction of rows that match at the same position (1 = the same picture).
    func similarity(to other: ScrollSignature) -> Double {
        guard rows == other.rows else { return 0 }
        var same = 0
        for y in 0..<rows where rowMatches(y, other, y) { same += 1 }
        return Double(same) / Double(rows)
    }
}

/// Joins screenshots of a scrolling window into one tall picture.
///
/// Each new frame is aligned to the previous one by finding how far the content moved (the shift that makes the
/// overlapping rows match). Fixed headers and footers (sticky toolbars) are detected and kept once, instead of being
/// repeated at every seam. Frames must all be the same size.
public struct ScrollStitcher {
    public enum AppendResult: Equatable, Sendable {
        /// The frame added this many new pixel rows.
        case appended(newRows: Int)
        /// Nothing moved: the end of the content was reached.
        case noChange
        /// The frame could not be aligned with the previous one (the content changed, or it jumped too far).
        case unmatched
    }

    /// Which way the content moves. Horizontal frames are turned a quarter turn so the same row-based alignment applies.
    public enum Axis: Sendable, Equatable { case vertical, horizontal }

    /// One screenshot and where it sits on the "document" (the whole page, in rows): its first row is document row `offset`.
    private struct Placed { var image: CGImage; let offset: Int }
    private var frames: [Placed] = []
    /// The tallest fixed bar seen at the top (and bottom) in any pair of frames. Fixed bars are detected unevenly from pair
    /// to pair (a translucent bar changes a little as the page moves behind it), so the largest estimate is used for every seam.
    private var headerBand = 0
    private var footerBand = 0
    private var bottomMargin = 0

    private var previous: ScrollSignature?
    private var frameSize: (width: Int, height: Int)?
    public private(set) var totalHeight = 0
    public private(set) var frameCount = 0
    /// How far (in pixels) the content moved between the last two frames added.
    public private(set) var lastShift = 0

    public let axis: Axis

    public init(axis: Axis = .vertical) { self.axis = axis }

    /// True when two frames are visibly different. `tolerance` is how much of the picture may differ and still count as
    /// "the same" (live content such as a playing video changes part of every frame).
    public static func framesDiffer(_ a: CGImage, _ b: CGImage, sameAbove: Double = 0.995) -> Bool {
        guard let x = ScrollSignature(a), let y = ScrollSignature(b) else { return true }
        return x.contentSimilarity(to: y) < sameAbove
    }

    /// How alike two frames are at the same positions, 0...1, counting only rows that have detail.
    public static func contentSimilarity(_ a: CGImage, _ b: CGImage) -> Double {
        guard let x = ScrollSignature(a), let y = ScrollSignature(b) else { return 0 }
        return x.contentSimilarity(to: y)
    }

    /// Above this share of identical rows, two frames are the same page position (only live content differs).
    static let samePositionSimilarity = 0.7

    public var width: Int { frameSize?.width ?? 0 }

    /// `bottomMargin`: rows at the bottom of each frame that are not used where frames join (the window's rounded corners).
    /// `expectedShift`: how far (in pixels) we asked the content to move. Used to choose between look-alike candidates.
    public mutating func append(_ original: CGImage, expectedShift: Int, bottomMargin: Int = 0) -> AppendResult {
        let frame = axis == .horizontal ? (original.rotatedQuarterTurn(clockwise: true) ?? original) : original
        guard let signature = ScrollSignature(frame) else { return .unmatched }
        guard let last = previous, let size = frameSize else {
            frames = [Placed(image: frame, offset: 0)]
            previous = signature
            frameSize = (frame.width, frame.height)
            totalHeight = frame.height
            frameCount = 1
            return .appended(newRows: frame.height)
        }
        guard frame.width == size.width, frame.height == size.height else { return .unmatched }

        let similarity = signature.similarity(to: last)
        if similarity >= 0.995 { return .noChange }

        var (header, footer) = Self.fixedBands(last, signature)
        // The very bottom of a window frame holds its rounded corners (and sometimes a scroll bar end): never keep it at a seam.
        footer = max(footer, bottomMargin)
        header = min(header, frame.height / 3)
        let columns = last.scrollingColumns(comparedWith: signature)
        guard let shift = Self.shift(from: last, to: signature, header: header, footer: footer, expected: expectedShift, columns: columns) else {
            // Mostly the same picture with no matching shift: live content (a video, an animation) changed, nothing scrolled.
            return signature.contentSimilarity(to: last) >= Self.samePositionSimilarity ? .noChange : .unmatched
        }

        let h = frame.height
        let nextOffset = (frames.last?.offset ?? 0) + shift
        let previousEnd = totalHeight
        headerBand = max(headerBand, min(max(header, Self.fixedTopBand(last, signature, columns: columns)), Int(Double(h) * 0.4)))
        footerBand = max(footerBand, footer)
        self.bottomMargin = max(self.bottomMargin, bottomMargin)
        frames.append(Placed(image: frame, offset: nextOffset))
        totalHeight = nextOffset + h
        previous = signature
        frameCount += 1
        lastShift = shift
        return .appended(newRows: max(totalHeight - previousEnd, 0))
    }

    /// Replaces the latest frame with a fresh picture of the SAME scroll position (taken again after the page finished
    /// loading). Only the upper part is compared to confirm it is the same place, because the lower part is exactly what
    /// may have changed (placeholders turning into content). Returns false if it is not the same place.
    public mutating func refreshLast(_ original: CGImage) -> Bool {
        let frame = axis == .horizontal ? (original.rotatedQuarterTurn(clockwise: true) ?? original) : original
        guard let signature = ScrollSignature(frame), let last = previous, let size = frameSize,
              frame.width == size.width, frame.height == size.height, !frames.isEmpty else { return false }
        // Scrolling back is never pixel-exact, so a few pixels of drift are tolerated when checking it is the same place.
        let upper = 0..<(frame.height / 4)
        guard signature.sameUpperPart(as: last, rows: upper, maxDrift: 4) else { return false }
        frames[frames.count - 1].image = frame
        previous = signature
        return true
    }

    /// The stitched picture, or nil if nothing was added.
    public func result() -> CGImage? {
        guard let tall = stitchedRows() else { return nil }
        return axis == .horizontal ? tall.rotatedQuarterTurn(clockwise: false) : tall
    }

    private func stitchedRows() -> CGImage? {
        guard let size = frameSize, totalHeight > 0 else { return nil }
        guard let context = CGContext(data: nil, width: size.width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // "Newest wins": wherever two frames overlap, the later frame supplies the picture, so a page that was still loading
        // when an earlier frame was taken (placeholders, images arriving) is replaced by what loaded next. Only the fixed bar
        // at the top of each later frame is skipped (the earlier frame already shows the page's own content there), and the
        // very bottom of each frame (window corners) is never used at a seam.
        let h = size.height
        var cuts: [Int] = [0]                                       // document row where each frame's contribution starts
        for index in 1..<max(frames.count, 1) where index < frames.count {
            let offset = frames[index].offset
            var cut = offset + headerBand
            cut = min(cut, frames[index - 1].offset + h - max(footerBand, bottomMargin))
            cut = max(cut, offset)
            cut = max(cut, (cuts.last ?? 0) + 1)
            cuts.append(cut)
        }
        for index in frames.indices {
            let start = cuts[index]
            let end = index + 1 < frames.count ? cuts[index + 1] : frames[index].offset + h
            let height = end - start
            guard height > 0, let piece = frames[index].image.cropping(to: CGRect(x: 0, y: start - frames[index].offset, width: size.width, height: height)) else { continue }
            // CGContext's origin is bottom-left; `start` counts from the top.
            context.draw(piece, in: CGRect(x: 0, y: totalHeight - start - height, width: size.width, height: height))
        }
        return context.makeImage()
    }

    // MARK: Alignment

    /// Rows at the top of `b` that stayed put compared with `a`: a fixed bar, even a slightly translucent one. Checked with the
    /// loose same-position test, so a bar whose colour shifts a little as the page scrolls behind it still counts.
    private static func fixedTopBand(_ a: ScrollSignature, _ b: ScrollSignature, columns: (mask: [Bool], active: Int)?) -> Int {
        let limit = Int(Double(b.rows) * 0.4)
        let window = 40
        var flags = [Bool](repeating: false, count: limit)
        for i in 0..<limit { flags[i] = b.rowLooselyMatches(i, a, i, mask: columns?.mask, active: columns?.active ?? 0) }
        // A bar is a dense run of fixed rows. Isolated moving rows inside it (text of a translucent bar over the changing page)
        // must not end it, so it is measured as a density over a sliding window, not as a run of consecutive rows.
        var best = 0, inWindow = 0
        for i in 0..<limit {
            if flags[i] { inWindow += 1 }
            if i >= window, flags[i - window] { inWindow -= 1 }
            let density = Double(inWindow) / Double(min(i + 1, window))
            if density >= 0.7 { best = i + 1 } else if i >= window, density < 0.35 { break }
        }
        return best >= 4 ? best : 0
    }

    /// Rows at the top and bottom that are identical in both frames: a sticky header and footer.
    private static func fixedBands(_ a: ScrollSignature, _ b: ScrollSignature) -> (header: Int, footer: Int) {
        let limit = a.rows / 3
        var header = 0
        while header < limit, a.rowMatches(header, b, header) { header += 1 }
        var footer = 0
        while footer < limit, a.rowMatches(a.rows - 1 - footer, b, b.rows - 1 - footer) { footer += 1 }
        return (header >= 4 ? header : 0, footer >= 4 ? footer : 0)
    }

    /// How the picture moved between two frames.
    public enum Motion: Equatable, Sendable {
        /// The content moved toward the start of the picture (scrolled toward the end), by `shift` pixels.
        case forward(shift: Int, score: Double)
        /// The content moved the other way (scrolled back toward the start).
        case backward(shift: Int, score: Double)
        /// Nothing scrolled (the same picture, perhaps with live content changing).
        case still
        /// The picture changed but no alignment stands out (a jump too big to overlap, or a different page).
        case unknown
    }

    /// Decides which way `to` is scrolled relative to `from` by scoring the alignment in BOTH directions and taking the clearly
    /// better one. Looking only one way can find a false match in repetitive content (lines of text), so direction is never
    /// concluded from a single weak match.
    public static func motion(from: CGImage, to: CGImage, axis: Axis, expected: Int) -> Motion {
        let a = axis == .horizontal ? (from.rotatedQuarterTurn(clockwise: true) ?? from) : from
        let b = axis == .horizontal ? (to.rotatedQuarterTurn(clockwise: true) ?? to) : to
        guard let x = ScrollSignature(a), let y = ScrollSignature(b), x.rows == y.rows else { return .unknown }
        let similarity = x.similarity(to: y)
        if similarity >= 0.995 { return .still }
        let columns = x.scrollingColumns(comparedWith: y)
        let forward = softShift(x, y, moving: movingRows(x, y, columns: columns), columns: columns, expected: expected)
        let backward = softShift(y, x, moving: movingRows(y, x, columns: columns), columns: columns, expected: expected)
        let f = forward?.score ?? 0, bk = backward?.score ?? 0
        if let forward, f >= 0.6, f >= bk + 0.1 { return .forward(shift: forward.shift, score: f) }
        if let backward, bk >= 0.6, bk >= f + 0.1 { return .backward(shift: backward.shift, score: bk) }
        return x.contentSimilarity(to: y) >= samePositionSimilarity ? .still : .unknown
    }

    /// Developer aid: the best-lining-up shifts for two frames, ignoring the acceptance thresholds.
    static func diagnose(_ a: CGImage, _ b: CGImage) -> [String] {
        guard let x = ScrollSignature(a), let y = ScrollSignature(b) else { return ["no signature"] }
        let (header, footer) = fixedBands(x, y)
        let columns = x.scrollingColumns(comparedWith: y)
        var lines = ["rows \(x.rows) header \(header) footer \(footer) dynamicColumns \(columns?.active ?? -1) of \(ScrollSignature.columns) similarity \(x.similarity(to: y))"]
        let moving = movingRows(x, y, columns: columns)
        lines.append("moving rows: \(moving.count)")
        if let best = softShift(x, y, moving: moving, columns: columns, expected: 0) {
            lines.append("soft shift \(best.shift): score \(String(format: "%.3f", best.score)) baseline \(String(format: "%.3f", best.baseline))")
        } else { lines.append("soft shift: no clear peak") }
        return lines
    }

    /// How many rows the content moved up between `a` and `b`, or nil if no shift lines the two up.
    /// Rows of `b` that carry detail and did NOT stay put compared with `a`: the part of the picture that really scrolled.
    /// Fixed bars (even slightly translucent ones), side panels and blank rows are left out, so only moving content decides.
    private static func movingRows(_ a: ScrollSignature, _ b: ScrollSignature, columns: (mask: [Bool], active: Int)?) -> [Int] {
        var rows: [Int] = []
        for i in 0..<b.rows {
            let detail = columns.map { b.hasContent(row: i, mask: $0.mask) } ?? b.hasContent(row: i)
            guard detail else { continue }
            if b.rowLooselyMatches(i, a, i, mask: columns?.mask, active: columns?.active ?? 0) { continue }
            rows.append(i)
        }
        return rows
    }

    /// Scores every possible shift by how closely the moving rows of `b` agree with `a` shifted by that much (a soft score,
    /// so a page drawn with sub-pixel blur still has a clear peak), and returns the best one if it clearly stands out.
    static func softShift(_ a: ScrollSignature, _ b: ScrollSignature, moving: [Int], columns: (mask: [Bool], active: Int)?,
                          expected: Int) -> (shift: Int, score: Double, baseline: Double)? {
        let minOverlap = max(16, a.rows / 14)
        guard moving.count >= 24, a.rows > minOverlap + 2 else { return nil }
        let samples = Array(moving.enumerated().filter { $0.offset % max(1, moving.count / 160) == 0 }.map(\.element))
        var scores: [(shift: Int, score: Double)] = []
        for s in 1...(a.rows - minOverlap) {
            var total = 0.0, n = 0.0
            for i in samples where i + s < a.rows {
                total += b.columnAgreement(i, a, i + s, tolerance: 12, mask: columns?.mask)
                n += 1
            }
            guard n >= 16 else { break }
            scores.append((s, total / n))
        }
        guard let best = scores.max(by: { $0.score < $1.score }) else { return nil }
        let baseline = scores.map(\.score).sorted()[scores.count / 2]            // what an unrelated shift typically scores
        // Near-ties (blurred copies of the same peak, or repeating content): prefer the one closest to what was asked.
        let near = scores.filter { best.score - $0.score <= 0.01 }
        let pick = near.min(by: { abs($0.shift - expected) < abs($1.shift - expected) }) ?? best
        guard best.score >= 0.5, best.score - baseline >= 0.2 else { return nil }
        return (pick.shift, best.score, baseline)
    }

    private static func shift(from a: ScrollSignature, to b: ScrollSignature, header: Int, footer: Int, expected: Int,
                              columns: (mask: [Bool], active: Int)?) -> Int? {
        func match(_ i: Int, _ j: Int) -> Bool {
            if let columns { return b.rowMatches(i, a, j, mask: columns.mask, active: columns.active) }
            return b.rowMatches(i, a, j)
        }
        func detail(_ row: Int) -> Bool { columns.map { b.hasContent(row: row, mask: $0.mask) } ?? b.hasContent(row: row) }
        // Preferred: line up only the rows that really moved. This is what makes sticky bars, translucent headers and side
        // panels harmless, whatever they look like.
        let moving = movingRows(a, b, columns: columns)
        if let best = softShift(a, b, moving: moving, columns: columns, expected: expected) { return best.shift }
        // Otherwise (very little moved, or almost no detail): the older whole-band comparison.
        let band = a.rows - header - footer
        let minOverlap = max(16, band / 12)
        guard band > minOverlap + 1 else { return nil }
        var best: (shift: Int, bucket: Int, distance: Int)?

        for s in 1...(band - minOverlap) {
            let overlap = band - s
            // Cheap test on a sample of rows first; only plausible shifts get the full comparison.
            let step = max(1, overlap / 48)
            var sampled = 0, bad = 0
            var i = header
            while i < header + overlap {
                sampled += 1
                if !match(i, i + s) { bad += 1; if bad * 2 > sampled + 8 { break } }
                i += step
            }
            guard bad * 2 <= sampled + 8, bad * 100 <= max(sampled, 1) * 45 else { continue }

            var mismatched = 0, informative = 0
            for i in header..<(header + overlap) {
                if !match(i, i + s) { mismatched += 1 }
                if detail(i) { informative += 1 }
            }
            let ratio = Double(mismatched) / Double(overlap)
            guard ratio <= 0.3, informative >= max(4, overlap / 40) else { continue }   // a blank overlap proves nothing
            let bucket = Int(ratio * 50)
            let distance = abs(s - expected)
            if best == nil || bucket < best!.bucket || (bucket == best!.bucket && distance < best!.distance) {
                best = (s, bucket, distance)
            }
        }
        return best?.shift
    }
}

extension CGImage {
    /// The picture turned 90°. (Clockwise puts the left edge at the top.)
    func rotatedQuarterTurn(clockwise: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
