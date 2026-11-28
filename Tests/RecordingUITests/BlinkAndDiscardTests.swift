import AppKit
import Testing
@testable import RecordingUI

struct BlinkTimingTests {
    private let smooth = RecordingBlink(style: .smooth, period: 1.4)

    @Test func itStartsFullyLitDimsAndRepeats() {
        #expect(smooth.opacity(at: 0) == 1)
        #expect(abs(smooth.opacity(at: 0.7) - RecordingBlink.dimmest) < 0.001)
        #expect(abs(smooth.opacity(at: 140) - 1) < 0.001)
        #expect(RecordingBlink.dimmest > 0.1)                                // it never disappears
    }

    /// "Smooth" means no jumps, from one sample of the animation to the next and where it wraps round.
    @Test(arguments: [2.2, 1.4, 0.9])
    func theSmoothFadeHasNoJumps(_ period: Double) throws {
        let animation = RecordingBlink(style: .smooth, period: period).animation()
        let values = try #require(animation.values as? [Double])
        #expect(zip(values, values.dropFirst()).map { abs($0 - $1) }.max()! < 0.1)
        #expect(values.first == values.last)
        #expect(values.min()! < 0.2 && values.max()! == 1)
        #expect(animation.duration == period && animation.repeatCount == .infinity)
    }

    @Test func classicBlinkHasOnlyTwoStates() throws {
        let blink = RecordingBlink(style: .onOff, period: 1)
        #expect(Set((0..<90).map { blink.opacity(at: Double($0) / 30) }) == [1, RecordingBlink.dimmest])
        #expect(blink.animation().calculationMode == .discrete)
        #expect((blink.animation().values as? [Double]) == [1, RecordingBlink.dimmest])
    }
}

@MainActor
struct BlinkDrawingTests {
    private func pixels(_ image: NSImage, scale: Int) -> [[Int]] {
        let side = 18 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<side * side).map { index in
            var value = [Int](repeating: 0, count: 4)
            rep.getPixel(&value, atX: index % side, y: index / side)
            return value
        }
    }

    /// The real brand artwork, from the repository.
    private func artwork() throws -> NSImage {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../CaptureDeck-brand-assets/menubar")
        let image = try #require(NSImage(contentsOf: folder.appendingPathComponent("MenuBarRecordingDark@2x.png")))
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @Test(arguments: [1, 2])
    func onlyTheDotIsRemovedFromTheArtwork(_ scale: Int) throws {
        let base = try artwork()
        let original = pixels(base, scale: scale), hollow = pixels(RecordingBlink.withoutDot(base), scale: scale)
        let side = 18 * scale
        for index in original.indices where original[index] != hollow[index] {
            let x = (Double(index % side) + 0.5) / Double(scale), y = (Double(index / side) + 0.5) / Double(scale)
            #expect(hypot(x - 9, y - 9) < 2.6, "a pixel outside the dot changed at \(x),\(y)")
        }
        let middle = side / 2 * side + side / 2
        #expect(original[middle][3] > 240 && hollow[middle][3] < 10, "the dot is still there")
    }

    @Test func theDotSitsInTheMiddleOfTheIconAlsoWithTheTimeBesideIt() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        button.isBordered = false
        button.imagePosition = .imageOnly
        let dot = MenuBarBlinkingDot()
        let blink = RecordingBlink(style: .smooth, period: 1.4)
        dot.show(blink, base: try artwork(), key: "dark", on: button)
        func iconMiddle() -> CGPoint {
            let rect = (button.cell as! NSButtonCell).imageRect(forBounds: button.bounds)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func dotMiddle() -> CGPoint { CGPoint(x: dot.dotFrame!.midX, y: dot.dotFrame!.midY) }
        #expect(dot.isRunning && dotMiddle() == iconMiddle())
        let alone = dotMiddle()
        button.imagePosition = .imageLeading
        button.title = " 00:12"
        button.frame.size.width = 80
        dot.show(blink, base: try artwork(), key: "dark", on: button)        // the same again only re-places it
        #expect(dotMiddle() == iconMiddle() && dotMiddle() != alone)
        dot.stop()
        #expect(!dot.isRunning)
    }
}

@MainActor
struct DiscardConfirmationTests {
    private func model(confirm: Bool) -> (RecordingControlsModel, () -> (discards: Int, restarts: Int)) {
        let model = RecordingControlsModel()
        model.style.confirmsDiscard = confirm
        let counter = Counter()
        model.onDiscard = { counter.discards += 1 }
        model.onRestart = { counter.restarts += 1 }
        return (model, { (counter.discards, counter.restarts) })
    }
    private final class Counter { var discards = 0, restarts = 0 }

    @Test func aSingleClickOnlyAsks() {
        let (model, count) = model(confirm: true)
        model.discardPressed()
        #expect(model.confirmingDiscard && count().discards == 0)
        model.discardPressed()
        #expect(!model.confirmingDiscard && count().discards == 1)
    }

    @Test func onlyOneQuestionIsOpenAtATime() {
        let (model, count) = model(confirm: true)
        model.discardPressed()
        model.restartPressed()
        #expect(model.confirmingRestart && !model.confirmingDiscard)
        model.discardPressed()                                               // asks again rather than discarding
        #expect(count() == (0, 0))
    }

    @Test func withConfirmationOffOneClickDoesIt() {
        let (model, count) = model(confirm: false)
        model.discardPressed()
        model.restartPressed()
        #expect(count() == (1, 1))
    }
}
