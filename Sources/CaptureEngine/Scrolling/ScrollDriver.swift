import AppKit
import CoreGraphics
import Foundation

/// How the window is scrolled.
public enum ScrollMethod: Sendable {
    /// Mouse wheel toward the end of the content.
    case wheel
    /// Mouse wheel the other way round: some setups (natural scrolling) flip synthetic wheel events, so both are tried.
    case wheelReversed
    case pageKey
    /// The Home key: jumps to the start of the content in browsers and most documents.
    case homeKey
}

/// Scrolls whatever window is under a point. A protocol so tests can drive the capture without real events.
public protocol ScrollDriving: Sendable {
    /// Called once before scrolling starts: moves the pointer to `point`, away from the page being captured, so it causes no
    /// hover effects. (Scroll events carry their own location, so the pointer does not need to be over the page.)
    func begin(parkingPointerAt point: CGPoint) async
    /// Called once when finished: puts the pointer back where the user left it.
    func end() async
    /// Scrolls the content by about `points` toward its end (down, or to the right) at `point` (global display coordinates).
    func scroll(_ axis: ScrollStitcher.Axis, method: ScrollMethod, points: Double, at point: CGPoint) async
}

public extension ScrollDriving {
    func begin(parkingPointerAt point: CGPoint) async {}
    func end() async {}
}

/// Posts smooth, wheel-like scroll events (or Page Down / arrow keys as a fallback). Needs the Accessibility permission
/// (macOS requires it for synthesising input).
public final class EventScrollDriver: ScrollDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var original: CGPoint?

    private func swapOriginal(_ new: CGPoint?) -> CGPoint? {
        lock.withLock { let old = original; original = new; return old }
    }

    public init() {}

    public func begin(parkingPointerAt point: CGPoint) async {
        _ = swapOriginal(CGEvent(source: nil)?.location)
        if point != .zero { warp(to: point) }
    }

    public func end() async {
        if let back = swapOriginal(nil) { warp(to: back) }
    }

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)           // keep the pointer responsive right after the jump
    }

    public func scroll(_ axis: ScrollStitcher.Axis, method: ScrollMethod, points: Double, at point: CGPoint) async {
        switch method {
        case .wheel: await wheel(axis, points: points, at: point)
        case .wheelReversed: await wheel(axis, points: -points, at: point)
        case .pageKey: await key(axis)
        case .homeKey: await homeKey()
        }
    }

    /// Trackpad-style scrolling: a gesture with a beginning, a middle and an end. Browsers apply gesture scrolls at once
    /// instead of animating them like a mouse wheel click, which makes each step quicker and its distance more predictable.
    private func wheel(_ axis: ScrollStitcher.Axis, points: Double, at point: CGPoint) async {
        let steps = 6
        let each = Int32((points / Double(steps)).rounded())
        for index in 0..<steps {
            let vertical: Int32 = axis == .vertical ? -each : 0         // negative = toward the end of the content
            let horizontal: Int32 = axis == .horizontal ? -each : 0
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { continue }
            event.location = point
            let phase: Int64 = index == 0 ? 1 : (index == steps - 1 ? 4 : 2)         // began, changed, ended
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.post(tap: .cgSessionEventTap)         // after the system's natural-scrolling flip, so the direction is as given
            try? await Task.sleep(nanoseconds: 14_000_000)
        }
    }

    private func homeKey() async {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x73, keyDown: down)
            event?.setIntegerValueField(.eventSourceUserData, value: StopEventTap.syntheticMarker)
            event?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 40_000_000)                  // apps ignore a key that is released instantly
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    /// Page Down (or Right Arrow x several for sideways): works in browsers and most documents that ignore synthetic wheels.
    private func key(_ axis: ScrollStitcher.Axis) async {
        let code: CGKeyCode = axis == .vertical ? 0x79 : 0x7C           // Page Down / Right Arrow
        let presses = axis == .vertical ? 1 : 12
        for _ in 0..<presses {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.setIntegerValueField(.eventSourceUserData, value: StopEventTap.syntheticMarker)
                event?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
