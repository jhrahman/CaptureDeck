import AppKit
import EditorEngine
import Testing
@testable import EditorUI

/// Serialized: the animation tests watch real time, which other tests running alongside would distort.
@MainActor
@Suite(.serialized)
struct ZoomTests {
    /// An editor in a real window, so zooming has a screen scale and a size to work with.
    private func editor() -> (EditorViewController, NSWindow) {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")      // 1400 x 900
        let controller = EditorViewController(document: doc, settings: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false                       // the test owns it; AppKit must not release it a second time
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))          // the controller's view otherwise starts at its minimum size
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    @Test func theSliderIsLogarithmicAndRoundTrips() {
        #expect(abs(ZoomBar.position(forPercent: 5)) < 0.0001)
        #expect(abs(ZoomBar.position(forPercent: 800) - 1) < 0.0001)
        #expect(ZoomBar.position(forPercent: 1) == 0 && ZoomBar.position(forPercent: 5000) == 1)       // beyond the slider: pinned at the ends
        for percent in [10.0, 25, 50, 100, 250, 640] {
            #expect(abs(ZoomBar.percent(forPosition: ZoomBar.position(forPercent: percent)) - percent) < 0.01)
        }
        // 100% sits well past the middle of the slider on this scale, so zooming out has room to move.
        #expect(ZoomBar.position(forPercent: 100) > 0.5 && ZoomBar.position(forPercent: 100) < 0.8)
    }

    @Test func zoomingToAPercentageSetsExactlyThat() {
        let (controller, window) = editor()
        defer { window.close() }
        controller.scrollView.zoom(toPercent: 200, animated: false)
        #expect(abs(controller.scrollView.zoomPercent - 200) < 0.5)
        controller.scrollView.zoom(toPercent: 37, animated: false)
        #expect(abs(controller.scrollView.zoomPercent - 37) < 0.5)
    }

    @Test func thePointUnderTheCursorStaysPutWhileZooming() {
        let (controller, window) = editor()
        defer { window.close() }
        let scroll = controller.scrollView
        scroll.zoom(toPercent: 300, animated: false)                                // zoomed in, so the picture is larger than the view
        let clip = scroll.contentView
        let anchor = NSPoint(x: 900, y: 300)                                         // a point of the picture
        func fraction() -> NSPoint { NSPoint(x: (anchor.x - clip.bounds.minX) / clip.bounds.width, y: (anchor.y - clip.bounds.minY) / clip.bounds.height) }
        // Bring the anchor into view first, wherever the layout put it.
        clip.scroll(to: NSPoint(x: anchor.x - clip.bounds.width / 2, y: anchor.y - clip.bounds.height / 2))
        scroll.reflectScrolledClipView(clip)
        let before = fraction()
        scroll.zoom(by: 1.4, around: anchor, animated: false)
        let after = fraction()
        #expect(abs(before.x - after.x) < 0.03 && abs(before.y - after.y) < 0.03, "\(before) -> \(after)")
    }

    @Test func theEasingGlidesAndSettlesGently() {
        let start: CGFloat = 0.5, goal: CGFloat = 2
        #expect(ZoomScrollView.eased(start: start, goal: goal, progress: 0) == start)
        #expect(abs(ZoomScrollView.eased(start: start, goal: goal, progress: 1) - goal) < 0.0001)
        let samples = (0...20).map { ZoomScrollView.eased(start: start, goal: goal, progress: Double($0) / 20) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1 > $0 })                    // always moving toward the goal
        // Quick at first, gentle at the end: the first step is larger than the last.
        #expect(samples[1] - samples[0] > samples[20] - samples[19])
        // Even in proportion: halfway through the time is well past the arithmetic middle of the two levels.
        #expect(ZoomScrollView.eased(start: start, goal: goal, progress: 0.5) > 1.0)
    }

    @Test func aZoomRequestStartsAGlideThatEndsExactlyOnTarget() async throws {
        let (controller, window) = editor()
        defer { window.close() }
        let scroll = controller.scrollView
        scroll.zoom(toPercent: 100, animated: false)
        #expect(!scroll.isAnimating)
        scroll.zoom(toPercent: 400)                                                  // eased
        #expect(scroll.isAnimating)
        for _ in 0..<200 where scroll.isAnimating { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!scroll.isAnimating)
        #expect(abs(scroll.zoomPercent - 400) < 0.5)
    }

    @Test func aNewZoomRequestTakesOverFromOneInProgress() async throws {
        let (controller, window) = editor()
        defer { window.close() }
        let scroll = controller.scrollView
        scroll.zoom(toPercent: 100, animated: false)
        scroll.zoom(toPercent: 800)
        try await Task.sleep(nanoseconds: 40_000_000)
        scroll.zoom(toPercent: 50)                                                   // changes its mind
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(abs(scroll.zoomPercent - 50) < 0.5)
    }

    @Test func theBarFollowsTheZoomAndTheMenuActionsWork() async throws {
        let (controller, window) = editor()
        defer { window.close() }
        _ = controller.view
        controller.scrollView.zoom(toPercent: 160, animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        // The status text no longer repeats the zoom: it lives in the control.
        func labels(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels) }
        let text = labels(controller.view).joined(separator: " | ")
        #expect(text.contains("1400 × 900 px"))
        #expect(!text.contains("Zoom 160"))
    }
}

@MainActor
struct ZoomBarSnapshotTests {
    @Test func bottomLeftControl() throws {
        let doc = EditorDocument(original: UXSnapshotTests.sampleImage(), title: "t")
        let controller = EditorViewController(document: doc, settings: nil)
        _ = controller.view
        try UXSnapshotTests.render(controller, width: 1000, height: 520, dark: true, name: "zoom-bar-dark")
        try UXSnapshotTests.render(controller, width: 1000, height: 520, dark: false, name: "zoom-bar-light")
    }
}
