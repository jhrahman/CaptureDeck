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

/// How fast the automatic scroll glides. The raw value is what Settings stores.
public enum ScrollSpeed: String, CaseIterable, Sendable {
    case verySlow, slow, medium, fast

    public var title: String {
        switch self {
        case .verySlow: "Very slow"
        case .slow: "Slow"
        case .medium: "Medium"
        case .fast: "Fast"
        }
    }

    /// Average speed of a glide.
    var pointsPerSecond: Double {
        switch self {
        case .verySlow: 300
        case .slow: 550
        case .medium: 900
        case .fast: 1800
        }
    }
}

/// One smooth scroll, cut into frames: it eases in, holds its speed and eases out, and the frames add up to exactly the
/// distance asked for.
enum ScrollGlide {
    static let frameInterval = 1.0 / 60

    static func deltas(points: Double, speed: ScrollSpeed) -> [Int32] {
        let count = max(6, Int((abs(points) / speed.pointsPerSecond / frameInterval).rounded()))
        var sent: Int32 = 0
        return (1...count).map { frame in
            let progress = Double(frame) / Double(count)
            let eased = progress - sin(2 * .pi * progress) * 0.12            // gentle start and stop, never quite still
            let total = Int32((points * eased).rounded())
            defer { sent = total }
            return total - sent
        }
    }
}

/// Scrolls a window. A protocol so tests can drive the capture without real events.
public protocol ScrollDriving: Sendable {
    /// Called once before scrolling starts: which window will be scrolled (`bounds` in global display coordinates), how
    /// fast, and how to ask whether the user has stopped the capture, so that a long glide can be cut short.
    func begin(windowID: CGWindowID, bounds: CGRect, speed: ScrollSpeed, isStopped: @escaping @Sendable () async -> Bool) async
    /// Scrolls the content by about `points` toward its end (down, or to the right) at `point` (global display coordinates).
    func scroll(_ axis: ScrollStitcher.Axis, method: ScrollMethod, points: Double, at point: CGPoint) async
}

public extension ScrollDriving {
    func begin(windowID: CGWindowID, bounds: CGRect, speed: ScrollSpeed, isStopped: @escaping @Sendable () async -> Bool) async {}
}

/// Posts smooth, trackpad-like scroll events (or Page Down / arrow keys as a fallback). Needs the Accessibility permission
/// (macOS requires it for synthesising input).
///
/// Wheel events go straight to the app that owns the window, so the mouse pointer stays free: the user can move it to the
/// status panel and press Done or Cancel while the page scrolls. (Events posted into the session instead drag the pointer
/// to the place being scrolled, again with every event.)
public final class EventScrollDriver: ScrollDriving, @unchecked Sendable {
    private struct Session {
        var windowID: CGWindowID = 0
        var pid: pid_t?
        var bounds = CGRect.zero
        var speed = ScrollSpeed.medium
        var isStopped: @Sendable () async -> Bool = { false }
    }

    private let lock = NSLock()
    private var current = Session()

    public init() {}

    public func begin(windowID: CGWindowID, bounds: CGRect, speed: ScrollSpeed, isStopped: @escaping @Sendable () async -> Bool) async {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first
        let session = Session(windowID: windowID, pid: info?[kCGWindowOwnerPID as String] as? pid_t, bounds: bounds, speed: speed, isStopped: isStopped)
        lock.withLock { current = session }
    }

    public func scroll(_ axis: ScrollStitcher.Axis, method: ScrollMethod, points: Double, at point: CGPoint) async {
        switch method {
        case .wheel: await wheel(axis, points: points, at: point)
        case .wheelReversed: await wheel(axis, points: -points, at: point)
        case .pageKey: await key(axis)
        case .homeKey: await homeKey()
        }
    }

    /// macOS has no public call to say where *inside a window* an event happens, and an app ignores a scroll sent straight
    /// to it without that (and without the window number below). Looked up by name, so a macOS without it falls back to
    /// posting into the session.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowLocation.self) }

    /// The number of the window an event is for (what `NSEvent.windowNumber` reads); it has no public name.
    private static let windowNumberField = CGEventField(rawValue: 51)

    private func send(_ event: CGEvent, at point: CGPoint, session: Session) {
        event.location = point
        guard let pid = session.pid, let setWindowLocation = Self.setWindowLocation else {
            event.post(tap: .cgSessionEventTap)         // after the system's natural-scrolling flip, so the direction is as given
            return
        }
        if let field = Self.windowNumberField { event.setIntegerValueField(field, value: Int64(session.windowID)) }
        setWindowLocation(event, CGPoint(x: point.x - session.bounds.minX, y: point.y - session.bounds.minY))
        event.postToPid(pid)
    }

    /// Trackpad-style scrolling: a gesture with a beginning, a middle and an end. Browsers apply gesture scrolls at once
    /// instead of animating them like a mouse wheel click, so the glide is exactly the one drawn here.
    private func wheel(_ axis: ScrollStitcher.Axis, points: Double, at point: CGPoint) async {
        let session = lock.withLock { current }
        let deltas = ScrollGlide.deltas(points: points, speed: session.speed)
        let started = ContinuousClock.now
        for (index, delta) in deltas.enumerated() {
            let stopped = await session.isStopped()
            let vertical: Int32 = axis == .vertical ? -delta : 0         // negative = toward the end of the content
            let horizontal: Int32 = axis == .horizontal ? -delta : 0
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { continue }
            let last = stopped || index == deltas.count - 1
            let phase: Int64 = last ? 4 : (index == 0 ? 1 : 2)                      // ended, began, changed
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            send(event, at: point, session: session)
            if last { break }
            // Paced against the clock, so late wake-ups do not slow the glide down.
            try? await Task.sleep(until: started + .seconds(Double(index + 1) * ScrollGlide.frameInterval), clock: .continuous)
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
