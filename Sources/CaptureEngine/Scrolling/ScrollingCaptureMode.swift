import AppKit
import ApplicationServices
import CoreGraphics
import CoreModels
import ImageIO

/// Captures a whole scrolling window as one tall (or wide) picture.
///
/// 1. The shortcut freezes every screen and frames the window under the pointer in red (it follows the pointer from
///    screen to screen).
/// 2. Click the window: it starts scrolling by itself. The direction is found by trying: down first, then to the right,
///    so it follows however the page is built.
/// 3. Click the window again (or press Return / Done) to finish; Esc cancels. It also stops by itself at the end of the
///    content. The stitched picture then goes through the usual steps (clipboard, file, editor).
public struct ScrollingCaptureMode: CaptureMode {
    public let id = "scrollingWindow"
    public let title = "Capture Scrolling Window"
    public let defaultShortcut: KeyShortcut? = KeyShortcut(keyCode: 0x01, modifiers: [.control, .shift], keyLabel: "S")
    public let wantsAccessibility = true

    /// Safety limits so a never-ending page (an endless feed) cannot use up memory.
    static let maxLength = 30_000
    static let maxFrames = 120

    private let windowFinder: (any PickTargetFinder)?
    private let selector: any RegionSelecting
    private let displaysProvider: @Sendable () async -> [DisplayInfo]
    private let driver: any ScrollDriving
    private let requiresAccessibility: Bool
    private let activatesTarget: Bool
    private let usesEventTap: Bool
    private let boundsProvider: @Sendable (CGWindowID) -> CGRect?

    public init(
        windowFinder: (any PickTargetFinder)? = nil,
        selector: any RegionSelecting = RegionSelector(),
        displaysProvider: @escaping @Sendable () async -> [DisplayInfo] = DisplayLocator.allDisplays,
        driver: any ScrollDriving = EventScrollDriver(),
        requiresAccessibility: Bool = true,
        activatesTarget: Bool = true,
        usesEventTap: Bool = true,
        boundsProvider: @escaping @Sendable (CGWindowID) -> CGRect? = WindowLocator.bounds(of:)
    ) {
        self.windowFinder = windowFinder
        self.selector = selector
        self.displaysProvider = displaysProvider
        self.driver = driver
        self.requiresAccessibility = requiresAccessibility
        self.boundsProvider = boundsProvider
        self.activatesTarget = activatesTarget
        self.usesEventTap = usesEventTap
    }

    public func run(_ context: CaptureContext) async throws -> CaptureResult {
        if requiresAccessibility, !AXIsProcessTrusted() {
            throw CaptureError.captureFailed("Scrolling capture needs the Accessibility permission, so it can scroll the window for you.\n\nEnable CaptureDeck in System Settings > Privacy & Security > Accessibility, then try again.")
        }
        // Step 1: freeze the screens and frame the window under the pointer, on whichever display it is on.
        // Move the pointer to another screen and the frame follows; click to choose.
        let snapshots = try await SnapshotRegionCapture.snapshots(context, displaysProvider: displaysProvider)
        let finder = windowFinder ?? WindowOnlyFinder(hint: "Click a window to start scrolling capture   Esc cancel")
        guard case .window(let windowID) = try await selector.pickTarget(on: snapshots, finder: finder) else {
            throw CaptureError.cancelled
        }
        if activatesTarget { await Self.bringToFront(windowID) }
        let bounds = boundsProvider(windowID) ?? .zero
        guard bounds.width >= 50, bounds.height >= 50 else { throw CaptureError.captureFailed("That window is too small to capture.") }

        // Step 2: scroll and stitch until the user stops it, or the content ends.
        let useTap = usesEventTap
        let session = await MainActor.run { ScrollCaptureSession(bounds: bounds, usesEventTap: useTap) }
        await MainActor.run { session.start() }
        do {
            let image = try await scrollAndStitch(windowID: windowID, bounds: bounds, session: session, context: context)
            await MainActor.run { session.stop() }
            return .image(image)
        } catch {
            await MainActor.run { session.stop() }
            throw error
        }
    }

