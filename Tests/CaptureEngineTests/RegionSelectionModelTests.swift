import CoreGraphics
import Testing
@testable import CaptureEngine

struct RegionSelectionModelTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func dragProducesNormalizedRectInAnyDirection() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 300, y: 200))
        m.drag(to: CGPoint(x: 100, y: 50))   // up and to the left
        #expect(m.selection == CGRect(x: 100, y: 50, width: 200, height: 150))
        #expect(m.end(at: CGPoint(x: 100, y: 50)) == CGRect(x: 100, y: 50, width: 200, height: 150))
        #expect(m.phase == .idle)
    }

    @Test func selectionIsClampedToDisplay() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 900, y: 500))
        let r = m.end(at: CGPoint(x: 5000, y: -300))
        #expect(r == CGRect(x: 900, y: 0, width: 100, height: 500))
    }

    @Test func clickWithoutDragIsNotASelection() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 10, y: 10))
        #expect(m.end(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(m.phase == .idle)
    }

    @Test func fractionalPointsRoundOutToWholePoints() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 10.4, y: 10.4))
        let r = m.end(at: CGPoint(x: 20.6, y: 20.6))
        #expect(r == CGRect(x: 10, y: 10, width: 11, height: 11))
    }

    @Test func tabSwitchesWhichCornerFollowsTheMouse() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 100, y: 100))
        m.drag(to: CGPoint(x: 200, y: 180))
        m.switchCorner()                        // now (200,180) is fixed, (100,100) follows
        m.drag(to: CGPoint(x: 50, y: 60))
        #expect(m.selection == CGRect(x: 50, y: 60, width: 150, height: 120))
    }

    @Test func arrowNudgesSurviveSubsequentMouseMoves() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 100, y: 100))
        m.drag(to: CGPoint(x: 200, y: 200))
        m.nudge(dx: 1, dy: 0)
        #expect(m.selection == CGRect(x: 100, y: 100, width: 101, height: 100))
        m.drag(to: CGPoint(x: 200, y: 200))     // mouse reports the same spot
        #expect(m.selection == CGRect(x: 100, y: 100, width: 101, height: 100))
    }

    @Test func returnConfirmsCurrentSelection() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 0, y: 0))
        m.drag(to: CGPoint(x: 40, y: 30))
        #expect(m.confirm() == CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    @Test func resetReturnsToIdle() {
        var m = RegionSelectionModel(bounds: bounds)
        m.begin(at: CGPoint(x: 5, y: 5))
        m.reset()
        #expect(m.selection == nil)
        #expect(m.confirm() == nil)
    }
}