    /// Makes the chosen window's app the active one, so keys (and the first scroll) reach it. A window that is merely visible
    /// beside the active app ignores synthetic keys and, in some apps, synthetic wheels.
    private static func bringToFront(_ windowID: CGWindowID) async {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return }
        await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]) }
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    /// Thrown inside the engine when the user asked to finish: whatever has been captured so far is the result.
    private struct FinishRequested: Error {}

    private func scrollAndStitch(windowID: CGWindowID, bounds: CGRect, session: ScrollCaptureSession, context: CaptureContext) async throws -> CapturedImage {
        let target = CaptureTarget.window(windowID)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let debug = ScrollDebugDump()
        let memory = ScrollDirectionMemory()
        let pace = ScrollTiming.scale
        let margin: (Double) -> Int = { Int((22 * $0).rounded()) }

        func grab() async throws -> CapturedImage { try await context.grabber.capture(target, includeCursor: false) }

        /// Every stage calls this: the user's stop must work during start-up probing as much as during scrolling.
        func checkStop() async throws {
            switch await MainActor.run(body: { session.reason }) {
            case .cancelled: throw CaptureError.cancelled
            case .done: throw FinishRequested()
            case nil: break
            }
        }

        /// Waits until the window has stopped moving AND finished loading. Two captures in a row that are practically
        /// identical mean it is done. If something keeps changing (a playing video), the page is accepted once it has not
        /// moved for a moment, so live content cannot hold the capture up. Needs at least `minimum` seconds, because right
        /// after a scroll the window can still look unchanged.
        func settledFrame(minimum: TimeInterval = 0.1) async throws -> CapturedImage {
            let started = Date()
            try? await Task.sleep(nanoseconds: UInt64(40_000_000 * pace))
            var last = try await grab()
            for _ in 0..<60 {
                try await checkStop()
                try? await Task.sleep(nanoseconds: UInt64(50_000_000 * pace))
                let next = try await grab()
                let similarity = ScrollStitcher.contentSimilarity(last.cgImage, next.cgImage)
                last = next
                let elapsed = Date().timeIntervalSince(started)
                if similarity >= 0.985, elapsed >= minimum * pace { break }                         // finished: nothing changes
                if similarity >= ScrollStitcher.samePositionSimilarity, elapsed >= (minimum + 0.7) * pace { break }   // live content only
            }
            return last
        }

        let first = try await grab()
        let scale = first.scale
        debug.save(first.cgImage, name: "frame-0")
        // The mouse pointer is left alone: it stays free for the Done and Cancel buttons, or a second click on the window.
        await driver.begin(windowID: windowID, bounds: bounds, speed: context.scrollSpeed) {
            await MainActor.run { session.reason != nil }
        }

        var stitcher = ScrollStitcher()
        var axis = ScrollStitcher.Axis.vertical
        var foundAxis = ScrollStitcher.Axis.vertical
        var base = first                                    // the latest picture of the window seen
        do {
            try await checkStop()
            // Step 3: find how this window scrolls, in two phases, judging every move by whether the new picture lines up
            // with the old one *geometrically* (that tells scrolling toward the end from scrolling back, and from live content).
            //   Phase 1: find which wheel direction moves toward the end (a tiny scroll; the capture starts wherever the user was).
            //   Phase 2: scroll toward the end by a small, measured amount (this also calibrates the speed).
            var method = ScrollMethod.wheel
            var step = 0.0
            var carriedAsk = 0.0                  // distance already scrolled toward the end while finding the direction
            var calibrationAsked = 0.0
            var directionFrame: CapturedImage?        // the picture right after the direction probe, if that moved toward the end
            var found = false

            func classify(_ axis: ScrollStitcher.Axis, _ from: CapturedImage, _ to: CapturedImage, asked: Double) -> (ScrollStitcher.Motion, ScrollStitcher?) {
                let expectedPx = Int((asked * Double(scale)).rounded())
                let motion = ScrollStitcher.motion(from: from.cgImage, to: to.cgImage, axis: axis, expected: expectedPx)
                guard case .forward = motion else { return (motion, nil) }
                var joined = ScrollStitcher(axis: axis)
                _ = joined.append(from.cgImage, expectedShift: expectedPx, bottomMargin: margin(scale))
                guard case .appended = joined.append(to.cgImage, expectedShift: expectedPx, bottomMargin: margin(scale)) else { return (.unknown, nil) }
                return (motion, joined)
            }

            /// Phase 0: which wheel method moves toward the end on this Mac? Decided ONCE, from a small scroll (so the two
            /// pictures overlap a lot and the verdict is clear), by scoring both directions. Returns nil if this axis does
            /// not scroll at all.
            func findDirection(_ axis: ScrollStitcher.Axis) async throws -> ScrollMethod? {
                var guess = memory.towardEnd(axis)
                let size = Double(axis == .vertical ? bounds.height : bounds.width)
                for attempt in 0..<2 {                                      // the guess first, then the opposite
                    try await checkStop()
                    await driver.scroll(axis, method: guess, points: size * 0.12, at: center)
                    let frame = try await settledFrame()
                    let (motion, _) = classify(axis, base, frame, asked: size * 0.12)
                    debug.log("direction \(axis) \(guess): \(motion)")
                    switch motion {
                    case .forward:
                        // `base` stays the picture the user started on, so the capture begins exactly where they were; the
                        // distance of this first scroll is remembered so the speed is still measured correctly.
                        carriedAsk = size * 0.12
                        directionFrame = frame
                        memory.learn(axis, towardEnd: guess)
                        return guess
                    case .backward:                                         // that method goes toward the START
                        base = frame
                        memory.learn(axis, towardEnd: ScrollDirectionMemory.opposite(of: guess))
                        return ScrollDirectionMemory.opposite(of: guess)
                    case .still:
                        // Could not move that way: either the end of the content, or the wrong axis, or the wrong sign.
                        if attempt == 0 { guess = ScrollDirectionMemory.opposite(of: guess) }
                    case .unknown:
                        base = frame
                        if attempt == 0 { guess = ScrollDirectionMemory.opposite(of: guess) }
                    }
                }
                return nil
            }

            /// Phase 2: one measured scroll toward the end, which also calibrates the speed.
            func probeForward(_ axis: ScrollStitcher.Axis, method tryMethod: ScrollMethod) async throws {
                try await checkStop()
                let distance = Double(axis == .vertical ? bounds.height : bounds.width) * (tryMethod == .pageKey ? 0.85 : 0.2)
                await driver.scroll(axis, method: tryMethod, points: distance, at: center)
                let frame = try await settledFrame()
                debug.save(frame.cgImage, name: "probe-\(axis)-\(tryMethod)")
                var (motion, joined) = classify(axis, directionFrame ?? base, frame, asked: distance)
                if let directionFrame, case .forward = motion, joined != nil {
                    // The direction probe already moved a little: chain the pictures (start -> after the probe -> now), so the
                    // capture still begins exactly where the user was, however far each scroll turns out to go.
                    var chain = ScrollStitcher(axis: axis)
                    _ = chain.append(base.cgImage, expectedShift: Int(carriedAsk * Double(scale)), bottomMargin: margin(scale))
                    if case .appended = chain.append(directionFrame.cgImage, expectedShift: Int(carriedAsk * Double(scale)), bottomMargin: margin(scale)),
                       case .appended = chain.append(frame.cgImage, expectedShift: Int(distance * Double(scale)), bottomMargin: margin(scale)) {
                        joined = chain
                    } else {
                        joined = nil
                    }
                    carriedAsk = 0
                }
                debug.log("probe \(axis) \(tryMethod): \(motion)")
                if case .forward = motion, let joined {
                    (stitcher, found) = (joined, true)
                    (foundAxis, method, step) = (axis, tryMethod, distance)
                    calibrationAsked = distance
                    base = frame
                } else {
                    base = frame
                }
            }

            for tryAxis in [ScrollStitcher.Axis.vertical, .horizontal] where !found {
                guard let toEnd = try await findDirection(tryAxis) else { continue }
                try await probeForward(tryAxis, method: toEnd)
            }
            if !found {                                                 // some windows only answer the keyboard
                try await probeForward(.vertical, method: .pageKey)
            }
            axis = foundAxis

            guard found else {
                // Nothing we do scrolls this window (it may use its own scrolling): follow the user's own scrolling instead.
                try await followManualScrolling(first: base, scale: scale, session: session, grab: grab, settled: settledFrame,
                                                check: checkStop, debug: debug, stitcher: &stitcher)
                return try finish(stitcher, first: base, scale: scale)
            }

            // Step 4: scroll on, keeping each step to about half a screen so the pictures always overlap well.
            let lengthPx = Double(axis == .vertical ? first.cgImage.height : first.cgImage.width)
            let targetShift = lengthPx * 0.62                       // about 60% of a screen per step still leaves a large overlap
            let adaptive = method != .pageKey
            var gain = max(Double(stitcher.lastShift) / max(calibrationAsked * Double(scale), 1), 0.05)    // pixels moved per point asked
            debug.log("calibrated: asked \(Int(calibrationAsked)) pt, moved \(stitcher.lastShift) px, gain \(String(format: "%.2f", gain))")
            func stepFor(_ gain: Double) -> Double { min(max(targetShift / gain / Double(scale), 8), lengthPx / Double(scale)) }
            if adaptive { step = stepFor(gain) }
            let expected = Int(targetShift)
            var recoveries = 0, stuck = 0, refreshes = 0, slowSteps = 0
            let count0 = stitcher.frameCount, length0 = stitcher.totalHeight
            await MainActor.run { session.update(frames: count0, length: length0, axis: axis) }

            while stitcher.frameCount < Self.maxFrames, stitcher.totalHeight < Self.maxLength {
                try await checkStop()
                let asked = step
                let stepStart = Date()
                await driver.scroll(axis, method: method, points: step, at: center)
                let scrolledAt = Date()
                let frame = try await settledFrame()
                let settledAt = Date()
                try await checkStop()                                   // stopped while waiting: drop this frame
                debug.save(frame.cgImage, name: "frame-\(stitcher.frameCount + 1)")
                let outcome = stitcher.append(frame.cgImage, expectedShift: expected, bottomMargin: margin(scale))
                debug.log("frame \(stitcher.frameCount) -> \(outcome)  [scroll \(Int(scrolledAt.timeIntervalSince(stepStart) * 1000)) ms, settle \(Int(settledAt.timeIntervalSince(scrolledAt) * 1000)) ms, join \(Int(Date().timeIntervalSince(settledAt) * 1000)) ms]")
                switch outcome {
                case .appended:
                    stuck = 0
                    // Two steps in a row that moved far less than asked mean the end of the content is here (it nudges by a few
                    // rows as footers and banners settle), so there is no point in carrying on.
                    slowSteps = adaptive && stitcher.lastShift < Int(targetShift * 0.25) ? slowSteps + 1 : 0
                    if slowSteps >= 2 { return try finish(stitcher, first: first, scale: scale) }
                    base = frame
                    if adaptive {                                       // follow the app's real scroll speed as it changes
                        gain = 0.5 * gain + 0.5 * max(Double(stitcher.lastShift) / max(asked * Double(scale), 1), 0.05)
                        step = stepFor(gain)
                    }
                    let (count, length) = (stitcher.frameCount, stitcher.totalHeight)
                    await MainActor.run { session.update(frames: count, length: length, axis: axis) }
                case .noChange:
                    stuck += 1
                    if stuck >= 2 { return try finish(stitcher, first: first, scale: scale) }     // the end of the content
                case .unmatched:
                    // First suspect: the page was still loading (placeholders, images arriving). Look again at the same spot.
                    var recovered = false
                    for waitSeconds in [0.7, 1.4] {
                        try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000 * pace))
                        try await checkStop()
                        let again = try await settledFrame(minimum: 0.1)
                        if case .appended = stitcher.append(again.cgImage, expectedShift: expected, bottomMargin: margin(scale)) {
                            debug.log("  -> joined after waiting for the page to load")
                            base = again
                            recovered = true
                            break
                        }
                    }
                    if recovered {
                        stuck = 0
                        let (count, length) = (stitcher.frameCount, stitcher.totalHeight)
                        await MainActor.run { session.update(frames: count, length: length, axis: axis) }
                        continue
                    }
                    // Second suspect: the PREVIOUS picture was taken while the page was still loading (placeholders in its lower
                    // part), so the new one cannot match it. Go back, take that position again now that it has loaded, replace it,
                    // and repeat the step.
                    if adaptive, refreshes < 3 {
                        refreshes += 1
                        await driver.scroll(axis, method: ScrollDirectionMemory.opposite(of: method), points: asked, at: center)
                        try? await Task.sleep(nanoseconds: UInt64(500_000_000 * pace))
                        let retaken = try await settledFrame(minimum: 0.3)
                        if stitcher.refreshLast(retaken.cgImage) {
                            debug.log("  -> retook the previous picture after the page loaded")
                            base = retaken
                            continue
                        }
                    }
                    // Otherwise probably scrolled further than the overlap: go back, and take smaller steps.
                    recoveries += 1
                    debug.save(base.cgImage, name: "unmatched-\(recoveries)-prev")
                    debug.save(frame.cgImage, name: "unmatched-\(recoveries)-next")
                    guard adaptive, recoveries <= 3 else {
                        // Say why it stopped: the page rearranged itself in a way that cannot be joined to what came before.
                        await MainActor.run { session.setNotice("The page changed while scrolling, so the capture stopped here") }
                        try? await Task.sleep(nanoseconds: UInt64(1_600_000_000 * pace))
                        return try finish(stitcher, first: first, scale: scale)
                    }
                    await driver.scroll(axis, method: ScrollDirectionMemory.opposite(of: method), points: asked, at: center)
                    _ = try await settledFrame(minimum: 0.25)
                    step = max(asked * 0.5, 8)
                    debug.log("overshoot: retrying with step \(Int(step)) pt")
                }
            }
            return try finish(stitcher, first: first, scale: scale)
        } catch is FinishRequested {
            return try finish(stitcher, first: base, scale: scale)
        }
    }

    /// The stitched picture; if nothing could be joined yet, the one picture of the window that was taken.
    private func finish(_ stitcher: ScrollStitcher, first: CapturedImage, scale: CGFloat) throws -> CapturedImage {
        guard stitcher.frameCount > 0, let stitched = stitcher.result() else { return first }
        return CapturedImage(cgImage: stitched, scale: scale)
    }

    /// Last resort for windows that ignore every way of scrolling them: the user scrolls, and CaptureDeck follows,
    /// adding each new screen as it settles. Ends when the user says so.
    private func followManualScrolling(
        first: CapturedImage, scale: CGFloat, session: ScrollCaptureSession,
        grab: () async throws -> CapturedImage, settled: (TimeInterval) async throws -> CapturedImage,
        check: () async throws -> Void, debug: ScrollDebugDump, stitcher: inout ScrollStitcher
    ) async throws {
        debug.log("auto-scroll did not work: following the user's own scrolling")
        await MainActor.run { session.setManual() }
        stitcher = ScrollStitcher(axis: .vertical)
        _ = stitcher.append(first.cgImage, expectedShift: Int(first.cgImage.height / 2), bottomMargin: Int((22 * scale).rounded()))
        var last = first
        while stitcher.totalHeight < Self.maxLength {
            try await check()
            try? await Task.sleep(nanoseconds: 120_000_000)
            let frame = try await grab()
            guard ScrollStitcher.framesDiffer(last.cgImage, frame.cgImage, sameAbove: 0.97) else { continue }
            let settledFrame = try await settled(0.2)                      // wait for the user's scroll to come to rest
            let outcome = stitcher.append(settledFrame.cgImage, expectedShift: Int(first.cgImage.height / 2), bottomMargin: Int((22 * scale).rounded()))
            debug.log("manual frame -> \(outcome)")
            if case .appended = outcome {
                let (count, length) = (stitcher.frameCount, stitcher.totalHeight)
                await MainActor.run { session.update(frames: count, length: length, axis: .vertical) }
            }
            last = settledFrame
        }
    }
}

/// Developer aid: if the folder ~/Library/Caches/CaptureDeck/scroll-debug exists, every frame seen is saved there as PNG,
/// so alignment problems can be reproduced offline. Does nothing otherwise.
struct ScrollDebugDump {
    private let folder: URL? = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("CaptureDeck/scroll-debug")
        var isDirectory: ObjCBool = false
        guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }()

    func log(_ line: String) {
        guard let folder, let data = (line + "\n").data(using: .utf8) else { return }
        let url = folder.appendingPathComponent("log.txt")
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: url) }
    }

    func save(_ image: CGImage, name: String) {
        guard let folder, let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(name).png") as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Pacing of the waits between scroll steps. Tests shrink it; the app always uses 1.
enum ScrollTiming {
    nonisolated(unsafe) static var scale = 1.0
}
